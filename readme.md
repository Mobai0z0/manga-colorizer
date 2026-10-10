# Manga Colorizer

[English](#english) · [中文](#中文)

黑白漫画（含网点）语义上色工具箱。语义级自动上色 + 交互式精修，覆盖 Windows 桌面、浏览器与 Android 端侧三种使用方式，核心引擎为纯 Dart 确定性实现。

---

## English

Semantic colorization for black-and-white manga (screentone-aware). Combines fully
automatic ONNX semantic colorization with interactive refinement, available on
**Windows desktop**, in the **browser**, and **on-device (Android)**. The core engine is
a deterministic pure-Dart implementation.

### Features

- **Fully automatic** — ONNX semantic colorization (SAM-guided generator) for hair / skin / eyes / background, on desktop, in the browser, and on-device in the Android app
- **Hint points** — click points on the canvas to pin region colors
- **Reference image** — transfer the overall tone of any colored image onto the page
- **Batch queue** — up to 32 pages per run; a single failure never blocks the rest
- **Long pages** — automatic tiled inference above 1024px (256px overlap, linear feathering)
- **Luminance fidelity** — every mode writes only Lab a/b chroma; L always comes from the original page
- **GPU acceleration** — DirectML first on Windows (any DX12 GPU), CUDA on NVIDIA, automatic CPU fallback

### Repository layout (monorepo)

| Path | Purpose |
| --- | --- |
| `src-tauri/` | Tauri 2 desktop shell (Windows) + Rust backend; bundles the Python sidecar |
| `tool/colorizer_service/` | Python (uvicorn) colorization service — shared by the desktop sidecar and the browser workbench |
| `web/` | Browser workbench frontend (static), served by the Python service |
| `mobile/` | Flutter Android app — on-device ONNX colorization |
| `packages/manga_colorizer_core/` | Pure-Dart colorization engine (hint-based chroma diffusion + luminance tint) |
| `packages/manga_colorizer_server/` | Shelf-based HTTP backend over the core engine |
| `packages/manga_colorizer_cli/` | CLI tools: batch colorize, tint, sample / comparison sheets |
| `models/` | ONNX weights (gitignored; downloaded at runtime) |

### Quick start

**Windows installer (recommended for most users)**
1. Download `Manga Colorizer_<version>_x64-setup.exe` from [Releases](../../releases) and install.
2. On first launch the app downloads model weights (~287 MB, one-time, to `%LOCALAPPDATA%\manga-colorizer\weights`).
3. Drag in manga pages → accept the disclaimer → start colorizing. Results appear in the **Gallery** tab.

Requirements: Windows 10 1809+ / 11 (WebView2 bundled by the installer). GPU acceleration needs a DX12 GPU (DirectML); falls back to CPU automatically.

**Python service + browser workbench**
Requires Python ≥ 3.10.

```bash
# 1) Dependencies (CPU baseline)
python -m pip install -r tool/colorizer_service/requirements.txt

# Windows GPU (DirectML, any DX12 GPU): pick ONE, do not mix with the CPU build
python -m pip install -r tool/colorizer_service/requirements-directml.txt

# 2) Download model weights (~300 MB, not shipped with the repo;
#    for CN network replace the host with hf-mirror.com)
python -c "import urllib.request as u; [u.urlretrieve(f'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/{n}', f'models/manga-light-colorizer/{n}') for n in ['v6_generator.onnx','v6_sam_encoder.onnx']]"

# 3) Start the service (binds 127.0.0.1:8788)
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 4) Open http://127.0.0.1:8788/ in your browser
```

NVIDIA CUDA path: `pip install -r tool/colorizer_service/requirements-gpu.txt`, supply matching CUDA/cuDNN runtimes, then launch with `COLORIZER_DEVICE=cuda`. The service fails loudly on CUDA errors and never silently falls back.

**Build the desktop app from source**
Requires Rust stable, Node.js (for the Tauri CLI), and Python ≥ 3.10.

```bash
# 1) Build the Python sidecar (onefile exe; Python 3.10–3.12 for the GPU path)
python -m venv .venv
.venv/Scripts/pip install -r tool/colorizer_service/requirements-directml.txt pyinstaller
.venv/Scripts/pyinstaller sidecar/manga-colorizer-sidecar.spec --noconfirm \
  --distpath build/sidecar-dist --workpath build/sidecar-work
cp build/sidecar-dist/manga-colorizer-sidecar.exe \
   src-tauri/binaries/manga-colorizer-sidecar-x86_64-pc-windows-msvc.exe

# 2) Build / run the desktop shell
npm install -g @tauri-apps/cli
tauri dev      # run in development
tauri build    # output: src-tauri/target/release/bundle/nsis/*.exe
```

The desktop window loads its UI from the bundled frontend (`http://tauri.localhost`); the sidecar serves the API on `127.0.0.1:8788`, reached by the frontend via CORS. The sidecar binds loopback only.

**Android app (on-device fully automatic)**
Build from source under `mobile/` (`flutter build apk --debug`, verified to build), or grab the official APK from Releases.
1. Install and open the app, switch to the **Auto** tab.
2. Weights are not bundled (CC BY-NC-SA); the app guides an in-app download on first use (~300 MB, resumable, SHA-256 verified).
3. Pick images and start; results can be shared / saved in-app. The **Hint** tab needs no weights and works fully offline.

Requirement: Android arm64 physical device. On-device inference uses the ONNX Runtime CPU execution provider (no GPU/NNAPI path yet).

### Documentation

📖 [Getting started](docs/getting-started.en.md) ·
[Architecture & API](docs/architecture.en.md) ·
[Development guide](docs/development.en.md) ·
[Licensing](docs/licensing.en.md)

### License

Repository code is [Apache-2.0](LICENSE). Model weights are
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) — **not** distributed
with the repo; downloaded by the app or the user separately
(see [NOTICE](NOTICE) and [docs/licensing.en.md](docs/licensing.en.md)).

---

## 中文

黑白漫画（含网点）语义上色工具箱：全自动 ONNX 语义上色 + 交互式精修，提供 **Windows 桌面**、**浏览器**、**Android 端侧** 三种使用方式，核心引擎为纯 Dart 确定性实现。

### 功能特性

- **全自动** — ONNX 语义上色（SAM 引导 + generator），发/肤/瞳/背景自动配色，桌面、浏览器与 Android 应用端侧均可用
- **提示点** — 在画布上点击落点，指定区域颜色精修
- **参考图** — 上传任意彩图，提取整体色调迁移到原稿
- **批量队列** — 一次最多 32 张，逐个处理，单张失败不阻断
- **长图** — >1024px 自动分块推理（overlap 256 + 线性羽化融合），整页漫画无下采样损失
- **亮度保真** — 所有模式只写 Lab a/b 色度，L 通道始终回写原稿
- **GPU 自动加速** — Windows 优先 DirectML（任意 DX12 显卡），NVIDIA 可用 CUDA，无 GPU 自动回退 CPU

### 仓库结构（monorepo）

| 路径 | 用途 |
| --- | --- |
| `src-tauri/` | Tauri 2 桌面壳（Windows）+ Rust 后端；打包内嵌 Python sidecar |
| `tool/colorizer_service/` | Python（uvicorn）上色服务——桌面 sidecar 与浏览器工作台共用 |
| `web/` | 浏览器工作台前端（静态），由 Python 服务托管 |
| `mobile/` | Flutter Android 应用——端侧 ONNX 上色 |
| `packages/manga_colorizer_core/` | 纯 Dart 上色引擎（提示点色度扩散 + 亮度染色） |
| `packages/manga_colorizer_server/` | 基于 Shelf 的 HTTP 后端，封装核心引擎 |
| `packages/manga_colorizer_cli/` | 命令行工具：批量上色、染色、取样 / 对比图 |
| `models/` | ONNX 权重（gitignore；运行时下载） |

### 快速开始

**Windows 安装包（推荐普通用户）**
1. 从 [Releases](../../releases) 下载 `Manga Colorizer_<版本>_x64-setup.exe` 并安装。
2. 首次启动会下载模型权重（约 287 MB，一次性，下载到 `%LOCALAPPDATA%\manga-colorizer\weights`）。
3. 拖入漫画页 → 勾选免责声明 → 开始上色。成品在「图库」页。

系统要求：Windows 10 1809+ / 11（WebView2 由安装包自动装）。GPU 加速需 DX12 显卡（DirectML）；无 GPU 时自动使用 CPU。

**Python 服务 + 浏览器工作台**
要求 Python ≥ 3.10。

```bash
# 1) 依赖（CPU 基础路径）
python -m pip install -r tool/colorizer_service/requirements.txt

# Windows GPU（DirectML，任意 DX12 显卡）：二选一，不要与 CPU 版混装
python -m pip install -r tool/colorizer_service/requirements-directml.txt

# 2) 下载模型权重（约 300MB，不随仓库分发；国内可把域名换成 hf-mirror.com）
python -c "import urllib.request as u; [u.urlretrieve(f'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/{n}', f'models/manga-light-colorizer/{n}') for n in ['v6_generator.onnx','v6_sam_encoder.onnx']]"

# 3) 启动服务（绑定 127.0.0.1:8788）
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 4) 浏览器打开 http://127.0.0.1:8788/
```

NVIDIA CUDA 路径：`pip install -r tool/colorizer_service/requirements-gpu.txt` 并自备匹配的 CUDA/cuDNN 运行库，以 `COLORIZER_DEVICE=cuda` 启动；CUDA 不可用时服务明确报错，不会静默回退。

**从源码构建桌面应用**
要求：Rust stable、Node.js（仅用于安装 Tauri CLI）、Python ≥ 3.10。

```bash
# 1) 构建 Python sidecar（onefile exe；GPU 路径建议 Python 3.10–3.12）
python -m venv .venv
.venv/Scripts/pip install -r tool/colorizer_service/requirements-directml.txt pyinstaller
.venv/Scripts/pyinstaller sidecar/manga-colorizer-sidecar.spec --noconfirm \
  --distpath build/sidecar-dist --workpath build/sidecar-work
cp build/sidecar-dist/manga-colorizer-sidecar.exe \
   src-tauri/binaries/manga-colorizer-sidecar-x86_64-pc-windows-msvc.exe

# 2) 构建/调试桌面壳
npm install -g @tauri-apps/cli
tauri dev      # 开发运行
tauri build    # 产物：src-tauri/target/release/bundle/nsis/*.exe
```

桌面窗口固定从打包内前端（`http://tauri.localhost`）加载界面，sidecar 在 `127.0.0.1:8788` 提供 API，前端通过 CORS 跨源访问。sidecar 仅绑定回环地址。

**Android 应用（端侧全自动）**
在 `mobile/` 下用 Flutter 从源码构建（`flutter build apk --debug`，构建验证通过），或等 Releases 的正式 APK。
1. 安装并打开应用，切到「全自动」页签。
2. 权重不随 APK 分发（CC BY-NC-SA），首次使用由应用内引导下载（约 300 MB，支持断点续传与 SHA-256 校验）。
3. 选图开始全自动上色，结果可在应用内分享/保存。「提示点上色」页签无需权重、完全离线可用。

设备要求：Android arm64 物理设备。端侧推理走 ONNX Runtime CPU 执行提供者（暂无 GPU/NNAPI 路径）。

### 文档

📖 [快速开始](docs/getting-started.zh.md) ·
[架构与 API](docs/architecture.zh.md) ·
[开发指南](docs/development.zh.md) ·
[许可与发行边界](docs/licensing.zh.md)

### 许可

仓库代码 [Apache-2.0](LICENSE)；模型权重 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
（不随仓库分发，由应用或使用者自行下载，见 [NOTICE](NOTICE) 与 [docs/licensing.zh.md](docs/licensing.zh.md)）。
