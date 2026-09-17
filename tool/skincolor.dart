// skincolor.dart — 肤色偏好度测量(新旧对照)
// 对每页: 找两版输出中属于"暖色皮肤候选"的像素(色相 0-60° 或 320-360°, 饱和>0.06, 明度>0.4),
// 统计: 平均色相 / 偏黄像素占比(hue>32°) / 自然带占比(15-25°) / CIE76 ΔE vs 参考肤色
// 用法: dart run tool/skincolor.dart <old.png> <new.png> <label>
import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

List<double> rgbToLab(int r, int g, int b) {
  double lin(int c) {
    final v = c / 255.0;
    return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final rl = lin(r), gl = lin(g), bl = lin(b);
  final x = (rl * 0.4124 + gl * 0.3576 + bl * 0.1805) / 0.95047;
  final y = (rl * 0.2126 + gl * 0.7152 + bl * 0.0722) / 1.00000;
  final z = (rl * 0.0193 + gl * 0.1192 + bl * 0.9505) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1.0 / 3).toDouble() : (7.787 * t + 16.0 / 116);
  final fx = f(x), fy = f(y), fz = f(z);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

void main(List<String> args) {
  final oldImg = img.decodePng(File(args[0]).readAsBytesSync())!;
  final newImg = img.decodePng(File(args[1]).readAsBytesSync())!;
  final label = args[2];

  // 参考肤色族: 自然日系肤色的基色/中间调/阴影三点, 取最小 ΔE(距离自然肤色族)。
  final refLabs = [
    rgbToLab(246, 216, 192), // base #F6D8C0
    rgbToLab(240, 200, 168), // mid  #F0C8A8
    rgbToLab(224, 168, 128), // shadow #E0A880
  ];

  var oldCount = 0, newCount = 0;
  var oldHueSum = 0.0, newHueSum = 0.0;
  var oldYellow = 0, newYellow = 0;
  var oldNatural = 0, newNatural = 0;
  var oldDE = 0.0, newDE = 0.0;
  var oldSatSum = 0.0, newSatSum = 0.0;

  final w = oldImg.width, h = oldImg.height;
  for (var y = 2; y < h - 2; y += 2) {
    for (var x = 2; x < w - 2; x += 2) {
      final po = oldImg.getPixel(x, y);
      final pn = newImg.getPixel(x, y);
      for (var pair = 0; pair < 2; pair++) {
        final int pr = pair == 0 ? po.r.toInt() : pn.r.toInt();
        final int pg = pair == 0 ? po.g.toInt() : pn.g.toInt();
        final int pb = pair == 0 ? po.b.toInt() : pn.b.toInt();
        final r = pr.toDouble(), g = pg.toDouble(), b = pb.toDouble();
        final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
        final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
        final d = mx - mn;
        if (mx <= 0 || d <= 0) continue;
        final s = d / mx;
        if (s < 0.06 || mx < 0.4 * 255) continue;
        double hh;
        if (mx == r) {
          hh = 60 * (((g - b) / d) % 6);
        } else if (mx == g) {
          hh = 60 * ((b - r) / d + 2);
        } else {
          hh = 60 * ((r - g) / d + 4);
        }
        if (hh < 0) hh += 360;
        // 只研究暖色相候选(皮肤竞争区)。
        if (hh > 60 && hh < 320) continue;

        final lab = rgbToLab(pr, pg, pb);
        var de = double.infinity;
        for (final ref in refLabs) {
          final d = math.sqrt(
              (lab[0] - ref[0]) * (lab[0] - ref[0]) +
                  (lab[1] - ref[1]) * (lab[1] - ref[1]) +
                  (lab[2] - ref[2]) * (lab[2] - ref[2]));
          if (d < de) de = d;
        }
        if (pair == 0) {
          oldCount++;
          oldHueSum += hh;
          oldSatSum += s;
          if (hh > 32 && hh <= 60) oldYellow++;
          if (hh >= 15 && hh <= 25) oldNatural++;
          oldDE += de;
        } else {
          newCount++;
          newHueSum += hh;
          newSatSum += s;
          if (hh > 32 && hh <= 60) newYellow++;
          if (hh >= 15 && hh <= 25) newNatural++;
          newDE += de;
        }
      }
    }
  }

  String fmt(double v) => v.toStringAsFixed(1);
  String pct(int a, int b) =>
      b == 0 ? '—' : '${(100 * a / b).toStringAsFixed(1)}%';
  stdout.writeln('[$label] 暖色候选像素: 旧 $oldCount / 新 $newCount');
  stdout.writeln(
      '  平均色相: 旧 ${fmt(oldHueSum / (oldCount == 0 ? 1 : oldCount))}° → 新 ${fmt(newHueSum / (newCount == 0 ? 1 : newCount))}° (自然带 15-25°)');
  stdout.writeln(
      '  偏黄占比(hue>32°): 旧 ${pct(oldYellow, oldCount)} → 新 ${pct(newYellow, newCount)}');
  stdout.writeln(
      '  自然带占比(15-25°): 旧 ${pct(oldNatural, oldCount)} → 新 ${pct(newNatural, newCount)}');
  stdout.writeln(
      '  平均ΔE vs 肤色族: 旧 ${fmt(oldDE / (oldCount == 0 ? 1 : oldCount))} → 新 ${fmt(newDE / (newCount == 0 ? 1 : newCount))}');
  stdout.writeln(
      '  平均饱和: 旧 ${(oldSatSum / (oldCount == 0 ? 1 : oldCount)).toStringAsFixed(3)} → 新 ${(newSatSum / (newCount == 0 ? 1 : newCount)).toStringAsFixed(3)}');
}
