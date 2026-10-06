// image_cap 的行为契约：
//   · cappedTargetSize：小图 null、超限缩到上限、纵横比保持、边界取整；
//   · rgbaToGrayPlanes：亮度公式与 core 的 decodeGrayscale 逐位一致；
//   · capDecodeRgba（主 isolate，dart:ui 编解码器）：不放大、超限缩放、
//     返回尺寸与 RGBA 缓冲一致、原始尺寸如实上报。
// capDecodeRgba 在 flutter_test 的 FlutterTester 上有真实 PNG 编解码器，
// 测试用 core 的 encodePng 造输入，纯本地无平台依赖。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

import 'package:manga_colorizer_mobile/image_cap.dart';

/// 造一张纯色 PNG（r,g,b 逐像素同值），保证解码后任意位置像素可预期。
Uint8List _solidPng(int width, int height) {
  final n = width * height;
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    rgb[i * 3] = 128;
    rgb[i * 3 + 1] = 64;
    rgb[i * 3 + 2] = 32;
  }
  return MangaImageIO.encodePng(rgb: rgb, width: width, height: height);
}

void main() {
  group('cappedTargetSize', () {
    test('长边在上限内返回 null，不触发缩放', () {
      expect(cappedTargetSize(640, 480), isNull);
      expect(cappedTargetSize(2048, 2048), isNull);
    });

    test('宽超限：长边缩到 2048，纵横比保持', () {
      final (w, h) = cappedTargetSize(3200, 400)!;
      expect(w, kMaxPickSide);
      expect(h, (400 * kMaxPickSide / 3200).round());
    });

    test('高超限（竖图）同样封顶', () {
      final (w, h) = cappedTargetSize(300, 4000)!;
      expect(w, (300 * kMaxPickSide / 4000).round());
      expect(h, kMaxPickSide);
    });

    test('自定义上限同步生效（设备分级降档路径）', () {
      final (w, h) = cappedTargetSize(3000, 1500, maxSide: 1280)!;
      expect(w, 1280);
      expect(h, (1500 * 1280 / 3000).round());
    });

    test('结果钳制在 1..maxSide（极端长宽比不产生 0 维）', () {
      final (w, h) = cappedTargetSize(100000, 1)!;
      expect(w, kMaxPickSide);
      expect(h, greaterThanOrEqualTo(1));
    });
  });

  group('rgbaToGrayPlanes（与 core decodeGrayscale 公式逐位一致）', () {
    test('纯色像素：亮度取 0.299/0.587/0.114 加权四舍五入', () {
      // 红色：0.299*255 = 76.245 → 76；与 decodeGrayscale 对同色 RGB 逐位一致。
      final planes =
          rgbaToGrayPlanes(Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]));
      expect(planes.gray, [76, 150]);
      // 绿色：0.587*255 = 149.685 → 150。
      expect(planes.grayRgb,
          [76, 76, 76, 150, 150, 150]);
    });

    test('白/黑边界 clamp 正确，alpha 不参与加权', () {
      // 灰蓝 128,64,32：0.299*128 + 0.587*64 + 0.114*32 = 79.488 → 79。
      final planes = rgbaToGrayPlanes(Uint8List.fromList(
          [255, 255, 255, 0, 0, 0, 0, 0, 128, 64, 32, 77]));
      expect(planes.gray, [255, 0, 79]);
      expect(planes.grayRgb.length, 9);
    });

    test('缓冲长度：gray = n，grayRgb = 3n', () {
      final n = 4 * 3;
      final planes = rgbaToGrayPlanes(Uint8List(n * 4));
      expect(planes.gray.length, n);
      expect(planes.grayRgb.length, n * 3);
    });

    test('与 core decodeGrayscale 随机像素逐位对拍', () {
      final rng = math.Random(7);
      final w = 257, n = w; // 257×1
      final rgba = Uint8List(n * 4);
      final rgb = Uint8List(n * 3);
      for (var i = 0; i < n; i++) {
        rgba[i * 4] = rng.nextInt(256);
        rgba[i * 4 + 1] = rng.nextInt(256);
        rgba[i * 4 + 2] = rng.nextInt(256);
        rgba[i * 4 + 3] = 255;
        rgb[i * 3] = rgba[i * 4];
        rgb[i * 3 + 1] = rgba[i * 4 + 1];
        rgb[i * 3 + 2] = rgba[i * 4 + 2];
      }
      // decodeGrayscale 吃的是编码文件字节（PNG/JPEG），不是裸 RGB——
      // 先经 encodePng 无损落一枚 PNG 再喂给它，才是旧路径的真实对拍。
      final png = MangaImageIO.encodePng(rgb: rgb, width: w, height: 1);
      final expected = MangaImageIO.decodeGrayscale(png);
      final got = rgbaToGrayPlanes(rgba);
      // decodeGrayscale 把亮度写满三通道，对拍第 0 通道即可。
      for (var i = 0; i < n; i++) {
        expect(got.gray[i], expected.rgb[i * 3], reason: '像素 $i 亮度不一致');
      }
    });
  });

  group('capDecodeRgba（FlutterTester 真实编解码器）', () {
    test('小图原样解码：不缩放、尺寸与缓冲一致、orig 为 null', () async {
      final got = await capDecodeRgba(_solidPng(64, 48));
      expect(got.width, 64);
      expect(got.height, 48);
      expect(got.origWidth, isNull);
      expect(got.origHeight, isNull);
      expect(got.rgba.length, 64 * 48 * 4);
      expect(got.rgba[0], 128); // R
      expect(got.rgba[1], 64); // G
      expect(got.rgba[2], 32); // B
    });

    test('宽超限：主 isolate 直接解码到目标尺寸，绝不物化全分辨率位图', () async {
      final got = await capDecodeRgba(_solidPng(3200, 400));
      expect(got.origWidth, 3200);
      expect(got.origHeight, 400);
      expect(got.width, kMaxPickSide);
      expect(got.height, (400 * kMaxPickSide / 3200).round());
      expect(got.rgba.length, got.width * got.height * 4);
    });

    test('高超限（竖图）同样封顶', () async {
      final got = await capDecodeRgba(_solidPng(300, 4000));
      expect(got.width, (300 * kMaxPickSide / 4000).round());
      expect(got.height, kMaxPickSide);
    });

    test('自定义上限生效（设备分级降档路径）', () async {
      final got = await capDecodeRgba(_solidPng(3000, 1500), maxSide: 1280);
      expect(got.width, 1280);
      expect(got.height, (1500 * 1280 / 3000).round());
    });

    test('无法解码的字节抛 FormatException（对齐旧路径的错误语义）', () async {
      expect(() => capDecodeRgba(Uint8List.fromList([1, 2, 3, 4])),
          throwsFormatException);
    });
  });
}
