# 漫画上色方案 v2: 参考图驱动 + 三种交互 + 深度模型

制定日期: 2026-09-17
用户决策: 本机 NVIDIA 显卡(≥6GB VRAM) · 个人使用/学习 · 三种交互都要
取代: 纯 Dart 色度扩散范式(archive, 见文末"旧方案定位")

---

## 0. 为什么必须换范式

旧引擎 (Levin 2004 色度扩散 + 色板 + descreen) 的三个结构性缺陷, 全部在
real-photo 实测中确认 (tool/check_luminance.dart 可复跑):

1. **颜色不对**: 色度扩散只在"提示点指定过的区域"插值颜色, 本质是"区块调色调";
   没有语义理解 — 头发/皮肤/衣服边界靠亮度相似度判断, 真实漫画灰阶连续,
   边界必然渗色 (发梢染肤色、白底泛蓝灰);
2. **染色粗劣**: 提示色只表达"色相意图", 经 adaptHintChromaToLuminance 缩放后
   饱和度/明度与目标脱节; 深色区域染不上饱和色, 浅色区域容易过饱和;
3. **亮度破坏**: descreen=true 时 61.3% 像素亮度被重写 (18.8% 偏差>20),
   视觉上"所有颜色都不对"的主要来源; descreen=false 又残留网点颗粒。

结论: 参数优化救不了范式。需要深度模型做**语义上色**。

## 1. 选型 (已按用户环境/许可筛选)

### 主力: MangaNinja (CVPR 2025 Highlight) — 参考图上色

| 项 | 说明 |
|---|---|
| 仓库 | https://github.com/ali-vilab/MangaNinjia |
| 原理 | SD1.5 + lineart ControlNet + Reference UNet (IP-Adapter 式) + PointNet; 逐步 patch shuffling 学局部语义匹配 |
| 质量 | 200 对动画基准上 SOTA, 全面超 BasicPBC/IP-Adapter/AnyDoor (DINO/CLIP/PSNR/MS-SSIM/LPIPS 全指标) |
| 显存 | 官方 ~6-8GB 峰值; ComfyUI 版实测 6GB 可跑 |
| 许可 | CC BY-NC 4.0 (非商业) — 个人使用/学习 OK |
| 交互 | 参考图 + (可选)点对应; 支持跨角色上色、多参考融合 |

### 全自动档: sharky172/manga-light-colorizer (ONNX)

| 项 | 说明 |
|---|---|
| 地址 | https://huggingface.co/sharky172/manga-light-colorizer |
| 原理 | FastViT-SA36 + SAM2.1 语义引导 + UNet V6; 无需参考图/提示点 |
| 部署 | ONNX Runtime, CPU 即可 (~5s/张); 有 NVIDIA 时可用 CUDA EP |
| 许可 | 权重 CC BY-NC-SA 4.0, 推理代码 GPL-3.0 — 个人 OK |
| 用途 | 批量预览/一键底色, 再对重点页走 MangaNinja 精修 |

### 提示点交互: 保留 Dart 引擎作为"点选器", 语义由模型承担

现有 Flutter/Dart 前端的提示点 UI 不浪费: 点位转成 MangaNinja 的 point-driven
控制 (参考图上点 + 线稿上点), 或作为 manga-light-colorizer 结果的局部修正输入。

### 云 API 兜底 (可选, 非主力)

- Apify ParseForge Manga Colorizer: ~$0.06-0.15/页;
- Watashi Colorizer: 信用点制, 支持跨章色板锁定 (出版级一致性)。

## 2. 架构: Python 模型服务 + 保留 Dart 资产

```
┌─────────────────────────────────────────────┐
│ Dart 层 (保留)                                │
│  • CLI/服务端壳: 图像 IO, PNG 编解码, tile 切分  │
│  • 色板 JSON / 角色档案 (直接喂给参考图模式)      │
│  • 批量管线: batch_run / compare / 台账         │
│  • HTTP 客户端 → 调本地 Python 服务             │
└──────────────────┬──────────────────────────┘
                   │ HTTP (multipart + JSON)
┌──────────────────▼──────────────────────────┐
│ Python 服务 (新增, FastAPI)                    │
│  /colorize_ref   → MangaNinja (参考图+点)      │
│  /colorize_auto  → manga-light-colorizer ONNX │
│  /lineart        → MangaLineExtraction 提线    │
│  管线: 预处理(去网点/切 tile 512) → 模型 → 拼回  │
└─────────────────────────────────────────────┘
```

**为什么这样分层**: 深度学习上色的生态在 Python (权重/预处理/DIFFUSERS),
Dart 生态没有等价物; 但 Dart 侧的工程资产 (色板、tile、批量、对比图) 全部可复用,
引擎接口本来就是"灰度入→RGB 出", 换后端不动 API 契约。

## 2. 三种交互 → 三个端点

| 交互 | 端点 | 模型 | 用户输入 |
|---|---|---|---|
| 全自动 | /colorize_auto | manga-light-colorizer ONNX | 仅漫画页 |
| 提示点 | /colorize_points | MangaNinja point-driven (点位对) | 漫画页 + 点对 |
| 参考图 | /colorize_ref | MangaNinja reference UNet | 漫画页 + 角色彩色图 |

## 3. 分阶段落地

### Phase A (本次): 服务骨架 + 全自动模型跑通
1. Python venv + FastAPI + onnxruntime-gpu;
2. 下载 manga-light-colorizer ONNX 权重 (~164MB erika 不用, 用 v6_generator.onnx + v6_sam_encoder.onnx);
3. Dart 侧加 `--backend http` 开关, colorize 命令转发到 Python 服务;
4. 用 out/real-photo/original/full-page-original.png 实测, 与现有引擎出对比图。

### Phase B: MangaNinja 参考图上色
1. clone ali-vilab/MangaNinjia, 下载 4 个 .pth + SD1.5 + lineart ControlNet;
2. ComfyUI_MangaNinjia 或官方 gradio 起服务, FastAPI 包装成 /colorize_ref;
3. 用 out/real-photo 已有素材做参考图 (boy/girl/citysky 彩色结果即参考图) 验证跨页一致性。

### Phase C: 质量验收闭环
- 固定测试集: out/real-photo 5 张 + out/sample_manga.png;
- 指标: 亮度保真 (复用 check_luminance.dart)、色度覆盖率、跨页角色色差 (ΔE);
- 每次调参出 triple 对比图人工复核。

## 4. 许可红线 (个人使用前提下)

| 模型 | 许可 | 个人 | 商用 |
|---|---|---|---|
| MangaNinja | CC BY-NC 4.0 | ✅ | ❌ 需授权 |
| manga-light-colorizer | 权重 CC BY-NC-SA 4.0 / 代码 GPL-3.0 | ✅ | ❌ |
| 本引擎 Dart 部分 | 自研 | ✅ | ✅ |

商用化时替换路线: 云 API (Watashi/Nero) 或联系 ali-vilab 商业授权。

## 5. 旧引擎定位

不删除: 色度扩散作为"无 GPU/离线/确定性"后备保留 (lockPureMonochrome 修复、
白区平涂、tile 管线都是已完成资产); Python 服务不可用时自动 fallback。
