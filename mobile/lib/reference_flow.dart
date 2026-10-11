// 参考图调色的可测入口：把「RGBA→RGB」「isolate 内迁移」收敛在库层，
// AutoTab 只做编排。迁移是纯 Dart（manga_colorizer_core transferReference，
// 免模型秒出），Isolate.run 的闭包必须是 static/顶层——见 auto_panel.dart
// 同款纪律（v0.5.1 教训：实例作用域闭包经共享 context 捕 this 变 unsendable）。
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

/// 在工作 isolate 里跑参考图迁移（reinhard 全强度；桌面参考图模式另提供
/// method/strength 选项）。[srcRgb]/[refRgb] 均为行优先 RGB，按值复制进
/// isolate（2048² ≈ 12.6MB/张，两份瞬时占用可接受）。
Future<Uint8List> transferInIsolate({
  required Uint8List srcRgb,
  required Uint8List refRgb,
  required int width,
  ReferenceMethod method = ReferenceMethod.reinhard,
  double strength = 1.0,
}) {
  final h = srcRgb.length ~/ (width * 3);
  return Isolate.run(() {
    return transferReference(
      srcRgb: srcRgb,
      refRgb: refRgb,
      srcPixels: width * h,
      refPixels: refRgb.length ~/ 3,
      method: method,
      strength: strength,
    );
  });
}
