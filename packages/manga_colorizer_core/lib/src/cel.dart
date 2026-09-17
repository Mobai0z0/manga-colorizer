library;

import 'dart:typed_data';

import 'filters.dart';
import 'yuv.dart';

/// 赛璐璐分层输出: 把上色成图分解为可再编辑图层。
///
/// 日式赛璐璐工作流: 底色(flat) → 阴影(shadow) → 高光(highlight) → 线稿(line)。
/// 分解规则 (确定性, 可复现):
/// - 线稿层: 原稿亮度 ≤ [inkThreshold] 的像素 (墨线原样保留, 全暗);
/// - 阴影层: 相对背景场 (原稿亮度的盒式模糊) 变暗超过 [shadowDelta] 的像素;
/// - 高光层: 相对背景场变亮超过 [highlightDelta] 的像素;
/// - 底色层: 其余像素 (成图原样)。
/// 各层为带 Alpha 的 RGBA: 底色层不透明, 阴影/高光/线稿层只在选中像素处不透明,
/// 叠加顺序 底色→阴影→高光→线稿 可还原近似成图 (线稿层 100% 覆盖墨线)。

/// 分层参数。
class CelLayerOptions {
  final double inkThreshold;
  final double shadowDelta;
  final double highlightDelta;
  final int blurRadius;

  const CelLayerOptions({
    this.inkThreshold = 0.45,
    this.shadowDelta = 0.06,
    this.highlightDelta = 0.06,
    this.blurRadius = 6,
  });
}

/// 四层 RGBA 输出。
class CelLayers {
  final int width;
  final int height;

  /// 每层均为 RGBA (4 通道)。
  final Uint8List flat;
  final Uint8List shadow;
  final Uint8List highlight;
  final Uint8List line;

  const CelLayers(this.width, this.height, this.flat, this.shadow,
      this.highlight, this.line);
}

/// 把成图 [coloredRgb] 按原稿亮度场分解为赛璐璐四层。
CelLayers decomposeCelLayers(
    Uint8List coloredRgb, Uint8List grayscaleRgb, int width, int height,
    {CelLayerOptions options = const CelLayerOptions()}) {
  final n = width * height;
  if (coloredRgb.length != n * 3 || grayscaleRgb.length != n * 3) {
    throw ArgumentError('像素数组长度与尺寸不匹配');
  }
  // 背景场: 原稿亮度的盒式模糊。
  final lum = Float32List(n);
  for (var i = 0; i < n; i++) {
    lum[i] = luminanceOfRgb(
        grayscaleRgb[i * 3], grayscaleRgb[i * 3 + 1], grayscaleRgb[i * 3 + 2]);
  }
  final background = boxBlur(lum, width, height, options.blurRadius);

  Uint8List mkLayer() => Uint8List(n * 4);

  final flat = mkLayer();
  final shadow = mkLayer();
  final highlight = mkLayer();
  final line = mkLayer();

  // 全层底: 先都填不透明底色 (flat 全图, 其余层默认透明)。
  for (var i = 0; i < n; i++) {
    flat[i * 4] = coloredRgb[i * 3];
    flat[i * 4 + 1] = coloredRgb[i * 3 + 1];
    flat[i * 4 + 2] = coloredRgb[i * 3 + 2];
    flat[i * 4 + 3] = 255;
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      final y0 = lum[i];
      final bg = background[i];
      final d = y0 - bg; // 正=比背景亮(高光倾向), 负=比背景暗(阴影倾向)。

      void put(Uint8List layer, int r, int g, int b) {
        layer[i * 4] = r;
        layer[i * 4 + 1] = g;
        layer[i * 4 + 2] = b;
        layer[i * 4 + 3] = 255;
      }

      if (y0 <= options.inkThreshold) {
        // 线稿层: 墨线用成图像素 (保留色线能力) 或原墨色。
        put(line, coloredRgb[i * 3], coloredRgb[i * 3 + 1],
            coloredRgb[i * 3 + 2]);
      } else if (d <= -options.shadowDelta) {
        put(shadow, coloredRgb[i * 3], coloredRgb[i * 3 + 1],
            coloredRgb[i * 3 + 2]);
      } else if (d >= options.highlightDelta) {
        put(highlight, coloredRgb[i * 3], coloredRgb[i * 3 + 1],
            coloredRgb[i * 3 + 2]);
      }
    }
  }
  return CelLayers(width, height, flat, shadow, highlight, line);
}
