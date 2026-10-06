// png_encode 的行为契约：RGBA/RGB → PNG 后经 core 的 decodeRgb 解码，
// 像素逐位还原（无损性）；尺寸不符时 ArgumentError；FlutterTester 上
// dart:ui 编解码器可用，纯本地无平台依赖。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

import 'package:manga_colorizer_mobile/png_encode.dart';

void main() {
  test('RGBA → PNG → 解码逐位还原', () async {
    const w = 33, h = 17; // 非整除尺寸防行列错位
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      rgba[i * 4] = (i * 7) % 256;
      rgba[i * 4 + 1] = (i * 13) % 256;
      rgba[i * 4 + 2] = (i * 29) % 256;
      rgba[i * 4 + 3] = 255;
    }
    final png = await encodePngFromRgba(rgba, w, h);
    final decoded = MangaImageIO.decodeRgb(png);
    expect(decoded.width, w);
    expect(decoded.height, h);
    for (var i = 0; i < w * h; i++) {
      expect(decoded.rgb[i * 3], rgba[i * 4], reason: '像素 $i R 不一致');
      expect(decoded.rgb[i * 3 + 1], rgba[i * 4 + 1], reason: '像素 $i G 不一致');
      expect(decoded.rgb[i * 3 + 2], rgba[i * 4 + 2], reason: '像素 $i B 不一致');
    }
  });

  test('RGB → PNG：填 alpha 编码，解码还原 RGB', () async {
    const w = 8, h = 8;
    final rgb = Uint8List(w * h * 3);
    rgb.fillRange(0, rgb.length, 200);
    final png = await encodePngFromRgb(rgb, w, h);
    final decoded = MangaImageIO.decodeRgb(png);
    expect(decoded.rgb, rgb);
  });

  test('缓冲长度不符抛 ArgumentError', () async {
    expect(() => encodePngFromRgba(Uint8List(7), 2, 2), throwsArgumentError);
    expect(() => encodePngFromRgb(Uint8List(7), 2, 2), throwsArgumentError);
  });
}
