import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:test/test.dart';

void main() {
  group('YUV 转换', () {
    test('中性灰往返保持无色度', () {
      for (final v in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final (y, u, vChroma) = rgbToYuv(v, v, v);
        expect(y, closeTo(v, 1e-9));
        expect(u, closeTo(0, 1e-9));
        expect(vChroma, closeTo(0, 1e-9));
        final (r, g, b) = yuvToRgb(y, u, vChroma);
        expect(r, closeTo(v, 1e-9));
        expect(g, closeTo(v, 1e-9));
        expect(b, closeTo(v, 1e-9));
      }
    });

    test('纯红转换与往返近似还原', () {
      final (y, u, v) = rgbToYuv(1.0, 0.0, 0.0);
      expect(y, closeTo(0.299, 1e-9));
      final (r, g, b) = yuvToRgb(y, u, v);
      expect(r, closeTo(1.0, 1e-6));
      expect(g, closeTo(0.0, 1e-6));
      expect(b, closeTo(0.0, 1e-6));
    });

    test('yuvToRgb 对非法色度仍截断到 [0,1]', () {
      final (r, g, b) = yuvToRgb(0.5, -0.6, 0.6);
      for (final c in [r, g, b]) {
        expect(c, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('ChromaSolver', () {
    // 8x8 图: 上半 亮 (245),下半 暗 (30)。
    final lum = Float32List(8 * 8);
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        lum[y * 8 + x] = y < 4 ? 0.96 : 0.12;
      }
    }

    test('无提示点时全场保持中性', () {
      final solver = ChromaSolver(width: 8, height: 8, luminance: lum);
      final solution = solver.solve(maxIterations: 50);
      for (final value in solution.u) {
        expect(value, closeTo(0, 1e-6));
      }
      for (final value in solution.v) {
        expect(value, closeTo(0, 1e-6));
      }
      expect(solver.hintCount, 0);
    });

    test('提示点色度扩散到同亮度区域且不跨强边界', () {
      final solver = ChromaSolver(width: 8, height: 8, luminance: lum);
      solver.addRgbHint(1, 1, 255, 0, 0); // 亮区 → 红
      expect(solver.hintCount, 1);
      final solution = solver.solve(maxIterations: 400);
      final (yu, uu, vu) = rgbToYuv(1.0, 0.0, 0.0);
      // 亮区远端也被染红 (V 接近提示色的 V≈0.5)。
      final farIndex = 3 * 8 + 6; // y=3 亮区
      expect(solution.v[farIndex], greaterThan(0.3));
      // U 通道接近提示色的 U≈-0.169 (红色的蓝黄色轴偏蓝)。
      expect(solution.u[farIndex], closeTo(uu, 0.1));
      // 暗区几乎不被染色 (强亮度边界阻断扩散)。
      final darkIndex = 6 * 8 + 6; // y=6 暗区
      expect(solution.v[darkIndex], lessThan(0.05));
    });

    test('坐标越界抛 ArgumentError', () {
      final solver = ChromaSolver(width: 8, height: 8, luminance: lum);
      expect(() => solver.addRgbHint(8, 0, 0, 0, 0), throwsArgumentError);
      expect(() => solver.addRgbHint(-1, 0, 0, 0, 0), throwsArgumentError);
      expect(() => solver.addRgbHint(0, 8, 0, 0, 0), throwsArgumentError);
    });

    test('非法参数抛 ArgumentError', () {
      expect(
          () => ChromaSolver(width: 8, height: 8, luminance: lum, sigma: 0),
          throwsArgumentError);
      expect(
          () => ChromaSolver(
              width: 8, height: 8, luminance: lum, epsilon: -0.1),
          throwsArgumentError);
      final solver = ChromaSolver(width: 8, height: 8, luminance: lum);
      expect(() => solver.solve(sorOmega: 2.0), throwsArgumentError);
      expect(() => solver.solve(maxIterations: 0), throwsArgumentError);
    });

    test('luminance 长度不匹配抛 ArgumentError', () {
      expect(
          () => ChromaSolver(
              width: 8, height: 8, luminance: Float32List(8 * 8 - 1)),
          throwsArgumentError);
    });

    test('锁定中性像素不传播色度', () {
      final solver = ChromaSolver(width: 8, height: 8, luminance: lum);
      solver.addRgbHint(1, 1, 255, 0, 0);
      // 锁定暗区某个像素 (亮度 0.12 不在默认锁定阈值内,手动锁)。
      final darkIndex = 6 * 8 + 6;
      solver.lockNeutral(darkIndex);
      expect(solver.isFixedAt(darkIndex), isTrue);
      expect(solver.lockedMonochromeCount, 1);
      final solution = solver.solve(maxIterations: 400);
      expect(solution.u[darkIndex], 0);
      expect(solution.v[darkIndex], 0);
    });
  });

  group('colorizeManga', () {
    test('默认锁定纯黑白: 黑色保持黑色,白色保持白色', () {
      // 4x1: 黑 灰 白 灰。
      final rgb = Uint8List.fromList(
          [0, 0, 0, 128, 128, 128, 255, 255, 255, 128, 128, 128]);
      final result = colorizeManga(
        grayscaleRgb: rgb,
        width: 4,
        height: 1,
        hints: const [ColorHint(x: 1, y: 0, r: 200, g: 30, b: 30)],
      );
      // 黑色像素保持黑色。
      expect(result.rgb[0], lessThan(10));
      expect(result.rgb[1], lessThan(10));
      expect(result.rgb[2], lessThan(10));
      // 白色像素保持白色。
      expect(result.rgb[6], greaterThan(245));
      // 灰色像素被染红 (r 明显大于 g/b)。
      expect(result.rgb[3], greaterThan(160));
      expect(result.rgb[4], lessThan(120));
      expect(result.lockedMonochromeCount, 2);
      expect(result.hintCount, 1);
    });

    test('无提示点且不锁定时输出中性灰', () {
      final rgb = Uint8List.fromList([100, 100, 100, 150, 150, 150]);
      final result = colorizeManga(
        grayscaleRgb: rgb,
        width: 2,
        height: 1,
        options: const ColorizeOptions(lockPureMonochrome: false),
      );
      for (var i = 0; i < 6; i++) {
        expect(result.rgb[i], closeTo(rgb[i], 1));
      }
    });

    test('grayscaleRgb 长度不匹配抛 ArgumentError', () {
      expect(
          () => colorizeManga(
              grayscaleRgb: Uint8List.fromList([1, 2, 3]),
              width: 2,
              height: 1),
          throwsArgumentError);
    });

    test('adaptHintChromaToLuminance 默认开启且能染中亮度区域', () {
      // 6x1 全部亮度 128,暗棕提示色 (40,25,15) 自身色度幅值极小:
      // 不适配时染出来接近灰,适配后按亮度比例放大为可见暖棕。
      final rgb = Uint8List.fromList(List.filled(18, 128));
      final hint = const ColorHint(x: 2, y: 0, r: 40, g: 25, b: 15);
      final withoutAdapt = colorizeManga(
        grayscaleRgb: rgb,
        width: 6,
        height: 1,
        hints: [hint],
        options: const ColorizeOptions(
            lockPureMonochrome: false, adaptHintChromaToLuminance: false),
      );
      final withAdapt = colorizeManga(
        grayscaleRgb: rgb,
        width: 6,
        height: 1,
        hints: [hint],
        options: const ColorizeOptions(
            lockPureMonochrome: false, adaptHintChromaToLuminance: true),
      );
      double chroma(Uint8List px, int i) {
        final (_, u, v) = rgbToYuv(
            px[i * 3] / 255, px[i * 3 + 1] / 255, px[i * 3 + 2] / 255);
        return u.abs() + v.abs();
      }
      // 适配后远端像素色度明显更强 (scale = 128/255 / 0.111 ≈ 4.5)。
      expect(chroma(withAdapt.rgb, 5), greaterThan(chroma(withoutAdapt.rgb, 5) * 2));
      expect(chroma(withAdapt.rgb, 5), greaterThan(0.1));
    });

    test('options.fromJson 支持部分字段 (缺省 maxIterations 用默认值)', () {
      final partial = ColorizeOptions.fromJson({'sigma': 0.05});
      expect(partial.sigma, 0.05);
      expect(partial.maxIterations, const ColorizeOptions().maxIterations);
      final empty = ColorizeOptions.fromJson({});
      expect(empty.maxIterations, 300);
      expect(
          () => ColorizeOptions.fromJson({'maxIterations': 0}),
          throwsFormatException);
    });

    test('options.fromJson 接受合法 JSON 并拒绝越界值', () {
      final options = ColorizeOptions.fromJson({
        'sigma': 0.05,
        'maxIterations': 500,
        'lockPureMonochrome': false,
      });
      expect(options.sigma, 0.05);
      expect(options.maxIterations, 500);
      expect(options.lockPureMonochrome, isFalse);
      expect(() => ColorizeOptions.fromJson({'sigma': 5.0}),
          throwsFormatException);
      expect(() => ColorizeOptions.fromJson({'sorOmega': 'x'}),
          throwsFormatException);
      expect(() => ColorizeOptions.fromJson([1, 2]), throwsFormatException);
    });

    test('ColorHint.fromJson 校验字段与范围', () {
      final hint = ColorHint.fromJson({'x': 3, 'y': 4, 'r': 255, 'g': 0, 'b': 0});
      expect(hint.x, 3);
      expect(hint.toJson(), {'x': 3, 'y': 4, 'r': 255, 'g': 0, 'b': 0});
      expect(() => ColorHint.fromJson({'x': 3.5, 'y': 4}),
          throwsFormatException);
      expect(() => ColorHint.fromJson({'x': -1, 'y': 4}),
          throwsFormatException);
      expect(() => ColorHint.fromJson({'x': 0, 'y': 0, 'r': 300}),
          throwsFormatException);
      expect(() => ColorHint.fromJson('nope'), throwsFormatException);
    });
  });

  group('applyTint', () {
    test('sepia 预设改变色调并保持明暗结构', () {
      // 2x1: 暗 (30) / 亮 (220)。
      final rgb = Uint8List.fromList([30, 30, 30, 220, 220, 220]);
      final out = applyTint(
        grayscaleRgb: rgb,
        width: 2,
        height: 1,
        palette: kTintPresets['sepia']!,
        options: const TintOptions(protectPaper: false),
      );
      // 暗部: 棕色 (r > b)。
      final darkR = out[0], darkB = out[2];
      expect(darkR, greaterThan(darkB));
      // 亮部: 米白 (接近白,轻微暖)。
      final brightR = out[3], brightB = out[5];
      expect(brightR, greaterThan(200));
      expect(brightB, greaterThan(150));
      // 明暗结构保持: 亮部各通道仍大于暗部对应通道。
      expect(out[3], greaterThan(darkR));
      expect(out[5], greaterThan(darkB));
    });

    test('paper 保护阈值内的像素保持原样', () {
      final rgb = Uint8List.fromList([250, 250, 250, 30, 30, 30]);
      final out = applyTint(
        grayscaleRgb: rgb,
        width: 2,
        height: 1,
        palette: kTintPresets['sepia']!,
      );
      expect(out[0], 250);
      expect(out[1], 250);
      expect(out[2], 250);
      // 暗部被染色。
      expect(out[3], greaterThan(30));
    });

    test('strength=0 输出与输入一致', () {
      final rgb = Uint8List.fromList([30, 30, 30, 200, 200, 200]);
      final out = applyTint(
        grayscaleRgb: rgb,
        width: 2,
        height: 1,
        palette: kTintPresets['moonlit']!,
        options: const TintOptions(strength: 0, protectPaper: false),
      );
      expect(out, rgb);
    });

    test('非法调色板与选项抛错', () {
      final rgb = Uint8List.fromList([30, 30, 30]);
      expect(
          () => applyTint(
              grayscaleRgb: rgb, width: 1, height: 1, palette: const []),
          throwsArgumentError);
      expect(
          () => applyTint(
              grayscaleRgb: rgb,
              width: 2,
              height: 1,
              palette: kTintPresets['sepia']!),
          throwsArgumentError);
      expect(
          () => TintOptions.fromJson({'strength': 2.0}),
          throwsFormatException);
      expect(
          () => TintStop.fromJson({'luminance': -1, 'r': 0, 'g': 0, 'b': 0}),
          throwsFormatException);
    });
  });

  group('TintStop / 预设', () {
    test('内置预设齐全且锚点合法', () {
      expect(kTintPresets.keys, containsAll(['sepia', 'warm-dawn', 'moonlit']));
      for (final palette in kTintPresets.values) {
        for (final stop in palette) {
          expect(stop.luminance, inInclusiveRange(0, 255));
          expect(stop.r, inInclusiveRange(0, 255));
          expect(stop.g, inInclusiveRange(0, 255));
          expect(stop.b, inInclusiveRange(0, 255));
        }
      }
    });
  });
}
