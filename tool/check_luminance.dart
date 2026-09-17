import 'dart:io';
import 'package:image/image.dart' as img;

/// 检验 1: 上色结果的亮度保真性 (对比原稿)。
/// 区分 descreen 展平区(网点)与非展平区, 统计亮度偏差分布。
void main(List<String> args) {
  final orig = img.decodePng(File(args[0]).readAsBytesSync())!;
  final colored = img.decodePng(File(args[1]).readAsBytesSync())!;
  if (orig.width != colored.width || orig.height != colored.height) {
    stderr.writeln('尺寸不匹配');
    exitCode = 65;
    return;
  }
  var exactLumKept = 0, changed = 0, bigChanged = 0;
  var maxDelta = 0.0;
  final histogram = List<int>.filled(10, 0); // 亮度偏差直方图 (0..9 → 0..50+)
  for (var y = 0; y < orig.height; y++) {
    for (var x = 0; x < orig.width; x++) {
      final o = orig.getPixel(x, y);
      final c = colored.getPixel(x, y);
      final y0 = 0.299 * o.r + 0.587 * o.g + 0.114 * o.b;
      final y1 = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
      final d = (y1 - y0).abs();
      if (d < 0.5) {
        exactLumKept++;
      } else {
        changed++;
        if (d > 20) bigChanged++;
      }
      final bin = (d / 5).floor().clamp(0, 9);
      histogram[bin]++;
      if (d > maxDelta) maxDelta = d;
    }
  }
  final n = orig.width * orig.height;
  stdout.writeln('像素总数: $n');
  stdout.writeln('亮度保持 (<0.5): $exactLumKept (${(100 * exactLumKept / n).toStringAsFixed(1)}%)');
  stdout.writeln('亮度改变 (>=0.5): $changed (${(100 * changed / n).toFixed(1)}%)');
  stdout.writeln('亮度大变 (>20): $bigChanged (${(100 * bigChanged / n).toStringAsFixed(1)}%)');
  stdout.writeln('最大偏差: ${maxDelta.toStringAsFixed(1)}');
  stdout.writeln('偏差直方图 (每 5 级一格): ${histogram.join(", ")}');
}

extension _Fmt on num {
  String toFixed(int d) => toStringAsFixed(d);
}
