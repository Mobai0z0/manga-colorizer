# 调研摘要 (有据可查版)

检索时间: 2026-09-15 · 工具: AutoGLM web_search (检索快照,未逐一打开全文)

## 1. 检索到的参考方案

| # | 方案 | 来源 | 结论 | 理由 |
|---|---|---|---|---|
| 1 | Monk Skin Tone (MST) 刻度 | [skintone.google](https://skintone.google/) | 采用其思想 | 官方强调"为研究者提供精确色值",印证"肤色应以公开色值档位为准"的做法;本引擎用五档公开调色板作种子色 |
| 2 | Skin Tones 公开调色板 `#8d5524 #c68642 #e0ac69 #f1c27d #ffdbac` | [color-hex.com](https://www.color-hex.com/) | **直接采用** | 五档覆盖浅→深,作为肤色扇区种子色与色板档案的人种分档依据 |
| 3 | Kolkur et al. 2017, Human Skin Detection Using RGB/HSV/YCbCr | [arxiv.org](https://arxiv.org/) (检索页) | 采用其结论 | 肤色在 YCbCr/RGB 空间聚成"暖色窄带"是文献共同结论;本引擎的 YUV 肤色扇区即该结论的工程化 |
| 4 | MangaNinja (2025-01, line art colorization with precise reference) | [GitHub](https://github.com/) / [项目页](https://johanan528.github.io/) / [arXiv](https://arxiv.org/) | Phase 2 候选 | "参考图对齐+精确匹配,一致性强"正是本 Goal 的跨图一致性方向;但依赖深度模型,当前引擎走确定性算法,列为升级路线 |
| 5 | Comicolorization (Semi-Automatic Manga Colorization) | [ResearchGate](https://www.researchgate.net/) (检索页) | 采用其交互模式 | "在草图上 scribble 指定物体颜色"与本引擎提示点模式同构,验证了提示点交互的可行性 |

## 2. 采用 / 不采用汇总

- **采用**: 公开肤色五档色值 (种子色+色板分档)、肤色暖色窄带约束 (YUV 扇区)、提示点/scribble 交互模式、色相容差验收 (8°)。
- **暂不采用 (记录理由)**: MangaNinja 等深度模型方案 — 上色质量上限更高、参考图一致性更强,但需要 GPU/模型权重/推理依赖,与本引擎"纯 Dart、确定性、可回滚"的当前定位冲突;待 Phase 2 以 ONNX 路线接入 (引擎接口已按"灰度入→RGB 出"抽象,替换不动色板契约)。

## 3. 检索缺口

- MST 官方色值表未打开原文核对 (仅快照),Phase 2 若需要跨人种更细分档再补;
- 上一任务调研清单中的 Style2Paints/manga-colorization-v2 链接仍未逐一验证,保留"待验证"标注。
