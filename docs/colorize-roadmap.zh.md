# 上色引擎路线图（v0.7 → v0.9）

> 2026-11-22 依据三路开源调研（HuggingFace / GitHub+论文 / 魔搭）制定。
> 裁决：**桌面旗舰档内存峰值上限 8GB**；新增模型只列入路线图、**不安排测试/试跑**；移动端适配轻量小模型。

## 0. 原则

1. **8GB 旗舰档上限**：任何引擎的「权重 + 推理峰值驻留」≤ 8GB（不含系统与 UI 占用）。超限模型不进集成队列，只进观察名单。
2. **互斥驻留**：沿用现有引擎热切换机制（settings.json `engine`），任意时刻仅一个引擎会话集驻留；空闲自动卸载覆盖所有新引擎。
3. **一套 manifest**：新模型全部走 `weights-manifest.json` optional 条目 + `hf-mirror.com` mirror 字段按需下载，不发安装包内置。
4. **许可合规**：新增权重许可证全部登记进 `NOTICE`；无许可证权重（qweasdd 系）不得默认启用。
5. **不新增评测活动**：本路线图不安排任何试跑/对比测试；集成项沿用现有金样回归与用户目检流程，其余候选模型何时启动验证由后续裁决。

## 1. 现状基线（v0.6.1）

| 引擎 | 模型 | 许可 | 权重 | 速度 | 状态 |
|---|---|---|---|---|---|
| v6 | sharky172/manga-light-colorizer（GAN+SAM） | CC-BY-NC-SA-4.0 | 191MB + SAM 104MB | 实时级 | 现役（五档色彩方案） |
| Sana | sana-manga-coloring-onnx-int8 | Apache-2.0 | 2.7GB int8 | CPU 30-75s/页 | 现役主力（standard 直出） |

移动端：v6 系 ONNX + 全档位 no-arena + onTrimMemory 让步 + `:inference` 进程隔离（ORT 1.27.0）。
质量收尾管线 v2（白色前景救援 / 纸白中和 / 自适应色度 / 色域映射）为两端公共后处理。

## 2. 桌面引擎矩阵与 8GB 预算表

| 档位 | 引擎 | 部署格式目标 | 权重 | 运行峰值预估 | 预算结论 | 阶段 |
|---|---|---|---|---|---|---|
| 快档 | v6 | 现有 ONNX | 0.3GB | <1GB | ✅ | 已上线 |
| 主力档 | Sana int8 | 现有 ONNX int8 | 2.7GB | ~4GB | ✅ | 已上线 |
| 参考图档 | ColorizeDiffusion v1.5 | SD1.5 fp16 ONNX（optimum 导出） | ~2.5-3.5GB | ~4-5GB | ✅ | v0.7.0 |
| 旗舰档 | MOSS-MangaColorist-v1 | DiT int8（transformer ~4.8GB）+ 文本编码器 int4（~2GB）+ VAE，模块 offload | ~7-8GB | ≤8GB（gate） | ⚠️ 顶格 | v0.8.0 预研 |

超限不集成（仅跟踪）：MangaNinja（8-12GB 五模块）、ColorFlow（10-13GB）、FLUX.2-klein 9B（17GB）、ColorizeDiffusion XL（17.9GB）。

## 3. 阶段计划

### v0.7.0 —— 参考图档引擎（桌面）✅ 2026-11-23 落地（托管项除外）
- **ColorizeDiffusion v1.5**（tellurion，CC-BY-NC-SA-4.0，已 NOTICE 标注）：
  - ✅ 实际上游形态为单文件 safetensors（switch-eps.safetensors 4.3GB）+ 自研
    refnet 框架（非 diffusers 管线）；经 `tool/cdf_export/` torch 参考实现
    （ref_run.py 逐算子对齐上游 switch.py/basemodel.py）+ torch.onnx 导出
    fp16 四件：DualCondUNet 1.73GB + OpenCLIP ViT-H-14 视觉塔 1.27GB（MIT laion2b，
    非 checkpoint 内权重）+ MultiEncoder 128MB + VAE 解码器 99MB，合计 ≈3.2GB ≤3.5GB 目标。
  - ✅ 对拍验证（verify_onnx.py）：hint/context/eps/VAE 全组件 rel ≤0.4%；
    DPMSolver++ numpy 移植（diffusers 0.43 逐行）用真实 eps 重放逐位一致；
    quality_check 22 项含调度器锁定测试。
  - ✅ sidecar `cdf_engine.py`：DPMSolver++ 20 步、CFG=4 两分支（参考图 guidance）、
    DML fp16 优先 + 引擎级 CPU 回退；服务端 `_colorize_cdf` 接入质量收尾管线 v2
    （原稿 L 回写 + 一致性 + 白前景救援/色域映射）。
  - ✅ 文本操控（上游 opt-in 项）未导出文本塔，延后；settings engine=cdf
    热切换/空闲卸载/health/capabilities 全通；auto/hints 端点 400 引导参考图模式；
    设置页第三档（CDF 参考图）+ 模式锁定 + 双语文案。
  - ⏸ manifest optional 条目与设置页应用内下载：**待权重托管**（sha256 已备于
    `tool/cdf_export/weights_sha256.json`；HF 原仓无 ONNX，需自建托管仓）。
    本地放置 `models/manga-light-colorizer/cdf-v1.5/{cdf_cond,cdf_control,
    cdf_unet,cdf_vae_decoder}.onnx` 即激活（health cdf_ready）。
- **轻量前置件（两端同批）**：
  - ✅ MangaLineExtraction（ljsabc MIT，HF p1atdev 43M 版）ONNX 导出（173MB fp32）；
    输入 [0,255] 灰度 16 倍数；service `lineClean` 设置开关（env COLORIZER_LINE_CLEAN
    等价）接入 v6/sana/cdf 上游，默认关；权重同待托管（本地放置即用）。
  - ⏸ ScreenStyle VAE：Google Drive 权重在本网络不可达，机制随托管一并落地。
  - ✅ 与现有去网点/tagger 前处理并存，默认沿用现行为。

### v0.7.x —— 移动端小模型适配
- **前置净化链（Android）**：
  - ✅ MangaLineExtraction（约 173MB fp32）2026-11-24 接入：设置默认关并持久化，
    全自动与参考图流程共用；isolate 与 `:inference` 双路径均先以 384px 长边上限、
    白底补齐 16 倍数运行临时 ORT FFI no-arena 会话，Run 后立即关闭，再裁切/回原尺寸。
    权重缺失或损坏时告警并按原稿继续；本阶段仅支持本地手动放置，应用内下载仍待托管，真机验收待做。
  - ⏸ ScreenStyle ONNX 化：权重托管与导出待办，体积不以已完成的 MLE 件估算。
- **参考卡 → 色签**：deepghs `anime_ch_hair/skin/eye_color` tagger（MIT，魔搭直下，各几十 MB）——参考卡自动读出发/肤/瞳色。输出仅映射 Sana 五维**闭集**标签（严禁开放 palette 词，防 11-22 已裁决的整页泛染），实验位 opt-in 默认关。
- **秒级预览档（可选位，默认关）**：lookx2/manga-colorization 31MB 静态 int8 QDQ ONNX（SM8750 实测 0.5-0.6s/页）。⚠️ 上游 qweasdd/manga-colorization-v2 **无许可证**——仅作预览底色、不落盘、不商用，启用前需用户明示；备选替代：DDColor-Anime（魔搭 lf3000y，Apache-2.0，pt 869MB → int8 ONNX ~250MB 估算）。

### v0.8.0 —— 旗舰档 8GB 预研（不试跑）✅ 2026-11-23 设计文档交付
- **MOSS-MangaColorist-v1**（moonrailgun，Apache-2.0 LoRA 141.8MB；底座 MOSS-Image-Base ≈4.7B DiT）：
  - ✅ 导出方案设计成文 `docs/v0.8.0-flagship-design.zh.md`：transformer int8 ≈4.8GB +
    文本编码器 int8（int4 无 ORT 原生支持，初版建议 int8）+ VAE fp16，会话级顺序
    offload（同一时刻单模块驻留），峰值纸面校核 ≈5.8GB < 8GB gate。
  - 是否启动试跑与质量裁决由后续决定。
- **Sana Sprint 自蒸馏立项**：✅ 立项方案成文（同一文档 §2）：以现有
  sana-manga-coloring ONNX int8 为教师、Sprint（DMD2 蒸馏 1-4 步）为结构，
  目标 30-75s → 5-15s/页；训练需 CUDA 环境，本批不启动。

### v0.9+ —— 远端
- 移动端 Sana 端侧化（int4，~1.2GB 级，参照 MNN 先例）。
- Cobra（Apache-2.0，PixArt-α 0.6B，200+ 参考图池）——等 ONNX/社区转换或算子简化，属参考图档升级换代候选。
- 观察名单滚动复核（见 §4）。

## 4. 观察名单（只跟踪，不集成，不测试）

| 模型 | 许可 | 不集成原因 | 触发条件 |
|---|---|---|---|
| MangaNinja（CVPR'25 Highlight） | CC-BY-NC | 8-12GB 五模块级联 | 出官方量化/ONNX 且 ≤8GB |
| Sana v2 "Painted" | 未标注 | 半成品（15k/30k 步）、无 ONNX | 训完 + 补许可 |
| ColorFlow | 腾讯学术许可 | 10-13GB + 许可严 | 无 |
| FLUX.2-klein 9B LoRA | 底座非商用 | 17.3GB 底座 | 无 |
| ColorizeDiffusion v2 | CC-BY-NC-SA | fp16 ~3.3GB 可行但 v1.5 已覆盖，v2 增益未验证 | v1.5 上线后按需 |
| DDColor / DDColor-Anime | Apache-2.0 | 灰度照片上色，漫画分布外 | 移动预览档需要替代时 |

## 5. manifest / 下载器变更清单

- 新增 optional 条目：CDF v1.5（fp16 全件）、MangaLineExtraction（当前仅本地手动放置）、ScreenStyle VAE、deepghs tagger ×3、（可选）lookx2 31MB。
- mirror 策略：CDF/MOSS/lookx2 走 hf-mirror.com；Sana 全家桶、DDColor、deepghs 有魔搭直链可配双源。
- `allReady/totalBytes` 维持只算必需件；旗舰档与前置件均不阻塞首启动。

## 6. 风险与回退

| 风险 | 缓解 |
|---|---|
| 8GB gate 失守（MOSS offload 峰值超限） | 预研阶段即卡 gate；不达标则降级为观察名单 |
| DirectML 算子覆盖（SD1.5 导出件） | CPU int8 兜底路径与 DML 路径并存，引擎级回退 |
| 16GB 机器内存压力 | 互斥驻留 + 空闲卸载 + 旗舰档默认不预热 |
| qweasdd 无许可连带风险 | 移动预览档默认关、不落盘、可一键移除 |
| ScreenStyle 商用限制 | NOTICE 标注学术许可；若涉商用需联系作者 |

## 7. 验收口径

- 集成项：现有 quality_check 金样回归 + 用户真机目检（本路线图不新增评测活动）。
- 未集成项：仅跟踪上游动态，不产生任何运行行为。
