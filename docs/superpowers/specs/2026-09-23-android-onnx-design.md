# Android 端侧 ONNX 全自动上色 — 架构方案（Phase D）

日期：2026-09-23 · 状态：待评审 · 决策人：mobai0z0
（本文为设计工作稿；发布进公开 docs 时再按双语规范翻译拆分）

## 1. 目标与非目标

**目标**：Android 端（`mobile/` Flutter 壳）离线运行 `v6_sam_encoder.onnx + v6_generator.onnx`
的**全自动**上色，效果与桌面 `/colorize_auto` 同源；无网络时已下载的权重仍可工作。

**非目标**：
- 端侧提示点/参考图新算法（现有纯 Dart 提示点路径不动）
- iOS / 其他平台
- 模型量化、蒸馏或换小模型（仅作为性能不达标时的后备选项记录）
- 把手机暴露为 API 服务或反向代理桌面端

## 2. 已核实事实（静态探查，2026-09-23）

| 事实 | 数据 |
|---|---|
| 权重体积 | generator 191,335,312 B + sam_encoder 108,983,556 B ≈ 300 MB（fp32） |
| 许可 | CC BY-NC-SA 4.0，**不得随 APK 分发**，只能使用者自行下载（与桌面同规则） |
| opset | 两模型均 ir 8 / ai.onnx 17，节点 ~2300/模型 |
| 算子 | 全为标准算子（Conv/MatMul/LayerNorm/InstanceNorm/Resize/Softmax/If/Slice/Tile…），无 GridSample/NMS/NonZero；ORT CPU EP 全支持，NNAPI/XNNPACK 预计会因 If/Shape 动态图碎图 |
| 张量接口 | SAM：`rgb_input [1,3,1024,1024]`（x/127.5−1）→ `sam_level0/1 [1,256,h,w]`；generator：`L_bw [1,1,1024,1024]`（灰度同归一化）+ 两特征 + `wd14_embedding [1,1024]` 全零 → `rgb_pred [1,3,1024,1024]`（[-1,1]） |
| 桌面管线 | 缩 1024² INTER_AREA → `_run_pair` → `(x+1)*127.5` clip → INTER_CUBIC 放大回原尺寸；长图 tile 1024 / overlap 256 线性羽化只融 a/b 色度，L 恒取原稿 |
| 环境 | Flutter 3.47 / Dart 3.13 / JDK 21 就绪；无连接设备、无模拟器 AVD（实测推迟到实现的 Step 0 门槛） |

## 3. 方案对比

- **A. 端侧 ORT CPU EP 直跑原模型（选定）**：保真与桌面 100% 同源；无需新后端；风险全在速度/内存，用 Step 0 实测门槛兜底。
- B. 手机连桌面 sidecar（局域网 API）：零模型工作，但违背"端侧"需求④，且要求桌面常开——排除。
- C. 先量化（int8 dynamic）再上端：省 ~4 倍内存与部分耗时，但引入精度变量、需离线量化工具链——不首发，降级时启用。
- D. MNN 转换版（见 3.1 参照）：换移动端专用推理栈，CPU 路径通常优于 ORT CPU EP，且有
  高通 NPU（QNN）加速空间；代价是 ONNX→MNN 转换需验证 `If`/动态 Shape 支持，且多维护一条
  模型产物线——作为 A 性能不达标时的首选升级路径，不进首发。

### 3.1 业界参照：local-dream（xororz/local-dream，Google Play 已上架）

同为本机跑扩散类模型（SD1.5/SDXL）的 Android 应用，其做法对本方案有直接借鉴意义：

| local-dream 做法 | 对本方案的启示 |
|---|---|
| 推理层为独立 C++ 原生模块（MNN CPU + 高通 QNN NPU），与 UI 层解耦 | 我们的等价边界是 `backend.dart`（两方法接口），将来换 MNN/NPU 只动一处 |
| 权重完全不随 APK 分发，用户自行导入/下载 | 印证 §7 许可路线在 Google Play 有上架先例（CC BY-NC-SA 可行） |
| 按硬件分档：NPU 路径要求 Hexagon V68+，SDXL 要求 8 Gen3+，明写设备门槛 | 采纳：Step 0 实测后在 docs 与应用内写明「最低设备档位」，低于门槛引导继续用提示点模式 |
| 模型格式为转换后的 MNN 包（非原始 ONNX） | 说明"ONNX→移动格式转换"是成熟路线，故 D 方案保留为性能不达标时的升级路径 |
| 单并发、生成中可取消、进度上报 | §4 性能护栏与之对齐 |

差异说明：local-dream 是原生 Compose 工程且跑 SD 全家桶（UNet+VAE+文本塔）；我们是 Flutter 壳 +
单一「SAM→generator」两 session 管线、图像到图像，无文本编码，移植面比它小得多，因此首发选
零转换成本的 ORT，而非一上来就维护双格式模型线。

## 4. 架构

```
mobile/lib/
  onnx/
    weights.dart        权重仓储：目录探测 / 下载(断点续传+sha256) / 空间与删除
    backend.dart        OnnxBackend 抽象接口（runSam/runGen）+ flutter_onnxruntime 实现
    pipeline.dart       全自动管线：预处理→分块→推理→羽化融合→L 合成→PNG（纯 Dart，backend 可注入 mock）
    auto_service.dart   isolate 看护 + 进度/取消 + 空闲释放 session
  main.dart             工作台新增「全自动」入口（权重未就绪→引导下载页）
packages/manga_colorizer_core/lib/src/
  lab.dart              RGB↔Lab 与 L 合成（对齐 OpenCV D65 量化语义）——新纯 Dart 工具，单测金样
```

依赖决策：ORT 绑定首选 [`flutter_onnxruntime`](https://pub.dev/packages/flutter_onnxruntime)
（活跃维护、暴露 float32 张量与多输入名 feed）；实现 Step 0 先验证它能加载本模型，
不满足则候补 [`onnxruntime_v2`](https://pub.dev/packages/onnxruntime_v2)，再不行降级为
自写 FFI 套 ORT Android AAR。绑定选型封闭在 `backend.dart` 一个文件内，接口只有两个方法。

**数据流**（单张）：
选图 → `weights.ready?` →（否→下载 UI：进度/断点续传/校验）→ isolate：
解码→灰度 → h≤1024∧w≤1024 ? 单块 : tile(1024, overlap 256) →
每块：`x/127.5−1` → `runSam` → `runGen(L_bw, sam0, sam1, zeros)` → `clip((y+1)*127.5)` →
块结果按 `_tile_bounds/_feather_weight` 移植逻辑融合色度 → L 通道恒取原稿灰度（lab.dart 合成）→
INTER_CUBIC 语义放大回原尺寸 → PNG → 系统相册/分享。

**错误处理**：
- 推理 OOM：该块降到 512² 重跑一次（generator 动态形状接受小输入；SAM 输入固定 1024，
  则整块改走 512² 居中缩放路径需 Step 0 验证——不通过就只重试同尺寸一次后报「内存不足，建议单块处理」）
- 下载中断：保留 .part + Range 续传；sha256 不符删除重下
- 权重缺失/损坏：全自动入口置灰 + 引导，不阻断现有提示点功能
- 应用退到后台 / 空闲 ≥60 s：`session.dispose()` 归还内存，回来重加载（~秒级）

**性能护栏**：并发 1（isolate 内串行）、进度回调按块上报、取消位图检查、
线程数默认 `min(4, 大核数)` 可在设置覆盖。

## 5. 测试

- 金样单测（PC `flutter test`）：lab.dart RGB↔Lab vs cv2 输出逐像素 ≤1；预处理归一化、
  反归一化、tile 边界/羽化权重与 Python `_tile_bounds/_feather_weight` 同输入同输出
- pipeline 单测：mock backend 返回常数场，验证形状/融合/L 保真/取消
- 手工门槛（真机）：3 页（单页/长页/细节密集）与桌面 `/colorize_auto` 结果目检一致；
  记录加载耗时、单块耗时、峰值 RSS 进 docs

## 6. 实施前置门槛（Step 0，代替本轮实测）

实现计划第 0 步为一次性真机 spike（throwaway）：arm64 设备加载两模型跑 1 块 1024²。
**放行线**：单块 ≤120 s 且峰值 RSS ≤4 GB → 按本方案继续；
不达标 → 回到方案分叉（D MNN 转换版 / C 量化 / 512² 低配模式 / 暂停 Phase D），另行决策，不擅自继续。

**附记（2026-09-24，whole-branch 终审后）**：上述 Step 0 门槛经用户裁决**推迟**——
`feat/android-onnx-auto` 分支未运行过任何真机推理、未记录过任何实测数字。门槛数字、
取消后空闲循环的峰值 RSS 增长检查、与桌面 `/colorize_auto` 的 3 页目检对拍，一并按
**合并后真机验收清单**执行；数字不达标仍按本节既有分叉（MNN/量化/512²/暂停）决策，
返工边界不变。另记三条诚实修正（终审 minor 项）：①§4 的「推理 OOM → 降 512² 重跑」
路径**未实现**（现失败直接报错并引导用户），列为后续增强；②§4 性能护栏「线程数默认
`min(4, 大核数)` 可覆盖」**未实现**（用 ORT 默认），同为后续项；③计划对
`_tile_bounds`/`_feather_weight` 的「逐字移植」应读作「语义逐值对齐」：浮点羽化权重经
最终 Lab 8bit 量化时的 `.round()` 与桌面整数 cast 存在 ≤1 LSB 的取整差，像素级一致性
以真机验收清单为准。

## 7. 许可与发行边界

APK 只含代码；权重页内署名 + 许可提示（复用桌面文案）；NOTICE 增补 flutter 绑定与
ORT 的 Apache-2.0/MIT 许可；F-Droid/商店描述不得暗示商用授权。CC BY-NC-SA 条款不变。

## 8. 交付与文档

v0.5.0：mobile「全自动」模式 + 权重下载器；`docs/architecture.{zh,en}.md` 移动端小节改写
（删除"端侧 ONNX 尚未实现"句）、`docs/getting-started.{zh,en}.md` 增 Android 上手；
版本三连（Cargo.toml / tauri.conf.json / service.py）与 mobile/pubspec 同步 bump。

## 9. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| ARM CPU 单块耗时不可接受 | 高 | Step 0 门槛；后备 D（MNN/QNN，见 §3.1）/ 512² / 量化 / 暂停 |
| SAM 输入固定 1024 使低配降级路径不成立 | 中 | Step 0 一并验证小输入可行性 |
| flutter 绑定与 ORT 版本对 opset 17 `If` 子图支持有坑 | 中 | 候选链 flutter_onnxruntime→onnxruntime_v2→自写 FFI，全部封在 backend.dart |
| 低端机 4 GB RAM 不够 300 MB fp32 + 激活 | 中 | 空闲即释放、单块串行、失败文案引导 |
| 300 MB 权重下载流量投诉 | 低 | 明示大小、仅 Wi-Fi 默认、可换 hf-mirror |
