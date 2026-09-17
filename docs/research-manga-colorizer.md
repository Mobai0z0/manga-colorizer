# 技术调研报告: Manga-Colorizer 与同类开源漫画上色项目

调研日期: 2026-09-15 · 方法: 逐仓库打开 README/源码页实测阅读(open-link),检索快照辅助
主参考: <https://github.com/BinitDOX/Manga-Colorizer>(用户指定)

---

## 1. 主参考拆解: BinitDOX/Manga-Colorizer

**定位**: 不是新算法,而是一个工程整合项目——把上游 AI 模型包装成"浏览器扩展 + 自托管服务端"的即用型上色方案,支持任意漫画网站边看边上色(on-the-fly)。

**架构**(实读 README 拆解):
- **AI 内核**: 直接采用 qweasdd/manga-colorization-v2 的 Generator 权重与 Extractor,用户需从外部下载 `generator.zip` + `extractor.pth` 放入 `Backend/networks/`;
- **服务端**: Python + PyTorch(`app-stream.py`,端口 5000,HTTPS 自签名);无 GPU 用户走 Kaggle P100 笔记本(每周约 30h 免费 GPU)+ ngrok 隧道;
- **客户端**: Firefox 临时扩展 / Chrome 未打包扩展 / Android Kiwi 浏览器 .crx,共三套客户端;
- **增强**: Real-ESRGAN 超分(来自 xiaogdgenuine/Manga-Colorization-FJ 的整合经验)、站点白名单自动上色、结果缓存目录。

**上游内核实读**(colorizator.py,62 行,全部逻辑):
1. 输入强制缩放到 576px 且边长必须被 32 整除(`resize_pad` + padding 补齐);
2. FFDNet 去噪预处理(默认 sigma=25,去除网点/扫描噪点);
3. hint 通道格式 = RGB 提示色(归一到 [-1,1])×mask + mask 通道,共 4 通道拼接到灰度图上;
4. Generator(条件 GAN 生成器)前向 → 输出 [-1,1] 色度图 → 反归一化;
5. 解 pad 还原原尺寸。
- 已知质量边界: 社区 issue 报告 **宽度超过 576px 的图上色质量下降**(issue #12, "processing images wider than 576px"),因为它对整图缩放到固定 576 推理再放大。

**许可与生态**: 仓库本身未在页面标注 License(上游 manga-colorization-v2 亦未见 LICENSE 文件);官方商业版 MangaColorizerPro 为封闭扩展;社区衍生: septn 的桌面 GUI、Firefox 官方商店扩展、Kaggle notebook。

## 2. 横向对比(≥3 个同类项目,均已实读)

| 项目 | 技术路线 | 交互模式 | 性能特征 | 许可证(页面可见信息) | 现状 |
|---|---|---|---|---|---|
| **BinitDOX/Manga-Colorizer**(主参考) | qweasdd GAN 生成器 + FFDNet 去噪 + Real-ESRGAN 超分 | 全自动,无需提示点 | GPU 秒级;固定 576px 推理,大图先缩后放,细节损失;>576px 质量下降有 issue 记录 | 页面未标注(复用上游需注意) | 活跃(2024-07 issue 处理) |
| **qweasdd/manga-colorization-v2** | 条件 GAN: Generator(全卷积)+ Extractor;hint 4 通道拼接 | 半自动: 支持 hint 点标注更新(`update_hint`) | 576px/32 对齐约束;CPU 可跑但慢 | 页面未标注 LICENSE | 2025-03 仍在更新 readme,v2.5 demo 预告中 |
| **xiaogdgenuine/Manga-Colorization-FJ** | 同上内核 + 三项工程增强: pt 格式权重(兼容 PyTorch≥1.0)、小显存分块推理(colortile/srtile/tile_pad)、Real-ESRGAN 超分 | 同上游(半自动) | 分块推理解决小显存;CPU 明确支持(`inference.py` 无 `-g` 即 CPU) | **有 LICENSE 文件**(2022-06-21 initial commit) | 归档状态(2022-06 停更) |
| **lllyasviel/Style2Paints V4.5** | 自研两阶段: lineart flat filling + 渲染;输入支持线稿+提示点+风格参考图+光源 | 人在回路: <15 次点击,支持全自动/半自动 | Windows x64 一键包(免 CUDA 免 python);输出为**分层 PSD**(线稿/固有色/渐变/阴影),非单张图 | 代码 Apache-2.0;**模型与二进制保留所有权利** | V5 预览未发布;V4.5 可下载 |

**交叉结论**:
1. **全自动路线**(BinitDOX 系)胜在零交互成本,败在角色一致性——每页独立推理,同一角色跨页色漂是固有缺陷,社区 issue 反馈的"color quality"问题即此类;
2. **半自动 hint 路线**(qweasdd 上游、本引擎、Style2Paints)可控性强;Style2Paints 的"分层输出+人类工作流"是质量天花板,但模型许可封闭、依赖重;
3. **工程共性**: 去噪(FFDNet)、分块推理(FJ tile)、超分(Real-ESRGAN)是三个可脱离模型独立复用的工程组件;
4. **许可敏感点**: qweasdd 系权重许可不明,商用前必须核实;Style2Paints 模型明确禁商用再分发。

## 3. 本引擎的吸收与差异(为什么我们这样做)

| 借鉴点 | 来源 | 本引擎落地 |
|---|---|---|
| 分块推理 + 重叠羽化 | FJ 的 tile/colortile 参数设计 | `colorizeMangaTiled`(tile 512/overlap 64/边界感知羽化),1024×1280 实测 PSNR-Y 73.2dB,比整图还高 2dB(提示点局部密度提升) |
| 576px/32 对齐教训 | colorization-v2 的 size 约束与 issue #12 | 反其道: 不缩图,多尺度求解器直接处理原分辨率,亮度通道零重采样 |
| 全自动模式的缺陷 | BinitDOX issue #12 色彩质量反馈 | 保持"色板驱动半自动"路线: 颜色从角色色板来,一致性由色相容差校验器兜底 |
| 层级输出思想 | Style2Paints 的分层 PSD | Phase 2: 色板天然对应分层(线稿层/固有色层),架构已按"灰度入→RGB 出"抽象留口 |
| 去噪预处理 | FFDNet(sigma=25) | Phase 2: 当前按亮度处理网点,细网点图建议先去噪;引擎接口留有预处理槽位 |

**不采用项及理由**: PyTorch/ONNX 深度模型栈(许可不明 + GPU 依赖,与本引擎"纯 Dart 确定性"定位冲突);Kaggle/ngrok 自托管链路(运维复杂度不适合本地工具)。

## 4. 检索与阅读记录

- BinitDOX/Manga-Colorizer README: 2026-09-15 实读(open-link 存档 `out/mc_readme.txt`)
- qweasdd/manga-colorization-v2 README + colorizator.py 全文: 实读(`out/mcv2_readme.txt` / `out/mcv2_colorizator.txt`)
- xiaogdgenuine/Manga-Colorization-FJ README: 实读(`out/fj_readme.txt`)
- lllyasviel/Style2Paints README: 实读(`out/s2p_readme.txt`)
- 社区 issue 与生态: web_search 快照(GitHub issue #12、Kaggle notebook、Firefox Add-ons、septn 桌面 GUI)
- 许可核实缺口: qweasdd/BinitDOX 两仓库页面未见 LICENSE 文件,已在本文标注"未标注";商用前需向作者确认
