# Architecture & API

[中文](architecture.zh.md) · For setup see [getting-started.en.md](getting-started.en.md)

## Component overview

```
Tauri 2 desktop shell (src-tauri)  Window lifecycle / weight downloader (resumable download + sha256) / sidecar supervision & auto-restart
  └─ web/dist                M3-style frontend (zero build, single page index.html + app.js)
       │ fetch (CORS)
       ▼
Python sidecar (:8788, tool/colorizer_service)
  ├─ Fully automatic:  manga-light-colorizer (SAM semantic guidance + generator, ONNX Runtime)
  ├─ Hint points:      luminance-similarity-weighted chroma diffusion (lightweight server-side version)
  ├─ Reference image:  Reinhard Lab dominant-color transfer ⊕ model semantic colors
  ├─ Long images:      tile 1024 / overlap 256 linear feather blending
  └─ Gallery ledger:   gallery.jsonl + settings.json persistence

packages/manga_colorizer_core    Pure-Dart colorization engine (Levin 2004 chroma diffusion, deterministic, offline-capable)
packages/manga_colorizer_cli     Batch colorization / three-panel comparison images / palette tools
packages/manga_colorizer_server  Dart HTTP backend (shelf, experimental path)
mobile/                          Flutter Android shell (Dart engine + on-device fully-automatic ONNX)
```

Feature set: fully automatic ONNX semantic colorization (SAM guidance + generator), hint-point
canvas refinement, reference-image color transfer, batch queue (up to 32 images at a time, a
single failure does not block the rest), automatic tiled inference for long images, luminance
fidelity (all modes write only the Lab a/b chroma; the L channel is always written back from the
original), and automatic GPU acceleration (DirectML preferred on Windows, CUDA available on
NVIDIA, automatic fallback to CPU when no GPU is present).

## Frontend (web/dist)

Material Design 3 style, **zero build, zero runtime dependencies** (MD3 tokens are implemented
with native CSS variables; the official `@material/web` npm package is not used; the official
component implementation can be swapped in separately if desired, with the interfaces unchanged).

When `tool/colorizer_service/service.py` detects this directory, it automatically mounts `/` to
it; the desktop shell (Tauri) window also loads its pages from the same directory inside the
package. Cross-origin access is allowed by the server-side CORS middleware (the service binds
only 127.0.0.1 and is never exposed to the LAN).

| File | Description |
|---|---|
| `index.html` + `app.js` | The only frontend page (shared by the browser workbench and the desktop shell: navigation + batch queue + hint-point canvas + reference image + gallery ledger + console log) |
| `boot-shell.html` | Weight-download page shown on the desktop shell's first launch (used only inside Tauri) |
| `app.css` | M3 (Expressive) tokens and component styles (light/dark theme tokens are maintained here) |
| `app-shell.css` / `app-ui.css` | Navigation shell and in-app feature component styles |

UI capabilities: drag-and-drop / click-to-pick upload (PNG/JPEG/WebP, limits read from
`/api/v1/capabilities`), service status badge (polls `/health`), three colorization modes,
non-commercial license acknowledgment checkbox, original/result comparison, result download,
light/dark themes (follow system + manual switch that is remembered), `prefers-reduced-motion`
animation degradation.

## Python sidecar (tool/colorizer_service)

FastAPI service, endpoints:

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Service status: weights present, model loaded, actual provider, fallback reason |
| GET | `/api/v1/device` | Device info: available providers, GPU model/VRAM/driver, output directory |
| GET | `/api/v1/capabilities` | Modes, endpoints, limits, license statement |
| POST | `/colorize_auto` | multipart `image` → PNG (fully automatic semantic colorization) |
| POST | `/colorize_hints` | multipart `image` + `hints`(JSON) → PNG (hint-point refinement) |
| POST | `/colorize_reference` | multipart `image` + `reference` → PNG (color transfer) |
| POST | `/api/v1/batch` | Batch queue (processed one at a time in submission order; a single failure does not block the rest) |
| GET | `/api/v1/gallery` | Colorization ledger (`limit` param, with elapsed time/device/dimensions) |
| GET | `/api/v1/logs` | Incremental pull of the backend log ring buffer (`after` sequence number) |
| GET/POST | `/api/v1/settings` | Mode / processor / theme / disclaimer persistence |
| GET | `/gallery/file/{name}` | Read a gallery result image (only files inside the output directory, with cache headers) |
| POST | `/shutdown` | Loopback address only: releases the model's VRAM/memory and requests a graceful service exit (called when the desktop shell quits) |

`hints` element: `{"x":int, "y":int, "r":0-255, "g":0-255, "b":0-255}`, capped at 4096.

```bash
# Fully automatic
curl -F "image=@page.png" http://127.0.0.1:8788/colorize_auto -o colored.png

# Hint points (canvas coordinates + RGB)
curl -F "image=@page.png" \
     -F 'hints=[{"x":640,"y":300,"r":30,"g":136,"b":229}]' \
     http://127.0.0.1:8788/colorize_hints -o colored.png

# Reference-image color transfer
curl -F "image=@page.png" -F "reference=@character.png" \
     http://127.0.0.1:8788/colorize_reference -o colored.png
```

Error semantics: `400` format/parameter error · `413` over 20MiB or 16M pixels · `429` the
single-concurrency slot is occupied · `503` model not ready · `500` server-side error (responses
are always `{"error": "..."}`).

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `COLORIZER_DEVICE` | `cpu` | `cpu` / `auto` / `cuda`; `auto` picks from the available providers (CUDA preferred over DirectML) |
| `COLORIZER_MODEL_DIR` | `models/manga-light-colorizer` | Weights directory |
| `COLORIZER_OUTPUT_DIR` | `out/gallery` | Output and ledger directory |
| `COLORIZER_WEB_DIST` | `web/dist` | Static frontend directory (`/` is not mounted if it does not exist) |
| `COLORIZER_LOG_FILE` | — | Append-only log file |
| `COLORIZER_PRELOAD` | `1` | Background model warm-up at startup (load + dummy inference); `0` disables it to save memory, at the cost of an extra 10-20s wait on the first colorization |
| `COLORIZER_IDLE_UNLOAD` | `600` | How many seconds of idle before releasing the model (memory + VRAM returned to the system; the next colorization wakes it automatically); `0` = keep it resident, never release |

## Dart engine (packages/manga_colorizer_core)

A pure-Dart package with no `dart:io` dependency, embeddable in Flutter — the offline/deterministic
path:

```bash
dart pub get
dart test                                      # 25 engine regression tests
dart run tool/colorize_auto_client.dart -i 漫画.png -o 输出.png
dart run manga_colorizer_cli:colorize -i 原稿.png -o 输出.png --hints hints.json
```

Features: luminance fully preserved, flat-fill of enclosed white regions, screentone descreening,
hint-color luminance adaptation, tiled inference; hint points use a global chroma-diffusion solve
(SOR-accelerated), more accurate than the lightweight server-side version; deterministic and
reproducible.

## Mobile (mobile/)

A lightweight Android-side workbench (Flutter) with two tabs:

- **Hint colorization**: pick an image → tap the canvas to drop hint points →
  colorize → share/save. Inference calls the pure-Dart engine
  `manga_colorizer_core` directly, running offline in an isolate, with no
  dependency on the desktop sidecar or any backend service, and no model
  weights needed.
- **Fully automatic**: on-device ONNX fully-automatic colorization, with
  pipeline semantics aligned to the desktop `/colorize_auto` — the same weight
  pair (v6_sam_encoder + v6_generator), tile 1024 / overlap 256 linear
  feathering, and the L channel always taken from the original gray image.
  Weights are not shipped inside the APK (CC BY-NC-SA); they are downloaded
  on first use inside the app, with resume support and SHA-256 verification,
  and the manifest carries an hf-mirror fallback source for mainland-China
  networks.

```bash
cd mobile
flutter pub get
flutter run            # Connect to an Android device / emulator
flutter test           # Widget smoke tests
```

Requires the Flutter SDK (Dart `^3.6.0`). The fully-automatic tab needs an
Android arm64 physical device: on-device inference runs on the ONNX Runtime
CPU execution provider (no GPU/NNAPI path); per-1024²-tile runtime and peak
memory are not yet measured on real devices, low-end devices may be slow, and
the gate numbers and conclusions here will be revised after real-device
measurement.
