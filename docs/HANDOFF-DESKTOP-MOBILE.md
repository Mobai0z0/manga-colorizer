# Manga Colorizer 桌面端 + 移动端 交接文档

> 生成：2026-09-18 · 分支 main · 桌面壳 v0.1.0
> 方案：Tauri 2 (Windows) + PyInstaller sidecar + Rust 首启权重下载 + Flutter Android (内嵌 manga_colorizer_core)

## 1. 目录结构（本次新增部分）

```
src-tauri/                  Tauri 2 桌面壳 (Rust)
  Cargo.toml                Rust 依赖（tauri 2 / reqwest / sha2 / dirs）
  tauri.conf.json           窗口、打包、sidecar、资源清单配置
  capabilities/default.json Tauri 权限（shell/dialog/窗口）
  src/lib.rs                启动编排：清单加载 → 权重判定 → 下载/拉服务 → 窗口跳转
  src/downloader.rs         权重下载：Range 断点续传、sha256 校验、ledger.jsonl 台账
  src/sidecar_mgr.rs        sidecar 进程拉起/看护/异常弹窗重启
  resources/weights-manifest.json  权重清单（版本/体积/sha256/直连+镜像 URL）
  icons/                    应用图标
sidecar/                    Python sidecar
  sidecar_entry.py          入口：--port 参数、web-dist 环境变量、端口复用检测
  manga-colorizer-sidecar.spec  PyInstaller 配置（onefile，内置 web/dist）
mobile/                     Flutter Android 工程
  lib/main.dart             提示点上色工作台（选图/落点/上色/对比/分享）
  assets/sample_bw.png      内置样例（真实漫画页）
  pubspec.yaml              path 依赖 ../packages/manga_colorizer_core
.github/workflows/ci.yml    CI：桌面安装包 + sidecar exe + APK 三产物
web/dist/boot-shell.html    首启引导页（下载进度/续传/台账/删除重下）
```

## 2. 环境搭建（新人照做即可）

### 2.1 基础
- Node 22+（Tauri CLI）、Python ≥3.10、Git
- VS C++ Build Tools（MSVC 工具集，Windows 必装）
- Android Studio 或仅命令行：Android SDK（platform-tools/build-tools/NDK 可选）+ JDK 17

### 2.2 Rust（一次性，rsproxy 国内镜像）
```powershell
# 安装 rustup（已装可跳过）
winget install Rustlang.Rustup
# 配置 rsproxy 镜像：写入 %USERPROFILE%\.cargo\config.toml
@"
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[registries.rsproxy]
index = "sparse+https://rsproxy.cn/index/"
"@ | Set-Content "$env:USERPROFILE\.cargo\config.toml"
rustc --version   # 验证
```

### 2.3 Flutter（腾讯镜像）
```powershell
# 环境变量（User 级）
FLUTTER_STORAGE_BASE_URL = https://mirrors.cloud.tencent.com/flutter
PUB_HOSTED_URL            = https://mirrors.cloud.tencent.com/pub
ANDROID_HOME              = E:\sdk\android    # 按实际 SDK 位置
```
本机 gradle wrapper 已改为腾讯镜像（mobile/android/gradle/wrapper/gradle-wrapper.properties）。

## 3. 构建步骤

### 3.1 Python sidecar（Windows）
```powershell
python -m pip install -r tool/colorizer_service/requirements.txt pyinstaller
python -m PyInstaller sidecar/manga-colorizer-sidecar.spec --noconfirm --distpath build/sidecar-dist --workpath build/sidecar-work
Copy-Item build/sidecar-dist/manga-colorizer-sidecar.exe src-tauri/binaries/manga-colorizer-sidecar-x86_64-pc-windows-msvc.exe
```
> 产物必须带 `-x86_64-pc-windows-msvc` 后缀放进 src-tauri/binaries/，否则 Tauri externalBin 报缺失。
> sidecar onefile 约 86MB（Python + onnxruntime + OpenCV），启动 3-5 秒属正常（onefile 自解压）。

### 3.2 Tauri 桌面安装包
```powershell
cd src-tauri
cargo build                 # 调试构建
cargo tauri build           # 正式 NSIS 安装包（需 npm i -g @tauri-apps/cli）
# 产物: src-tauri/target/release/bundle/nsis/Manga Colorizer_0.1.0_x64-setup.exe
```

### 3.3 Flutter Android APK
```powershell
cd mobile
flutter pub get
flutter build apk --release
# 产物: mobile/build/app/outputs/flutter-apk/app-release.apk
```

### 3.4 本地验证 sidecar（不经壳）
```powershell
Start-Process build/sidecar-dist/manga-colorizer-sidecar.exe -ArgumentList '--port','18799'
curl http://127.0.0.1:18799/health        # {"ok":true,...}
curl http://127.0.0.1:18799/ -UseBasicParsing   # 应返回工作台 HTML（>8KB）
```

## 4. 权重清单更新方法

清单：`src-tauri/resources/weights-manifest.json`
- 换模型版本：更新 `version`、每个文件的 `size`（字节数）、`sha256`（小写 hex）、`pathTemplate` / `mirrorPathTemplate`
- 本地计算校验值：
```powershell
python -c "import hashlib;p=r'文件路径';h=hashlib.sha256(open(p,'rb').read());print(h.hexdigest())"
```
- 下载源默认 HuggingFace，断点续传依赖 HTTP Range；`mirrorPathTemplate` 走 hf-mirror.com 作为备用源（主源失败自动切一次）
- 版本变更后 `allReady` 判定按新 sha256 执行：旧文件校验不符会提示重新下载，不会误用
- 运行时落位：`%LOCALAPPDATA%\manga-colorizer\weights\<baseDir>\`，含 `ledger.jsonl`（台账）与 `*.part`（未完成断点）

## 5. 权重下载器行为（验收对照）

| 场景 | 行为 |
|---|---|
| 首启无权重 | 窗口停在引导页（boot-shell.html），显示清单版本/总量/进度 |
| 下载中 | 150ms 节流推送进度事件；sha256 校验阶段进度条转不确定态 |
| 断网 | reqwest 超时 30s → 报「网络连接失败…已保留断点」，重试从断点续传（主源 1 次 + 镜像 1 次） |
| 磁盘不足 | 下载前 GetDiskFreeSpaceExW 检查（剩余 < 需求 + 64MB 余量）→ 明确报错，不落损坏文件 |
| 校验失败 | sha256 不符 → 删除 .part → 报「校验失败已清除」，重试即全新下载 |
| 删除权重 | 引导页「删除已下载权重」→ 清空文件 + 台账记录 freedBytes |
| 续传证据 | 台账每行含 resumedFrom / bytesDone / sha256 / 时间 |
| 下载完成 | 自动拉起 sidecar → /health 就绪 → 窗口跳转 http://127.0.0.1:8788/（原工作台，前端零改动） |

## 6. 已知问题与限制

1. **真机/干净机项未在本机复现**：干净 Windows VM 安装、Android 真机 3 图上色、人为断网续传实测——见 `DELIVERY/desktop-mobile-acceptance.md` 待执行清单。
2. **CI 首跑待推送**：仓库尚无 remote（.git 无 origin）。`git remote add origin <URL> && git push -u origin main` 后 GitHub Actions 自动构建三产物。
3. **安装包未签名**：SmartScreen 首次运行会提示「仍要运行」；签名证书到位后在 tauri.conf.json windows.digestAlgorithm 基础上走 signtool。
4. **WebView2**：安装包用 embedBootstrapper 模式，Win10 老版本会随安装器装 WebView2 Runtime（需联网，一次性）。
5. **sidecar 端口固定 8788**：若被占用，复用已有服务（健康检查通过即认为可用）；彻底冲突需改 sidecar_mgr::PORT 与 tauri.conf.json 窗口 URL。
6. **移动端为提示点引擎**：Android 端跑纯 Dart core（提示点色度扩散 + 色板 tint），不带 ONNX 全自动模型（手机端模型体积/推理性能是另一阶段的事）。
7. **Flutter pub workspace**：mobile 已加入根 pubspec.yaml workspace；单独在 mobile/ 下跑 pub get 需保留根 workspace 完整。

## 7. 回滚步骤

1. **发版纪律**：每次出正式安装包前打 tag：`git tag v0.1.0 && git push origin v0.1.0`；同时把上一版安装包归档到 `DELIVERY/releases/<旧版本号>/`。
2. **桌面端回退**：控制面板卸载新版 → 安装归档目录里的旧版 setup.exe（用户数据/权重在 %LOCALAPPDATA%\manga-colorizer\ 不受卸载影响，版本兼容）。
3. **权重回退**：把 weights-manifest.json 的 version/sha256 改回旧值并重新构建 → 应用检测到校验不符会引导重新下载旧权重。
4. **代码回退**：`git revert <commit>` 或 `git reset --hard v0.1.0`（后者需 force push，团队场景用 revert）。
5. **CI 回退**：Actions 页面选旧 tag 的成功 run，重新下载该版产物即可。

## 8. 测试与验收

见 [DELIVERY/desktop-mobile-acceptance.md](../DELIVERY/desktop-mobile-acceptance.md)：
- 已实测项（本机）：sidecar 冒烟（health/capabilities/静态页）、Tauri debug 构建产物、core 引擎回归（25 项，仓库原有）
- 待执行项：干净 VM 全流程、真机 3 图上色、四种异常路径逐项、CI 绿灯截图
