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

### Cross-end contract check (required after changing schemes / design tokens / limits)

```bash
python tool/contracts/check_contracts.py   # stdlib only; no venv or weights needed
```

Validates the finish-scheme table (`service.py FINISH_SCHEMES` <-> `core finish.dart
kFinishSchemes` <-> Web scheme selector), warm-paper design tokens (`web/dist/app.css` <->
`mobile/lib/theme/warm_tokens.dart`), the Web manual/system theme color values, and the batch
limit (`MAX_BATCH` <-> `MAXN`). The release workflow runs it in the validate job; any drift
exits non-zero and prints every mismatch.

Memory telemetry: the desktop sidecar appends `rss_mb` / `rss_peak_mb` (plus `gpu_mem_mb` on
CUDA; DirectML exposes no user-space VRAM counter) to its log lines and `gallery.jsonl` after
each image; the mobile app already logs `RSS=…MB (peak …MB)` at key stages
(`mobile/lib/mem_info.dart`).

## MNN inference backend (v0.6.x, one of two backends)

The desktop sidecar and the mobile app both support MNN (Alibaba 3.6.1, CPU) as
an optional inference runtime, coexisting with the default ONNX Runtime and
switchable (desktop env `COLORIZER_BACKEND`, mobile settings "inference
backend"). Pipeline and decisions: `docs/mnn-research.zh.md` appendix A.

```bash
# 1) Build the MNN toolchain from source (PyPI mnn is stuck at 2.9.6; source
#    build required. On Windows see tmp/pymnn-build.bat: vcvars64 -> cmake
#    Ninja -> ninja -> pip install)
git clone --branch 3.6.1 --depth 1 https://github.com/alibaba/MNN.git tmp/mnn-src

# 2) Graph fix + conversion + comparison (v6_*.fix.onnx is a prerequisite for
#    passing the gate: If inlining / pads constant-folding / InstanceNorm
#    decomposition — three confirmed root causes of MNN numeric drift)
.venv/Scripts/python.exe tool/mnn/fix_encoder_graph.py \
  --src models/manga-light-colorizer/v6_sam_encoder.onnx \
  --dst models/manga-light-colorizer/v6_sam_encoder.fix.onnx
.venv/Scripts/python.exe tool/mnn/fix_encoder_graph.py \
  --src models/manga-light-colorizer/v6_generator.onnx \
  --dst models/manga-light-colorizer/v6_generator.fix.onnx \
  --input-name L_bw --skip-if-inline --decompose-instancenorm
.venv/Scripts/python.exe tool/mnn/convert_models.py --models-dir models/manga-light-colorizer
.venv/Scripts/python.exe tool/mnn/compare_onnx_mnn.py \
  --models-dir models/manga-light-colorizer --variants fp32 --gate
# Gate: rgb uint8 99.8% of pixels <=1, max <=3, feature cos >=0.999
# (fp16/w8 fail and are not shipped)

# 3) Desktop MNN backend: install pymnn into .venv (full build flags in
#    requirements-mnn.txt), place models/manga-light-colorizer/v6_*.fp32.mnn
#    into the weights dir, then
COLORIZER_BACKEND=mnn  # sidecar env; the /health backend field shows the state
```

On mobile, MNN is vendored as a git submodule
(`mobile/android/app/src/main/cpp/third_party/mnn`, pinned to the 3.6.1 tag)
and compiled from source into the APK; the first `flutter build apk` is
significantly slower (MNN built once per ABI). After cloning, run
`git submodule update --init --depth 1`.

## Known limitations

- Server-side hint points use local diffusion in a 64px window (the lightweight version); for a
  globally exact solve, use the Dart CLI path.
- Reference-image transfer is a global statistic (Reinhard/histogram); there is no per-region
  semantic correspondence. In reference mode the semantic hues come from the model (5:5 blend
  in Lab a/b); the reference image only contributes global tone statistics.
- The service binds 127.0.0.1 with no authentication; public deployment requires your own
  reverse proxy, authentication, and TLS.
- Android on-device fully-automatic colorization runs on the ONNX Runtime CPU execution
  provider (no GPU/NNAPI path): per-1024²-tile runtime and peak memory on arm64 physical
  devices are not yet measured, low-end devices may be slow. Since v0.5.9 inference runs
  in a dedicated `:inference` process (the UI process is insulated from inference crashes,
  sessions are returned with the process); real-device acceptance checklist: consecutive
  images without re-paying model load (5min idle window on the high tier), backgrounded
  inference keeps running via the foreground service (notification-permission denial must
  not block it), cancel during load must not crash and must allow an immediate retry, no
  jank at save/gallery time, and no lowmemorykiller hits on the main process in logcat
  across repeated tasks.
- Weights are CC BY-NC-SA: uploading to GitHub / free sharing / non-commercial integration are
  OK; paid services and ad-monetized use require separate authorization
  (see [licensing.en.md](licensing.en.md) for details).
- The MNN backend (v0.6.x) is currently an **optional backend; the default
  remains ORT**. Flipping the default requires passing real-device acceptance.
  Checklist (low/mid/high-tier devices, ORT vs MNN A/B via settings → inference
  backend):
  - Tile runtime: compare per-1024²-tile times on the same image (per-tile logs
    on the log page); degradation must be ≤30%;
  - Memory: `/proc` RSS instrumentation + `dumpsys meminfo <pkg>:inference` for
    steady-state PSS (MNN mmap weights are file-backed and reclaimable — check
    whether private dirty drops notably below ORT);
  - Stability: ≥10-image stress loop on the low tier, zero LMK hits on the
    `:inference` process, zero UI crashes;
  - Quality: visual A/B of both backends on the same image — the **model
    layer** delta is ≤4/255 on <0.3% of pixels (desktop-compared); the
    **finishing layer** may diverge more: the per-pixel keep gate of the
    white-rescue is only 2.0 wide (c0±1), so small model chroma perturbations
    flip rescue strength (L press and chroma keep) in light/near-white areas
    (measured L delta up to 14) — inherent narrow-gate sensitivity, not a
    backend defect. The bar is "each output looks acceptable on its own", not
    pixel identity. If cross-backend appearance diverges glaringly, a follow-up
    would widen/soften the gate on both ends + regenerate goldens;
  - Switching: set MNN → re-enter the auto page → readiness gating/download
    entry correct; switching back to ORT leaves no residue.

## Contributing

- Issues / PRs are welcome, especially contributions on theming, performance, and platform
  adaptation (macOS / Linux sidecar).
- For licensing and distribution boundaries see [licensing.en.md](licensing.en.md).

## Acknowledgments and references

- [sharky172/manga-light-colorizer](https://huggingface.co/sharky172/manga-light-colorizer) — ONNX weights (CC BY-NC-SA 4.0)
- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer), [qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2), [xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ), [lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — research references (no code/weights copied)
- Levin-Lischinski-Weiss 2004 chroma diffusion — algorithmic basis of the Dart engine
