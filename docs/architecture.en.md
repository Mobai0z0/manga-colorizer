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
original), color finishing (chroma gain + out-of-gamut equal-ratio shrink mapping, see the
Chinese doc section「色彩收尾」), and automatic GPU acceleration (DirectML preferred on Windows,
CUDA available on NVIDIA, automatic fallback to CPU when no GPU is present).

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
| `COLORIZER_CHROMA_GAIN` | `1.2` | Chroma gain applied to the fully automatic output (before quantization, clamped to 0.5-2.0); `1.0` = gain off, only the gamut mapping remains |

## Dart engine (packages/manga_colorizer_core)

A pure-Dart package with no `dart:io` dependency, embeddable in Flutter — the offline/deterministic
path:

```bash
dart pub get
dart test                                      # 35 engine regression tests
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
  feathering, the L channel always taken from the original gray image, and the
  same color finishing math (gain constant `kAutoChromaGain` matching the
  desktop default; the desktop tiled path feeds float chroma straight into the
  finish, while on-device it goes through 8-bit a/b quantization first,
  ≤0.5 Lab units — same order as the resize interpolation deviation).
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

### Inference process isolation (v0.5.9, after xororz/local-dream's architecture)

The fully-automatic pipeline (`AutoEngine`/worker RPC in
`onnx/auto_service.dart`) is served over two paths sharing the same seams
(factory and tiling parameters in `onnx/serving_seams.dart`):

- **Dedicated `:inference` process** (production default on Android):
  `InferenceService` (`android:process=":inference"`, kept alive by a dataSync
  foreground service) starts a headless FlutterEngine running the Dart
  entrypoint `inferenceMain`, which serves a frame protocol on 127.0.0.1
  (`onnx/socket_protocol.dart`, length-prefixed frames: hello/config/job →
  progress/log/result/error). The entrypoint lives in `inference_main.dart`,
  but the engine resolves named entrypoints against the root library only —
  `lib/main.dart` keeps a root-library forwarder (the two-arg `DartEntrypoint`
  consults `Dart_RootLibrary()`). `InferenceService.onStartCommand` must also
  call `FlutterLoader.startInitialization` first (that process has no
  FlutterActivity and the Application class is the default
  `android.app.Application`, so `findAppBundlePath` would NPE otherwise).
  An inference crash or a system kill only takes
  down the inference process; the UI process survives and can surface an error
  and retry, and process death returns both ORT sessions (~300MB) to the OS —
  **sessions have no leak path**. While backgrounded, the foreground service
  keeps the task running to completion (user-selected; needs the notification
  permission, denial does not block inference).
- **In-process isolate** (fallback path): used automatically when the service
  fails to start/connect (OEM background limits, non-standard devices); also
  the natural path for Windows debugging and host tests. Cancel/shutdown/idle/
  memory-pressure all go through graceful stop — the worker finishes its
  current tile (a native run cannot be interrupted) → `dispose()` →
  `['stopped']` ack before the handle is reclaimed, eliminating the Kotlin-side
  session retention on kill paths (the root cause of the earlier
  "crash right after starting colorization"); kill remains only as the
  grace-timeout fallback for a hung native call.
- **Automatic retry on unexpected worker death**: when the `:inference` process
  dies mid-task (LMK reclaim, native crash), AutoEngine no longer fails the
  in-flight job outright — within a retry budget (default 2) it reaps the dead
  worker, restarts the service with the original ResourceTier settings, and
  resends the current image: the UI merely sees progress restart from zero,
  plus one warn line carrying the death reason. A user cancel/shutdown during
  the retry window aborts the revive immediately (no inference is resurrected
  behind a cancelled task); once the budget is exhausted the job fails as
  before. The death reason is captured via `ApplicationExitInfo` (API 30+,
  `exitReason` on MainActivity) — the main process queries the last exit
  record of `:inference` (only entries fresher than 10 minutes, to avoid
  misleading stale records) and the log page shows the actual root cause
  ("low-memory kill (LMK)" / "native crash (signal n)" / ANR) instead of a
  vague guess.
- Cancel/shutdown/idle-expiry/memory-pressure (idle-gated) all end up
  returning the ~300MB of sessions on both paths; the idle retention is
  tiered via ResourceTier (≥6GB 5min / 4–6GB 2min / low tier 60s) so
  consecutive images do not pay the model load again.
