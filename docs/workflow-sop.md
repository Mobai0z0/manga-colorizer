# 可复用上色流程 (SOP)

适用: manga-colorizer 引擎 0.1.0+ · 上次演练: 2026-09-15 (三场景 PASS + 回滚演练通过)

## 一、新增角色的标准动作

1. 在 `out/character_palettes.json` 的 `characters` 数组追加一个角色块:
   `characterId`(英文稳定 ID)、`displayName`、`parts`(skin/hair/eyes/uniform/scarf…);
2. 肤色从五档种子色调色板选档 (`#8d5524 #c68642 #e0ac69 #f1c27d #ffdbac`),
   或自定义后自行确认落在自然肤色范围 — 入口会自动拦截违和肤色;
3. 每个部位写清 `usage`(哪个部位、什么场合用)。

## 二、给新图上色的标准动作

```bash
# 1) 生成线稿灰度图 (或导入已有线稿, PNG/JPG 均可)
dart run manga_colorizer_cli:make_sample -o out/新图.png

# 2) 确定槽位: 在新图上找每个部位的代表坐标 (x,y)
#    单人场景可直接用 recommendedSampleSlots; 新构图手动填

# 3) 色板驱动上色 + 自动校验 (一条命令完成)
dart run manga_colorizer_cli:colorize_palette \
  --palette out/character_palettes.json --character akari \
  --scene single --out-dir out
# 退出码 0 = PASS; 70 = 校验 FAIL (会打印每处偏差); 65 = 色板本身违和
```

## 三、参数与命名规则

- 成图命名: `<characterId>-<scene>.png`;校验报告同名 `-check.json`;
- 每次批量产出建版本目录 (`out_v1/`、`out_v2/`),回滚 = 用色板 JSON 重跑同名命令;
- 算法参数只经 `--options` JSON 传入,默认值已调优 (sigma 0.03 / SOR ω1.93 / 多尺度)。

## 四、校验与验收

- 校验器判定: 色相差 ≤8° (硬契约) + 亮度对原稿差 ≤0.06 + 肤色扇区复检;
- 校验报告 JSON 逐部位给出 target/sampled/hueΔ/lumΔ/pass,即验收对照表数据源;
- 常识性目检清单见 [`character-color-spec.md`](character-color-spec.md) §4。

## 五、回滚方法 (已演练)

1. 保留每版色板 JSON (不可覆盖历史版本);
2. 发现偏色: 先跑 `--palette 坏版本.json` 复现问题 → 确认校验器能拦截 (exit 65/70);
3. 恢复: 用上一版正确色板重跑 `colorize_palette` → 成图哈希应与污染前一致
   (算法确定性,2026-09-15 演练 SHA256 比对通过);
4. 若需调整色板本身: 改 JSON → 重跑全部场景 → 全部 `-check.json` PASS 后归档新版本号。

## 六、边界情形速查

| 情形 | 处理 |
|---|---|
| 多人同框 | 每角色独立色板+槽位,一次命令内全部上色 (duo 场景示例) |
| 夜间/暗光 | 线稿先压暗 (×0.8),色板不动,校验按"亮度对原稿"判定 |
| 遮挡 | 被遮部位不设槽位即可,色板保证露出的新图一致 |
| 非人部位 | 自定义 role (如 weapon/background),同样享受色板契约 |
