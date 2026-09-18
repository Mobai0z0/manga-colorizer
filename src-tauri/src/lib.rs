//! Manga Colorizer desktop shell: window lifecycle + weight download + sidecar supervision.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod downloader;
mod sidecar_mgr;

use std::path::PathBuf;
use std::sync::Mutex as StdMutex;
use std::thread;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Url};

use downloader::{DownloadEvent, Manifest, WeightsStatus};
use sidecar_mgr::SidecarStatus;

pub struct AppState {
    manifest: Option<Manifest>,
    manifest_error: Option<String>,
    downloading: StdMutex<bool>,
}

#[derive(Clone, Serialize)]
struct UiProgress {
    phase: String,   // idle | downloading | verifying | done | failed
    currentFile: String,
    fileBytesDone: u64,
    fileBytesTotal: u64,
    totalBytesDone: u64,
    totalBytes: u64,
    message: Option<String>,
    resumedFrom: u64,
}

fn total_of(m: &Option<Manifest>) -> (u64, u64) {
    match m {
        Some(m) => {
            let total: u64 = m.files.iter().map(|f| f.size).sum();
            (total, m.files.len() as u64)
        }
        None => (0, 0),
    }
}

fn weights_status(state: &AppState) -> WeightsStatus {
    match &state.manifest {
        Some(m) => downloader::status(m),
        None => WeightsStatus {
            dir: downloader::app_data_dir(),
            manifestVersion: "unknown".into(),
            allReady: false,
            totalBytes: 0,
            doneBytes: 0,
            files: vec![],
        },
    }
}

fn weights_ready(state: &AppState) -> bool {
    match &state.manifest {
        Some(m) => downloader::status(m).allReady,
        None => false,
    }
}

#[tauri::command]
fn cmd_weights_status(state: tauri::State<AppState>) -> WeightsStatus {
    weights_status(&state)
}

#[tauri::command]
fn cmd_weights_dir(state: tauri::State<AppState>) -> String {
    weights_status(&state).dir.display().to_string()
}

#[tauri::command]
fn cmd_ledger(state: tauri::State<AppState>) -> Vec<serde_json::Value> {
    match &state.manifest {
        Some(m) => downloader::read_ledger(m),
        None => vec![],
    }
}

#[tauri::command]
fn cmd_delete_weights(app: AppHandle, state: tauri::State<AppState>) -> Result<u64, String> {
    let m = state.manifest.as_ref().ok_or("清单未加载")?;
    let freed = downloader::delete_all(m)?;
    let _ = app.emit("weights-status", weights_status(&state));
    Ok(freed)
}

#[tauri::command]
fn cmd_open_weights_dir(state: tauri::State<AppState>) -> Result<(), String> {
    let dir = weights_status(&state).dir;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    opener::open(&dir)
}

#[tauri::command]
fn cmd_sidecar_status() -> SidecarStatus {
    SidecarStatus { state: "starting".into(), code: None, message: None }
}

#[tauri::command]
fn cmd_sidecar_log_path() -> String {
    sidecar_mgr::log_path().display().to_string()
}

#[tauri::command]
fn cmd_service_port() -> u16 {
    sidecar_mgr::PORT
}

mod opener {
    pub fn open(path: &std::path::Path) -> Result<(), String> {
        #[cfg(target_os = "windows")]
        {
            std::process::Command::new("explorer")
                .arg(path)
                .spawn()
                .map_err(|e| e.to_string())?;
            Ok(())
        }
        #[cfg(not(target_os = "windows"))]
        {
            std::process::Command::new("xdg-open")
                .arg(path)
                .spawn()
                .map_err(|e| e.to_string())?;
            Ok(())
        }
    }
}

#[tauri::command]
fn cmd_start_download(app: AppHandle, state: tauri::State<AppState>) -> Result<bool, String> {
    let already = *state.downloading.lock().unwrap();
    if already {
        return Ok(false);
    }
    let manifest = state.manifest.clone().ok_or_else(|| {
        state.manifest_error.clone().unwrap_or_else(|| "权重清单未加载".into())
    })?;
    *state.downloading.lock().unwrap() = true;
    let app2 = app.clone();

    thread::spawn(move || {
        let _ = app2.emit("download-progress", UiProgress {
            phase: "downloading".into(),
            currentFile: String::new(),
            fileBytesDone: 0,
            fileBytesTotal: 0,
            totalBytesDone: 0,
            totalBytes: manifest.files.iter().map(|f| f.size).sum(),
            message: None,
            resumedFrom: 0,
        });

        let manifest_total: u64 = manifest.files.iter().map(|f| f.size).sum();
        let mut aborted = false;
        let mut last_err: Option<String> = None;
        let files_total = manifest.files.len();
        let mut completed_bytes: u64 = 0;

        for (idx, entry) in manifest.files.iter().enumerate() {
            let mut use_mirror = false;
            let mut attempt = 0;
            loop {
                attempt += 1;
                let app_ev = app2.clone();
                let entry_clone = entry.clone();
                let manifest_clone = manifest.clone();
                let idx_done = completed_bytes;
                let res = std::thread::spawn(move || {
                    downloader::download_one(&manifest_clone, &entry_clone, use_mirror, move |ev: DownloadEvent| {
                        let _ = app_ev.emit("download-progress", UiProgress {
                            phase: ev.phase.clone(),
                            currentFile: ev.name.clone(),
                            fileBytesDone: ev.bytesDone,
                            fileBytesTotal: ev.totalBytes,
                            totalBytesDone: idx_done + ev.bytesDone,
                            totalBytes: manifest_total,
                            message: ev.error.clone(),
                            resumedFrom: ev.resumedFrom,
                        });
                    })
                });
                match res.join() {
                    Ok(Ok(_)) => {
                        completed_bytes += entry.size;
                        break;
                    }
                    Ok(Err(e)) => {
                        last_err = Some(e.clone());
                        // one retry on primary, then one via mirror, then give up (keep partials)
                        if attempt == 1 && !use_mirror {
                            use_mirror = true;
                            continue;
                        }
                        aborted = true;
                        break;
                    }
                    Err(_) => {
                        last_err = Some("下载线程异常崩溃".into());
                        if attempt == 1 && !use_mirror {
                            use_mirror = true;
                            continue;
                        }
                        aborted = true;
                        break;
                    }
                }
            }
            let _ = idx;
            let _ = files_total;
            if aborted {
                break;
            }
        }

        {
            let st = app2.state::<AppState>();
            *st.downloading.lock().unwrap() = false;
        }
        let st = {
            let state_any = app2.state::<AppState>();
            weights_status(&state_any)
        };

        if aborted {
            let _ = app2.emit("download-progress", UiProgress {
                phase: "failed".into(),
                currentFile: last_err.clone().unwrap_or_default(),
                fileBytesDone: 0,
                fileBytesTotal: 0,
                totalBytesDone: st.doneBytes,
                totalBytes: st.totalBytes,
                message: last_err,
                resumedFrom: 0,
            });
        } else {
            let _ = app2.emit("download-progress", UiProgress {
                phase: "done".into(),
                currentFile: String::new(),
                fileBytesDone: 0,
                fileBytesTotal: 0,
                totalBytesDone: st.totalBytes,
                totalBytes: st.totalBytes,
                message: None,
                resumedFrom: 0,
            });
            // weights ready -> (re)start sidecar now
            let _ = app2.emit("weights-status", st);
            let _ = sidecar_mgr::spawn(&app2);
            sidecar_mgr::watch(app2.clone());
            reload_main_window(&app2);
        }
    });

    Ok(true)
}



fn reload_main_window(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let url = Url::parse(&format!("http://127.0.0.1:{}/", sidecar_mgr::PORT)).expect("service url");
        let _ = win.navigate(url);
        let _ = win.show();
        let _ = win.set_focus();
    }
}

fn preload_status(app: &AppHandle) {
    let _ = app.emit("download-progress", UiProgress {
        phase: "idle".into(),
        currentFile: String::new(),
        fileBytesDone: 0,
        fileBytesTotal: 0,
        totalBytesDone: 0,
        totalBytes: 0,
        message: None,
        resumedFrom: 0,
    });
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // 1) load manifest from resource dir (dev: repo path)
            let manifest_path: PathBuf = {
                let res = app.path().resource_dir().map_err(|e| e.to_string())?;
                let p = res.join("resources").join("weights-manifest.json");
                if p.is_file() {
                    p
                } else {
                    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources").join("weights-manifest.json")
                }
            };
            let (manifest, manifest_error) = if manifest_path.is_file() {
                match downloader::load_manifest(&manifest_path) {
                    Ok(m) => (Some(m), None),
                    Err(e) => (None, Some(e)),
                }
            } else {
                (None, Some(format!("权重清单缺失: {}", manifest_path.display())))
            };

            app.manage(AppState {
                manifest,
                manifest_error,
                downloading: StdMutex::new(false),
            });

            let handle = app.handle().clone();
            preload_status(&handle);

            // 2) weights ready?
            let ready = {
                let st = handle.state::<AppState>();
                weights_ready(&st)
            };

            if !ready {
                // stay on the bundled shell page; frontend will show downloader UI
                let _ = handle.emit("boot-stage", "need-weights");
            } else {
                let _ = handle.emit("boot-stage", "starting-service");
                let h2 = handle.clone();
                thread::spawn(move || {
                    if let Err(e) = sidecar_mgr::spawn(&h2) {
                        let _ = h2.emit("sidecar-status", SidecarStatus {
                            state: "missing".into(), code: None, message: Some(e),
                        });
                    }
                    sidecar_mgr::watch(h2.clone());
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            cmd_weights_status,
            cmd_weights_dir,
            cmd_ledger,
            cmd_delete_weights,
            cmd_open_weights_dir,
            cmd_start_download,
            cmd_sidecar_status,
            cmd_sidecar_log_path,
            cmd_service_port
        ])
        .on_page_load(|webview, payload| {
            if let tauri::webview::PageLoadEvent::Started = payload.event() {
                let _ = webview;
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                sidecar_mgr::kill();
            }
            let _ = app;
        });
}



