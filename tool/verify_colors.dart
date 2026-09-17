// verify_colors.dart — 按块统计成图众数色 vs 用户选色
// 用法: dart run tool/verify_colors.dart <painted.png> <idmap.png> <colors.json>
import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final painted = img.decodePng(File(args[0]).readAsBytesSync())!;
  final idImg = img.decodePng(File(args[1]).readAsBytesSync())!;
  final map = jsonDecode(File(args[2]).readAsStringSync())
      as Map<String, dynamic>;
  for (final entry in map.entries) {
    final id = int.parse(entry.key);
    final want = entry.value as String;
    final counts = <int, int>{};
    for (var y = 0; y < painted.height; y++) {
      for (var x = 0; x < painted.width; x++) {
        final p = idImg.getPixel(x, y);
        if (((p.r.toInt() & 0xFF) | ((p.g.toInt() & 0xFF) << 8)) != id) {
          continue;
        }
        final q = painted.getPixel(x, y);
        final key = (q.r.toInt() << 16) | (q.g.toInt() << 8) | q.b.toInt();
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) {
      print('[$id] 无像素');
      continue;
    }
    final sortedKeys = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final top = sortedKeys.take(3).map((k) {
      final r = (k >> 16) & 0xFF, g = (k >> 8) & 0xFF, b = k & 0xFF;
      return '#${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')} x${counts[k]}';
    }).join(', ');
    print('[$id] 用户选 $want | 块内众数: $top');
  }
}
