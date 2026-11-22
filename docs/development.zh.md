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

### 跨端契约检查（改方案表 / 设计令牌 / 上限后必跑）

```bash
python tool/contracts/check_contracts.py   # stdlib，无需 venv / 权重
```

校验色彩方案表（`service.py FINISH_SCHEMES` ↔ `core finish.dart kFinishSchemes` ↔ Web
方案下拉）、暖纸设计令牌（`web/dist/app.css` ↔ `mobile/lib/theme/warm_tokens.dart`）、
Web 手动/系统主题色值、批量上限（`MAX_BATCH` ↔ `MAXN`）。发布工作流在 validate 阶段
自动执行；有漂移时退出码非 0 并逐条打印差异。

内存观测：桌面 sidecar 每张图结束后在日志与 `gallery.jsonl` 记录 `rss_mb` /
`rss_peak_mb`（CUDA 环境额外记 `gpu_mem_mb`；DirectML 没有用户态显存计数）；移动端
关键阶段已有 `RSS=…MB（峰值 …MB）` 日志（`mobile/lib/mem_info.dart`）。

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

- **引擎迁移：Sana-manga-coloring（2026-11-22, 第四轮）**: v6 GAN 的质量上限
  （色彩贫瘠/黄绿泛染）已到顶——WD14 语义自举在用户真机 8 页回归中被判负
  （见下条），模型迁移为主线。新引擎 `COLORIZER_ENGINE=sana` 接入
  [Sana-manga-coloring ONNX int8](https://huggingface.co/masterofaudio2077/sana-manga-coloring-onnx-int8)
  （**Apache-2.0**，SANA 600M i2i 漫画上色微调，纯 onnxruntime 无 PyTorch）:
  整页 i2i（短边 512、两边 32 倍数，无分块）、闭集五维标签条件
  （mood/time_of_day/lighting/saturation/palette，方案表 `sana_engine.SANA_SCHEMES`
  映射，quality_check 有词表校验）、输出自带手涂明度（不做 L 回写/收尾/一致性）。
  性能: CPU int8 20 步 ≈ 55-75s/页（4 线程；cache=0.15 步缓存 ≈1.6x），
  DirectML fp16 转换为后续性能主线。权重 ~2.7GB（encode/decode/head/blocks/out
  五文件）放 `models/manga-light-colorizer/sana-manga-coloring-int8/`。
  2026-11-22 续: 设置页新增「上色模型」切换（与移动端同语义）——service 以
  settings.json `engine` 热切换（释放两会话集，v6 重新预热，sana 五会话不常驻
  预热、首次上色懒加载），`COLORIZER_ENGINE` 环境变量只定启动默认；下载清单
  以 `optional: true` 条目接入 Sana 权重（boot 下载跳过可选文件、allReady 不
  计入），设置页「下载 Sana 权重」按钮按需触发（`cmd_start_optional_download`，
  复用断点续传/校验/镜像）。hints/reference 的语义基底同样经 colorize() 按
  当前引擎路由。
  验收: `COLORIZER_ENGINE=sana` 起服后 /colorize_auto 出图对比 v6 zeros——
  自然肤色/深发保留/背景干净/无黄绿泛染；已知差异: 调色板随噪声种子波动
  （固定种子可复现），「重新上色」按钮为后续 UX。
- **WD14 语义自举（默认关闭）**: 生成器 `wd14_embedding` 是
  FiLM 语义主色通路，官方推理脚本恒置零使模型处于欠饱和退化态（色度 C≈5.8）。sidecar
  现按「单步自举」出图: gen@512 zeros → MOAT tagger 吃原始输出去网点后的版本得
  1024 维嵌入 → gen@512 带嵌入出图。关键取证（`tmp/wd14_*.py`）: ①FiLM 通路仅在训练
  分辨率 512 有效（@1024 嵌入几乎不影响输出，嵌入方向两分辨率余弦 0.94），生成器因此
  固定跑 512、色度场上采样（赛璐璐平涂色度低频，结构由原稿 L 回写承担）；②两步迭代
  会振荡漂移，单步即收敛；③tagger 吃黑白原稿会拉向 monochrome 语义（色度反降），必须
  吃第一遍的彩色输出；④**tagger 输入必须去网点（3×3 中值×2）**——网点高频让 tagger
  把角色读成 bandages/black_background，嵌入把用户样张脸部引导成绿色（C=27, hue81°），
  去网点后读出 smile/open_mouth/1girl，脸部圆均色相 42° 自然肤色、绿域 77%→46%。
  效果: 收尾后非纸白区色度 gag 页 7.9→28.8 / 4koma 页 8.0→15.8，纸白更净。
  tagger 权重（wd14_tagger_moat.onnx, 326MB, Apache-2.0）经 weights-manifest.json
  随主权重下载；**缺失/损坏时自动回退 zeros 旧路径**（`/health` 的 `wd14` 三态可见）。
  env: `COLORIZER_WD14=0` 关闭、`COLORIZER_WD14_THREADS`（默认 4）。
  **移动端已启用（2026-11-21 第三轮）**: tagger 权重按档位门控——只有满配档
  （≥6GB，`ResourceTier.hostTagger`）在主权重就绪后顺手下载（可选组件，不阻塞
  必需权重；下载失败仅告警）；后端按文件存在性加载（缺失/损坏 → zeros 路径），
  加载失败（低内存 OOM）也只回退不致命。管线 `pipeline.dart` 走桌面同配方
  （gen@512 两遍 + 去网点 tagger 输入 + 特征逐通道双线性缩 32²/16²），自举
  中途失败整块降级 zeros@1024。MNN 后端不支持 tagger（zeros 路径）。真机验收
  清单: 满配档下载入口出现 tagger 条目且下载后全自动出图显著更饱和（对比
  zeros 版截图）；中/低档不出 tagger 下载且行为与旧版一致；推理中杀
  `:inference` 进程重启后自举恢复。验收: auto(DML) 与 CPU 各出一张，观感色彩
  应显著更饱和（DML 与 CPU 有固有数值差，各自可接受即可）；回退: 改名 tagger
  文件重启后 `/health` wd14.active=false 且三模式正常。
- **参考图模式升级（2026-11-21, 两端同步）**: ①auto 语义引导改用 tagger(参考图) 嵌入
  （`_emb_override`，输出色板明确向参考图语义靠拢，`tmp/ref_emb.py`）；tagger 不可用
  回退自举嵌入。②色调迁移从「作用在灰度原稿」改为「作用在 auto 输出」——旧实现把
  Reinhard 的 ref_std/src_std 作用在灰度扫描噪声上（std 1-3），色度被放大 5-8 倍成
  随机噪声，5:5 融合把语义色稀释成灰洗。③融合收尾补白色前景救援（两端同步:
  桌面 `_blend_reference_auto` / Dart `blendReferenceAuto` + 金样新增 rescue 用例）——
  网点衣服区在原稿是封闭近白（L=255），无救援时 L=100 色域映射把色度坍缩成纯白。
  移动端 `referenceColorizeInIsolate` 增加 width/height 参数（救援标记需要连通域）。
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
- [SmilingWolf/wd-v1-4-moat-tagger-v2](https://huggingface.co/SmilingWolf/wd-v1-4-moat-tagger-v2) 与 [deepghs/wd14_tagger_with_embeddings](https://huggingface.co/deepghs/wd14_tagger_with_embeddings) — WD14 语义自举的 tagger 权重（Apache-2.0）
- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer)、[qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2)、[xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ)、[lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — 调研参考（未复制代码/权重）
- Levin-Lischinski-Weiss 2004 色度扩散 — Dart 引擎算法基础
