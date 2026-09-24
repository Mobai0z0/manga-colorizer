# Development Guide

[中文](development.zh.md) · For architecture see [architecture.en.md](architecture.en.md)

## Building the desktop app from source

Requirements: Rust stable (`rustup`), Node.js (only for installing the Tauri CLI), Python ≥ 3.10.

```bash
# 1) Build the Python sidecar (onefile exe; Python 3.10–3.12 recommended for the GPU path)
python -m venv .venv
.venv/Scripts/pip install -r tool/colorizer_service/requirements-directml.txt pyinstaller
.venv/Scripts/pyinstaller sidecar/manga-colorizer-sidecar.spec --noconfirm \
  --distpath build/sidecar-dist --workpath build/sidecar-work
cp build/sidecar-dist/manga-colorizer-sidecar.exe \
   src-tauri/binaries/manga-colorizer-sidecar-x86_64-pc-windows-msvc.exe

# 2) Build/debug the desktop shell
npm install -g @tauri-apps/cli
tauri dev      # Development run
tauri build    # Artifact: src-tauri/target/release/bundle/nsis/*.exe
```

Notes: the desktop window always loads its UI from the packaged frontend
(`http://tauri.localhost`); the sidecar serves the API on `127.0.0.1:8788`, and the frontend
accesses it cross-origin via CORS (the sidecar binds only the loopback address).

## Development conventions

- Engine changes: run `packages/manga_colorizer_core/test/` (all 25 tests green is the baseline);
  `dart analyze` must stay warning-free.
- Frontend changes: validate syntax with `node --check web/dist/*.js`, and visually check under
  both dark/light themes (`html[data-theme]`).
- Server changes: verify manually via `GET /health`, `GET /api/v1/device`, and small-image POSTs
  in all three modes.
- Desktop shell changes: run `cargo check` (in `src-tauri/`).
- Files under `tool/` are one-off analysis/forensics scripts; rough code is acceptable, but each
  must keep a first-line comment stating its purpose/usage.

## Known limitations

- Server-side hint points use local diffusion in a 64px window (the lightweight version); for a
  globally exact solve, use the Dart CLI path.
- Reference-image transfer is a global statistic (Reinhard); there is no per-region semantic
  correspondence.
- The service binds 127.0.0.1 with no authentication; public deployment requires your own
  reverse proxy, authentication, and TLS.
- Android on-device fully-automatic colorization runs on the ONNX Runtime CPU execution
  provider (no GPU/NNAPI path): per-1024²-tile runtime and peak memory on arm64 physical
  devices are not yet measured, low-end devices may be slow, and the first real-device
  acceptance gate will be filled in after real-device measurement.
- Weights are CC BY-NC-SA: uploading to GitHub / free sharing / non-commercial integration are
  OK; paid services and ad-monetized use require separate authorization
  (see [licensing.en.md](licensing.en.md) for details).

## Contributing

- Issues / PRs are welcome, especially contributions on theming, performance, and platform
  adaptation (macOS / Linux sidecar).
- For licensing and distribution boundaries see [licensing.en.md](licensing.en.md).

## Acknowledgments and references

- [sharky172/manga-light-colorizer](https://huggingface.co/sharky172/manga-light-colorizer) — ONNX weights (CC BY-NC-SA 4.0)
- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer), [qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2), [xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ), [lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — research references (no code/weights copied)
- Levin-Lischinski-Weiss 2004 chroma diffusion — algorithmic basis of the Dart engine
