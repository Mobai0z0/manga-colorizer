import 'dart:io';
import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// CLI 公用 IO 辅助。
class CliIo {
  /// 读取并解码图像文件 (自动灰度化)。
  static DecodedImage readGrayscale(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('错误: 找不到文件 $path');
      exitCode = 66;
      throw StateError('file not found: $path');
    }
    try {
      return MangaImageIO.decodeGrayscale(file.readAsBytesSync());
    } catch (e) {
      // 解码器可能抛 FormatException 之外的异常 (空文件/截断数据),
      // 统一收敛为干净退出码 65, 不让进程崩溃成 255。
      stderr.writeln('错误: 无法解码图像 $path (${e.runtimeType}: $e)');
      exit(65);
    }
  }

  /// 写 PNG 文件。
  static void writePng(String path, Uint8List rgb, int width, int height) {
    final png = MangaImageIO.encodePng(rgb: rgb, width: width, height: height);
    File(path).writeAsBytesSync(png);
  }
}

/// 在 RGB 图上画提示点标记 (圆点 + 白描边),用于对比图。
Uint8List drawHintMarkers({
  required Uint8List rgb,
  required int width,
  required int height,
  required List<ColorHint> hints,
  int radius = 3,
}) {
  final out = Uint8List.fromList(rgb);
  for (final hint in hints) {
    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final d2 = dx * dx + dy * dy;
        if (d2 > radius * radius) continue;
        final x = hint.x + dx;
        final y = hint.y + dy;
        if (x < 0 || x >= width || y < 0 || y >= height) continue;
        final i = (y * width + x) * 3;
        final isEdge = d2 >= (radius - 1) * (radius - 1);
        if (isEdge) {
          out[i] = 255;
          out[i + 1] = 255;
          out[i + 2] = 255;
        } else {
          out[i] = hint.r;
          out[i + 1] = hint.g;
          out[i + 2] = hint.b;
        }
      }
    }
  }
  return out;
}
