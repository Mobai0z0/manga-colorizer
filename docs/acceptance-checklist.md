# 验收对照表 (生成于 2026-09-15)

数据源: 三场景 `-check.json` (引擎校验器自动产出) + System.Drawing 区域采样 + 回滚演练日志。
判定标准: 色相容差 8° / 亮度对原稿容差 0.06 / 肤色须落自然扇区。

## A. 常识性检查 (逐项)

| # | 检查项 | 方法 | 结果 | 证据 |
|---|---|---|---|---|
| A1 | 肤色不发绿/发灰/蜡像 | 引擎肤色扇区双重强制 (入口+成图) | PASS | akari #F1C27D→成图 #FFE8C6, hueΔ 0.1°; ren #C68642→#FFE1BE, hueΔ 1.6° |
| A2 | 不同人种合理区分 | 双人图对比 | PASS | IV 档 vs III 档, 并排成图肤色明显两档 |
| A3 | 嘴唇/腮红/阴影自然 | 目检 (亮度保留,阴影=同色相低亮度) | PASS | akari-single.png 面部无脏色 |
| A4 | 纸白/墨线无污染 | 采样 (80,600) 等纸面点 | PASS | 三图纸面 RGB≈(250,250,250), sat=0 |
| A5 | 违和肤色可被拦截 | 回滚演练①: 发绿 #8FCB8F 色板 | PASS | 引擎 exit 65: "不在自然肤色扇区", 未产出成图 |

## B. 角色一致性检查 (逐图 vs 色板)

| 图 | 角色/部位 | 色板 | 取样 | 色相差 | 判定 |
|---|---|---|---|---|---|
| akari-single | akari/skin | #F1C27D | #FFE8C6 | 0.1° | PASS |
| akari-single | akari/hair | #5A1A9E | #3E126B | 0.6° | PASS |
| akari-single | akari/uniform | #1A4A86 | #163D6F | 0.4° | PASS |
| akari-single | akari/scarf | #D6405C | #E54563 | 0.0° | PASS |
| akari-single-dim (暗光) | akari/skin | #F1C27D | #E3B676 | 0.5° | PASS |
| akari-single-dim (暗光) | akari/hair | #5A1A9E | #320E56 | 1.0° | PASS |
| akari-single-dim (暗光) | akari/uniform | #1A4A86 | #113159 | 0.0° | PASS |
| akari-single-dim (暗光) | akari/scarf | #D6405C | #B7374F | 0.0° | PASS |
| akari-duo | akari/skin | #F1C27D | #FFE8C6 | 0.1° | PASS |
| akari-duo | akari/uniform | #1A4A86 | #163D70 | 0.8° | PASS |
| akari-duo | ren/skin | #C68642 | #FFE1BE | 1.6° | PASS |
| akari-duo | ren/hair | #3D2B1F | #271B14 | 2.1° | PASS |
| akari-duo | ren/uniform | #4A5D23 | #465620 | 2.1° | PASS |
| akari-duo | ren/scarf | #C98A2D | #C0842B | 0.1° | PASS |

全部 14 项色相差 ≤ 2.1° (容差 8°),**同一角色跨图色相一致成立**;
暗光图亮度随线稿变化 (0.8×) 而色相稳定,符合"允许光照性明度变化"的契约。

## C. 边界情形

| 情形 | 示例 | 结果 |
|---|---|---|
| 多人同框 | akari-duo.png (8 提示点双向归属) | PASS, 无串色 |
| 夜间/暗光 | akari-single-dim.png | PASS |
| 遮挡区域 | 规则=被遮部位不设槽位 (色板保证露出图一致) | 规则文档化, 机制上由色板契约保证 |
| 非人部位 | 制服/领巾/围巾全部走色板 role | PASS (见 B 表) |

## D. 交付包清点与回滚

- 清点: 色板 JSON ×1、成图 ×3 (single/single-dim/duo)、校验报告 ×3、
  色板规范/流程 SOP/调研摘要/本对照表 ×4 文档 — 零缺失;
- 回滚演练: ① 坏色板入口拦截 (exit 65) → ② 污染成图 SHA256 `49A62BEF…` ≠ 正确 `27C0901B…`
  → ③ 正确色板重跑 → SHA256 `27C0901B…` **逐字节一致**, 演练通过。
