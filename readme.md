# manga-colorizer

黑白漫画（含网点）语义上色工具箱：深度模型自动上色 + 提示点精修 + 参考图色调迁移，附零构建 Web 工作台与纯 Dart 确定性引擎。

- **全自动** — ONNX 语义上色（SAM 引导 + generator），发/肤/瞳/背景语义配色
- **提示点** — 画布点击落点，指定区域颜色
- **参考图** — 上传任意彩图，提取整体色调迁移到原稿
- **长图** — >1024px 自动分块推理（overlap 256 + 线性羽化），整页漫画无下采样损失
- **亮度保真** — 所有模式只写 Lab a/b 色度，L 通道始终回写原稿

**许可**：本仓库代码 [Apache-2.0](LICENSE)；模型权重 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)（不随仓库分发，使用者自行下载，见 [NOTICE](NOTICE) 与 [docs/licensing.md](docs/licensing.md)）。

## 架构

```
web/dist  MD3 风格工作台（零构建，同源挂载，无 CORS）
   │
tool/colorizer_service  FastAPI + ONNX Runtime（:8788）
   ├─ 全自动:   manga-light-colorizer（SAM 语义引导 + generator）
   ├─ 提示点:   亮度相似度加权色度扩散（服务端轻量版）
   ├─ 参考图:   Reinhard Lab 主色迁移 ⊕ 模型语义色
   └─ 长图:     tile 1024 / overlap 256 线性羽化融合

packages/manga_colorizer_core    纯 Dart 上色引擎（Levin 2004 色度扩散，确定性，可离线）
packages/manga_colorizer_server  Dart shelf HTTP 服务（:8787，REST + 演示页）
packages/manga_colorizer_cli     批量上色 / 样例 / 三联对比图 / 色板工具
```

## 快速开始

要求：Python ≥3.10（Web 工作台 + 深度上色）；Dart SDK ≥3.6（引擎与 CLI，可选）。

```bash
# 1) Python 依赖（CPU 基础路径）
python -m pip install -r tool/colorizer_service/requirements.txt

# 2) 下载模型权重（约 300MB，不随仓库分发；国内可把域名换成 hf-mirror.com）
python -c "import urllib.request as u; [u.urlretrieve(f'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/{n}', f'models/manga-light-colorizer/{n}') for n in ['v6_generator.onnx','v6_sam_encoder.onnx']]"

# 3) 启动服务（默认 CPU，绑定 127.0.0.1:8788）
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 4) 打开工作台
#    http://127.0.0.1:8788/
```

GPU（可选）：`python -m pip install -r tool/colorizer_service/requirements-gpu.txt` 并自备匹配的 CUDA/cuDNN，然后 `COLORIZER_DEVICE=cuda` 启动；CUDA 不可用时服务明确报错，不会静默回退。

Dart 部分（可选）：

```bash
dart pub get
dart run tool/colorize_auto_client.dart -i 漫画.png -o 输出.png   # HTTP 客户端
dart test                                # 25 项引擎回归
```

## HTTP API（Python 服务，:8788）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 服务状态：权重在位、模型加载、实际 provider、回退原因 |
| GET | `/api/v1/capabilities` | 模式、端点、限制、许可声明（前端据此渲染） |
| POST | `/colorize_auto` | multipart `image` → PNG（全自动语义上色） |
| POST | `/colorize_hints` | multipart `image` + `hints`(JSON) → PNG（提示点精修） |
| POST | `/colorize_reference` | multipart `image` + `reference` → PNG（色调迁移） |

`hints` 元素：`{"x":int, "y":int, "r":0-255, "g":0-255, "b":0-255}`，上限 4096。

```bash
# 全自动
curl -F "image=@page.png" http://127.0.0.1:8788/colorize_auto -o colored.png

# 提示点（画布坐标 + RGB）
curl -F "image=@page.png" \
     -F 'hints=[{"x":640,"y":300,"r":30,"g":136,"b":229}]' \
     http://127.0.0.1:8788/colorize_hints -o colored.png

# 参考图色调迁移
curl -F "image=@page.png" -F "reference=@character.png" \
     http://127.0.0.1:8788/colorize_reference -o colored.png
```

错误语义：`400` 格式/参数错误 · `413` 超 20MiB 或 16M 像素 · `429` 单并发占用 · `503` 模型未就绪 · `500` 服务端错误（响应均为 `{"error": "..."}`）。

### 配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `COLORIZER_DEVICE` | `cpu` | `cpu` / `auto` / `cuda`；`cuda` 失败直接报错不回退 |
| `COLORIZER_MODEL_DIR` | `models/manga-light-colorizer` | 权重目录 |

限制：上传 ≤20MiB、≤16M 像素、单并发（其余请求 429）、仅 PNG/JPEG/WebP。

## Web 工作台

`web/dist/` 由服务同源挂载（`http://127.0.0.1:8788/`），零构建零运行时依赖：

- 拖放/点选上传，类型与大小预检（限制从 `/api/v1/capabilities` 读取）
- 提示点模式：色板选色 → 画布点击落点 → 双击删除 → 上色
- 参考图模式：缩略图预览 → 色调迁移
- 原图/上色切换对比、下载、耗时与尺寸显示
- 服务状态徽标（就绪/权重缺失/未连接，15s 轮询）
- 深浅主题跟随系统，`prefers-reduced-motion` 降级；桌面/移动响应式

技术说明：MD3 令牌以原生 CSS 变量实现（非官方 `@material/web` 包），交互逻辑无框架（`web/dist/app.js`），详见 [web/dist/README.md](web/dist/README.md)。

## Dart 引擎（离线 / 确定性路径）

`manga_colorizer_core` 是无 `dart:io` 依赖的纯 Dart 包，可嵌入 Flutter：

```dart
final result = colorizeManga(
  grayscaleRgb: gray, width: w, height: h,
  hints: [ColorHint(x: 195, y: 173, r: 86, g: 26, b: 178)],
);
final toned = applyTint(grayscaleRgb: gray, width: w, height: h,
  palette: kTintPresets['sepia']!);
```

特性：亮度完全保留、封闭白区平涂、网点 descreen（盒模糊均值场）、提示色亮度适配、tile 分块。提示点是**全局**色度扩散求解（SOR 加速），比服务端轻量版更精确；确定性可复现（同参数逐位一致），适合批量与回归。CLI：

```bash
dart run manga_colorizer_cli:colorize -i 原稿.png -o 输出.png --hints hints.json
dart run manga_colorizer_cli:compare  -i 原稿.png -o 对比.png --hints hints.json
dart run manga_colorizer_cli:batch_run --palette out/character_palettes.json --character akari --out-dir out/batch
```

Dart 服务（:8787）另提供 `/api/colorize`、`/api/tint`，见 `dart run manga_colorizer_server:server`。

## 性能参考（实测）

| 输入 | 后端 | 耗时 |
|---|---|---|
| 1280×760 单页 | CPU（onnxruntime 1.30，laptop） | 10–18 s |
| 1280×7376 整页（分块） | CPU | ~122 s |

分块推理质量（vs 单块整缩）：Lab a/b 均值差 <0.6，PSNR >33dB；窗口接缝跳变 ≤0.5（可见阈值 8），无可见拼接痕。数据为单次实测，非保证值；GPU 路径未在本仓库验证（CUDA 依赖属环境配置）。

## 已知限制

- 服务端提示点为 64px 窗口局部扩散（轻量版）；需要全局精确求解用 Dart CLI 路径。
- 参考图迁移是全局统计（Reinhard），不做逐区域语义对应；人设精确映射见路线图。
- ONNX 服务默认 CPU；CUDA 路径需自配依赖，本仓库未验证具体 GPU 性能。
- 服务绑定 127.0.0.1，无认证；对外部署需自备反向代理、认证与 TLS。
- 权重 CC BY-NC-SA：上传 GitHub / 免费分享 / 非商业集成 OK；收费服务、广告盈利需另行授权（详见 [docs/licensing.md](docs/licensing.md)）。

## 开发

```bash
dart pub get          # workspace 依赖
dart test             # 引擎 25 项回归
dart analyze          # 静态分析
```

- 引擎改动跑 `packages/manga_colorizer_core/test/`（25 项全绿为基线）。
- 服务无自动化测试套件；手动验证：`GET /health`、`GET /api/v1/capabilities`、小图三模式 POST。
- 前端改动用 `node --check web/dist/app.js` + 无头浏览器截图复核。
- 仓库不含模型权重、真实漫画素材与运行产物（`.gitignore` 已排除）。

## 路线

- [ ] 参考图逐区域语义映射（人设对位，参考 MangaNinja 思路）
- [ ] 服务端提示点升级为全局扩散求解
- [ ] Docker 镜像与 CI（含模型下载校验）
- [ ] GPU 路径文档与实测矩阵

## 致谢与参考

- [sharky172/manga-light-colorizer](https://huggingface.co/sharky172/manga-light-colorizer) — ONNX 权重（CC BY-NC-SA 4.0）
- [BinitDOX/Manga-Colorizer](https://github.com/BinitDOX/Manga-Colorizer)、[qweasdd/manga-colorization-v2](https://github.com/qweasdd/manga-colorization-v2)、[xiaogdgenuine/Manga-Colorization-FJ](https://github.com/xiaogdgenuine/Manga-Colorization-FJ)、[lllyasviel/Style2Paints](https://github.com/lllyasviel/Style2Paints) — 调研参考（未复制代码/权重）
- Levin-Lischinski-Weiss 2004 色度扩散 — Dart 引擎算法基础

以上参考均为独立实现对照，本仓库不含其代码或权重。
