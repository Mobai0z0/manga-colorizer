# manga-colorizer · 黑白漫画上色后端


## 深度模型上色 (推荐, 已落地)

纯 Dart 引擎之上新增 **Python ONNX 服务** (manga-light-colorizer, 语义上色):
颜色由深度模型预测 (非区块调色), 亮度通道始终回写原稿。
真实漫画实测: 语义配色正确 (发/肤/瞳/背景), CPU 约 10s/张。
方案与验收: `docs/plan-colorization-v2.md` / `docs/acceptance-phase-a.md`。
许可与发行边界: `docs/licensing.md` (社区非商业预览版)。

```bash
# 一次性: 安装 Python 依赖 (CPU 基础路径) + 下载权重 (约 300MB, 可用 hf-mirror 镜像)
python -m pip install -r tool/colorizer_service/requirements.txt
python -c "import urllib.request as u; [u.urlretrieve(f'https://hf-mirror.com/sharky172/manga-light-colorizer/resolve/main/models/{n}?download=true', f'models/manga-light-colorizer/{n}') for n in ['v6_generator.onnx','v6_sam_encoder.onnx']]"

# 启动服务 (默认 CPU; 首次请求自动加载模型)
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 方式 A: 浏览器打开 http://127.0.0.1:8788/ (MD3 工作台: 上传/对比/下载)
# 方式 B: Dart 客户端 (全自动, 无需提示点)
dart run tool/colorize_auto_client.dart -i 漫画.png -o 输出.png
```

**许可与设备说明** (详见 `docs/licensing.md`):
- 模型权重 CC BY-NC-SA 4.0 —— 上传 GitHub/免费社区使用/非商业应用集成本身不等于商用,
  但收费服务、广告盈利、商业推广需另行授权; 权重不随仓库分发。
- 环境 `COLORIZER_DEVICE=cpu|auto|cuda` (默认 cpu); `cuda` 失败时明确报错不静默回退,
  GPU 需自装 onnxruntime-gpu 及配套 CUDA/cuDNN (`requirements-gpu.txt`)。
- `COLORIZER_MODEL_DIR` 可指定权重目录; 上限 20MiB / 16M 像素 / 单并发。
- 服务只绑定 127.0.0.1; 对外部署请自备反向代理与认证。

纯 Dart 实现的黑白漫画/线稿上色引擎 + HTTP 服务 + CLI 工具集 + 浏览器工作台。

| 包/目录 | 说明 |
|---|---|
| `packages/manga_colorizer_core` | 上色引擎: 提示点色度扩散(Levin 2004)+ 亮度渐变映射,零原生依赖 |
| `packages/manga_colorizer_server` | shelf HTTP 服务: REST API + 交互式 API 演示页 |
| `packages/manga_colorizer_cli` | 命令行: 批量上色 / 样例生成 / 三联对比图 |
| `tool/colorizer_service` | Python ONNX 模型服务 (深度上色后端, 见上节) |
| `web/dist` | MD3 风格浏览器工作台 (零构建, 由 ONNX 服务同源挂载, 见 `web/dist/README.md`) |

## 快速开始

```bash
# 1) 拉依赖 (workspace 结构,在仓库根执行一次即可)
dart pub get

# 2) 启动后端 (http://127.0.0.1:8787, 含 API 演示页)
dart run manga_colorizer_server:server --port 8787

# 3) 生成合成漫画样例 + 提示点上色 + 三联对比图
dart run manga_colorizer_cli:make_sample -o out/sample_manga.png
dart run manga_colorizer_cli:colorize -i out/sample_manga.png -o out/colorized.png --hints out/hints.json
dart run manga_colorizer_cli:compare -i out/sample_manga.png -o out/compare.png --hints out/hints.json

# 4) 整图色调映射 (无提示点, 一键怀旧色)
dart run manga_colorizer_cli:colorize -i 原稿.png -o 输出.png --preset sepia

# 5) 测试与分析
dart test
dart analyze
```

## 两种上色模式

### 1. 提示点上色 `colorizeManga` — 点哪儿色哪儿

在黑白图上放置若干提示点 (坐标 + 目标 RGB),引擎把色度沿**亮度相近的连通区域**扩散
(Levin-Lischinski-Weiss 2004 色度扩散, YUV 空间 + SOR 加速 + 粗到细多尺度求解):

- 亮度 (Y) 完全保留原稿 —— 线稿、网点、明暗不丢失;
- 纯黑/纸白自动锁定为无色边界 (`lockPureMonochrome`,可关);
- **封闭白区平涂** (`fillClosedWhiteRegions`,默认开): 有明确提示点的封闭近白区域
  (如脸部、衣服内空白) 按提示色平涂并保留原明暗纹理;连到图像边缘或无提示的
  白区保持纸白不受污染;
- **网点漫画支持** (`descreen`,网点页建议开启): 求解/锁定/归属统一用盒模糊均值场
  (网点→灰阶反解),输出把网点展平为均匀色层 (均值场亮 ≤0.12 的墨线保留);
  v0.5 修复: 旧版中值滤波对 50% 棋盘网点无效,且原亮度 0/255 把整块网点锁成中性,
  导致网点区域染不上色。
- 提示色只表达"色相意图",`adaptHintChromaToLuminance` 默认按目标区亮度适配色度幅值,
  深色提示也能染深色区域;
- 多尺度预解让 512×640 级别的图在秒级全局收敛。

```dart
final result = colorizeManga(
  grayscaleRgb: gray,          // 8bit RGB 交错, r=g=b
  width: w, height: h,
  hints: [ColorHint(x: 195, y: 173, r: 86, g: 26, b: 178)],
);
```

### 2. 整图色调 `applyTint` — 一键换色调

亮度 → 调色板渐变映射 (gradient map),自带 `sepia` / `warm-dawn` / `moonlit` 预设,
支持自定义锚点和纸白保护:

```dart
final rgb = applyTint(
  grayscaleRgb: gray, width: w, height: h,
  palette: kTintPresets['sepia']!,
  options: const TintOptions(strength: 0.9, protectPaper: true),
);
```

## HTTP API

启动: `dart run manga_colorizer_server:server --port 8787` (默认 127.0.0.1:8787)

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/health` | 健康检查 + 引擎信息 |
| GET | `/api/presets` | 内置色调预设 |
| POST | `/api/colorize` | multipart: `image`(文件) + `hints`(JSON 数组) + `options`(JSON, 可省) → PNG |
| POST | `/api/tint` | multipart: `image` + `preset` 或 `palette` + `options` → PNG |

hints 数组元素: `{"x":int, "y":int, "r":0-255, "g":0-255, "b":0-255}`,上限 4096 个。
colorize 响应头: `x-colorize-iterations` / `x-colorize-max-delta` / `x-colorize-hints` /
`x-colorize-locked-monochrome`。

colorize 可选 options (JSON, 全部可省):

```json
{
  "sigma": 0.03,                      // 亮度相似度带宽, 越小越尊重线稿边界
  "epsilon": 1e-6,                    // 权重下限
  "maxIterations": 300,               // 全分辨率 SOR 迭代上限
  "sorOmega": 1.93,                   // SOR 松弛因子 (0,2)
  "tolerance": 1e-5,                  // 收敛阈值
  "lockPureMonochrome": true,         // 锁定纯黑/纸白
  "fillClosedWhiteRegions": true,     // 平涂有提示的封闭近白区域 (脸部等)
  "monochromeLowThreshold": 0.05,     // 墨黑阈值 (亮度 ≤)
  "monochromeHighThreshold": 0.95,    // 纸白阈值 (亮度 ≥)
  "adaptHintChromaToLuminance": true, // 提示色度按目标区亮度适配
  "regionChromaCorrection": true,     // 区域色度校正 (后处理)
  "chromaMagnitudeGain": 1.0,         // 校正幅值增益 (>1 加饱和)
  "hueCorrectionStrength": 0.35,      // 色向对齐提示色强度 (0..1)
  "regionLuminanceWeight": 4.0        // 区域归属中亮度距离权重
}
```

tint 可选 options: `{"strength": 0..1, "protectPaper": bool, "paperThreshold": 0..255}`。

curl 示例:

```bash
curl -F "image=@page.png" \
     -F 'hints=[{"x":100,"y":80,"r":86,"g":26,"b":178}]' \
     -F 'options={"maxIterations":400}' \
     http://127.0.0.1:8787/api/colorize --output colored.png
```

浏览器打开 `http://127.0.0.1:8787/` 即为 API 演示页 (上传 → 点击放提示点 → 上色预览),
仅作接口验证,不是产品前端。

## 与未来 Flutter 前端的衔接

两条路径, 已按此分层:

1. **进程内直接调用** — `manga_colorizer_core` 是纯 Dart 包 (无 dart:io 依赖),
   Flutter App 直接 `import 'package:manga_colorizer_core/manga_colorizer_core.dart'`,
   提示点 UI → `colorizeManga()` 即可, 移动端同源同行为;
2. **HTTP 远程调用** — App/网页通过 `/api/colorize` 上传原图+提示点, 服务端渲染回 PNG。

## 色板驱动的常识与一致性上色 (v0.2)

针对“颜色要符合人类常识 (如肤色)、同一角色颜色统一”的需求, 引擎新增三层机制
(详见 `docs/character-color-spec.md` 与 `docs/workflow-sop.md`):

1. **角色色板档案** — 角色各部位固定色值 (JSON), 提示点颜色只从色板生成;
2. **自然肤色扇区约束** — 肤色色相钋进公开五档种子色推导的暖色窄带,
   入口拒绝发绿/发灰/蜡像色板 (`enforceNaturalSkin`, 默认开);
3. **成图校验器** — 逐部位取样比对色板 (色相差 ≤8° 硬契约) + 肤色扇区复检,
   退出码 0=PASS / 70=FAIL / 65=色板违和。

```bash
# 角色色板 + 槽位 → 上色 → 自动校验 (三场景: single / single-dim / duo)
dart run manga_colorizer_cli:colorize_palette \
  --palette out/character_palettes.json --character akari \
  --scene duo --out-dir out
```

回滚 = 保留每版色板 JSON, 用上一版重跑同名命令即可逐字节复现 (算法确定性已演练)。

## 批量上色与定量验证 (v0.3, 参考 Manga-Colorizer 生态后新增)

```bash
# 固定测试集 12 张 (含 3 张 1024x1280 大图触发分块管线), 逐张出对比图+指标
dart run manga_colorizer_cli:batch_run \
  --palette out/character_palettes.json --character akari --out-dir out/batch
```

- 每张产出 `<tag>.png` (成图) 与 `<tag>-compare.png` (原稿|成图双联);
- `batch_metrics.json` 留档: PSNR-Y (结构保真)、色度覆盖率、耗时、tile 数;
- 复跑确定性: 同参数重跑 PSNR-Y 逐位一致 (2026-09-15 演练 12/12 一致);
- 留档基线: 日常图 PSNR-Y 62–72dB, 色度覆盖事 0.98–1.00;
  1024x1280 分块 (9 tiles) PSNR-Y 72.9–73.2dB, 覆盖事 0.74–0.79。

## 异常处理与退出码

| 场景 | 行为 | 退出码 |
|---|---|---|
| 损坏/空/无法解码文件 | stderr 明确报错, 安全退出 | 65 |
| 找不到输入文件 | stderr 明确报错 | 66 |
| 参数/JSON 非法 | stderr 明确报错 | 64 |
| 色板肤色违反常识扇区 | 引擎入口拒绝, 不产出成图 | 65 |
| 成图校验 FAIL (色相差 >8°) | 打印逐部位偏差 | 70 |
| API 无效 multipart / 越界提示点 / 未知 preset | 400 / 400 / 404 JSON 错误 | HTTP 码 |
| 超大 multipart (>64MB) | 413 | HTTP 码 |
| 深度模型权重缺失 (Phase 2 未启用) | 不依赖任何权重, 本引擎无需下载 | — |

## 风险与回滚预案

| 风险 | 预案 |
|---|---|
| 上色效果不稳/偏色 | 保留每版色板 JSON; 校验器逐部位拦截; 回滚 = 用上一版色板重跑 (确定性逐字节复现, 已演练) |
| 依赖冲突 | Dart SDK ≥3.6; 仅依赖 image/shelf/args 四个纯 Dart 包 (pub.dev 锁定版本于 pubspec.lock) |
| 大图内存 | >768px 自动分块 (tile 512 / overlap 64); 可调 tileSize/overlap |
| 外部参考仓库权重链接失效 | 本引擎零权重依赖, 不受影响; 参考仓库链接仅调研用途 |
| 环境无 GPU | 本引擎纯 CPU 实现 (Dart), 无 GPU 要求 |

## Phase 2 路线 (深度模型)

- `onnxruntime` / `onnxruntime_dart` 类绑定 + 开源上色模型 — 候选: qweasdd/manga-colorization-v2 (BinitDOX/Manga-Colorizer 同款内核, 权重许可待核实), MangaNinja (参考图对齐, 一致性最强); 详见 `docs/research-manga-colorizer.md`;
- 去噪预处理槽位 (对标 FFDNet): 当前按亮度处理网点;
- 分层输出 (对标 Style2Paints 的 PSD): 色板天然对应线稿层/固有色层;
- 引擎接口已按 "灰度输入 → RGB 输出" 抽象, 换深度模型不影响 API 契约。

## 参考项目与许可说明

本项目的算法谱系与致谢 (全部为调研参考, 未复制任何代码/权重):

- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer) — 用户指定主参考; 其架构 (扩展+自托管) 与 576px 约束教训为本项目的反面教材; 仓库页未标注 LICENSE;
- [qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2) — 上游 AI 内核 (Generator+Extractor+FFDNet), hint 通道设计参考; 页面未标注 LICENSE;
- [xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ) — 分块推理与超分整合经验 (有 LICENSE);
- [lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — 分层输出思想; 代码 Apache-2.0, 模型保留所有权利 (故不采用其模型);
- [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) — 超分组件 (本引擎暂未集成)。

本引擎为独立纯 Dart 实现 (Levin 2004 色度扩散 + 自研工程化), 不含上述项目的任何代码或模型权重; 商用前请自行核实各参考仓库许可。

## 已知边界

- SOR 迭代为 CPU 实现, 4K 级原图建议先缩放再上色 (引擎内部已多尺度加速);
- 极细网点 (screentone) 目前按亮度处理, 专门的网点检测/去除属 Phase 2;
- WebP 解码依赖 `image` 包能力, 个别旧版 WebP 可能不支持。
