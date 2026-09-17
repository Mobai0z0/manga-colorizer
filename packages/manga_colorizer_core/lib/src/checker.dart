import 'dart:math' as math;
import 'dart:typed_data';

import 'palette.dart';
import 'skin.dart';
import 'yuv.dart';

/// 单个部位的校验结果。
class PartCheck {
  final String role;
  final String name;
  final int targetR;
  final int targetG;
  final int targetB;
  final int sampledR;
  final int sampledG;
  final int sampledB;
  final double hueDeltaDeg;
  final double luminanceDelta;
  final bool pass;

  const PartCheck(
      this.role,
      this.name,
      this.targetR,
      this.targetG,
      this.targetB,
      this.sampledR,
      this.sampledG,
      this.sampledB,
      this.hueDeltaDeg,
      this.luminanceDelta,
      this.pass);

  Map<String, Object> toJson() => {
        'role': role,
        'name': name,
        'target': toHexColor(targetR, targetG, targetB),
        'sampled': toHexColor(sampledR, sampledG, sampledB),
        'hueDeltaDeg': double.parse(hueDeltaDeg.toStringAsFixed(1)),
        'luminanceDelta': double.parse(luminanceDelta.toStringAsFixed(3)),
        'pass': pass,
      };
}

/// 整张成图的校验报告。
class PaletteCheckReport {
  final String characterId;
  final List<PartCheck> parts;
  final List<String> failures;

  const PaletteCheckReport(this.characterId, this.parts, this.failures);

  bool get pass => failures.isEmpty;

  Map<String, Object> toJson() => {
        'characterId': characterId,
        'pass': pass,
        'failures': failures,
        'parts': [for (final p in parts) p.toJson()],
      };
}

double _hueDeg(int r, int g, int b) {
  final y = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  final u = (b / 255 - y) / 1.772;
  final v = (r / 255 - y) / 1.402;
  final deg = math.atan2(v, -u) * 180 / math.pi;
  return deg < 0 ? deg + 360 : deg;
}

double _lum(int r, int g, int b) =>
    (0.299 * r + 0.587 * g + 0.114 * b) / 255;

double _angularDelta(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// 校验上色成图: 在 [samplePoints] 指定的部位取样点 (每部位可多点) 处
/// 取 5×5 中值色,与 [palette] 对应部位色板比对。
///
/// 判定:
/// - 色相: 取样色 vs 色板色,差 ≤ [hueToleranceDeg] (严格,一致性核心);
/// - 亮度: 提供 [expectedLumaAt] 时对照原稿亮度 (亮度保留策略下,
///   成图亮度随线稿/环境光变化属预期,见 Goal 语义);未提供时对照色板亮度;
/// - role=skin 的部位额外检查自然肤色扇区 ([isNaturalSkinRgb])。
PaletteCheckReport checkImageAgainstPalette({
  required Uint8List rgb,
  required int width,
  required int height,
  required CharacterPalette palette,
  required Map<String, List<(int, int)>> samplePoints,
  double hueToleranceDeg = 8.0,
  double luminanceTolerance = 0.06,
  double Function(int x, int y)? expectedLumaAt,
}) {
  if (rgb.length != width * height * 3) {
    throw ArgumentError('rgb 长度与图像尺寸不匹配');
  }
  int channelMedian(List<int> values) {
    values.sort();
    return values[values.length ~/ 2];
  }

  int sampleChannel(int x, int y, int c) {
    final values = <int>[];
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final sx = (x + dx).clamp(0, width - 1);
        final sy = (y + dy).clamp(0, height - 1);
        values.add(rgb[(sy * width + sx) * 3 + c]);
      }
    }
    return channelMedian(values);
  }

  (int, int, int) sample(int x, int y) => (
        sampleChannel(x, y, 0),
        sampleChannel(x, y, 1),
        sampleChannel(x, y, 2),
      );

  final checks = <PartCheck>[];
  final failures = <String>[];
  for (final part in palette.parts) {
    final points = samplePoints[part.role];
    if (points == null || points.isEmpty) continue;
    for (final (x, y) in points) {
      if (x < 0 || x >= width || y < 0 || y >= height) {
        failures.add('部位 ${part.role}: 取样点 ($x,$y) 超出图像');
        continue;
      }
      final (sr, sg, sb) = sample(x, y);
      final hueDelta =
          _angularDelta(_hueDeg(sr, sg, sb), _hueDeg(part.r, part.g, part.b));
      final expectedLum =
          expectedLumaAt != null ? expectedLumaAt(x, y) : _lum(part.r, part.g, part.b);
      final lumDelta = (_lum(sr, sg, sb) - expectedLum).abs();
      var ok = hueDelta <= hueToleranceDeg && lumDelta <= luminanceTolerance;
      var extra = '';
      if (part.role == 'skin') {
        final natural = isNaturalSkinRgb(sr, sg, sb);
        if (!natural) {
          extra = ' 且肤色超出自然扇区';
          ok = false;
        }
      }
      checks.add(PartCheck(part.role, part.name, part.r, part.g, part.b, sr,
          sg, sb, hueDelta, lumDelta, ok));
      if (!ok) {
        failures.add(
            '${part.name}(${part.role}) 取样${toHexColor(sr, sg, sb)} vs 色板${toHexColor(part.r, part.g, part.b)} '
            '色相差 ${hueDelta.toStringAsFixed(1)}° 亮度差 ${lumDelta.toStringAsFixed(3)}$extra');
      }
    }
  }
  if (checks.isEmpty && failures.isEmpty) {
    failures.add('没有可校验的取样点 (samplePoints 为空或 role 不匹配)');
  }
  return PaletteCheckReport(palette.characterId, checks, failures);
}

/// 从色板条目推导用于约束求解的目标色度 (skin 部位钳进自然扇区)。
(double, double) paletteTargetChroma(PalettePart part) {
  final (y, u, v) = rgbToYuv(part.r / 255, part.g / 255, part.b / 255);
  if (part.role == 'skin') {
    return enforceNaturalSkin(u, v);
  }
  return (u, v);
}
