import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 解码后的 RGB 图像 (8bit 三通道交错)。
class DecodedImage {
  final int width;
  final int height;
  final Uint8List rgb;

  const DecodedImage(this.width, this.height, this.rgb);
}

/// 图像编解码门面 (PNG 输出;输入支持 PNG/JPEG/WebP/BMP/GIF)。
class MangaImageIO {
  /// 解码任意支持格式为 RGB。
  static DecodedImage decodeRgb(List<int> bytes) {
    final image = img.decodeImage(Uint8List.fromList(bytes));
    if (image == null) {
      throw const FormatException('无法解码图像,支持格式: PNG/JPEG/WebP/BMP/GIF');
    }
    return _toRgb(image);
  }

  /// 解码并转为灰度 (r=g=b=感知亮度),供上色管线使用。
  static DecodedImage decodeGrayscale(List<int> bytes) {
    final source = decodeRgb(bytes);
    final n = source.width * source.height;
    final gray = Uint8List(n * 3);
    for (var i = 0; i < n; i++) {
      final y = (0.299 * source.rgb[i * 3] +
              0.587 * source.rgb[i * 3 + 1] +
              0.114 * source.rgb[i * 3 + 2])
          .round()
          .clamp(0, 255);
      gray[i * 3] = y;
      gray[i * 3 + 1] = y;
      gray[i * 3 + 2] = y;
    }
    return DecodedImage(source.width, source.height, gray);
  }

  /// 将 RGB 像素编码为 PNG 字节。
  static Uint8List encodePng({
    required Uint8List rgb,
    required int width,
    required int height,
  }) {
    if (rgb.length != width * height * 3) {
      throw ArgumentError('rgb 长度与 ${width}x$height 不匹配');
    }
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgb.buffer,
      numChannels: 3,
    );
    return img.encodePng(image);
  }

  /// 将 RGBA 像素编码为 PNG 字节 (赛璐璐分层导出用)。
  static Uint8List encodePngRgba(Uint8List rgba, int width, int height) {
    if (rgba.length != width * height * 4) {
      throw ArgumentError('rgba 长度与 ${width}x$height 不匹配');
    }
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    return img.encodePng(image);
  }

  static DecodedImage _toRgb(img.Image image) {
    final n = image.width * image.height;
    final rgb = Uint8List(n * 3);
    var offset = 0;
    for (final pixel in image) {
      rgb[offset++] = _channel(pixel.r);
      rgb[offset++] = _channel(pixel.g);
      rgb[offset++] = _channel(pixel.b);
    }
    return DecodedImage(image.width, image.height, rgb);
  }

  static int _channel(num value) => value.round().clamp(0, 255);
}
