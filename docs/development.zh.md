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

## MNN 推理后端（v0.6.x，双后端之一）

桌面 sidecar 与移动端都有 MNN（阿里 3.6.1，CPU）作为可选推理运行时，与默认
ONNX Runtime 并存可切换（桌面 env `COLORIZER_BACKEND`，移动端设置页「推理后端」）。
模型链路与决策记录见 `docs/mnn-research.zh.md` 附录 A。

```bash
# 1) MNN 源码构建工具链（PyPI mnn 停在 2.9.6，必须源码构建；Windows 参考
#    tmp/pymnn-build.bat 的幂等构建链：vcvars64 → cmake Ninja → ninja → pip install）
git clone --branch 3.6.1 --depth 1 https://github.com/alibaba/MNN.git tmp/mnn-src

# 2) 图修复 + 转换 + 对拍（v6_*.fix.onnx 是过门前提：If 内联/pads 常量化/
#    InstanceNorm 分解三处都是 MNN 数值漂移根因，跳过修复图直接转换会漂移）
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
# 通过门：rgb uint8 99.8% 像素 ≤1、max ≤3、特征 cos ≥0.999（fp16/w8 不达标不分发）

# 3) 桌面启用 MNN 后端：pymnn 装进 .venv（requirements-mnn.txt 有完整构建参数），
#    把 models/manga-light-colorizer/v6_*.fp32.mnn 放进权重目录后
COLORIZER_BACKEND=mnn  # sidecar 启动环境变量；/health 的 backend 字段可见生效情况
```

移动端 MNN 以 git submodule vendor（`mobile/android/app/src/main/cpp/third_party/mnn`，
钉 3.6.1 tag）从源码编译进 APK，首次 `flutter build apk` 会显著变慢（三 ABI 各编一遍
MNN）；克隆仓库后需 `git submodule update --init --depth 1`。

## 已知限制

- 服务端提示点为 64px 窗口局部扩散（轻量版）；需要全局精确求解用 Dart CLI 路径。
- 参考图迁移是全局统计（Reinhard/histogram），不做逐区域语义对应；参考图模式的
  语义色相由模型提供（Lab a/b 5:5 融合），参考图只贡献全局色调统计。
- 服务绑定 127.0.0.1，无认证；对外部署需自备反向代理、认证与 TLS。
- Android 应用端侧全自动走 ONNX Runtime CPU 执行提供者（无 GPU/NNAPI 路径）：每
  1024² 分块耗时与 arm64 真机峰值内存尚未实测，低端设备可能较慢。v0.5.9 起推理跑在
  `:inference` 独立进程（UI 进程不被推理连坐，会话随进程归还），真机验收清单：
  连续多图不重付模型加载（高档 5min 空闲窗）、推理中切后台保活跑完（通知权限被拒
  也应照常）、加载中取消不崩且可立即重试、完成入库不卡顿、多次任务后 logcat 无
  lowmemorykiller 命中主进程。
- 权重 CC BY-NC-SA：上传 GitHub / 免费分享 / 非商业集成 OK；收费服务、广告盈利需另行授权
  （详见 [licensing.zh.md](licensing.zh.md) / [licensing.en.md](licensing.en.md)）。
- MNN 后端（v0.6.x）当前为**可选后端，默认仍是 ORT**；切默认需真机验收达标。验收清单
  （低/中/高三档设备，ORT vs MNN A/B，设置→推理后端切换）：
  - 分块耗时：同图全自动每 1024² 块耗时对比（log 页有逐块埋点），劣化 ≤30%；
  - 内存：`/proc` RSS 埋点 + `dumpsys meminfo <pkg>:inference` 看稳态 PSS（MNN mmap
    权重为 file-backed，可被回收——关注 private dirty 部分是否显著低于 ORT）；
  - 稳定性：低档机连跑 ≥10 张压测，`:inference` 进程零 LMK 命中、UI 进程零闪退；
  - 画质：同图双后端输出目检——**模型层**差异 ≤4/255 且占比 <0.3%（桌面已对拍）；
    **收尾层**允许更大差异：白区救援的逐像素 keep 门限宽度仅 2.0（c0±1），模型色度
    微扰会使浅色/近白区域的救援强度（压 L 与保色度）像素级翻转（实测 L 差至 14），
    属窄门限固有敏感而非后端缺陷；验收标准是「两版各自画质可接受」而非像素一致。
    若跨后端观感差异刺眼，后续可做救援门限加宽/软化的两端同步改动+金样重生成；
  - 切换链路：设置切 MNN → 重新进全自动页 → 就绪门控/下载入口正确；切回 ORT 不残留。

## 参与

- Issue / PR 欢迎为主题、性能与平台适配（macOS / Linux sidecar）贡献力量。
- 许可与发行边界见 [licensing.zh.md](licensing.zh.md)。

## 致谢与参考

- [sharky172/manga-light-colorizer](https://huggingface.co/sharky172/manga-light-colorizer) — ONNX 权重（CC BY-NC-SA 4.0）
- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer)、[qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2)、[xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ)、[lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — 调研参考（未复制代码/权重）
- Levin-Lischinski-Weiss 2004 色度扩散 — Dart 引擎算法基础
