// forensic.dart — 色值方差与线稿纯净度取证
// 用法: dart run tool/forensic.dart <new.png> <old.png> <bw.png> <label>
import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final newImg = img.decodePng(File(args[0]).readAsBytesSync())!;
  final oldImg = img.decodePng(File(args[1]).readAsBytesSync())!;
  final bw = img.decodePng(File(args[2]).readAsBytesSync())!;
  final label = args[3];

  // 在 5 个固定窗口(中央大色块区域)取 9x9 网点色值, 统计 RGB 欧氏距离标准差。
  double stddev(img.Image im, int cx, int cy) {
    final vals = <int>[];
    for (var y = cy - 24; y <= cy + 24; y += 6) {
      for (var x = cx - 24; x <= cx + 24; x += 6) {
        final p = im.getPixel(x, y);
        vals.add(p.r.toInt() + p.g.toInt() + p.b.toInt());
      }
    }
    final mean = vals.reduce((a, b) => a + b) / vals.length;
    final variance =
        vals.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
            vals.length;
    return math.sqrt(variance);
  }

  // 找色彩最饱和的 5 个窗口作为「大色块」抽样点。
  double satOf(img.Pixel p) => math
      .max(math.max(p.r, p.g), p.b)
      .toDouble() -
      math.min(math.min(p.r, p.g), p.b).toDouble();
  int best = 0;
  final spots = <int>[];
  final w = newImg.width, h = newImg.height;
  for (var i = 0; i < 400; i++) {
    final x = 40 + (i * 7919) % (w - 100);
    final y = 40 + (i * 104729) % (h - 100);
    final p = newImg.getPixel(x, y);
    final sat = satOf(p).toInt();
    if (sat > best) {
      best = sat;
    }
    spots.add(sat);
  }
  spots.sort();
  // 取前 5 高饱和位置窗口(重新扫)。
  final threshold = spots[spots.length - 30];
  final windows = <List<int>>[];
  for (var i = 0; i < 400 && windows.length < 5; i++) {
    final x = 40 + (i * 7919) % (w - 100);
    final y = 40 + (i * 104729) % (h - 100);
    final p = newImg.getPixel(x, y);
    final sat = satOf(p).toInt();
    if (sat >= threshold) {
      windows.add([x, y]);
    }
  }

  var newSum = 0.0, oldSum = 0.0;
  for (final win in windows) {
    newSum += stddev(newImg, win[0], win[1]);
    oldSum += stddev(oldImg, win[0], win[1]);
  }
  newSum /= windows.length;
  oldSum /= windows.length;

  // 线稿纯净度: 只测原稿实心墨线(采样点及四邻域全部 V<0.10)处的通道偏差。
  var lineDrift = 0;
  var lineCount = 0;
  var whiteDriftMax = 0;
  for (var y = 3; y < h - 3; y += 3) {
    for (var x = 3; x < w - 3; x += 3) {
      final gp = bw.getPixel(x, y);
      final gv = (gp.r + gp.g + gp.b) / 3;
      if (gv < 25) {
        // 确认是实心墨线: 四邻域也都够黑。
        var solid = true;
        for (final o in const [[3, 0], [-3, 0], [0, 3], [0, -3]]) {
          final op = bw.getPixel(x + o[0], y + o[1]);
          if ((op.r + op.g + op.b) / 3 >= 25) {
            solid = false;
            break;
          }
        }
        if (!solid) continue;
        lineCount++;
        final np = newImg.getPixel(x, y);
        final d = (np.r - np.g).abs().toInt() +
            (np.g - np.b).abs().toInt() +
            (np.r - np.b).abs().toInt();
        if (d > lineDrift) lineDrift = d;
      } else if (gv > 250) {
        // 实心白纸(四邻域也白)才算。
        var solid = true;
        for (final o in const [[3, 0], [-3, 0], [0, 3], [0, -3]]) {
          final op = bw.getPixel(x + o[0], y + o[1]);
          if ((op.r + op.g + op.b) / 3 <= 250) {
            solid = false;
            break;
          }
        }
        if (!solid) continue;
        final np = newImg.getPixel(x, y);
        final d = (np.r - np.g).abs().toInt() +
            (np.g - np.b).abs().toInt() +
            (np.r - np.b).abs().toInt();
        if (d > whiteDriftMax) whiteDriftMax = d;
      }
    }
  }

  stdout.writeln('[$label]');
  stdout.writeln(
      '  色块内色值标准差: 新版 ${newSum.toStringAsFixed(1)} vs 旧版 ${oldSum.toStringAsFixed(1)} '
      '(抽样 ${windows.length} 个高饱和窗口, >0 = 有自然层次)');
  stdout.writeln(
      '  墨线污染检查: ${lineCount} 个黑线采样点, 最大通道偏移 $lineDrift '
      '(<=6 视为线稿纯净)');
  stdout.writeln(
      '  白底纯净度: 最大通道偏移 $whiteDriftMax (<=8 视为干净)');
}
