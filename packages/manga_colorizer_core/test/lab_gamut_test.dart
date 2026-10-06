import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:test/test.dart';

/// labToRgbGamut 行为测试 + 跨语言金样。
///
/// 金样（test/goldens/gamut_golden.json）由桌面
/// tool/colorizer_service/gen_gamut_golden.py 用 service._finish_bgr
/// （numpy/float32，OpenCV 惯例输出 **BGR**）生成：rgb 路为色域内原色
/// （含边界量化噪声），grid 路为 L/a/b 全随机（大量真超域）。Dart 端输出
/// RGB，对比时按 [2,1,0] 反转桌面通道。容差 ±1 = float32/float64 舍入
/// 边界，超出即两端数学失步——先查 lab.dart 与 service.py 是否只改了一头。
void main() {
  test('in-gamut pixels are bit-identical to labToRgb', () {
    // 远离色域边界的柔和色（8bit 往返不触发出域收缩路径）
    final lab = Uint8List(8 * 3);
    final ls = [64, 128, 191, 217];
    final ab = [
      [142, 118], // 柔和红
      [118, 138], // 柔和绿
      [120, 150], // 柔和黄
      [128, 128], // 纯中性
    ];
    for (var i = 0; i < 4; i++) {
      lab[i * 3] = ls[i];
      lab[i * 3 + 1] = ab[i][0];
      lab[i * 3 + 2] = ab[i][1];
      lab[(i + 4) * 3] = ls[i];
      lab[(i + 4) * 3 + 1] = ab[i][0];
      lab[(i + 4) * 3 + 2] = ab[i][1];
    }
    final viaGamut = labToRgbGamut(Uint8List.fromList(lab), 8);
    final plain = labToRgb(Uint8List.fromList(lab), 8);
    for (var i = 0; i < plain.length; i++) {
      expect(viaGamut[i], plain[i], reason: 'pixel $i ch ${i % 3}');
    }
  });

  test('out-of-gamut chroma keeps hue instead of clipping toward primaries', () {
    // 暗部蓝紫 (L≈30, hue≈250°, 高色度): 旧截断会把通道拉到 0/1、色相大偏
    final lab = Uint8List.fromList(
        [77, 128 - 30, 128 - 56]); // a=-30 b=-56 → hue≈242°
    final mapped = labToRgbGamut(lab, 1);
    final clipped = labToRgb(lab, 1);
    final labMapped = rgbToLab(mapped, 1);
    final labClipped = rgbToLab(clipped, 1);
    double hue(List<int> p) =>
        math.atan2(p[2] - 128.0, p[1] - 128.0) * 180.0 / math.pi;
    double hueErr(double a, double b) {
      final d = (a - b).abs() % 360.0;
      return d > 180.0 ? 360.0 - d : d;
    }

    final inHue = hue([0, 128 - 30, 128 - 56]);
    final errMapped = hueErr(hue(labMapped), inHue);
    final errClipped = hueErr(hue(labClipped), inHue);
    expect(errMapped, lessThan(errClipped),
        reason: '色域映射的色相保持必须优于逐通道截断 '
            '(mapped=$errMapped° clipped=$errClipped°)');
    // 亮度严格保持（映射前后 L 差 ≤1.5, 8bit 量化容差）
    expect((labMapped[0] - lab[0]).abs(), lessThanOrEqualTo(1),
        reason: 'L mapped=${labMapped[0]} in=${lab[0]}');
  });

  test('pure black stays black regardless of chroma', () {
    // L=0 + 强红: 旧逐通道截断输出 ~RGB(103,0,0)（黑被提亮成彩黑）
    final lab = Uint8List.fromList([0, 128 + 80, 128 + 30]);
    final out = labToRgbGamut(lab, 1);
    for (final v in out) {
      expect(v, lessThanOrEqualTo(2), reason: 'BGR=${out.toList()}');
    }
  });

  test('chromaGain boosts measurable chroma of muted colors', () {
    // L≈60 的柔和肤色类: a=163(35), b=148(20)
    final lab = Uint8List.fromList([153, 163, 148]);
    final base = rgbToLab(labToRgbGamut(lab, 1, chromaGain: 1.0), 1);
    final boosted = rgbToLab(labToRgbGamut(lab, 1, chromaGain: 1.2), 1);
    double chroma(List<int> p) {
      final a = p[1] - 128.0, b = p[2] - 128.0;
      return math.sqrt(a * a + b * b);
    }

    expect(chroma(boosted), greaterThan(chroma(base)));
  });

  test('neutral pixels stay neutral under gain', () {
    final lab = Uint8List.fromList([51, 128, 128, 153, 128, 128, 230, 128, 128]);
    final out = labToRgbGamut(lab, 3, chromaGain: 1.2);
    for (var p = 0; p < 3; p++) {
      final r = out[p * 3], g = out[p * 3 + 1], b = out[p * 3 + 2];
      final spread = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      expect(spread, lessThanOrEqualTo(1),
          reason: 'neutral pixel $p RGB=[$r,$g,$b]');
    }
  });

  final golden = jsonDecode(
          File('test/goldens/gamut_golden.json').readAsStringSync())
      as Map<String, dynamic>;
  for (final entry in golden.entries) {
    final gain = double.parse(entry.key.split('_').last);
    final block = entry.value as Map<String, dynamic>;
    final l = (block['l'] as List).cast<int>();
    final ab = (block['ab'] as List)
        .map<List<double>>((e) =>
            (e as List).map<double>((v) => (v as num).toDouble()).toList())
        .toList();
    final bgr = (block['bgr'] as List)
        .map<List<int>>((e) => (e as List).cast<int>())
        .toList();
    final n = l.length;
    final lab = Uint8List(n * 3);
    for (var i = 0; i < n; i++) {
      lab[i * 3] = l[i];
      lab[i * 3 + 1] = ab[i][0].round().clamp(0, 255);
      lab[i * 3 + 2] = ab[i][1].round().clamp(0, 255);
    }
    test('gamut golden ${entry.key} matches desktop _finish_bgr ±1', () {
      final got = labToRgbGamut(lab, n, chromaGain: gain);
      var worst = 0;
      String? at;
      for (var i = 0; i < n * 3; i++) {
        // 桌面金样是 BGR，Dart 输出 RGB：反转通道序后对比
        final diff = (got[i] - bgr[i ~/ 3][2 - i % 3]).abs();
        if (diff > worst) {
          worst = diff;
          at = 'px${i ~/ 3} ch${i % 3} got=${got[i]} want=${bgr[i ~/ 3][2 - i % 3]}';
        }
      }
      expect(worst, lessThanOrEqualTo(1), reason: at);
    });
  }
}
