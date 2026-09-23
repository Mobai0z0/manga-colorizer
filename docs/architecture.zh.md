# 架构与 API（中文）

[English](architecture.en.md) · 上手见 [getting-started.zh.md](getting-started.zh.md)

## 组件总览

```
Tauri 2 桌面壳（src-tauri）  窗口生命周期 / 权重下载器（断点续传 + sha256）/ sidecar 看护与自动重启
  └─ web/dist                M3 风格前端（零构建，唯一页面 index.html + app.js）
       │ fetch（CORS）
       ▼
Python sidecar（:8788，tool/colorizer_service）
  ├─ 全自动:   manga-light-colorizer（SAM 语义引导 + generator，ONNX Runtime）
  ├─ 提示点:   亮度相似度加权色度扩散（服务端轻量版）
  ├─ 参考图:   Reinhard Lab 主色迁移 ⊕ 模型语义色
  ├─ 长图:     tile 1024 / overlap 256 线性羽化融合
  └─ 图库台账: gallery.jsonl + settings.json 持久化

packages/manga_colorizer_core    纯 Dart 上色引擎（Levin 2004 色度扩散，确定性，可离线）
packages/manga_colorizer_cli     批量上色 / 三联对比图 / 色板工具
packages/manga_colorizer_server  Dart HTTP 后端（shelf，实验路径）
mobile/                          Flutter Android 壳（调用同款 Dart 引擎）
```

功能特性：全自动 ONNX 语义上色（SAM 引导 + generator）、提示点画布精修、参考图色调迁移、
批量队列（一次最多 32 张，单张失败不阻断）、长图自动分块推理、亮度保真（所有模式只写
Lab a/b 色度，L 通道始终回写原稿）、GPU 自动加速（Windows 优先 DirectML，NVIDIA 可用
CUDA，无 GPU 自动回退 CPU）。

## 前端（web/dist）

Material Design 3 风格，**零构建、零运行时依赖**（MD3 令牌以原生 CSS 变量实现，未使用
官方 `@material/web` npm 包；如需官方组件实现可另行替换，接口不变）。

服务端 `tool/colorizer_service/service.py` 检测到该目录存在时自动将 `/` 挂载到它；桌面壳
（Tauri）窗口也从打包内的同目录加载页面。跨源访问由服务端 CORS 中间件放行（服务仅绑定
127.0.0.1，不暴露局域网）。

| 文件 | 说明 |
|---|---|
| `index.html` + `app.js` | 唯一前端页面（浏览器工作台与桌面壳共用：导航 + 批量队列 + 提示点画布 + 参考图 + 图库台账 + 控制台日志） |
| `boot-shell.html` | 桌面壳首次启动的权重下载页（仅 Tauri 内使用） |
| `app.css` | M3 (Expressive) 令牌与组件样式（深浅主题令牌在此维护） |
| `app-shell.css` / `app-ui.css` | 导航壳层与 APP 功能组件样式 |

界面能力：拖放/点选上传（PNG/JPEG/WebP，限制从 `/api/v1/capabilities` 读取）、服务状态
徽标（轮询 `/health`）、三种上色模式、非商业许可确认勾选、原图/结果对比、结果下载、
深浅主题（跟随系统 + 手动切换记忆）、`prefers-reduced-motion` 动画降级。

## Python sidecar（tool/colorizer_service）

FastAPI 服务，端点：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 服务状态：权重在位、模型加载、实际 provider、回退原因 |
| GET | `/api/v1/device` | 设备信息：可用 provider、GPU 型号/显存/驱动、输出目录 |
| GET | `/api/v1/capabilities` | 模式、端点、限制、许可声明 |
| POST | `/colorize_auto` | multipart `image` → PNG（全自动语义上色） |
| POST | `/colorize_hints` | multipart `image` + `hints`(JSON) → PNG（提示点精修） |
| POST | `/colorize_reference` | multipart `image` + `reference` → PNG（色调迁移） |
| POST | `/api/v1/batch` | 批量队列（按提交顺序逐个处理，单个失败不阻断） |
| GET | `/api/v1/gallery` | 上色台账（`limit` 参数，含耗时/设备/尺寸） |
| GET | `/api/v1/logs` | 后端日志环形缓冲增量拉取（`after` 序列号） |
| GET/POST | `/api/v1/settings` | 模式 / 处理器 / 主题 / 免责声明 持久化 |
| GET | `/gallery/file/{name}` | 读取图库成品图片（仅限输出目录下的文件，带缓存头） |
| POST | `/shutdown` | 仅回环地址：释放模型显存/内存并请求服务优雅退出（桌面壳退出时调用） |

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

错误语义：`400` 格式/参数错误 · `413` 超 20MiB 或 16M 像素 · `429` 单并发占用 ·
`503` 模型未就绪 · `500` 服务端错误（响应均为 `{"error": "..."}`）。

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `COLORIZER_DEVICE` | `cpu` | `cpu` / `auto` / `cuda`；`auto` 按可用 provider 选择（CUDA 优先于 DirectML） |
| `COLORIZER_MODEL_DIR` | `models/manga-light-colorizer` | 权重目录 |
| `COLORIZER_OUTPUT_DIR` | `out/gallery` | 成品与台账目录 |
| `COLORIZER_WEB_DIST` | `web/dist` | 静态前端目录（不存在则不挂载 `/`） |
| `COLORIZER_LOG_FILE` | — | 追加写入的日志文件 |
| `COLORIZER_PRELOAD` | `1` | 启动时后台预热模型（加载 + 空推理）；`0` 关闭以省内存，代价是首次上色多等 10-20s |
| `COLORIZER_IDLE_UNLOAD` | `600` | 空闲多少秒后释放模型（内存+显存归还系统，下次上色自动唤醒）；`0` = 常驻不释放 |

## Dart 引擎（packages/manga_colorizer_core）

无 `dart:io` 依赖的纯 Dart 包，可嵌入 Flutter，离线/确定性路径：

```bash
dart pub get
dart test                                      # 25 项引擎回归
dart run tool/colorize_auto_client.dart -i 漫画.png -o 输出.png
dart run manga_colorizer_cli:colorize -i 原稿.png -o 输出.png --hints hints.json
```

特性：亮度完全保留、封闭白区平涂、网点 descreen、提示色亮度适配、tile 分块；提示点为
全局色度扩散求解（SOR 加速），比服务端轻量版更精确；确定性可复现。

## 移动端（mobile/）

Android 侧轻量工作台（Flutter）：选图 → 画布点按落提示点 → 上色 → 分享/保存。推理直接
调用纯 Dart 引擎 `manga_colorizer_core`，在 isolate 中离线执行，不依赖桌面 sidecar 或
任何后端服务；不涉及 ONNX 权重（CC BY-NC-SA 仅约束桌面/浏览器全自动路径）。

```bash
cd mobile
flutter pub get
flutter run            # 连接 Android 设备 / 模拟器
flutter test           # 控件冒烟测试
```

要求 Flutter SDK（Dart `^3.6.0`）。Android 端侧 ONNX 全自动上色为独立演进方向，尚未在
本模块实现。
