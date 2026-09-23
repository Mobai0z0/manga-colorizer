# 快速开始（中文）

[English](getting-started.en.md) · 开发/架构见 [architecture.zh.md](architecture.zh.md) 与 [development.zh.md](development.zh.md)

四条上手路径：Windows 安装包（普通用户）、Python 服务 + 浏览器工作台（无桌面环境）、
从源码构建桌面应用（贡献者）、Android 应用（端侧全自动，见方式四）。

## 方式一：Windows 安装包（推荐普通用户）

1. 从 [Releases](../../releases) 下载
   `Manga Colorizer_<版本>_x64-setup.exe` 并安装。
2. 首次启动会下载模型权重（约 287 MB，一次性，下载到 `%LOCALAPPDATA%\manga-colorizer\weights`）。
   国内网络可在系统代理下重试，或参考[手动下载权重](#手动下载权重)。
3. 就绪后进入工作台：拖入漫画页 → 勾选免责声明 → 开始上色。成品在「图库」页，文件在
   `%LOCALAPPDATA%\manga-colorizer\gallery`。

系统要求：Windows 10 1809+ / Windows 11（WebView2 由安装包自动装）。GPU 加速需 DX12 显卡
（DirectML）；无 GPU 时自动使用 CPU。

## 方式二：Python 服务 + 浏览器工作台

要求 Python ≥ 3.10。

```bash
# 1) 依赖（CPU 基础路径）
python -m pip install -r tool/colorizer_service/requirements.txt

# Windows GPU（DirectML，任意 DX12 显卡）：二选一，不要与 CPU 版混装
python -m pip install -r tool/colorizer_service/requirements-directml.txt

# 2) 下载模型权重（约 300MB，不随仓库分发；国内可把域名换成 hf-mirror.com）
python -c "import urllib.request as u; [u.urlretrieve(f'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/{n}', f'models/manga-light-colorizer/{n}') for n in ['v6_generator.onnx','v6_sam_encoder.onnx']]"

# 3) 启动服务（绑定 127.0.0.1:8788）
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 4) 浏览器打开 http://127.0.0.1:8788/
```

NVIDIA CUDA 路径：`python -m pip install -r tool/colorizer_service/requirements-gpu.txt`
并自备匹配的 CUDA/cuDNN 运行库，以 `COLORIZER_DEVICE=cuda` 启动；CUDA 不可用时服务明确报错，不会静默回退。

> **DirectML 版本说明**：`requirements-directml.txt` 把 `onnxruntime-directml` 钉在 `<1.21`。
> 实测 1.24.x 的 DirectML 数值在本模型上会让背景出现彩色斑块（噪点），且首次长图分块推理
> 易触发显存瞬时不足；1.20.1 为干净基线。1.20.x 没有 Python 3.13/3.14 wheel，GPU 路径请用
> Python 3.10–3.12（CPU 路径 3.14 可用）。GPU 单块推理失败时该块自动回退 CPU，长图不会整体失败。

## 方式四：Android 应用（端侧全自动）

在 `mobile/` 下用 Flutter 从源码构建（`flutter build apk --debug`，本分支实现时验证通过），
或等 Releases 的正式 APK。

1. 安装并打开应用，切到「全自动」页签。
2. 权重不随 APK 分发（CC BY-NC-SA），首次使用由应用内引导下载（约 300MB，一次性），
   支持断点续传与 SHA-256 校验；manifest 内置 hf-mirror 镜像源备选（国内网络）。
3. 就绪后选图开始全自动上色，结果可在应用内分享/保存。「提示点上色」页签不受影响，
   无需权重、完全离线可用。

设备要求：Android arm64 物理设备。端侧推理走 ONNX Runtime CPU 执行提供者（无
GPU/NNAPI 路径），每 1024² 分块耗时与峰值内存尚未真机实测——低端设备可能较慢，
该方式的表现与结论待实测后修订。

## 手动下载权重

从 [模型发布页](https://huggingface.co/sharky172/manga-light-colorizer) 下载 `v6_generator.onnx`
与 `v6_sam_encoder.onnx`（国内可换 `hf-mirror.com` 域名），放入：

- 桌面应用：`%LOCALAPPDATA%\manga-colorizer\weights\manga-light-colorizer\`
- 源码运行：仓库 `models/manga-light-colorizer/`

## 故障排查

| 现象 | 处理 |
|---|---|
| 顶栏显示「模型预热中…」 | 应用启动即在后台加载模型（首次 10-20 秒），预热完成后上色无需等待；内存紧张的机器可用 `COLORIZER_PRELOAD=0` 关闭预热 |
| 顶栏显示「模型休眠中」 | 空闲 10 分钟后自动释放模型以归还内存/显存，属正常行为；提交上色会自动唤醒（约 10-20 秒），可用 `COLORIZER_IDLE_UNLOAD=0` 改为常驻 |
| 顶栏显示「服务未连接」 | 等待 1-2 分钟（sidecar 启动）；仍失败则查看日志 `%LOCALAPPDATA%\manga-colorizer\logs\sidecar.log`，或重启应用（弹窗中选「重启服务」） |
| 处理器选项显示 GPU 灰色 / 「未检测到可用 GPU」 | DirectML 需要 DX12 显卡与较新显卡驱动；NVIDIA 机器若走 CUDA 需自装 CUDA/cuDNN。服务端日志会打印 `get_available_providers()` |
| 上色结果背景出现彩色斑块 | 确认 sidecar 用的是 `requirements-directml.txt`（onnxruntime-directml <1.21）构建；1.24.x 的 DirectML 在本模型上有已知数值问题 |
| 权重下载失败 | 检查网络/代理后重试（支持断点续传）；或按上文「手动下载权重」操作 |
| 主题不生效 | 主题可手动切换（导航栏底部按钮）并记忆；未手动切换时跟随系统深浅色 |

## 性能参考（实测）

| 输入 | 后端 | 耗时 |
|---|---|---|
| 512×384 | GPU · DirectML（RTX 5060 Laptop，热身后） | ~2 s |
| 1280×760 单页 | CPU（onnxruntime 1.30，laptop） | 10–18 s |
| 1280×7376 整页（分块） | CPU | ~122 s |

分块推理质量（vs 单块整缩）：Lab a/b 均值差 <0.6，PSNR >33dB；接缝跳变 ≤0.5（可见阈值 8）。
数据为单次实测，非保证值。
