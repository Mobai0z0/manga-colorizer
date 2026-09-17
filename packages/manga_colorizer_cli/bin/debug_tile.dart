import 'dart:io';
import 'dart:typed_data';

import 'package:manga_colorizer_cli/src/sample_page.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 调试: 定位分块管线的亮度误差分布,输出误差热区图。
Future<void> main(List<String> args) async {
  const w = 1024, h = 1280;
  final source = makeSampleManga(width: w, height: h, seed: 10, brightness: 1.0);
  final palette = CharacterPalette.fromJson({
    'characterId': 'akari',
    'displayName': 'akari',
    'parts': [
      {'role': 'skin', 'hex': '#F1C27D'},
      {'role': 'hair', 'hex': '#5A1A9E'},
      {'role': 'uniform', 'hex': '#1A4A86'},
      {'role': 'scarf', 'hex': '#D6405C'},
    ],
  });
  final slots = recommendedSampleSlots(w, h);
  for (final s in slots) {
    final i = (s.y * w + s.x) * 3;
    stdout.writeln(
        'slot ${s.role} (${s.x},${s.y}) gray=${source.rgb[i]}');
  }
  final hints = paletteToHints(palette, slots);
  final result = colorizeMangaTiled(
      grayscaleRgb: source.rgb,
      width: w,
      height: h,
      hints: hints,
      options: const ColorizeOptions(maxIterations: 600),
      tileSize: 512,
      overlap: 64);

  // 亮度误差图: |ΔY|>3 红, >1 黄, 其余白。
  final errMap = Uint8List(w * h * 3);
  var over3 = 0, over1 = 0;
  var maxErr = 0.0;
  final hist = <int, int>{};
  for (var i = 0; i < w * h; i++) {
    final ya = 0.299 * source.rgb[i * 3] +
        0.587 * source.rgb[i * 3 + 1] +
        0.114 * source.rgb[i * 3 + 2];
    final yb = 0.299 * result.rgb[i * 3] +
        0.587 * result.rgb[i * 3 + 1] +
        0.114 * result.rgb[i * 3 + 2];
    final d = (ya - yb).abs();
    if (d > maxErr) maxErr = d;
    final bucket = d.round();
    hist[bucket] = (hist[bucket] ?? 0) + 1;
    if (d > 3) {
      over3++;
      errMap[i * 3] = 220;
      errMap[i * 3 + 1] = 30;
      errMap[i * 3 + 2] = 30;
    } else if (d > 1) {
      over1++;
      errMap[i * 3] = 240;
      errMap[i * 3 + 1] = 200;
      errMap[i * 3 + 2] = 60;
    } else {
      errMap[i * 3] = 250;
      errMap[i * 3 + 1] = 250;
      errMap[i * 3 + 2] = 250;
    }
  }
  final sortedKeys = hist.keys.toList()..sort((a, b) => b.compareTo(a));
  var acc = 0;
  for (final k in sortedKeys.take(6)) {
    acc += hist[k]!;
    stdout.writeln('err>=$k: ${hist[k]} px (cum ${acc})');
  }
  stdout.writeln('over1=$over1 over3=$over3 maxErr=$maxErr');
  File('out/batch/errmap_test04.png').writeAsBytesSync(
      MangaImageIO.encodePng(rgb: errMap, width: w, height: h));
  stdout.writeln('errmap -> out/batch/errmap_test04.png');
}
