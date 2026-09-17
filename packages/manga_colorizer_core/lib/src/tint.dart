import 'dart:typed_data';

import 'yuv.dart';

/// 渐变映射锚点: 亮度位置 [luminance] (0..255) + 目标颜色。
class TintStop {
  final int luminance;
  final int r;
  final int g;
  final int b;

  const TintStop(this.luminance, this.r, this.g, this.b);

  factory TintStop.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('palette stop 必须是 '
          '{"luminance","r","g","b"}');
    }
    return TintStop(
      _readInt(json, 'luminance', 0, 255),
      _readInt(json, 'r', 0, 255),
      _readInt(json, 'g', 0, 255),
      _readInt(json, 'b', 0, 255),
    );
  }
}

int _readInt(Map json, String key, int min, int max) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('$key 必须是整数,实际为 $value');
  }
  if (value < min || value > max) {
    throw FormatException('$key=$value 超出允许范围 [$min, $max]');
  }
  return value;
}

/// 色调映射参数。
class TintOptions {
  /// 与原图灰度的混合比例,0 = 不上色,1 = 完全映射。
  final double strength;

  /// 保护近纸白区域不被染色。
  final bool protectPaper;

  /// 纸白保护阈值 (亮度 ≥ 该值保持原样)。
  final int paperThreshold;

  const TintOptions({
    this.strength = 1.0,
    this.protectPaper = true,
    this.paperThreshold = 245,
  });

  factory TintOptions.fromJson(Object? json) {
    if (json == null) return const TintOptions();
    if (json is! Map) throw const FormatException('options 必须是对象');
    const defaults = TintOptions();
    final strength = json['strength'];
    if (strength != null && (strength is! num || strength < 0 || strength > 1)) {
      throw const FormatException('options.strength 必须在 [0,1] 区间');
    }
    final paperThreshold = json['paperThreshold'];
    if (paperThreshold != null &&
        (paperThreshold is! int || paperThreshold < 0 || paperThreshold > 255)) {
      throw const FormatException('options.paperThreshold 必须是 0..255 整数');
    }
    return TintOptions(
      strength: (strength as num?)?.toDouble() ?? defaults.strength,
      protectPaper: (json['protectPaper'] as bool?) ?? defaults.protectPaper,
      paperThreshold: paperThreshold as int? ?? defaults.paperThreshold,
    );
  }
}

/// 亮度-调色板渐变映射 (gradient map) 上色。
///
/// 为每个亮度值预先建立映射 LUT: 目标色按其自身亮度缩放到输入亮度,
/// 保持画面明暗结构不变,只改变色调。调色板按亮度排序后分段线性插值。
Uint8List applyTint({
  required Uint8List grayscaleRgb,
  required int width,
  required int height,
  required List<TintStop> palette,
  TintOptions options = const TintOptions(),
}) {
  final pixelCount = width * height;
  if (grayscaleRgb.length != pixelCount * 3) {
    throw ArgumentError(
        'grayscaleRgb 长度 (${grayscaleRgb.length}) 与 ${width}x$height 不匹配');
  }
  if (palette.isEmpty) {
    throw ArgumentError('palette 至少需要 1 个锚点');
  }
  final strength = options.strength.clamp(0.0, 1.0);

  // 1) 构造 256 级亮度 → RGB 的映射 LUT。
  final sorted = [...palette]..sort((a, b) => a.luminance.compareTo(b.luminance));
  final lutR = Uint8List(256);
  final lutG = Uint8List(256);
  final lutB = Uint8List(256);
  for (var l = 0; l < 256; l++) {
    // 找到覆盖 l 的调色板分段。
    var lo = sorted[0];
    var hi = sorted.last;
    if (l <= lo.luminance) {
      hi = lo;
    } else if (l >= hi.luminance) {
      lo = hi;
    } else {
      for (var s = 0; s < sorted.length - 1; s++) {
        if (l >= sorted[s].luminance && l <= sorted[s + 1].luminance) {
          lo = sorted[s];
          hi = sorted[s + 1];
          break;
        }
      }
    }
    final span = hi.luminance - lo.luminance;
    final t = span <= 0 ? 0.0 : (l - lo.luminance) / span;
    final r = lo.r + (hi.r - lo.r) * t;
    final g = lo.g + (hi.g - lo.g) * t;
    final b = lo.b + (hi.b - lo.b) * t;
    // 将插值色按输入亮度重新缩放,保持感知亮度 ≈ 输入亮度。
    final colorLuma = luminanceOfRgb(r.round(), g.round(), b.round());
    final scale = colorLuma > 1 / 255 ? l / 255 / colorLuma : 0.0;
    lutR[l] = (r * scale).round().clamp(0, 255);
    lutG[l] = (g * scale).round().clamp(0, 255);
    lutB[l] = (b * scale).round().clamp(0, 255);
  }

  // 2) 逐像素映射并与灰度原图按 strength 混合。
  final out = Uint8List(pixelCount * 3);
  for (var i = 0; i < pixelCount; i++) {
    final r0 = grayscaleRgb[i * 3];
    final g0 = grayscaleRgb[i * 3 + 1];
    final b0 = grayscaleRgb[i * 3 + 2];
    final y = (0.299 * r0 + 0.587 * g0 + 0.114 * b0).round().clamp(0, 255);
    if (options.protectPaper && y >= options.paperThreshold) {
      out[i * 3] = r0;
      out[i * 3 + 1] = g0;
      out[i * 3 + 2] = b0;
      continue;
    }
    out[i * 3] = (r0 + (lutR[y] - r0) * strength).round().clamp(0, 255);
    out[i * 3 + 1] = (g0 + (lutG[y] - g0) * strength).round().clamp(0, 255);
    out[i * 3 + 2] = (b0 + (lutB[y] - b0) * strength).round().clamp(0, 255);
  }
  return out;
}

/// 内置调色板预设。
const Map<String, List<TintStop>> kTintPresets = {
  'sepia': [
    TintStop(0, 30, 18, 10),
    TintStop(96, 122, 74, 42),
    TintStop(192, 205, 158, 106),
    TintStop(255, 248, 236, 214),
  ],
  'warm-dawn': [
    TintStop(0, 42, 26, 34),
    TintStop(90, 168, 84, 72),
    TintStop(190, 242, 168, 118),
    TintStop(255, 255, 232, 200),
  ],
  'moonlit': [
    TintStop(0, 12, 16, 34),
    TintStop(96, 52, 76, 118),
    TintStop(200, 138, 168, 208),
    TintStop(255, 226, 238, 252),
  ],
};
