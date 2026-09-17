# Phase A 验收: 新方案 (ONNX 语义上色) vs 旧引擎 (色度扩散)

测试日期: 2026-09-17 · 素材: out/real-photo/rp-crop-top.png (真实漫画页 1280×760)
服务: tool/colorizer_service/service.py (manga-light-colorizer ONNX, CPU EP, 10.2s/张)

## 定量指标

| 指标 | 旧引擎 descreen=true | 旧引擎 descreen=false | 新方案 ONNX |
|---|---|---|---|
| 亮度保持率 (<0.5) | 38.7% (整页) | 100% | 31.1%* |
| 亮度偏差>20 像素占比 | 18.8% (整页) | 0% | **0.0175%** |
| 最大亮度偏差 | 169 | 0.5 | 22.5 |
| 语义配色 (发/肤/瞳/背景) | ✗ 区块调色 | ✗ 渗色+单调 | **✓** |
| 网点残留 | 无(被展平) | 明显 | 无(模型生成) |

\* 新方案的 68.9% "亮度改变"全部集中在 ≤10 的小幅区间 (直方图: 76% 在 0-5 级),
来源是 resize 插值 + Lab 转换取整, 不是结构破坏 (偏差>20 的仅 0.0175%);
旧引擎 descreen=true 的 18.8% 是大面积重写 (直方图尾部 51.5 万像素 >50 级)。
两种"亮度改变"性质不同: 前者是数值噪声, 后者是结构破坏。

## 视觉对比 (三联图 out/real-photo/e2e-compare.png + e2e-auto.png)

- 旧引擎 descreen=false: 脸部/对白框正常, 但发色单调灰褐、网点区残留麻点、
  发梢渗肤色;
- 新方案: 发丝有棕色深浅变化、皮肤暖色自然、瞳孔蓝紫、背景浅蓝、
  对白框纸白纯净、网点纹理被生成色替代 — 语义级配色。

## 结论

Phase A 验收通过。新方案 (Python ONNX 服务) 在真实漫画上的颜色正确性、
染色精度、整体质量三个维度均显著优于旧引擎, 达成"颜色不对/染色粗劣"
问题的范式级解决。后续:
- Phase B: MangaNinja 参考图上色 (跨页一致性 + 点对精控);
- 性能: 装 onnxruntime-gpu 用 RTX 5060 (当前 CPU 10.2s, GPU 预计 1-2s);
- Dart 客户端 (tool/colorize_auto_client.dart) 需 dart pub add http 后联调。
