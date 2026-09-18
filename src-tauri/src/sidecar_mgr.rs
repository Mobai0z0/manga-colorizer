//! Sidecar process manager: spawn bundled python service, health-watch, restart with dialog.
use std::fs::OpenOptions;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager};

pub static CHILD: Mutex<Option<Child>> = Mutex::new(None);
pub const PORT: u16 = 8788;

#[derive(Clone, serde::Serialize)]
pub struct SidecarStatus {
    pub state: String, // starting | ready | exited | missing | restarting
    pub code: Option<i32>,
    pub message: Option<String>,
}

fn exe_dir() -> Option<PathBuf> {
    std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf()))
}

pub fn sidecar_exe() -> Option<PathBuf> {
    let name = "manga-colorizer-sidecar.exe";
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(d) = exe_dir() {
        candidates.push(d.join(name));
        candidates.push(d.join("binaries").join(name));
    }
    // dev fallback: target-triple-suffixed build output
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let triples = [
            "x86_64-pc-windows-msvc",
            "x86_64-pc-windows-gnu",
        ];
        for t in triples {
            candidates.push(
                PathBuf::from(&manifest_dir)
                    .join("target")
                    .join("debug")
                    .join(format!("manga-colorizer-sidecar-{t}.exe")),
            );
            candidates.push(
                PathBuf::from(&manifest_dir)
                    .join("binaries")
                    .join(format!("manga-colorizer-sidecar-{t}.exe")),
            );
        }
        candidates.push(PathBuf::from(&manifest_dir).join("binaries").join(name));
    }
    candidates.into_iter().find(|p| p.is_file())
}

pub fn log_path() -> PathBuf {
    crate::downloader::app_data_dir().join("logs").join("sidecar.log")
}

pub fn health_ok(port: u16) -> bool {
    let url = format!("http://127.0.0.1:{port}/health");
    if let Ok(client) = reqwest::blocking::Client::builder()
        .timeout(Duration::from_millis(900))
        .build()
    {
        return client.get(&url).send().map(|r| r.status().is_success()).unwrap_or(false);
    }
    false
}

fn model_dir_env() -> Option<PathBuf> {
    // dev: repo ./models (compile-time path); packaged: LOCALAPPDATA weights dir
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(|p| p.join("models").join("manga-light-colorizer"));
    if dev.as_ref().map(|d| d.is_dir()).unwrap_or(false) {
        return dev;
    }
    Some(crate::downloader::app_data_dir().join("weights").join("manga-light-colorizer"))
}

fn web_dist_env() -> Option<PathBuf> {
    // dev: repo web/dist (compile-time path); packaged: sidecar bundles its own web-dist
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(|p| p.join("web").join("dist"));
    if dev.as_ref().map(|d| d.is_dir()).unwrap_or(false) {
        return dev;
    }
    None
}

pub fn spawn(app: &AppHandle) -> Result<(), String> {
    let exe = sidecar_exe().ok_or_else(|| {
        "服务组件缺失（sidecar 未找到），请重新安装应用".to_string()
    })?;

    // If a previous sidecar still serves the port, reuse it (e.g. app restarted).
    if health_ok(PORT) {
        let _ = app.emit("sidecar-status", SidecarStatus {
            state: "ready".into(), code: None, message: Some("检测到已有服务在运行，直接复用".into()),
        });
        return Ok(());
    }

    let mut cmd = Command::new(&exe);
    cmd.arg("--port").arg(PORT.to_string());
    if let Some(m) = model_dir_env() {
        cmd.env("COLORIZER_MODEL_DIR", &m);
    }
    if let Some(w) = web_dist_env() {
        cmd.env("COLORIZER_WEB_DIST", &w);
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    // route sidecar output to a log file for handoff debugging
    let _ = std::fs::create_dir_all(log_path().parent().unwrap());
    let log = OpenOptions::new().create(true).append(true).open(&log_path());
    match log {
        Ok(f) => {
            cmd.stdout(Stdio::from(f.try_clone().expect("log clone")));
            cmd.stderr(Stdio::from(f));
        }
        Err(_) => {
            cmd.stdout(Stdio::null());
            cmd.stderr(Stdio::null());
        }
    }

    match cmd.spawn() {
        Ok(child) => {
            *CHILD.lock().unwrap() = Some(child);
            let _ = app.emit("sidecar-status", SidecarStatus {
                state: "starting".into(), code: None, message: Some(exe.display().to_string()),
            });
            Ok(())
        }
        Err(e) => Err(format!("拉起上色服务失败: {e}")),
    }
}

pub fn kill() {
    if let Some(mut c) = CHILD.lock().unwrap().take() {
        let _ = c.kill();
        let _ = c.wait();
    }
}

/// Watchdog: wait until healthy, then monitor child exit for the app lifetime.
pub fn watch(app: AppHandle) {
    thread::spawn(move || {
        // phase 1: wait for readiness up to 60s
        let mut ready = false;
        for _ in 0..120 {
            if health_ok(PORT) {
                ready = true;
                break;
            }
            {
                let mut guard = CHILD.lock().unwrap();
                if let Some(c) = guard.as_mut() {
                    if let Ok(Some(status)) = c.try_wait() {
                        guard.take();
                        let _ = app.emit("sidecar-status", SidecarStatus {
                            state: "exited".into(), code: status.code(),
                            message: Some("上色服务在启动阶段退出".into()),
                        });
                        prompt_after_exit(app);
                        return;
                    }
                }
            }
            thread::sleep(Duration::from_millis(500));
        }

        let _ = app.emit("sidecar-status", SidecarStatus {
            state: if ready { "ready".into() } else { "exited".into() },
            code: None,
            message: if ready { None } else { Some("服务健康检查超时".into()) },
        });

        if !ready {
            prompt_after_exit(app);
            return;
        }

        // phase 2: lifetime watchdog
        loop {
            thread::sleep(Duration::from_secs(2));
            {
                let mut guard = CHILD.lock().unwrap();
                if let Some(c) = guard.as_mut() {
                    if let Ok(Some(status)) = c.try_wait() {
                        guard.take();
                        let _ = app.emit("sidecar-status", SidecarStatus {
                            state: "exited".into(), code: status.code(),
                            message: Some("上色服务已退出，正在处理".into()),
                        });
                        drop(guard);
                        prompt_after_exit(app);
                        return;
                    }
                }
            }
        }
    });
}

/// Show a blocking dialog after unexpected sidecar exit; restart or quit.
fn prompt_after_exit(app: AppHandle) {
    use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
    let _ = app.emit("sidecar-status", SidecarStatus {
        state: "restarting".into(), code: None, message: None,
    });
    let choice = app
        .dialog()
        .message("上色服务已异常退出。\n\n选择「确定」重启服务并恢复界面，选择「取消」退出应用。\n详细日志见应用数据目录 logs/sidecar.log")
        .title("Manga Colorizer")
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom("重启服务".into(), "退出应用".into()))
        .blocking_show();

    if choice {
        match spawn(&app) {
            Ok(()) => {
                watch(app.clone());
                // wait for health then reload window
                thread::spawn(move || {
                    for _ in 0..120 {
                        if health_ok(PORT) {
                            break;
                        }
                        thread::sleep(Duration::from_millis(500));
                    }
                    if let Some(win) = app.get_webview_window("main") {
                        let _ = win.eval("window.location.reload()");
                        let _ = win.show();
                        let _ = win.set_focus();
                    }
                    let _ = app.emit("sidecar-status", SidecarStatus {
                        state: "ready".into(), code: None, message: None,
                    });
                });
            }
            Err(e) => {
                let _ = app.emit("sidecar-status", SidecarStatus {
                    state: "missing".into(), code: None, message: Some(e),
                });
                app.exit(1);
            }
        }
    } else {
        app.exit(0);
    }
}

