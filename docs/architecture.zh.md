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
mobile/                          Flutter Android 壳（Dart 引擎 + 端侧 ONNX 全自动）
```

功能特性：全自动 ONNX 语义上色（SAM 引导 + generator）、提示点画布精修、参考图色调迁移、
批量队列（一次最多 32 张，单张失败不阻断）、长图自动分块推理、亮度保真（所有模式只写
Lab a/b 色度，L 通道始终回写原稿）、色彩收尾（色度增益 + 超色域等比收缩映射，见下）、
GPU 自动加速（Windows 优先 DirectML，NVIDIA 可用 CUDA，无 GPU 自动回退 CPU）。

### 色彩收尾（两端同数学）

全自动输出的最后一步统一走「色彩收尾」，桌面在 `service.py _finish_bgr`（numpy 向量化
+ 64 行分块），移动端在 `manga_colorizer_core` 的 `labToRgbGamut`（逐像素标量，零额外
缓冲），两端以跨语言金样对拍锁定一致（`packages/manga_colorizer_core/test/goldens/
gamut_golden.json`，由 `tool/colorizer_service/gen_gamut_golden.py` 生成）：

1. **色度增益** `a' = 128 + (a−128)·G`，补偿模型输出的普遍偏灰（默认 G=1.2）；
2. **色域映射**：大幅超出 sRGB 色域的像素不做逐通道截断（截断把色相拉向三原色，
   是输出发灰发闷的主因），改为线性 RGB 空间按「亮度不变、色度等比收缩」取最大可行
   t；t≥0.95 的微量出域是 8bit Lab 量化噪声，维持截断恰好还原原色。

增益只施加一次（在模型全自动色的 a/b 上）；提示点/参考图路径的用户显式色不再放大。
冒烟断言见 `tool/colorizer_service/quality_check.py`（不加载模型，秒级）。

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
| `COLORIZER_CHROMA_GAIN` | `1.2` | 全自动输出色度增益（量化前施加，clamp 0.5-2.0）；`1.0` = 关闭增益仅剩色域映射 |

## Dart 引擎（packages/manga_colorizer_core）

无 `dart:io` 依赖的纯 Dart 包，可嵌入 Flutter，离线/确定性路径：

```bash
dart pub get
dart test                                      # 35 项引擎回归
dart run tool/colorize_auto_client.dart -i 漫画.png -o 输出.png
dart run manga_colorizer_cli:colorize -i 原稿.png -o 输出.png --hints hints.json
```

特性：亮度完全保留、封闭白区平涂、网点 descreen、提示色亮度适配、tile 分块；提示点为
全局色度扩散求解（SOR 加速），比服务端轻量版更精确；确定性可复现。

## 移动端（mobile/）

Android 侧轻量工作台（Flutter），两个页签：

- **提示点上色**：选图 → 画布点按落提示点 → 上色 → 分享/保存。推理直接调用纯 Dart
  引擎 `manga_colorizer_core`，在 isolate 中离线执行，不依赖桌面 sidecar 或任何后端
  服务，也不需要模型权重。
- **全自动**：端侧 ONNX 全自动上色，管线语义对齐桌面 `/colorize_auto`——同款权重对
  （v6_sam_encoder + v6_generator）、tile 1024 / overlap 256 线性羽化融合、L 通道
  始终回写原稿灰度、色彩收尾同数学（增益常量 `kAutoChromaGain` 与桌面默认一致；
  桌面 tiled 路径全程浮点直达收尾，端侧在 8bit a/b 量化后收尾，≤0.5 Lab 单位，
  与 resize 插值偏差同级）。权重不随 APK 分发（CC BY-NC-SA），首次使用时在应用内
  引导下载，支持断点续传与 SHA-256 校验，manifest 内置 hf-mirror 镜像源备选（国内网络）。

```bash
cd mobile
flutter pub get
flutter run            # 连接 Android 设备 / 模拟器
flutter test           # 控件冒烟测试
```

要求 Flutter SDK（Dart `^3.6.0`）。全自动页签需 Android arm64 物理设备：端侧推理走
ONNX Runtime CPU 执行提供者（无 GPU/NNAPI 路径），每 1024² 分块耗时与峰值内存尚未
真机实测，低端设备可能较慢，相关门槛与结论待实测后修订。

### 全自动推理的进程隔离（v0.5.9，参考 xororz/local-dream 架构）

全自动管线（`onnx/auto_service.dart` 的 AutoEngine/worker RPC）在两条服务路径上
复用同一套接缝（`onnx/serving_seams.dart` 的工厂与分块参数）：

- **`:inference` 独立进程**（Android 生产默认）：`InferenceService`
  （`android:process=":inference"`，dataSync 前台服务保活）启动 headless
  FlutterEngine 跑 Dart 入口 `inferenceMain`，在 127.0.0.1 上提供帧协议服务
  （`onnx/socket_protocol.dart`，长度前缀帧：hello/config/job →
  progress/log/result/error）。入口真身在 `inference_main.dart`，但引擎按名
  查找只认根库——`lib/main.dart` 里留有根库转发（`DartEntrypoint` 二参构造
  只查 `Dart_RootLibrary()`）；`InferenceService.onStartCommand` 还须先
  `FlutterLoader.startInitialization`（该进程无 FlutterActivity，Application
  是默认 `android.app.Application`，不初始化则 `findAppBundlePath` 直接 NPE）。
  推理崩溃 / 被系统所杀只终结推理进程，UI 进程存活
  可报错重试；进程死亡即 ORT 双 session（~300MB）全部归还，**会话无滞留路径**。
  推理中切后台由前台服务保活跑完（用户选择，需通知权限，拒绝不影响推理）。
- **进程内 isolate**（回退路径）：服务启动/连接失败（OEM 后台限制、非标准设备）
  自动回退；Windows 调试与宿主测试天然走此路径。取消/关闭/空闲到期/内存压力统一
  走优雅停止——worker 做完当前块（原生运行不可中断）→ `dispose()` →
  `['stopped']` ack 后才回收，杜绝 kill 路径上 Kotlin 插件持有的 session 滞留
  （旧实现「开始上色就闪退」的根因）；宽限超时（原生挂死）才回退 kill。
- **worker 意外死亡自动重试**：`:inference` 进程在任务中死亡（LMK 回收、原生
  崩溃）时，AutoEngine 不再让在飞 job 直接失败——按预算（默认 2 次）自动收尸 →
  重新拉起服务（按原 ResourceTier 档位）→ 重发当前图：UI 只看到进度回零再走完，
  日志页多一条带原因的 warn。重试窗口内用户取消/关闭立即中止（绝不复活出用户
  已放弃的推理）；预算耗尽才报错完单。死亡原因经 `ApplicationExitInfo`
  （API 30+，MainActivity 的 `exitReason`）取证——主进程查询 `:inference` 上次
  退出记录（只认 10 分钟内的新鲜条目，避免拿陈旧记录误导），日志页直接显示
  「系统低内存回收(LMK) / 原生崩溃(signal n) / ANR」，不再是猜测性表述。
- 取消/关闭/空闲到期/内存压力（空闲门控）在两条路径上都落到「归还 ~300MB 会话」；
  空闲保留时长随 ResourceTier 分级下发（≥6GB 5min / 4–6GB 2min / 低档 60s），
  连续多图不重付模型加载。
