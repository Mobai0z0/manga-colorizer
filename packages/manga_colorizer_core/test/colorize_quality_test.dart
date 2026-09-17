import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:test/test.dart';

void main() {
  test('closed white region accepts a color hint instead of staying white', () {
    // 5x5: black outline enclosing a 3x3 white region.
    final input = Uint8List(5 * 5 * 3);
    for (var y = 1; y < 4; y++) {
      for (var x = 1; x < 4; x++) {
        input.fillRange((y * 5 + x) * 3, (y * 5 + x) * 3 + 3, 255);
      }
    }
    final result = colorizeManga(
      grayscaleRgb: input,
      width: 5,
      height: 5,
      hints: const [ColorHint(x: 2, y: 2, r: 220, g: 140, b: 90)],
    );
    for (final pixel in [6, 12, 18]) {
      expect(result.rgb.sublist(pixel * 3, pixel * 3 + 3), [220, 140, 90]);
    }
    expect(result.rgb.sublist(0, 3), [0, 0, 0]);
  });

  test('hint ownership uses source luminance and preserves the seed color', () {
    // Both source regions have the same brightness. A green hint's own
    // brightness must not make it override the red seed at x=1.
    final input = Uint8List(9 * 3)..fillRange(0, 27, 128);
    const hints = [
      ColorHint(x: 1, y: 0, r: 255, g: 0, b: 0),
      ColorHint(x: 7, y: 0, r: 0, g: 255, b: 0),
    ];
    ColorizeResult run(bool correct) => colorizeManga(
          grayscaleRgb: input,
          width: 9,
          height: 1,
          hints: hints,
          options: ColorizeOptions(
            regionChromaCorrection: correct,
            hueCorrectionStrength: 1,
            regionLuminanceWeight: 100,
          ),
        );
    final original = run(false);
    final corrected = run(true);
    expect(corrected.rgb.sublist(3, 6), original.rgb.sublist(3, 6));
    expect(corrected.rgb[2 * 3], greaterThan(corrected.rgb[2 * 3 + 1]));
  });

  test('tiled colorize with white fill matches whole-image result', () {
    // 一个 300x8 的长条,白区框横跨多块 128px tile,提示点在 x=80。
    const w = 300, h = 8;
    final input = Uint8List(w * h * 3)..fillRange(0, w * h * 3, 255);
    for (var y = 2; y <= 5; y++) {
      for (var x = 2; x <= 297; x++) {
        if (y == 2 || y == 5 || x == 2 || x == 93) {
          input.fillRange((y * w + x) * 3, (y * w + x) * 3 + 3, 0);
        }
      }
    }
    const hints = [ColorHint(x: 80, y: 3, r: 220, g: 140, b: 90)];
    final whole = colorizeManga(
        grayscaleRgb: input, width: w, height: h, hints: hints);
    final tiled = colorizeMangaTiled(
        grayscaleRgb: input, width: w, height: h, hints: hints,
        tileSize: 128, overlap: 32);
    expect(tiled.tileCount, greaterThan(1));
    expect(tiled.rgb, whole.rgb);
  });

  test('open white region (outline broken to border) stays paper', () {
    // 6x6: 三面黑框、底部开口,内部白区与贴边纸白连通 → 即使有提示也不填色。
    const w = 6, h = 6;
    final input = Uint8List(w * h * 3)..fillRange(0, w * h * 3, 255);
    void ink(int x, int y) =>
        input.fillRange((y * w + x) * 3, (y * w + x) * 3 + 3, 0);
    for (var x = 1; x <= 4; x++) {
      ink(x, 1);
    }
    for (var y = 1; y <= 4; y++) {
      ink(1, y);
      ink(4, y);
    }
    final result = colorizeManga(
      grayscaleRgb: input,
      width: w,
      height: h,
      hints: const [ColorHint(x: 2, y: 2, r: 220, g: 140, b: 90)],
    );
    expect(result.rgb.sublist((2 * w + 2) * 3, (2 * w + 2) * 3 + 3),
        [255, 255, 255]);
    expect(result.rgb.sublist((3 * w + 3) * 3, (3 * w + 3) * 3 + 3),
        [255, 255, 255]);
  });
}
