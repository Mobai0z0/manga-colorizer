# 社区版许可与发行边界

**本仓库代码采用 [Apache License 2.0](../LICENSE)（第三方组件见 [NOTICE](../NOTICE)）。**
模型权重不随仓库分发，仍受其自身许可约束（见下表）。

## 已核验的上游声明

来源：[sharky172/manga-light-colorizer 模型卡](https://huggingface.co/sharky172/manga-light-colorizer#license)。本次通过 hf-mirror 的 README 原文核对 License 段落。

| 模型权重 | [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) | 非商业可选后端；不随源码分发，使用者自行下载 |
| 上游推理代码 | [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) | 保留来源说明；本地 service.py 为独立实现，与上游代码的相似性待审计 |
| 本仓库原创代码 | Apache-2.0 | 见 LICENSE / NOTICE；调用 NC 权重不改变权重自身许可 |
| Material Web | Apache-2.0（见安装包 LICENSE） | 保留第三方许可证；前端构建不改变模型权重许可 |

上传 GitHub、免费分享和非商业应用集成本身不等于商用。但“免费”不必然满足 NC：广告盈利、商业推广、收费服务等应另行确认授权。

## 使用者义务

- 使用受 NC 限制的模型前阅读完整许可证；非商业不是免责或漫画版权授权。
- 分发权重时须保留署名、来源与许可信息；修改受许可材料还涉及修改标记和 ShareAlike 条款。
- 调用模型的独立代码、生成结果不应简单一概归入同一许可证；原始漫画版权和具体条款仍需核对。
- 不得将本仓库的开源目标宣传为模型可商用授权。
- 前端中的许可确认只作为提示，不替代完整许可证。

## 公开发布前仍需完成

1. 核对本地推理代码来源，以及基础模型/附属权重的来源和许可链。本页只确认发布者对该仓库材料的声明，不构成完整法律审计。
2. 不提交 models/、out/、真实漫画、日志、虚拟环境和本机代理配置。公开样例须另选授权明确的素材。
3. 保留 npm/Python/Dart 依赖的许可说明；发布二进制包前检查所包含的第三方材料。

当前定位：Apache-2.0 代码 + 使用者自行下载的 NC 权重；许可链的完整法律审计仍待完成。
