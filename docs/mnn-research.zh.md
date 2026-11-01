# MNN（阿里巴巴推理框架）调研报告

调研备忘（本文档仅中文，无配套 .en.md） · 相关架构背景见 [architecture.zh.md](architecture.zh.md)

> 调研日期：**2026-10-31**。所有"最新"类数字均以当日一手抓取为准（GitHub API / Releases 页 / 官方文档站），benchmark 数字均标注来源与自测性质。标签约定：
> 【一手来源】= 本次直接抓取的 GitHub 仓库/Release/API/官方文档原文；【官方数据】= 官方发布的论文、Release Note、文档中的自测数字；【第三方】= 独立来源；【推断】= 基于以上事实的推理，未经实测。

## TL;DR

1. MNN 是阿里淘天团队维护的端侧推理引擎（Apache-2.0，C++），仓库创建于 2019-04，**最新 release 3.6.1（2026-07-23 发布）**，master 持续有提交（最近一次 2026-10-30），2026 年保持约 1–3 个月一版的节奏，维护活跃。
2. 后端矩阵：CPU（x86 AVX2/AVX512、ARM NEON/DotProd/FP16/SME2）最成熟；GPU 有 OpenCL/Metal/Vulkan/CUDA；NPU 有 QNN、联发科 APU、CoreML、HiAI，**3.6.1 新增高通 Hexagon DSP 直编后端**（LLM 场景为主）。
3. 内存特性正是本项目想要的：**权重 mmap 加载**（文件背页，可被系统回收）、`memory = low` 模式 + 权重量化（需 `-DMNN_LOW_MEMORY=ON`）按机型分级、`--fp16` 权重减半 + ARM82 fp16 计算。
4. 官方自测数据（MLSys'20/OSDI'22 论文）：Android 4 线程比 TF-Lite/NCNN/Mace 快约 30%+；**但没有任何权威的 MNN vs ONNX Runtime 移动端对比**，内存峰值对比数据缺失——必须自测。
5. Android 无现行官方 maven 产物（`com.alibaba.android:mnn` 停在 5 年前的 0.0.8）；**每个 GitHub release 附官方预编译 SDK zip**（3.6.1 Android 含 armv7+armv8、CPU+OpenCL+Vulkan，仅 6.2MB）；Java 绑定在仓库 `project/android/src`。
6. **Flutter 没有可用的高质量 MNN 插件**：pub.dev 仅有 3 个社区包（mnn / mnn_engine / mnnllm），下载量 26–384、基本面向 LLM；接入 Flutter 需自建 FFI/JNI 桥（参考 xororz/local-dream：git submodule + NDK 源码编译 + C++ API 直调）。
7. 最大风险：**SAM 这类"ViT+Conv 混合"模型走 ONNX→MNN 转换的算子与数值风险**（LayerNorm/MatMul/attention 支持，但社区 issue 中有 IsNaN 不支持、MultiHeadAttention 转换失败、转换后精度漂移等案例），且 MNN 官方算子验收主要在自家导出的 LLM 图上。
8. 结论（推断）：移动端收益（mmap + 量化分级 + 包体）值得做 POC，但迁移成本 = 转模型 + 金样对拍 + 自建 Flutter 桥，进程隔离短期内仍应保留；Windows 桌面用 MNN Vulkan/CUDA 替代 DirectML **可行性一般、优先级低**。

---

## 1. MNN 是什么

**定位**（【一手来源】[README](https://github.com/alibaba/MNN)）："高效、轻量的深度学习框架，支持推理与训练"，已在阿里 30+ 款 App（淘宝、天猫、优酷、钉钉等）70+ 场景落地；当前口号已转向 "powering high-performance on-device LLMs and Edge AI"。MNN 是阿里端云协同系统 Walle（OSDI'22）的基础计算容器。

**历史**（【一手来源】GitHub API `created_at` + 【第三方】公开报道）：仓库 **2019-04-15** 创建，2019 年 5 月正式对外开源；前导版本论文发表于 MLSys 2020（*MNN: A Universal and Efficient Inference Engine*）。维护方为**淘宝技术部**（贡献者含搜索工程、达摩院、优酷员工；核心 committer 如 wangzhaode、jxt1234），3.x 阶段重心明显转向 MNN-LLM / MNN-Diffusion。

**开源协议**：Apache-2.0（【一手来源】GitHub API license 字段）。

**活跃度**（【一手来源】[GitHub API](https://api.github.com/repos/alibaba/MNN)，2026-10-31 抓取）：

| 指标 | 值 |
| --- | --- |
| Stars / Forks | 16,310 / 2,495 |
| Open issues | 85 |
| 最近 push | 2026-10-30（持续维护中） |
| 最新 release | **3.6.1，发布于 2026-07-23**（GitHub Actions 自动发布） |
| Release 节奏 | 2026 年：3.4.0（2 月）→ 3.4.1（3 月）→ 3.5.0（4 月）→ 3.6.0（6 月）→ 3.6.1（7 月）；截至 2026-10-31 约 3 个月无新版，但 master 有持续提交 |

**Releases 页一手摘录**（【一手来源】[releases](https://github.com/alibaba/MNN/releases)）：
- 3.6.1（2026-07）：新增 **Hexagon NPU 后端**（Qwen3-0.6B W4 在骁龙 8 Elite 上 prefill 2667 tok/s，CPU 的 7.9×）；Transformer C4 融合图全后端启用；修复 mmap 分配失败崩溃、Arm82 fp16 精度等问题。
- 3.6.0（2026-06）：CUDA Blackwell(sm_120)、Vulkan W8A8 coopMat、2/3-bit 权重量化全栈、KleidiAI v1.16。
- 3.5.0（2026-04）：**Vulkan 后端支持 LLM**、MUSA（摩尔线程）后端、RISC-V RVV、`mmap_size` 配置项。
- 3.4.x（2026-02/03）：CPU/Metal Flash Attention、KV Cache 量化、QNN 支持 Qwen3/VL 模型。

## 2. 架构与能力

### 2.1 模型转换链路（MNNConvert）

【一手来源】[官方文档·转换工具](https://mnn-docs.readthedocs.io/en/latest/tools/convert.html)、README：

```bash
./MNNConvert -f ONNX --modelFile model.onnx --MNNModel model.mnn --bizCode manga
```

- 来源框架：**ONNX、TFLite、TorchScript、TensorFlow(pb)、Caffe、JSON(可互转查看)**；README 称 ONNX 转换器覆盖 158 个 ONNX 算子。
- 图优化：算子融合 / 算子替代 / 布局调整（NC4HW4）在转换期完成。
- 量化选项（同一工具内）：
  - `--fp16`：conv/matmul/LSTM 权重存为 fp16，模型减半（注意：仅存储减半，运行时是否 fp16 计算取决于后端与精度设置，见 2.3）；
  - `--weightQuantBits 2~8`：权重量化（默认加载时反量化回 float，不影响数值；8bit 官方称"精度基本无损、体积 -4×"）；
  - `--hqq`、`--weightQuantBlock 128`（block 32~128 越小精度越高）、`--compressionParamsFile`；
  - `auto_quant.py` 自动压缩：按误差率（如 `--rate 0.05`）自动跳过敏感层；
  - 离线 int8 PTQ（带校准）：需 100–1000 张校准图，支持 KL / ADMM / EMA；
  - 专项导出 `MNN2QNNModel`（QNN 离线图）。
- 正确性校验：`tools/scripts/testMNNFromOnnx.py` 等脚本，输出 `TEST_SUCCESS` 即通过；出错可用 DEBUG 参数按支配树二分定位错误层。**这个工具链直接可用于我们的金样对拍 POC。**

### 2.2 后端支持矩阵

【一手来源】README 精度矩阵（S=支持且深度优化，A=可用，B=有 bug 或未优化，C=不支持）：

| 架构/精度 | Normal | FP16 | Int8 |
| --- | --- | --- | --- |
| x86/x64 AVX2 / AVX512 | S | C | A / S(AVX512) |
| ARMv8（NEON/DotProd，FP16 需 v8.2，BF16 需 v8.6） | S | S | S |
| OpenCL | A | S | S |
| Metal | A | S | S |
| Vulkan | A | A | A |
| CUDA | A | S | A |
| NPU：CoreML/HiAI = A；NNAPI = B；**QNN = C(Normal)/B(FP16)** | | | |

补充（【一手来源】各 release note + CMake 文档）：
- **Hexagon**：3.6.1 新增高通 Hexagon DSP 直编后端（`MNN_HEXAGON`），目前覆盖 Attention 等 LLM 关键算子——**CV/ViT 模型尚不可用**（推断，依据其 release note 仅列 LLM 算子）。
- **QNN**：3.2.0 起支持 CV 模型，3.4/3.6 逐步支持 Qwen3/VL、Interp/Resize；`MNN2QNNModel` 生成离线 context。
- **联发科 APU**：3.3.0 提及 MTK NPU 支持（场景为 LLM）。
- **平台**：Android 4.3+、iOS 8.0+、macOS、Linux、Windows、鸿蒙（3.6.x 有 harmony 预编译包）、RISC-V。
- **Windows 是否一等公民**（综合判断）：受支持且 x86 CPU 内核为 S 级（AVX2/AVX512），官方每个 release 附 **windows_x64_cpu_opencl_vulkan_avx512.zip（3.6.1，约 250MB）** 预编译包，含 OpenCL+Vulkan 后端；CUDA 后端需自行编译（`MNN_CUDA=ON`，3.6.0 修复了 Windows CUDA CMake）。但 GPU 后端默认全部 OFF、Windows 专属文档很少、FAQ 提到需 `/WHOLEARCHIVE:MNN` 静态链接等 quirks——**可用，但明显不如 Android/iOS 一等**【推断，基于文档与 release 包构成】。

### 2.3 内存相关特性（本项目最关心）

【一手来源】runtime 配置文档（[运行时后端配置](https://mnn-docs.readthedocs.io/en/latest/start/python.html)）+ release notes：

- **mmap 权重加载**：CPU 后端权重以 mmap 方式映射模型文件；3.2.0 支持"生成 mmap 缓存文件后删除原始 weight 文件"，3.4.0 OpenCL 后端支持 mmap 权重存储，3.5.0 新增 `mmap_size` 配置，3.6.1 修复各后端 mmap 分配失败崩溃。LLM 侧 `DiskEmbedding` 长期基于 mmap。**文件背页在内存压力下可被内核回收**，这与 ORT arena 的私有脏页有本质区别（回收行为属【推断】，mmap 机制本身是【一手来源】）。
- **内存分级**：RuntimeManager `memory` 配置 0=normal / 1=high / **2=low**；CPU 后端 `memory=2` + 权重量化模型 + 编译期 `-DMNN_LOW_MEMORY=ON` 时启用**动态量化**（计算时反量化，降低常驻内存）；GPU 后端 `memory=2` 表示运行时反量化权重以省显存。这正是 local-dream 这类项目"按设备内存分级"的机制（local-dream 具体调用方式见 4.4）。
- **FP16**：`--fp16` 仅存储减半；真正 fp16 计算需 ARM82 后端（`MNN_ARM82`，默认 ON）+ 运行时 `precision=2 (low)`，官方称"内存减半、一般 50%–100% 加速"。GPU 上 `precision=2` = fp16 存储与计算。
- **加载/分配时机**：`shape_mutable=False` 可把内存分配提前到 load 阶段（前向时不再重复分配）；GPU 调优结果可用 `setCache()` 落盘复用。
- 包体：README 称 Android 核心 so 约 **800KB**（armv7a、c++_shared，仅核心引擎）；iOS 全功能静态库约 12MB。官方 3.6.1 Android SDK zip（armv7+armv8、CPU+OpenCL+Vulkan）合计 **6.2MB**（【一手来源】release asset）。

### 2.4 Python API（pymnn）

- `pip install MNN`，含推理（`MNN.nn` / Module / Expr API）、训练、量化（`mnnquant`）、转换（`mnnconvert`）、`MNN.llm` 子模块（【一手来源】[PyMNN 指南](https://mnn-docs.readthedocs.io/en/latest/start/python.html)、[PyPI JSON](https://pypi.org/pypi/MNN/json)）。
- **注意矛盾点**：3.6.1 release note 写 `pip install mnn==3.6.1`，但 PyPI JSON（2026-10-31 抓取）显示最新发布版本仍是 **2.9.6（2024-10-14 上传）**，没有 3.x wheel。POC 时先实测 `pip index` / 安装结果，不要按 release note 断言（【一手来源】两处冲突，如实记录）。
- 3.3.0 修复了 PyMNN 在 Python 3.13+ 编译失败；3.4.1 让 LLM 实例内置 Executor 解决 Python 绑定资源泄漏。C++ 才是第一公民，Python 主要是工具链与 LLM 便捷层【推断】。

## 3. 性能与内存数据

### 官方自测数据（【官方数据】，均为官方论文/Release 自测）

- **MLSys 2020 论文**（移动 CNN）：与 CoreML / TF-Lite / NCNN / Mace 相比，Android 4 线程约 **快 34%**、iOS 约 30%（论文自测，MobileNet 系 CNN 为主）。
- **OSDI 2022（Walle）论文**：与 TensorFlow / TF-Lite / PyTorch / PyTorch Mobile / TVM 的基准对比（脚本在仓库 `/benchmark`）。
- **README 宣称**：ARM v8.2 fp16 约为 fp32 的 2×，sdot/VNNI 路径约 2.5×。
- **3.6.1 LLM 基准**（Qwen3-0.6B W4，骁龙 8 Elite）：Hexagon pp512 2667 tok/s（CPU 7.9×、OpenCL 1.8×）；3.6.1 vs 3.6.0：Qwen3-4B OpenCL prefill +101.7%、CPU decode +72.2%。
- **体积**：Android 核心 so ~800KB、iOS 静态库 ~12MB、官方 Android SDK zip 6.2MB（见 2.3）。

### 第三方数据（【第三方】/ 数据缺口）

- 2026-10 检索（WebSearch）**未找到任何权威的 MNN vs ONNX Runtime 移动端速度/峰值内存对比**；现有第三方综合基准（如 Zhang 2022 *A Comprehensive Benchmark of Deep Learning Libraries*）覆盖 TFLite / PyTorch Mobile / ncnn / MNN / Mace / SNPE，不含 ORT。
- 社区实践信号：MNN 被广泛用于 Android 端侧 SD/LLM（MNN-Chat、local-dream、各类 LLM app），其 CPU 路径在"省内存 + 快加载"上的口碑来自工程实践而非公开跑分。
- **数据缺口结论**：CNN/ViT 推理速度、峰值内存（RSS/PSS）、LMK 存活率这类关键指标必须在本项目模型（SAM encoder 1024×1024）上自测，社区数据不可引用【推断】。

## 4. 端侧集成

### 4.1 Android

- **无现行官方 maven 产物**：Maven Central 上的 `com.alibaba.android:mnn` 最新 0.0.8（约 2021 年，MNN Kit 时代），【一手来源】[central.sonatype.com](https://central.sonatype.com/artifact/com.alibaba.android/mnn)。
- **官方预编译产物**：每个 GitHub release 附 SDK zip（3.6.1：`mnn_3.6.1_android_armv7_armv8_cpu_opencl_vulkan.zip`，6.2MB，含 so + 头文件）【一手来源】release asset 列表。
- **常规做法**：拿 release zip，或仓库 `project/android` 用 NDK CMake 自编（`build_64.sh` 等；可选 `MNN_ARM82`/`MNN_OPENCL`/`MNN_VULKAN`/`MNN_LOW_MEMORY`）。
- **Java/Kotlin API**：仓库 `project/android/src` 提供官方 Java 绑定（`com.alibaba.mnn` 包，含 Interpreter/Session 封装与 demo）【一手来源】目录树。API 形态为经典 Interpreter/Session：createRuntime(config) → createSession → runSession → 取 Tensor，Java 层负责输入输出拷贝。
- so 体积：核心引擎约 0.8MB（armv7 c++_shared，README）；全功能（含 GPU 后端）每个 ABI 约 2–4MB 量级（从 6.2MB 双 ABI zip 推算）【推断】。

### 4.2 iOS

- 支持 CocoaPods：CMake 可生成 `MNN.podspec`（`MNN_GENERATE_PODSPEC`），也可用 release zip（3.6.1：`mnn_3.6.1_ios_armv82_cpu_metal.zip`，3.2MB）；iOS 8.0+，Metal 后端 S 级【一手来源】CMake 文档 + release asset。

### 4.3 Flutter 绑定现状（检索于 2026-10-31，【一手来源】pub.dev 检索结果）

| 包 | 版本/时间 | 数据 | 说明 |
| --- | --- | --- | --- |
| `mnn`（rainyl） | 0.1.3，约 2026-04 | 6 赞 / 29 下载 | Dart+Flutter 封装，基于作者自己维护的 MNN C API fork，非官方 |
| `mnn_engine` | 0.2.0，2026-10-26 | 0 赞 / 384 下载 | 仅 Android，MNN-LLM 方向（OpenAI 兼容 API server） |
| `mnnllm` | 0.0.2，约 2025 年中 | 1 赞 / 26 下载 | MNN-LLM 绑定，久未更新 |

**结论：没有官方 Flutter 插件；社区绑定 adoption 极低且以 LLM 为主，没有 `flutter_onnxruntime` 那种成熟度的 CV 推理插件。** 若走 MNN，Flutter 侧需自建插件：dart:ffi 直调 MNN C++ API，或 Android 平台通道 + Java/JNI 绑定【推断】。

### 4.4 xororz/local-dream 如何集成 MNN（本项目关注 MNN 的直接参照）

【一手来源】[local-dream README](https://github.com/xororz/local-dream) + `.gitmodules`（2026-10-31 抓取）：

- 纯原生 Android（Kotlin + Jetpack Compose），非 Flutter。
- **MNN 以 git submodule 方式 vendor**：`app/src/main/cpp/3rdparty/MNN → github.com/alibaba/MNN.git`（原仓库，非 fork），随 NDK CMake 从源码编译进 APK；同目录还有 cpp-httplib / nlohmann-json / xtensor / zstd / tokenizers-cpp / happyyzy 版 stable-diffusion.cpp。
- C++/JNI 层直接调用 MNN 的 C++ API 做 CPU 推理；NPU 路径单独走 Qualcomm QNN SDK（其 README 致谢：MNN="CPU model execution"、QNN SDK="NPU model execution"）。
- **没有魔改 MNN 本体**——submodule 指向官方仓库【一手来源】；其"按设备内存分级"依赖 MNN 自身的 `memory = low` / 量化加载机制（具体 config 代码本次未逐行核验【推断】）。
- 启示：本项目 Flutter Android 侧也可用"NDK 插件 + submodule 源码编译 + C++ API"的相同形态，绕开对 Dart 生态绑定的依赖。

## 5. 算子覆盖与风险

- **Transformer/ViT 算子**：README 称支持 CNN/RNN/GAN/Transformer；CMake 有 `MNN_SUPPORT_TRANSFORMER_FUSE`；3.4–3.6 的 RoPE/Attention/LayerNorm C4 融合路径主要针对**自家 llmexport 导出的 LLM 图**，不保证对任意 ONNX ViT 拓扑开箱即用【推断】。SAM encoder 用的 LayerNorm / Softmax / MatMul / GELU / Conv 属常规覆盖面（158 个 ONNX 算子）之内，但需逐层验证。
- **ONNX 转换已知问题（GitHub issues，【一手来源】issue 编号，检索于 2026-10）**：
  - `These Op Not Support: ONNX::IsNaN`（#4153，Qwen3 模型转换）；
  - LSTM 转换失败（#877、#1890，后者为版本回归）；
  - `torch.nn.MultiHeadAttention` 经 ONNX 转换报错（2024）；
  - **转换后精度与 PyTorch/ONNX 不一致**（#2475，维度格式转换相关）、concat/resize 输出尺寸错误（#880）。
  - 应对：调 opset、拆算子、用最新版 MNNConvert、用 `testMNNFromOnnx.py` 逐层定位。
- **数值精度**：`--fp16` 仅存储减半，运行时默认反量化回 fp32 计算；真 fp16 需 ARM82 + precision=low。官方称视觉模型 fp16 通常 <0.1% 损失，但也提示语音/小目标检测等敏感任务需实测；3.6.1 修过 Arm82 LinearAttention fp16 精度 bug——**fp16 路径历史上出过精度问题，金样对拍必须覆盖 fp16 开关两种配置**【一手来源 + 推断】。
- **量化对图像生成类模型**：3.2.0 官方承认旧量化方式影响 CV 精度，为此加了 input block-wise 量化与非 1x1 Conv 的权重 block 量化（"Diffusion 场景 CPU 生图效果提升"）；`--weightQuantBlock 32~128`、HQQ、auto_quant 敏感层跳过都是官方给出的画质兜底手段【一手来源】。对上色这种图像生成任务，int8 PTQ 预计需要敏感层白名单调试【推断】。
- **布局坑**：MNN 内部 CV 算子用 NC4HW4（channel 按 4 pad），直接按 NHWC 读 buffer 会遇到 elementSize 不一致；用 TENSORFLOW 布局 host tensor + copyFrom/ToHostTensor 规避（官方 FAQ）。

## 6. MNN-LLM（一段话）

MNN-LLM 是基于 MNN 引擎的端侧 LLM 运行时（已并入主仓库，3.x 的主要研发重心）：支持 Qwen/Llama/Baichuan/GLM 等模型的导出与推理，W4/W8 + block64 量化、KV Cache 量化与 TurboQuant、EAGLE-3/lookahead 投机解码、多模态与语音，配套官方 Android/iOS 应用 MNN Chat；3.5/3.6 把 Vulkan、CUDA、QNN、Hexagon、MUSA 等后端都接入了 LLM 路径。与本项目关系不大，但其工程投入侧面证明了 MNN 代码库的活跃度。

## 7. 对 manga-colorizer 的适用性评估（除标注外均为【推断】）

### 7.1 移动端（Flutter Android，替代 ORT CPU）

**预期收益**：
- **权重常驻内存**：SAM encoder ~290MB 权重由 ORT 私有内存转为 mmap 文件背页，LMK 压力下可回收；配合 `--fp16`（权重减半）或 `--weightQuantBits 8 + MNN_LOW_MEMORY + memory=low`，常驻内存有望显著低于 ORT arena。这是替代"arena 关闭补丁堆"的机制性方案。
- 速度：MNN 论文数据优于 TF-Lite/ncnn，但 **vs ORT 1.23 Android CPU 无公开对比**，ARMv8.2 设备上 fp16/sdot 路径可能占优，需实测。
- 包体：双 ABI 全后端 SDK 6.2MB，比 ORT Android 更小（需实测比对 ort 的 .so）。

**迁移成本（高）**：
1. 模型链路：encoder/decoder 各跑 MNNConvert + testMNNFromOnnx 对拍；SAM 的 ViT+Conv 混合图是转换器覆盖度的现实考验（第 5 节 issue 清单）。
2. 数值对拍：金样测试需覆盖 fp32 / fp16(ARM82+low) / int8 权重量化三档，上色画质对权重精度敏感。
3. 推理层重写：Flutter 无成熟插件，需自建 NDK 插件（参考 local-dream 的 submodule + C++ API 形态）；输入预处理（ImageProcess/CV 模块）与 NC4HW4 布局差异也要适配。

**进程隔离是否仍需要**：**建议保留**。mmap 只解决权重，1024×1024 ViT 的激活张量峰值依旧很大，且 GPU/OpenCL 路径在低端机不可用时仍走 CPU；等 POC 实测"单进程峰值 PSS + LMK 存活率"达标后再考虑去掉 `:inference` 进程。

### 7.2 Windows 桌面（MNN Vulkan/CUDA 补充 DirectML）

- 可行性：官方 Windows 预编译包含 OpenCL+Vulkan 后端，CUDA 可自编；CPU 后端（AVX2/AVX512）为 S 级，可作为"绕开 DirectML 数值问题"的备选。
- 代价与风险：MNN 在 Windows GPU 上的实战验证远少于 ORT-DirectML 生态，ViT 算子在 Vulkan 后端的覆盖/性能未知，接入意味着再维护一套 runtime 与模型分发；CUDA 自编需 NV 工具链，包体/分发复杂。
- **结论：优先级低。** 桌面端内存充裕，DirectML 数值问题建议继续用"钉版本 <1.21"规避；如要 POC，MNN Windows 只值得作为 Vulkan 一项小实验，不作主路线。

### 7.3 建议的 POC 验证步骤清单

1. **转换冒烟**（PC，半天）：用 3.6.1 `MNNConvert` 转 SAM encoder/decoder ONNX；`testMNNFromOnnx.py` 逐层余弦对拍；记录失败算子清单（这一步直接决定项目生死）。
2. **金样对拍**（PC + 真机）：固定 20 张典型漫画样张，fp32 CPU 下对比 ORT 输出（PSNR / max abs diff 阈值）；再开 `--fp16` 与 ARM82 `precision=low` 复测；再测 `--weightQuantBits 8 + memory=low`。
3. **资源实测**（低内存安卓机）：对比 ORT 1.23 vs MNN 的单帧延迟（1/2/4 线程）、**峰值 PSS**、load 后稳态 PSS、file-backed vs private dirty 占比、APK 体积增量。
4. **GPU 路径探底**（可选）：OpenCL（Adreno/Mali）与 Vulkan 跑 encoder，用 MNN 调试统计 CPU fallback 算子比例与耗时；不达标即锁定 CPU 路线。
5. **集成形态**：写最小 FFI/JNI 插件（load → resize → run → destroy 全链路 + mmap 加载），在 Flutter demo 中验证双 ABI 打包与崩溃恢复。
6. **LMK 压测**：MNN 方案下重复第 3 轮内存压测，对比进程被杀率；达标后再讨论是否撤销 `:inference` 进程隔离。
7. **Windows 附带实验**（可选，1 天内）：用官方 windows zip + Vulkan 后端跑 encoder，验证数值与性能，只作记录不作决策依据。

## 8. 主要来源

- 仓库与元数据（一手）：https://github.com/alibaba/MNN 、 https://api.github.com/repos/alibaba/MNN 、 https://github.com/alibaba/MNN/releases （3.6.1 发布 2026-07-23，附 Android/Windows/iOS 预编译包清单）
- 官方文档（一手）：https://mnn-docs.readthedocs.io/en/latest/ （intro/about、tools/convert、tools/compress、tools/benchmark、start/python、compile/cmake、faq）
- local-dream（一手）：https://github.com/xororz/local-dream （README + `.gitmodules`）
- pub.dev（一手）：https://pub.dev/packages?q=mnn （mnn / mnn_engine / mnnllm）
- PyPI（一手）：https://pypi.org/pypi/MNN/json （最新 2.9.6，2024-10-14）
- Maven Central（一手）：https://central.sonatype.com/artifact/com.alibaba.android/mnn （0.0.8，约 2021）
- 官方论文（官方数据）：MLSys 2020《MNN: A Universal and Efficient Inference Engine》、OSDI 2022《Walle》
- ONNX 转换 issue（一手编号）：alibaba/MNN #4153、#877、#1890、#2475、#880（检索自 WebSearch，2026-10-31）
- 第三方背景（第三方）：Zhang 2022 深度学习框架综合基准（不含 ORT）、ONNX Runtime 移动端内存宣传数据（官方博客）

---

## 附录 A：Stage 0 转换与对拍实测记录（2026-10-31）

工具链：MNN 3.6.1 源码构建（Windows VS 18 / MSVC 14.51；`MNN_BUILD_CONVERTER=ON` 必须
`MNN_WIN_RUNTIME_MT=ON`）；pymnn 3.6.1 同源构建安装进 .venv（Python 3.14 可用，
PyPI `mnn==2.9.6` 不可用）。脚本：`tool/mnn/{fix_encoder_graph,convert_models,compare_onnx_mnn}.py`。

### 结论

- **fp32 过门（采用）**：真实样张 e2e rgb uint8 差异 99.896% 像素 ≤1、max=3；合成样张
  99.96%–100% ≤1、max ≤2；encoder 特征 cos ≥0.99999。残差为后端累加顺序噪声，经分块
  羽化与 Lab 收尾后不可见。通过门按 99.8% ≤1 / max ≤3 判定（门限可调，脚本内注释有据）。
- **fp16 不采用**：encoder 特征无损（cos 0.99997）但 generator 对权重存储减半极敏感，
  真实样张 e2e 82.8% ≤1 / max 17——GAN 型生成器的权重敏感性超出官方"基本无损"适用面。
- **w8 不采用**：46% ≤1 / max 119，图像生成任务不可用（与 2.5 节"量化影响 CV 精度"一致）。
- 因此内存收益不走"权重减半/量化"，走 **fp32 + mmap 文件背页**（机制目标不变）。

### 三处 MNN 数值漂移根因（全部已修复，修在图上而非 MNN）

1. **If 条件分支选错**：encoder trunk 有 2 个按窗口数 Expand/重采样 pos_embed_window 的
   If；1024² 输入下 ORT 实测两条件均为 False（走 else/Identity），MNNConvert 静态展平
   选错分支 → 特征左列/顶行结构性漂移（cos 0.95）。修复＝按 ORT 验证结果内联 else 分支。
2. **动态 pads 丢失**：5 个 Pad 的 pads 由 `Mod(k - size%k)` 动态算出，MNNConvert 丢弃该
   输入（警告 `empty input, the index is 2`）按 0 pad 处理；真值非零（如 [0,0,0,0,0,6,6,0]）。
   修复＝ORT 探针真值后回填常量 initializer。
3. **InstanceNormalization 重写路径缺陷**：MNN 把它重写为 Reshape+LayerNorm(group=1)，
   在真实模型上产生右缘线性漂移（e2e 82%–98% ≤1，max 9–19；小形状隔离测试甚至出现
   1e28 垃圾值）。修复＝预分解为 ReduceMean/Sub/Mul/Sqrt/Div 基本算子（scale/bias 先
   Reshape 至与输入同秩——MNN BinaryOp 不支持 4D×1D 广播；axes 按 ONNX 语义取 dim 2..rank-1）。

### 其它实测坑（记录备查）

- pymnn `shape_mutable=False`（load 期预分配）在本模型的 Windows x86 路径触发 MNN 内部
  整数除零崩溃；一律 `shape_mutable=True`。Android FFI 用 C++ API 自控配置，不受此影响。
- ORT 1.24.4 对本模型"只加条件输出、剪掉 If 子图"的探针会走出 bad allocation 的错误优化
  路径；探针必须同时带上 If 的输出。
- 隔离验证（单 Resize/DepthToSpace/InstanceNorm 小模型）是定位这三个根因的关键手段；
  MNN 的 CPU Interp half_pixel、DepthToSpace 实现本身与 ORT 完全一致。

### 产物

- `models/manga-light-colorizer/v6_{sam_encoder,generator}.fix.onnx`（修复图）与
  `*.fp32.mnn`（采用档）+ `mnn-manifest.json`（size/sha256）；fp16/w8 mnn 留档不分发。
- `mnn-compare-report.json`：过门数字。
