# 开发指南（中文）

[English](development.en.md) · 架构见 [architecture.zh.md](architecture.zh.md)

## 从源码构建桌面应用

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

## 开发约定

- 引擎改动跑 `packages/manga_colorizer_core/test/`（25 项全绿为基线）；`dart analyze` 保持无警告。
- 前端改动用 `node --check web/dist/*.js` 验语法，并在深/浅主题（`html[data-theme]`）下目检。
- 服务端改动手动验证：`GET /health`、`GET /api/v1/device`、小图三模式 POST。
- 桌面壳改动跑 `cargo check`（在 `src-tauri/` 下）。
- `tool/` 下为一次性分析与取证脚本，允许粗糙，但须保留首行用途/用法注释。

## 已知限制

- 服务端提示点为 64px 窗口局部扩散（轻量版）；需要全局精确求解用 Dart CLI 路径。
- 参考图迁移是全局统计（Reinhard），不做逐区域语义对应。
- 服务绑定 127.0.0.1，无认证；对外部署需自备反向代理、认证与 TLS。
- Android 应用端侧全自动走 ONNX Runtime CPU 执行提供者（无 GPU/NNAPI 路径）：每
  1024² 分块耗时与 arm64 真机峰值内存尚未实测，低端设备可能较慢，Step 0 门槛待
  真机实测后回填。
- 权重 CC BY-NC-SA：上传 GitHub / 免费分享 / 非商业集成 OK；收费服务、广告盈利需另行授权
  （详见 [licensing.zh.md](licensing.zh.md) / [licensing.en.md](licensing.en.md)）。

## 参与

- Issue / PR 欢迎为主题、性能与平台适配（macOS / Linux sidecar）贡献力量。
- 许可与发行边界见 [licensing.zh.md](licensing.zh.md)。

## 致谢与参考

- [sharky172/manga-light-colorizer](https://huggingface.co/sharky172/manga-light-colorizer) — ONNX 权重（CC BY-NC-SA 4.0）
- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer)、[qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2)、[xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ)、[lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — 调研参考（未复制代码/权重）
- Levin-Lischinski-Weiss 2004 色度扩散 — Dart 引擎算法基础
