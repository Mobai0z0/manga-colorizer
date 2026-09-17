// linecheck.dart — 线稿/白底纯净度终检(绝对口径)
// 白底: 原稿 >=250 且四邻域 >=250 的像素, 成图后通道互差(彩色度)与亮度保持
// 墨线: 原稿 <=25 且四邻域 <=25 的像素, 成图后必须仍暗(V<0.25)且低彩色
// 用法: dart run tool/linecheck.dart <new.png> <bw.png> <label>
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final newImg = img.decodePng(File(args[0]).readAsBytesSync())!;
  final bw = img.decodePng(File(args[1]).readAsBytesSync())!;
  final label = args[2];
  final w = newImg.width, h = newImg.height;

  var whiteTotal = 0, whiteColored = 0, whiteDark = 0;
  var lineTotal = 0, lineColored = 0, lineLifted = 0;
  for (var y = 3; y < h - 3; y += 2) {
    for (var x = 3; x < w - 3; x += 2) {
      final gp = bw.getPixel(x, y);
      final gv = (gp.r + gp.g + gp.b) / 3;
      bool solid(List<int> o, bool Function(double) test) {
        for (final d in const [
          [3, 0],
          [-3, 0],
          [0, 3],
          [0, -3],
        ]) {
          final op = bw.getPixel(x + d[0], y + d[1]);
          if (!test((op.r + op.g + op.b) / 3)) return false;
        }
        return true;
      }

      final np = newImg.getPixel(x, y);
      final chroma = (np.r - np.g).abs() + (np.g - np.b).abs() + (np.r - np.b).abs();
      final nv = (np.r + np.g + np.b) / 3;
      if (gv >= 250 && solid([], (v) => v >= 250) &&
          solid(const [3, 0], (v) => v >= 250) &&
          solid(const [-3, 0], (v) => v >= 250) &&
          solid(const [0, 3], (v) => v >= 250) &&
          solid(const [0, -3], (v) => v >= 250)) {
        whiteTotal++;
        if (chroma > 24) whiteColored++;
        if (nv < 200) whiteDark++;
      } else if (gv <= 25 &&
          solid(const [3, 0], (v) => v <= 25) &&
          solid(const [-3, 0], (v) => v <= 25) &&
          solid(const [0, 3], (v) => v <= 25) &&
          solid(const [0, -3], (v) => v <= 25)) {
        lineTotal++;
        if (chroma > 45) lineColored++;
        if (nv > 64) lineLifted++;
      }
    }
  }
  String pct(int a, int b) => b == 0 ? '—' : '${(100 * a / b).toStringAsFixed(2)}%';
  stdout.writeln('[$label]');
  stdout.writeln(
      '  纯白底 $whiteTotal 采样: 被染色 $whiteColored (${pct(whiteColored, whiteTotal)}), 被压暗 $whiteDark (${pct(whiteDark, whiteTotal)})');
  stdout.writeln(
      '  实心墨线 $lineTotal 采样: 被染色(>45) $lineColored (${pct(lineColored, lineTotal)}), 被提亮(>64) $lineLifted (${pct(lineLifted, lineTotal)})');
}
