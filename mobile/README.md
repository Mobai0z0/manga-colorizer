# Manga Colorizer — 移动端（Flutter）

Android 侧的轻量工作台：选图 → 在画布上点按落提示点 → 上色 → 分享/保存。
推理直接调用纯 Dart 引擎 [`manga_colorizer_core`](../packages/manga_colorizer_core)，
在 isolate 中离线执行，**不依赖桌面 sidecar 或任何后端服务**。

## 功能

- 从相册选图，或加载内置样例（`assets/sample_bw.png`）
- 提示点上色：点按图片指定区域颜色，色度扩散求解，亮度完整保留原稿
- 原图 / 上色结果切换对比、一键清空提示点
- 结果通过系统分享面板保存或转发
- Material 3 主题（`ColorScheme.fromSeed`）

## 开发

```bash
cd mobile
flutter pub get
flutter run            # 连接 Android 设备 / 模拟器
flutter test           # 控件冒烟测试
```

要求 Flutter SDK（Dart `^3.6.0`）。

## 说明

- 提示点算法与桌面「提示点」模式同源（Levin 2004 色度扩散），但为端侧独立实现。
- 模型权重的 CC BY-NC-SA 许可仅适用于桌面/浏览器的 ONNX 全自动路径；本移动端只用
  纯 Dart 引擎，不涉及 ONNX 权重。整体许可见 [docs/licensing.md](../docs/licensing.md)。
- Android 端侧 ONNX 全自动上色是后续独立方向，尚未在本模块实现。
