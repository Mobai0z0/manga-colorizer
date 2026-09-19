# Manga Colorizer

黑白漫画（含网点）语义上色工具箱：Windows 桌面应用（Tauri 2 + Python sidecar），
外加浏览器工作台与纯 Dart 确定性引擎。

- **全自动** — ONNX 语义上色（SAM 引导 + generator），发/肤/瞳/背景自动配色
- **提示点** — 在画布上点击落点，指定区域颜色精修
- **参考图** — 上传任意彩图，提取整体色调迁移到原稿
- **批量队列** — 一次最多 32 张，逐个处理，单张失败不阻断
- **长图** — >1024px 自动分块推理（overlap 256 + 线性羽化融合），整页漫画无下采样损失
- **亮度保真** — 所有模式只写 Lab a/b 色度，L 通道始终回写原稿
- **GPU 自动加速** — Windows 优先 DirectML（任意 DX12 显卡），NVIDIA 可用 CUDA，无 GPU 自动回退 CPU

**许可**：仓库代码 [Apache-2.0](LICENSE)；模型权重 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
（不随仓库分发，由应用或使用者自行下载，见 [NOTICE](NOTICE) 与 [docs/licensing.md](docs/licensing.md)）。

## 快速开始

### 方式一：Windows 安装包（推荐普通用户）

1. 从 [Releases](../../releases) 下载 `Manga Colorizer_<版本>_x64-setup.exe` 并安装。
2. 首次启动会下载模型权重（约 287 MB，一次性，下载到 `%LOCALAPPDATA%\manga-colorizer\weights`）。
   国内网络可在系统代理下重试，或参考[手动下载权重](#手动下载权重)。
3. 就绪后进入工作台：拖入漫画页 → 勾选免责声明 → 开始上色。成品在「图库」页，文件在
   `%LOCALAPPDATA%\manga-colorizer\gallery`。

系统要求：Windows 10 1809+ / Windows 11（WebView2 由安装包自动装）。GPU 加速需 DX12 显卡
（DirectML）；无 GPU 时自动使用 CPU。

### 方式二：Python 服务 + 浏览器工作台

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

NVIDIA CUDA 路径：`python -m pip install -r tool/colorizer_service/requirements-gpu.txt`
并自备匹配的 CUDA/cuDNN 运行库，以 `COLORIZER_DEVICE=cuda` 启动；CUDA 不可用时服务明确报错，不会静默回退。

> **DirectML 版本说明**：`requirements-directml.txt` 把 `onnxruntime-directml` 钉在 `<1.21`。
> 实测 1.24.x 的 DirectML 数值在本模型上会让背景出现彩色斑块（噪点），且首次长图分块推理
> 易触发显存瞬时不足；1.20.1 为干净基线。1.20.x 没有 Python 3.13/3.14 wheel，GPU 路径请用
> Python 3.10–3.12（CPU 路径 3.14 可用）。GPU 单块推理失败时该块自动回退 CPU，长图不会整体失败。

### 方式三：从源码构建桌面应用

要求：Rust stable（`rustup`）、Node.js（仅用于安装 Tauri CLI）、Python ≥ 3.10。

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

说明：桌面窗口固定从打包内前端（`http://tauri.localhost`）加载界面，sidecar 在
`127.0.0.1:8788` 提供 API，前端通过 CORS 跨源访问（sidecar 仅绑定回环地址）。

## 架构

```
Tauri 2 桌面壳（src-tauri）  窗口生命周期 / 权重下载器（断点续传 + sha256）/ sidecar 看护与自动重启
  └─ web/dist                M3 风格前端（零构建）：工作台 / APP 界面（批量队列+图库+日志）/ 引导页
       │ fetch（CORS）
       ▼
Python sidecar（:8788，tool/colorizer_service）
  ├─ 全自动:   manga-light-colorizer（SAM 语义引导 + generator，ONNX Runtime）
  ├─ 提示点:   亮度相似度加权色度扩散（服务端轻量版）
  ├─ 参考图:   Reinhard Lab 主色迁移 ⊕ 模型语义色
  ├─ 长图:     tile 1024 / overlap 256 线性羽化融合
  └─ 图库台账: gallery.jsonl + settings.json 持久化

packages/manga_colorizer_core    纯 Dart 上色引擎（Levin 2004 色度扩散，确定性，可离线）
packages/manga_colorizer_cli     批量上色 / 三联对比图 / 色板工具
mobile/                          Flutter Android 壳（调用同款引擎）
```

## HTTP API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 服务状态：权重在位、模型加载、实际 provider、回退原因 |
| GET | `/api/v1/device` | 设备信息：可用 provider、GPU 型号/显存/驱动、输出目录 |
| GET | `/api/v1/capabilities` | 模式、端点、限制、许可声明 |
| POST | `/colorize_auto` | multipart `image` → PNG（全自动语义上色） |
| POST | `/colorize_hints` | multipart `image` + `hints`(JSON) → PNG（提示点精修） |
| POST | `/colorize_reference` | multipart `image` + `reference` → PNG（色调迁移） |
| GET | `/api/v1/gallery` | 上色台账（分页，含耗时/设备/尺寸） |
| GET/POST | `/api/v1/settings` | 模式 / 处理器 / 主题 / 免责声明 持久化 |

`hints` 元素：`{"x":int, "y":int, "r":0-255, "g":0-255, "b":0-255}`，上限 4096。

```bash
# 全自动
curl -F "image=@page.png" http://127.0.0.1:8788/colorize_auto -o colored.png

# 提示点（画布坐标 + RGB）
curl -F "image=@page.png" \
     -F 'hints=[{"x":640,"y":300,"r":30,"g":136,"b":229}]' \
     http://127.0.0.1:8788/colorize_hints -o colored.png

# 参考图色调迁移
curl -F "image=@page.png" -F "reference=@character.png" \
     http://127.0.0.1:8788/colorize_reference -o colored.png
```

错误语义：`400` 格式/参数错误 · `413` 超 20MiB 或 16M 像素 · `429` 单并发占用 · `503` 模型未就绪 · `500` 服务端错误（响应均为 `{"error": "..."}`）。

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `COLORIZER_DEVICE` | `cpu` | `cpu` / `auto` / `cuda`；`auto` 按可用 provider 选择（CUDA 优先于 DirectML） |
| `COLORIZER_MODEL_DIR` | `models/manga-light-colorizer` | 权重目录 |
| `COLORIZER_OUTPUT_DIR` | `out/gallery` | 成品与台账目录 |
| `COLORIZER_WEB_DIST` | `web/dist` | 静态前端目录（不存在则不挂载 `/`） |
| `COLORIZER_LOG_FILE` | — | 追加写入的日志文件 |
| `COLORIZER_PRELOAD` | `1` | 启动时后台预热模型（加载 + 空推理）；`0` 关闭以省内存，代价是首次上色多等 10-20s |
| `COLORIZER_IDLE_UNLOAD` | `600` | 空闲多少秒后释放模型（内存+显存归还系统，下次上色自动唤醒）；`0` = 常驻不释放 |

## 故障排查

| 现象 | 处理 |
|---|---|
| 顶栏显示「模型预热中…」 | 应用启动即在后台加载模型（首次 10-20 秒），预热完成后上色无需等待；内存紧张的机器可用 `COLORIZER_PRELOAD=0` 关闭预热 |
| 顶栏显示「模型休眠中」 | 空闲 10 分钟后自动释放模型以归还内存/显存，属正常行为；提交上色会自动唤醒（约 10-20 秒），可用 `COLORIZER_IDLE_UNLOAD=0` 改为常驻 |
| 顶栏显示「服务未连接」 | 等待 1-2 分钟（sidecar 启动）；仍失败则查看日志 `%LOCALAPPDATA%\manga-colorizer\logs\sidecar.log`，或重启应用（弹窗中选「重启服务」） |
| 处理器选项显示 GPU 灰色 / 「未检测到可用 GPU」 | DirectML 需要 DX12 显卡与较新显卡驱动；NVIDIA 机器若走 CUDA 需自装 CUDA/cuDNN。服务端日志会打印 `get_available_providers()` |
| 上色结果背景出现彩色斑块 | 确认 sidecar 用的是 `requirements-directml.txt`（onnxruntime-directml <1.21）构建；1.24.x 的 DirectML 在本模型上有已知数值问题 |
| 权重下载失败 | 检查网络/代理后重试（支持断点续传）；或按下方「手动下载权重」操作 |
| 主题不生效 | 主题可手动切换（导航栏底部按钮）并记忆；未手动切换时跟随系统深浅色 |

### 手动下载权重

从 [模型发布页](https://huggingface.co/sharky172/manga-light-colorizer) 下载 `v6_generator.onnx`
与 `v6_sam_encoder.onnx`（国内可换 `hf-mirror.com` 域名），放入：

- 桌面应用：`%LOCALAPPDATA%\manga-colorizer\weights\manga-light-colorizer\`
- 源码运行：仓库 `models/manga-light-colorizer/`

## 性能参考（实测）

| 输入 | 后端 | 耗时 |
|---|---|---|
| 512×384 | GPU · DirectML（RTX 5060 Laptop，热身后） | ~2 s |
| 1280×760 单页 | CPU（onnxruntime 1.30，laptop） | 10–18 s |
| 1280×7376 整页（分块） | CPU | ~122 s |

分块推理质量（vs 单块整缩）：Lab a/b 均值差 <0.6，PSNR >33dB；接缝跳变 ≤0.5（可见阈值 8）。
数据为单次实测，非保证值。

## Dart 引擎（离线 / 确定性路径）

`manga_colorizer_core` 是无 `dart:io` 依赖的纯 Dart 包，可嵌入 Flutter：

```bash
dart pub get
dart test                                      # 25 项引擎回归
dart run tool/colorize_auto_client.dart -i 漫画.png -o 输出.png
dart run manga_colorizer_cli:colorize -i 原稿.png -o 输出.png --hints hints.json
```

特性：亮度完全保留、封闭白区平涂、网点 descreen、提示色亮度适配、tile 分块；
提示点为全局色度扩散求解（SOR 加速），比服务端轻量版更精确；确定性可复现。

## 已知限制

- 服务端提示点为 64px 窗口局部扩散（轻量版）；需要全局精确求解用 Dart CLI 路径。
- 参考图迁移是全局统计（Reinhard），不做逐区域语义对应。
- 服务绑定 127.0.0.1，无认证；对外部署需自备反向代理、认证与 TLS。
- 权重 CC BY-NC-SA：上传 GitHub / 免费分享 / 非商业集成 OK；收费服务、广告盈利需另行授权（详见 [docs/licensing.md](docs/licensing.md)）。

## 参与

- Issue / PR 欢迎为主题、性能与平台适配（macOS / Linux sidecar）贡献力量。
- 引擎改动跑 `packages/manga_colorizer_core/test/`（25 项全绿为基线）；`dart analyze` 保持无警告。
- 前端改动用 `node --check web/dist/*.js` 验语法，并在深/浅主题下目检。
- 服务端改动手动验证：`GET /health`、`GET /api/v1/device`、小图三模式 POST。

## 致谢与参考

- [sharky172/manga-light-colorizer](https://huggingface.co/sharky172/manga-light-colorizer) — ONNX 权重（CC BY-NC-SA 4.0）
- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer)、[qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2)、[xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ)、[lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — 调研参考（未复制代码/权重）
- Levin-Lischinski-Weiss 2004 色度扩散 — Dart 引擎算法基础
