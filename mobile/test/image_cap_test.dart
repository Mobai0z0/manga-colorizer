// capDecodeGrayscale 的行为契约：小图原样通过、超限长边缩到 kMaxPickSide、
// 纵横比保持。缩放走 image 包 average 插值（与管线 INTER_AREA 同族），
// 纯 Dart 无平台依赖，宿主测试直接覆盖。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

import 'package:manga_colorizer_mobile/image_cap.dart';

DecodedImage _solid(int width, int height) {
  final n = width * height;
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    rgb[i * 3] = 128;
    rgb[i * 3 + 1] = 64;
    rgb[i * 3 + 2] = 32;
  }
  return DecodedImage(width, height, rgb);
}

void main() {
  test('长边在上限内的小图原样通过，不触发缩放', () {
    final src = _solid(640, 480);
    final png = MangaImageIO.encodePng(
        rgb: src.rgb, width: src.width, height: src.height);
    final got = capDecodeGrayscale(png);
    expect(got.image.width, 640);
    expect(got.image.height, 480);
    expect(got.origWidth, isNull);
    expect(got.origHeight, isNull);
  });

  test('宽超限：长边缩到 2048，纵横比保持', () {
    final src = _solid(3200, 400);
    final png = MangaImageIO.encodePng(
        rgb: src.rgb, width: src.width, height: src.height);
    final got = capDecodeGrayscale(png);
    expect(got.origWidth, 3200);
    expect(got.origHeight, 400);
    expect(got.image.width, kMaxPickSide);
    expect(got.image.height, (400 * kMaxPickSide / 3200).round());
    // 输出缓冲必须与声明尺寸一致（防 fromBytes 视图/通道数错位）。
    expect(got.image.rgb.length, got.image.width * got.image.height * 3);
  });

  test('高超限（竖图）同样封顶', () {
    final src = _solid(300, 4000);
    final png = MangaImageIO.encodePng(
        rgb: src.rgb, width: src.width, height: src.height);
    final got = capDecodeGrayscale(png);
    expect(got.image.width, (300 * kMaxPickSide / 4000).round());
    expect(got.image.height, kMaxPickSide);
  });
}
