//! Weight downloader: resumable HTTP Range downloads + sha256 verify + ledger.
//!
//! Design:
//! - weights dir: %LOCALAPPDATA%/manga-colorizer/weights/<baseDir>
//! - partial file: <name>.part ; final: <name>
//! - ledger.jsonl appended per attempt; download-state.json for resume cursor
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Debug, Deserialize, Clone)]
pub struct Manifest {
    pub schemaVersion: u32,
    pub version: String,
    #[serde(rename = "baseDir")]
    pub base_dir: String,
    #[serde(rename = "updatedAt")]
    pub updated_at: String,
    pub files: Vec<ManifestEntry>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct ManifestEntry {
    pub name: String,
    pub size: u64,
    pub sha256: String,
    #[serde(rename = "pathTemplate")]
    pub path_template: String,
    #[serde(rename = "mirrorPathTemplate", default)]
    pub mirror_path_template: Option<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct WeightStatus {
    pub name: String,
    pub size: u64,
    pub sha256: String,
    pub present: bool,
    pub partial_bytes: u64,
    pub verified: bool,
    pub verifyError: Option<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct WeightsStatus {
    pub dir: PathBuf,
    pub manifestVersion: String,
    pub allReady: bool,
    pub totalBytes: u64,
    pub doneBytes: u64,
    pub files: Vec<WeightStatus>,
}

#[derive(Debug, Serialize, Clone)]
pub struct DownloadEvent {
    pub name: String,
    pub bytesDone: u64,
    pub totalBytes: u64,
    pub phase: String, // downloading | verifying | done | failed
    pub error: Option<String>,
    pub resumedFrom: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct ResumeState {
    #[serde(rename = "lastIntentSha256", default)]
    last_intent_sha256: String,
    #[serde(rename = "updatedAtMs", default)]
    updated_at_ms: u128,
}

pub fn app_data_dir() -> PathBuf {
    let base = dirs::data_local_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("manga-colorizer")
}

pub fn weights_dir(manifest: &Manifest) -> PathBuf {
    app_data_dir().join("weights").join(&manifest.base_dir)
}

pub fn manifest_resource_path() -> Result<PathBuf, String> {
    // resolved by Tauri at build time into the resource dir; dev fallback:
    Ok(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources/weights-manifest.json"))
}

pub fn load_manifest(path: &Path) -> Result<Manifest, String> {
    let raw = fs::read_to_string(path).map_err(|e| format!("read manifest: {e}"))?;
    let m: Manifest = serde_json::from_str(&raw).map_err(|e| format!("parse manifest: {e}"))?;
    if m.schemaVersion != 1 {
        return Err(format!("unsupported manifest schemaVersion {}", m.schemaVersion));
    }
    for f in &m.files {
        if f.sha256.len() != 64 || hex::decode(&f.sha256).is_err() {
            return Err(format!("bad sha256 for {}", f.name));
        }
    }
    Ok(m)
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut f = fs::File::open(path).map_err(|e| format!("open for hash: {e}"))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf).map_err(|e| format!("read for hash: {e}"))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex::encode(h.finalize()))
}

fn file_size(path: &Path) -> u64 {
    fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// Check current on-disk status for every manifest entry.
pub fn status(manifest: &Manifest) -> WeightsStatus {
    let dir = weights_dir(manifest);
    let mut files = Vec::new();
    let mut total = 0u64;
    let mut done = 0u64;
    for f in &manifest.files {
        total += f.size;
        let final_path = dir.join(&f.name);
        let part_path = dir.join(format!("{}.part", f.name));
        let present = final_path.is_file();
        let mut verified = false;
        let mut verify_error = None;
        if present {
            match sha256_file(&final_path) {
                Ok(h) if h == f.sha256.to_lowercase() => verified = true,
                Ok(_) => {
                    verify_error = Some("校验不符：文件内容与清单不一致".into());
                }
                Err(e) => verify_error = Some(e),
            }
        }
        let partial = if present { 0 } else { file_size(&part_path) };
        if verified {
            done += f.size;
        } else {
            done += partial.min(f.size);
        }
        files.push(WeightStatus {
            name: f.name.clone(),
            size: f.size,
            sha256: f.sha256.clone(),
            present,
            partial_bytes: partial,
            verified,
            verifyError: verify_error,
        });
    }
    WeightsStatus {
        dir,
        manifestVersion: manifest.version.clone(),
        allReady: files.iter().all(|f| f.verified),
        totalBytes: total,
        doneBytes: done,
        files,
    }
}

fn ledger_path(dir: &Path) -> PathBuf {
    dir.join("ledger.jsonl")
}

fn append_ledger(dir: &Path, record: &serde_json::Value) {
    let _ = fs::create_dir_all(dir);
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ledger_path(dir))
    {
        let _ = writeln!(f, "{record}");
    }
}

pub fn read_ledger(manifest: &Manifest) -> Vec<serde_json::Value> {
    let p = ledger_path(&weights_dir(manifest));
    let mut out = Vec::new();
    if let Ok(raw) = fs::read_to_string(p) {
        for line in raw.lines() {
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
                out.push(v);
            }
        }
    }
    out
}

pub fn delete_all(manifest: &Manifest) -> Result<u64, String> {
    let dir = weights_dir(manifest);
    let mut freed = 0u64;
    if !dir.exists() {
        return Ok(0);
    }
    for f in &manifest.files {
        for p in [dir.join(&f.name), dir.join(format!("{}.part", f.name))] {
            if p.is_file() {
                freed += file_size(&p);
                fs::remove_file(&p).map_err(|e| format!("删除 {}: {e}", p.display()))?;
            }
        }
    }
    append_ledger(&dir, &serde_json::json!({
        "event": "delete_all",
        "freedBytes": freed,
        "time": chrono_now()
    }));
    Ok(freed)
}

fn chrono_now() -> String {
    // lightweight RFC3339-ish local timestamp without extra deps
    let d = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    format!("epoch-ms:{}", d.as_millis())
}

fn free_disk_bytes(dir: &Path) -> Result<u64, String> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::ffi::OsStrExt;
        let wide: Vec<u16> = dir
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut free: u64 = 0;
        let mut total: u64 = 0;
        let mut total_free: u64 = 0;
        let ret = unsafe {
            windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut free,
                &mut total,
                &mut total_free,
            )
        };
        if ret == 0 {
            return Err("查询磁盘剩余空间失败".into());
        }
        Ok(free)
    }
    #[cfg(not(target_os = "windows"))]
    {
        Ok(u64::MAX)
    }
}

fn resume_state_path(dir: &Path) -> PathBuf {
    dir.join("download-state.json")
}

fn load_resume(dir: &Path) -> ResumeState {
    fs::read_to_string(resume_state_path(dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_resume(dir: &Path, st: &ResumeState) {
    let _ = fs::create_dir_all(dir);
    if let Ok(json) = serde_json::to_string(st) {
        let _ = fs::write(resume_state_path(dir), json);
    }
}

/// Blocking download of one manifest entry with resume + verify + ledger.
pub fn download_one(
    manifest: &Manifest,
    entry: &ManifestEntry,
    use_mirror: bool,
    mut on_event: impl FnMut(DownloadEvent),
) -> Result<WeightStatus, String> {
    let dir = weights_dir(manifest);
    fs::create_dir_all(&dir).map_err(|e| format!("创建目录失败: {e}"))?;
    let final_path = dir.join(&entry.name);
    let part_path = dir.join(format!("{}.part", entry.name));

    // Already good?
    if final_path.is_file() {
        if let Ok(h) = sha256_file(&final_path) {
            if h == entry.sha256.to_lowercase() {
                on_event(DownloadEvent {
                    name: entry.name.clone(),
                    bytesDone: entry.size,
                    totalBytes: entry.size,
                    phase: "done".into(),
                    error: None,
                    resumedFrom: entry.size,
                });
                append_ledger(&dir, &serde_json::json!({
                    "event":"verify_existing_ok","file":entry.name,"sha256":entry.sha256,"time":chrono_now()
                }));
                return Ok(status(manifest).files.into_iter().find(|s| s.name == entry.name).unwrap());
            }
        }
        // corrupted final file -> remove and redownload from scratch
        let _ = fs::remove_file(&final_path);
    }

    // Disk space guard: need remaining bytes + 64MB margin
    let have = file_size(&part_path);
    if have > entry.size {
        let _ = fs::remove_file(&part_path);
    }
    let need = entry.size.saturating_sub(have.min(entry.size)) + 64 * 1024 * 1024;
    match free_disk_bytes(&dir) {
        Ok(free) if free < need => {
            let msg = format!(
                "磁盘空间不足：剩余 {}，至少需要 {}。请清理磁盘后重试",
                humansize(free),
                humansize(need)
            );
            append_ledger(&dir, &serde_json::json!({
                "event":"download_failed","file":entry.name,"reason":"disk_full","time":chrono_now()
            }));
            return Err(msg);
        }
        _ => {}
    }

    let url = if use_mirror {
        entry
            .mirror_path_template
            .clone()
            .unwrap_or_else(|| entry.path_template.clone())
    } else {
        entry.path_template.clone()
    };

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| format!("网络初始化失败: {e}"))?;

    // Range resume: GET with Range; resume supported iff 206 Partial Content.
    let mut start = have.min(entry.size);
    let mut req = client.get(&url);
    if start > 0 {
        req = req.header("Range", format!("bytes={}-", start));
    }
    let mut resp = req.send().map_err(|e| classify_net_err(&e))?;
    let resumed_from = if start > 0 && resp.status() == reqwest::StatusCode::PARTIAL_CONTENT {
        start
    } else {
        // server ignored range (200) or no local bytes -> restart from scratch
        start = 0;
        let _ = fs::remove_file(&part_path);
        0
    };
    let total: u64 = if start > 0 {
        resp.headers()
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.rsplit('/').next())
            .and_then(|s| s.parse().ok())
            .unwrap_or(entry.size)
    } else {
        resp.content_length().unwrap_or(entry.size)
    };

    let mut out = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&part_path)
        .map_err(|e| format!("打开临时文件失败: {e}"))?;

    let mut hasher = Sha256::new();
    if start > 0 {
        // seed the hasher with existing bytes
        let mut existing = fs::File::open(&part_path).map_err(|e| format!("读取断点失败: {e}"))?;
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = existing.read(&mut buf).map_err(|e| format!("读取断点失败: {e}"))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
    }

    let mut done = start;
    let mut last_emit = std::time::Instant::now();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = resp.read(&mut buf).map_err(|e| format!("下载中断: {e}"))?;
        if n == 0 {
            break;
        }
        out.write_all(&buf[..n]).map_err(|e| format!("写入失败: {e}"))?;
        hasher.update(&buf[..n]);
        done += n as u64;
        if last_emit.elapsed() >= Duration::from_millis(150) {
            last_emit = std::time::Instant::now();
            on_event(DownloadEvent {
                name: entry.name.clone(),
                bytesDone: done,
                totalBytes: total.max(done),
                phase: "downloading".into(),
                error: None,
                resumedFrom: resumed_from,
            });
        }
    }
    out.flush().ok();
    drop(out);

    if done < entry.size {
        let msg = format!("下载中断：{} / {}（下次启动将从断点续传）", humansize(done), humansize(entry.size));
        append_ledger(&dir, &serde_json::json!({
            "event":"download_interrupted","file":entry.name,"bytesDone":done,"totalBytes":entry.size,"time":chrono_now()
        }));
        save_resume(&dir, &ResumeState {
            last_intent_sha256: entry.sha256.clone(),
            updated_at_ms: SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_millis(),
        });
        on_event(DownloadEvent {
            name: entry.name.clone(),
            bytesDone: done,
            totalBytes: entry.size,
            phase: "failed".into(),
            error: Some(msg.clone()),
            resumedFrom: resumed_from,
        });
        return Err(msg);
    }

    on_event(DownloadEvent {
        name: entry.name.clone(),
        bytesDone: done,
        totalBytes: entry.size,
        phase: "verifying".into(),
        error: None,
        resumedFrom: resumed_from,
    });

    let actual = hex::encode(hasher.finalize());
    if actual != entry.sha256.to_lowercase() {
        // corrupted -> remove, ledger, clear error state
        let _ = fs::remove_file(&part_path);
        append_ledger(&dir, &serde_json::json!({
            "event":"download_failed","file":entry.name,"reason":"sha256_mismatch",
            "expected":entry.sha256,"actual":actual,"time":chrono_now()
        }));
        let msg = "文件校验失败（sha256 不符），已清除损坏文件，请重试下载".to_string();
        on_event(DownloadEvent {
            name: entry.name.clone(),
            bytesDone: 0,
            totalBytes: entry.size,
            phase: "failed".into(),
            error: Some(msg.clone()),
            resumedFrom: resumed_from,
        });
        return Err(msg);
    }

    fs::rename(&part_path, &final_path).map_err(|e| format!("落盘失败: {e}"))?;
    append_ledger(&dir, &serde_json::json!({
        "event":"download_done","file":entry.name,"size":entry.size,
        "sha256":entry.sha256,"resumedFrom":resumed_from,"time":chrono_now()
    }));
    save_resume(&dir, &ResumeState {
        last_intent_sha256: entry.sha256.clone(),
        updated_at_ms: SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_millis(),
    });
    on_event(DownloadEvent {
        name: entry.name.clone(),
        bytesDone: entry.size,
        totalBytes: entry.size,
        phase: "done".into(),
        error: None,
        resumedFrom: resumed_from,
    });

    Ok(status(manifest).files.into_iter().find(|s| s.name == entry.name).unwrap())
}

fn classify_net_err(e: &reqwest::Error) -> String {
    if e.is_timeout() || e.is_connect() {
        "网络连接失败，请检查网络后重试（已保留断点，重试会从断点继续）".into()
    } else {
        format!("网络错误: {e}")
    }
}

fn humansize(n: u64) -> String {
    if n >= 1 << 30 {
        format!("{:.1}GB", n as f64 / (1 << 30) as f64)
    } else if n >= 1 << 20 {
        format!("{:.1}MB", n as f64 / (1 << 20) as f64)
    } else {
        format!("{:.0}KB", n as f64 / 1024.0)
    }
}



