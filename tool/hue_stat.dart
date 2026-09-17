// hue_stat.dart — 成图色相分布统计(验收: 单一色相≤40%, 中性灰保留)
// 用法: dart run tool/hue_stat.dart <img.png> <label>
import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final im = img.decodePng(File(args[0]).readAsBytesSync())!;
  final label = args[1];
  final buckets = List<int>.filled(12, 0); // 30° 一桶
  var neutral = 0, total = 0;
  for (var y = 0; y < im.height; y += 2) {
    for (var x = 0; x < im.width; x += 2) {
      final p = im.getPixel(x, y);
      final r = p.r / 255.0, g = p.g / 255.0, b = p.b / 255.0;
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      final d = mx - mn;
      total++;
      if (d <= 0 || mx <= 0 || d / mx < 0.08) {
        neutral++;
        continue;
      }
      double hh;
      if (mx == r) {
        hh = 60 * (((g - b) / d) % 6);
      } else if (mx == g) {
        hh = 60 * ((b - r) / d + 2);
      } else {
        hh = 60 * ((r - g) / d + 4);
      }
      if (hh < 0) hh += 360;
      buckets[(hh ~/ 30) % 12]++;
    }
  }
  final colored = total - neutral;
  stdout.writeln('[$label] 采样 $total, 中性(灰白) ${pct(neutral, total)}');
  var maxShare = 0;
  var maxIdx = -1;
  for (var i = 0; i < 12; i++) {
    final pctV = pct(buckets[i], total);
    stdout.writeln(
        '  ${_name(i)}: $pctV (${_pctOfColored(buckets[i], colored)})');
    if (buckets[i] > maxShare) {
      maxShare = buckets[i];
      maxIdx = i;
    }
  }
  stdout.writeln(
      '  → 单一色相占全图最高: ${pct(maxShare, total)} (${_name(maxIdx)}) — '
      '验收阈值 ≤40%: ${maxShare / total <= 0.40 ? "PASS" : "FAIL"}');
}

String _pctOfColored(int a, int colored) =>
    colored == 0 ? '—' : '${(100 * a / colored).toStringAsFixed(1)}% 彩色区';

String pct(int a, int b) => '${(100 * a / b).toStringAsFixed(1)}%';

String _name(int i) =>
    ['红', '橙', '黄', '黄绿', '绿', '青绿', '青', '天蓝', '蓝', '紫蓝', '紫', '品红'][i];
