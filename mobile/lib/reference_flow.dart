// 参考图上色的可测入口：把「RGBA→RGB」「isolate 内迁移+融合」收敛在库层，
// AutoTab 只做编排。Isolate.run 的闭包必须是 static/顶层——见 auto_panel.dart
// 同款纪律（v0.5.1 教训：实例作用域闭包经共享 context 捕 this 变 unsendable）。
//
// v0.6.1 起参考图模式同步桌面（service.py `_process_reference`）：
// [referenceColorizeInIsolate] 把「模型语义色 ⊕ 参考图迁移色 Lab a/b 5:5
// 融合、L 恒取原稿」收敛为单 isolate 端到口。纯迁移入口（无模型、无融合）
// 随 v0.6.0 旧路径全量替换移除——桌面参考图模式无对应行为。
import 'dart:isolate';
import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// RGBA（capDecodeRgba 产物）→ 紧凑 RGB（迁移入口吃 3 通道）。
/// 工作 isolate 执行（4.2M 次循环放主 isolate 会掉帧）。
Uint8List rgbaToRgbBytes(Uint8List rgba) {
  final n = rgba.length ~/ 4;
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    rgb[i * 3] = rgba[i * 4];
    rgb[i * 3 + 1] = rgba[i * 4 + 1];
    rgb[i * 3 + 2] = rgba[i * 4 + 2];
  }
  return rgb;
}

/// 桌面参考图模式同款端到口（service.py `_process_reference` 的 Dart 镜像）：
/// 模型语义色 [autoRgb]（engine.colorize 产物）⊕ 参考图迁移色（
/// [transferReference]，[method]/[strength] 与桌面端选项同语义）在 Lab a/b
/// 上 5:5 融合，L 恒取 [srcGray]（原稿灰度，[grayToLabL] 转 Lab L）。
/// 迁移与融合整个在一个工作 isolate 完成——闭包为顶层作用域，无 this 可捕
/// （unsendable 纪律同 v0.5.1 教训）。
Future<Uint8List> referenceColorizeInIsolate({
  required Uint8List srcRgb,
  required Uint8List refRgb,
  required Uint8List autoRgb,
  required Uint8List srcGray,
  ReferenceMethod method = ReferenceMethod.reinhard,
  double strength = 1.0,
}) {
  final pixels = srcRgb.length ~/ 3;
  return Isolate.run(() {
    final styled = transferReference(
      srcRgb: srcRgb,
      refRgb: refRgb,
      srcPixels: pixels,
      refPixels: refRgb.length ~/ 3,
      method: method,
      strength: strength,
    );
    return blendReferenceAuto(
      autoRgb: autoRgb,
      styledRgb: styled,
      srcLBytes: grayToLabL(srcGray),
      pixels: pixels,
    );
  });
}
