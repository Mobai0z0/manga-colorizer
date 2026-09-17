# 技术调研: 日本黑白漫画(含网点)上色的参考项目

调研日期: 2026-09-17 · 方法: web_search 检索(未逐一实读源码,结论标注"待实测")
场景澄清: 本项目输入是**日本黑白漫画扫描稿**(含网点 screentone、灰阶、扫描噪点),
不是干净线稿。此前 `research-manga-colorizer.md` 调研的多数方法以 lineart 为输入,
直接套用会有问题,本文补充网点处理路线。

---

## 1. 关键认知: 网点不是噪声,是亮度编码

- Hensman & Aizawa (arXiv:1706.06918) 的实验结论: **网点与灰度对上色的作用相同**——
  "当目标图与训练图网点类型一致时,颜色更准,网点相当于给模型提供了灰度信息";
  反之,完全无网点的图上色质量会下降。
- 但网点也有害: 它是黑白高频振荡,上色后若原样保留亮度,黑点仍嵌在色块里,
  成图呈现"脏色/麻点"——这正是本引擎对真实漫画"效果不理想"的一个根本原因
  (合成样例无网点,掩盖了该问题)。
- 去网点的副作用(同篇论文记录): 边缘毛糙、阴影区多出假线。因此**不能只做去网点**,
  需要结构线与网点分离后再分别处理。

## 2. 网点处理参考项目(按路线分类,均未实测)

### 路线 A: 深度模型分离 结构线 / 网点

| 项目 | 论文/状态 | 作用 | 对本项目 |
|---|---|---|---|
| [ljsabc/MangaLineExtraction_PyTorch](https://github.com/ljsabc/MangaLineExtraction_PyTorch) | SIGGRAPH 2017 "Deep Extraction of Manga Structural Lines", 权重 erika.pth (~164MB) | 单一模型去除不规则/规则/任意尺度/图示型网点,输出结构线 | **首选**: 直接解决"网点嵌在色块里"问题; 原版 Theano 有 [ljsabc/MangaLineExtraction](https://github.com/ljsabc/MangaLineExtraction), HuggingFace 有 transformers 移植 `p1atdev/MangaLineExtraction-hf` |
| [msxie92/ScreenStyle](https://github.com/msxie92/ScreenStyle) | SIGGRAPH Asia 2020, ScreenVAE | 学习 4 通道中间域,把网点漫画映射到"纹理与内容分离"的表示,支持彩色↔网点双向转换 | 更重的方案; 若仅需提线,MangaLineExtraction 已够 |
| [msxie92/MangaRestoration](https://github.com/msxie92/MangaRestoration) | CVPR 2021, SE-Net+MR-Net | 利用下采样走样线索修复低质量扫描网点 | 仅当输入是低分辨率/走样扫描时需要 |
| [msxie92/MangaInpainting](https://github.com/msxie92/MangaInpainting) | SIGGRAPH 2021 | 结构线与网点解耦后做语义修补 | 修对话气泡/遮挡时有用,与本任务正交 |

### 路线 B: DSP 去网点(无深度模型)

| 项目 | 方法 | 对本项目 |
|---|---|---|
| [natethegreate/Screentone-Remover](https://github.com/natethegreate/Screentone-Remover) | 高斯模糊+双边滤波去高频, Laplacian 锐化保边 | 本引擎现有 `descreen` 选项(3×3 中值×2 + 盒模糊均值场)就是同思想; 提升空间: 换成"模糊+锐化"两段式,比纯中值更保边 |
| [Cec1c/Aletheia-Lens](https://github.com/Cec1c/Aletheia-Lens) v1.2.0 | Screentone-Remover 思路的独立实现, 轻中重三档 | 可参考其分档参数设计 |

### 路线 C: 保留网点作为上色线索

- cGAN 漫画上色 (arXiv:1706.06918, 社区复现 [ryanliwag/cgan-based-manga-colorization-using-1-training-image](https://github.com/ryanliwag/cgan-based-manga-colorization-using-1-training-image)):
  用单张彩色参考图训练; 网点模式直接映射颜色; 配套 "trapped ball" 分割抗线稿小缺口。
  对本引擎的启发: **提示点扩散的权重场可利用网点局部均值**,而非只看中值滤波后的亮度——
  本引擎 `descreen` 已做了一半,缺的是"网点→灰阶"的显式反解。

## 3. 推荐管线(结合本引擎现状)

```
扫描稿 → [A/B] 网点处理 → 本引擎 colorizeManga (提示点/色板) → 结构线叠回
              │
              ├─ 稳妥: MangaLineExtraction 提线 → 线稿+均值灰阶 → 上色 → 叠线
              └─ 快速: 升级 descreen 为 Screentone-Remover 式 模糊+锐化
```

- 本引擎接口已按"灰度入→RGB 出"抽象,把步骤 2 的输出作为输入即可,API 契约不变;
- `readme.md` 已标注"网点按亮度处理属 Phase 2",本文将该路线具体化。

## 4. 许可注意(商用前必须逐仓库核实)

| 项目 | 页面可见信息 |
|---|---|
| MangaLineExtraction (原版/PyTorch) | 未见 LICENSE 标注(与 qweasdd 系类似), 需联系作者 |
| msxie92 系 (ScreenStyle/Restoration/Inpainting) | 学术项目, 未见明确商用条款 |
| Screentone-Remover / Aletheia-Lens | 社区工具, 需核实 |
| 训练数据 Manga109 | 研究用途, 衍生模型商用需注意 |

## 5. 采用/不采用(本轮)

- **采用(思路)**: "先分离网点再上色"的两段式管线; descreen 参数分档; 网点=亮度编码的认知。
- **不采用(本轮)**: 全部深度模型——本引擎当前定位仍是纯 Dart 零权重; 以上项目作为
  Phase 2 (ONNX 集成) 的候选与预研依据。
- 检索缺口: 各仓库 LICENSE 全部未逐一打开核实; MangaLineExtraction 的网点数据集
  作者称"计划发布"但未见实际发布。
