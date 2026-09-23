# Manga Colorizer

[English](#english) · [中文](#中文)

---

## English

Semantic colorization for black-and-white manga (screentone-aware): a Windows desktop
app (Tauri 2 + Python sidecar), plus a browser workbench and a deterministic pure-Dart
engine.

- **Fully automatic** — ONNX semantic colorization (SAM-guided generator) for hair / skin / eyes / background, on desktop, browser, and on-device in the Android app
- **Hint points** — click points on the canvas to pin region colors
- **Reference image** — transfer the overall tone of any colored image onto the page
- **Batch queue** — up to 32 pages per run; a single failure never blocks the rest
- **Long pages** — automatic tiled inference above 1024px (256px overlap, linear feathering)
- **Luminance fidelity** — every mode writes only Lab a/b chroma; L always comes from the original page
- **GPU acceleration** — DirectML first on Windows (any DX12 GPU), CUDA on NVIDIA, automatic CPU fallback

**License**: repository code [Apache-2.0](LICENSE); model weights
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) — not distributed
with the repo and downloaded by the app or the user separately
(see [NOTICE](NOTICE) and [docs/licensing.en.md](docs/licensing.en.md)).

📖 Documentation: [Getting started](docs/getting-started.en.md) ·
[Architecture & API](docs/architecture.en.md) ·
[Development guide](docs/development.en.md) ·
[Licensing](docs/licensing.en.md)

---

## 中文

黑白漫画（含网点）语义上色工具箱：Windows 桌面应用（Tauri 2 + Python sidecar），
外加浏览器工作台与纯 Dart 确定性引擎。

- **全自动** — ONNX 语义上色（SAM 引导 + generator），发/肤/瞳/背景自动配色，桌面、浏览器与 Android 应用端侧均可用
- **提示点** — 在画布上点击落点，指定区域颜色精修
- **参考图** — 上传任意彩图，提取整体色调迁移到原稿
- **批量队列** — 一次最多 32 张，逐个处理，单张失败不阻断
- **长图** — >1024px 自动分块推理（overlap 256 + 线性羽化融合），整页漫画无下采样损失
- **亮度保真** — 所有模式只写 Lab a/b 色度，L 通道始终回写原稿
- **GPU 自动加速** — Windows 优先 DirectML（任意 DX12 显卡），NVIDIA 可用 CUDA，无 GPU 自动回退 CPU

**许可**：仓库代码 [Apache-2.0](LICENSE)；模型权重 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
（不随仓库分发，由应用或使用者自行下载，见 [NOTICE](NOTICE) 与 [docs/licensing.zh.md](docs/licensing.zh.md)）。

📖 文档：[快速开始](docs/getting-started.zh.md) ·
[架构与 API](docs/architecture.zh.md) ·
[开发指南](docs/development.zh.md) ·
[许可与发行边界](docs/licensing.zh.md)
