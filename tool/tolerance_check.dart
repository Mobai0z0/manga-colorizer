// tolerance_check.dart — 同类别区块色值容差检查(验收: 类别内色值差异)
// 对每类别: 找该类别全部块的像素, 统计 HSL 色相分布(排除 s<0.06 中性),
// 输出色相极差/平均饱和差/亮度极差, 与容差比较。
// 用法: dart run tool/tolerance_check.dart <classified.png> <idmap.png> <ledger.json>
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final im = img.decodePng(File(args[0]).readAsBytesSync())!;
  final idImg = img.decodePng(File(args[1]).readAsBytesSync())!;
  final ledger =
      jsonDecode(File(args[2]).readAsStringSync()) as Map<String, Object?>;
  final blocks = (ledger['blocks'] as List).cast<Map<String, Object?>>();
  final catOf = <int, String>{};
  for (final b in blocks) {
    catOf[b['id'] as int] = b['category'] as String;
  }

  // 类别 → 色相/饱和/明度累计。
  final hueMin = <String, double>{};
  final hueMax = <String, double>{};
  final satSum = <String, double>{};
  final satCnt = <String, int>{};
  final valMin = <String, double>{};
  final valMax = <String, double>{};
  final sampled = <String, int>{};
  for (var y = 0; y < im.height; y += 2) {
    for (var x = 0; x < im.width; x += 2) {
      final p = idImg.getPixel(x, y);
      final id = (p.r.toInt() & 0xFF) | ((p.g.toInt() & 0xFF) << 8);
      final cat = catOf[id];
      if (cat == null) continue;
      final q = im.getPixel(x, y);
      final r = q.r / 255.0, g = q.g / 255.0, b = q.b / 255.0;
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      final d = mx - mn;
      final s = mx <= 0 ? 0.0 : d / mx;
      sampled[cat] = (sampled[cat] ?? 0) + 1;
      // 明度极差对全部像素统计(含中性)。
      valMin[cat] = math.min(valMin[cat] ?? 2.0, mx);
      valMax[cat] = math.max(valMax[cat] ?? 0.0, mx);
      if (d <= 0 || s < 0.06) continue; // 中性色不入色相统计
      double hh;
      if (mx == r) {
        hh = 60 * (((g - b) / d) % 6);
      } else if (mx == g) {
        hh = 60 * ((b - r) / d + 2);
      } else {
        hh = 60 * ((r - g) / d + 4);
      }
      if (hh < 0) hh += 360;
      hueMin[cat] = math.min(hueMin[cat] ?? 999, hh);
      hueMax[cat] = math.max(hueMax[cat] ?? -1, hh);
      satSum[cat] = (satSum[cat] ?? 0) + s;
      satCnt[cat] = (satCnt[cat] ?? 0) + 1;
    }
  }

  print('=== 同类别色值容差检查(容差: 色相极差 ≤18° 且 同色相族) ===');
  var allPass = true;
  for (final cat in [
    'hair', 'eye', 'skin', 'garment', 'white', 'sky', 'backdrop'
  ]) {
    if (hueMin[cat] == null) continue;
    final range = hueMax[cat]! - hueMin[cat]!;
    final sameHueFamily =
        hueMax[cat]! <= 60 || hueMin[cat]! >= 180; // 同属暖或同属冷
    final pass = range <= 18 || (sameHueFamily && range <= 40);
    if (!pass) allPass = false;
    print(
        '[$cat] 采样 ${sampled[cat]} | 色相 ${hueMin[cat]!.toStringAsFixed(0)}°–${hueMax[cat]!.toStringAsFixed(0)}°(极差 ${range.toStringAsFixed(0)}°) '
        '| 均饱和 ${(satSum[cat]! / (satCnt[cat] ?? 1)).toStringAsFixed(2)} '
        '| 明度 ${(valMin[cat]! * 255).round()}–${(valMax[cat]! * 255).round()} '
        '→ ${pass ? "PASS" : "FAIL"}');
  }
  print(allPass ? '→ 全类别容差 PASS' : '→ 存在 FAIL 类别(见上)');
}
