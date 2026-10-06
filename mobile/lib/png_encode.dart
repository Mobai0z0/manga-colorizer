// dart:ui 原生 PNG 编码：像素进引擎（ImageDescriptor.raw + codec）后由
// toByteData(png) 在引擎线程出 PNG 字节，主 isolate 只等 Future。替代 image
// 包的纯 Dart zlib 编码——2048² 的 encodePng 在 Dart 里可达秒级（「编码
// PNG…」是全自动任务收尾的主要等待），原生路径通常在百毫秒级。
// 像素内容与 image 包路径逐位一致（都是无损耗 PNG）；容器字节（压缩器/滤波
// 选择、RGBA 通道）可以不同——对预览/图库/分享只要求合法 PNG。
// 必须在主 isolate 调用（dart:ui 编解码器约束，同 capDecodeRgba）。
import 'dart:typed_data';
import 'dart:ui' as ui;

/// RGBA 像素编码为 PNG（引擎线程执行，主 isolate await）。
Future<Uint8List> encodePngFromRgba(
    Uint8List rgba, int width, int height) async {
  if (rgba.length != width * height * 4) {
    throw ArgumentError('rgba 长度与 ${width}x$height 不匹配');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = ui.ImageDescriptor.raw(buffer,
        width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('PNG 编码失败：引擎未返回字节');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    // 逆序释放：descriptor/codec 还引用 buffer，最后才放。
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// RGB 像素编码为 PNG：填 alpha 后走 [encodePngFromRgba]（拷贝一份 4 通道
/// 缓冲，2048² 时 ~16.8MB 瞬时，远小于 Dart zlib 的编码缓冲与耗时）。
Future<Uint8List> encodePngFromRgb(
    Uint8List rgb, int width, int height) async {
  if (rgb.length != width * height * 3) {
    throw ArgumentError('rgb 长度与 ${width}x$height 不匹配');
  }
  final n = width * height;
  final rgba = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    rgba[i * 4] = rgb[i * 3];
    rgba[i * 4 + 1] = rgb[i * 3 + 1];
    rgba[i * 4 + 2] = rgb[i * 3 + 2];
    rgba[i * 4 + 3] = 255;
  }
  return encodePngFromRgba(rgba, width, height);
}
