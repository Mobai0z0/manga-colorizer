# Getting Started

[中文](getting-started.zh.md) · For the development/architecture guides see [architecture.en.md](architecture.en.md) and [development.en.md](development.en.md)

Four onboarding paths: the Windows installer (regular users), the Python service + browser
workbench (no desktop environment), building the desktop app from source (contributors), and
the Android app (on-device fully automatic, Option 4).

## Option 1: Windows installer (recommended for regular users)

1. Download `Manga Colorizer_<version>_x64-setup.exe` from [Releases](../../releases) and
   install it.
2. On first launch it downloads the model weights (~287 MB, one-time, into
   `%LOCALAPPDATA%\manga-colorizer\weights`). On networks in mainland China, retry through the
   system proxy or see [Manual weight download](#manual-weight-download).
3. Once ready, enter the workbench: drag in manga pages → tick the disclaimer checkbox → start
   colorization. Results live in the Gallery page; the files are in
   `%LOCALAPPDATA%\manga-colorizer\gallery`.

System requirements: Windows 10 1809+ / Windows 11 (WebView2 is installed automatically by the
installer). GPU acceleration requires a DX12 GPU (DirectML); without a GPU it automatically uses
the CPU.

## Option 2: Python service + browser workbench

Requires Python ≥ 3.10.

```bash
# 1) Dependencies (CPU base path)
python -m pip install -r tool/colorizer_service/requirements.txt

# Windows GPU (DirectML, any DX12 GPU): pick one of the two, never mix with the CPU build
python -m pip install -r tool/colorizer_service/requirements-directml.txt

# 2) Download model weights (~300MB, not distributed with the repo; in mainland China you can swap the domain to hf-mirror.com)
python -c "import urllib.request as u; [u.urlretrieve(f'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/{n}', f'models/manga-light-colorizer/{n}') for n in ['v6_generator.onnx','v6_sam_encoder.onnx']]"

# 3) Start the service (binds 127.0.0.1:8788)
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 4) Open http://127.0.0.1:8788/ in a browser
```

NVIDIA CUDA path: `python -m pip install -r tool/colorizer_service/requirements-gpu.txt`, supply
the matching CUDA/cuDNN runtime libraries yourself, and start with `COLORIZER_DEVICE=cuda`; if
CUDA is unavailable the service errors out explicitly instead of silently falling back.

> **DirectML version note**: `requirements-directml.txt` pins `onnxruntime-directml` to `<1.21`.
> In testing, the DirectML numerics of 1.24.x produce colored background splotches (noise) on
> this model, and the first tiled inference run on a long image easily triggers a momentary VRAM
> shortage; 1.20.1 is a clean baseline. 1.20.x has no Python 3.13/3.14 wheels, so use
> Python 3.10–3.12 for the GPU path (the CPU path works on 3.14). When GPU per-tile inference
> fails, that tile automatically falls back to CPU, so long images never fail as a whole.

## Option 4: Android app (on-device fully automatic)

Build from source with Flutter under `mobile/` (`flutter build apk --debug`, green at
implementation time on this branch), or wait for the official APK in Releases.

1. Install and open the app, switch to the "Fully automatic" tab.
2. Weights are not shipped inside the APK (CC BY-NC-SA); on first use the app guides you
   through downloading them (~300 MB, one-time), with resume support and SHA-256
   verification; the manifest carries an hf-mirror fallback source for mainland-China networks.
3. Once ready, pick an image and start fully automatic colorization; results can be
   shared/saved from inside the app. The "Hint colorization" tab is unaffected — it needs no
   weights and works fully offline.

Device requirement: an Android arm64 physical device. On-device inference runs on the ONNX
Runtime CPU execution provider (no GPU/NNAPI path); per-1024²-tile runtime and peak memory
are not yet measured on real devices — low-end devices may be slow, and the behavior and
conclusions of this option will be revised after measurement.

## Manual weight download

Download `v6_generator.onnx` and `v6_sam_encoder.onnx` from the
[model release page](https://huggingface.co/sharky172/manga-light-colorizer) (in mainland China
you can swap the domain to `hf-mirror.com`) and place them in:

- Desktop app: `%LOCALAPPDATA%\manga-colorizer\weights\manga-light-colorizer\`
- Running from source: the repo's `models/manga-light-colorizer/`

## Troubleshooting

| Symptom | Remedy |
|---|---|
| Top bar shows "Model warming up…" | The app loads the model in the background right at startup (10-20 s the first time); once warm-up finishes, colorization needs no waiting. On memory-constrained machines, `COLORIZER_PRELOAD=0` disables warm-up |
| Top bar shows "Model dormant" | After 10 minutes of idle the model is automatically unloaded to return memory/VRAM; this is normal behavior. Submitting a colorization wakes it automatically (~10-20 s); `COLORIZER_IDLE_UNLOAD=0` keeps it resident instead |
| Top bar shows "Service not connected" | Wait 1-2 minutes (sidecar startup); if it still fails, check the log at `%LOCALAPPDATA%\manga-colorizer\logs\sidecar.log`, or restart the app (choose "Restart service" in the dialog) |
| GPU greyed out in the processor options / "No usable GPU detected" | DirectML requires a DX12 GPU and a recent graphics driver; on NVIDIA machines using the CUDA path you must install CUDA/cuDNN yourself. The server-side log prints `get_available_providers()` |
| Colored splotches in the background of results | Confirm the sidecar was built with `requirements-directml.txt` (onnxruntime-directml <1.21); 1.24.x DirectML has known numerical issues on this model |
| Weight download failed | Check the network/proxy and retry (resumable download is supported); or follow the "Manual weight download" steps above |
| Theme not applying | The theme can be switched manually (button at the bottom of the navigation bar) and the choice is remembered; when not switched manually it follows the system light/dark setting |

## Performance reference (measured)

| Input | Backend | Time |
|---|---|---|
| 512×384 | GPU · DirectML (RTX 5060 Laptop, after warm-up) | ~2 s |
| 1280×760 single page | CPU (onnxruntime 1.30, laptop) | 10–18 s |
| 1280×7376 full page (tiled) | CPU | ~122 s |

Tiled inference quality (vs whole-image single-tile downscale): Lab a/b mean difference <0.6,
PSNR >33dB; seam jumps ≤0.5 (perceptible threshold 8). Figures are from single measured runs,
not guaranteed values.
