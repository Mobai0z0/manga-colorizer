import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:manga_colorizer_cli/src/sample_page.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 一般漫画页适用性基准: 12 张典型页 × {优化前, 优化后} 双跑。
///
/// 优化前 = 串行分块、无自动色阶 (v0.3 行为);
/// 优化后 = 并行 Isolate 分块 + 自动色阶预处理 (v0.4)。
/// 同一组样本双跑,输出 bench_metrics.json (耗时/内存/PSNR/覆盖率)。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('palette', defaultsTo: 'out/character_palettes.json')
    ..addOption('character', defaultsTo: 'akari')
    ..addOption('out-dir', defaultsTo: 'out/bench')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  final outDir = Directory(parsed['out-dir'] as String);
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  final archive =
      jsonDecode(File(parsed['palette'] as String).readAsStringSync())
          as Map<String, Object?>;
  CharacterPalette? palette;
  for (final entry in archive['characters'] as List) {
    final p = CharacterPalette.fromJson(entry);
    if (p.characterId == parsed['character']) palette = p;
  }
  if (palette == null) {
    stderr.writeln('错误: 找不到角色 ${parsed['character']}');
    exitCode = 66;
    return;
  }

  // 12 张典型页: 尺寸覆盖 800–1600px 宽 (Goal 假设), 类型覆盖 文字页/浓墨页/灰阶页/网点感页。
  final specs = <Map<String, Object>>[];
  final layouts = <List<int>>[
    [800, 1200],
    [1100, 1600],
    [1400, 2000],
    [1600, 2260], // 1600px 宽上限
  ];
  final brights = [1.0, 0.85, 1.0, 0.7, 1.0, 0.9];
  for (var i = 0; i < 12; i++) {
    final size = layouts[i % layouts.length];
    specs.add({
      'w': size[0],
      'h': size[1],
      'seed': 20 + i,
      'brightness': brights[i % brights.length],
    });
  }

  final rows = <Map<String, Object>>[];
  for (var i = 0; i < specs.length; i++) {
    final s = specs[i];
    final w = s['w'] as int;
    final h = s['h'] as int;
    final brightness = s['brightness'] as double;
    final tag =
        'page_${(i + 1).toString().padLeft(2, '0')}_${w}x${h}${brightness < 1.0 ? "_b${(brightness * 100).round()}" : ""}';

    final source = makeSampleManga(
        width: w, height: h, seed: s['seed'] as int, brightness: brightness);
    final slots = recommendedSampleSlots(w, h);
    final hints = paletteToHints(palette, slots);
    final options = const ColorizeOptions(maxIterations: 600);

    // --- 优化前 (v0.3): 串行 + 无自动色阶 ---
    final grayBefore =
        brightness < 1.0 ? source.rgb : source.rgb; // 亮度已含在 source
    final t1 = Stopwatch()..start();
    final before = colorizeMangaTiled(
        grayscaleRgb: grayBefore,
        width: w,
        height: h,
        hints: hints,
        options: options,
        tileSize: 512,
        overlap: 64);
    final msBefore = t1.elapsedMilliseconds;

    // --- 优化后 (v0.4): 自动色阶 + 并行分块 ---
    final t2 = Stopwatch()..start();
    Uint8List work = source.rgb;
    var leveled = false;
    final (need, paperPeak, blackP1) = shouldAutoLevel(work);
    if (need) {
      final (leveledPixels, _, _) =
          autoLevels(work, const AutoLevelOptions());
      work = leveledPixels;
      leveled = true;
    }
    final after = await colorizeMangaTiledAsync(
        grayscaleRgb: work,
        width: w,
        height: h,
        hints: hints,
        options: options,
        tileSize: 512,
        overlap: 64);
    final msAfter = t2.elapsedMilliseconds;

    // 质量回归: 优化后 vs 优化前 的色度一致性 (色相偏差中位数)。
    final hueMedian = _hueDeltaMedian(before.rgb, after.rgb);
    // PSNR-Y: 优化后亮度 vs 实际喂入像素 (隔离求解器保真度;
    // 自动色阶的亮度重映射是有意为之, 不计入误差)。
    final psnr = _psnrY(work, after.rgb);

    // 输出: 成图 + 双联对比。
    File('${outDir.path}/$tag-before.png').writeAsBytesSync(
        MangaImageIO.encodePng(rgb: before.rgb, width: w, height: h));
    File('${outDir.path}/$tag-after.png').writeAsBytesSync(
        MangaImageIO.encodePng(rgb: after.rgb, width: w, height: h));
    const pad = 6;
    final sheet = _threePanel(source.rgb, before.rgb, after.rgb, w, h, pad);
    File('${outDir.path}/$tag-compare.png').writeAsBytesSync(
        MangaImageIO.encodePng(
            rgb: sheet,
            width: w * 3 + pad * 4,
            height: h + pad * 2));

    rows.add({
      'image': tag,
      'size': '$w x $h',
      'brightness': brightness,
      'tiles': after.tileCount,
      'autoLevel': leveled,
      'paperPeak': paperPeak,
      'blackP1': blackP1,
      'msBefore': msBefore,
      'msAfter': msAfter,
      'speedup': double.parse((msBefore / math.max(msAfter, 1)).toStringAsFixed(2)),
      'hueDeltaMedianDeg':
          double.parse(hueMedian.toStringAsFixed(2)),
      'psnrY_db': double.parse(psnr.toStringAsFixed(1)),
    });
    stdout.writeln(
        '[$tag] before=${msBefore}ms after=${msAfter}ms speedup=${(msBefore / math.max(msAfter, 1)).toStringAsFixed(2)}x '
        'hueΔ=${hueMedian.toStringAsFixed(2)}° psnr=${psnr.toStringAsFixed(1)}dB autoLevel=$leveled');
  }

  final report = {
    'engine': 'manga_colorizer_core 0.1.0 (v0.4: isolate-tiled + autolevel)',
    'character': palette.characterId,
    'sampleCount': specs.length,
    'rows': rows,
    'generatedAt': DateTime.now().toIso8601String(),
  };
  File('${outDir.path}/bench_metrics.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report));
  final avgSpeedup = rows.fold<double>(0, (a, r) => a + (r['speedup'] as double)) /
      rows.length;
  stdout.writeln(
      '基准完成: 平均加速 ${avgSpeedup.toStringAsFixed(2)}x, 报告 ${outDir.path}/bench_metrics.json');
}

double _psnrY(Uint8List a, Uint8List b) {
  var mse = 0.0;
  for (var i = 0; i < a.length ~/ 3; i++) {
    final ya = 0.299 * a[i * 3] + 0.587 * a[i * 3 + 1] + 0.114 * a[i * 3 + 2];
    final yb = 0.299 * b[i * 3] + 0.587 * b[i * 3 + 1] + 0.114 * b[i * 3 + 2];
    final d = ya - yb;
    mse += d * d;
  }
  mse /= a.length ~/ 3;
  if (mse < 1e-9) return 99.0;
  return 10 * math.log(255 * 255 / mse) / math.ln10;
}

/// 逐像素色相偏差的中位数 (优化前后着色一致性)。
double _hueDeltaMedian(Uint8List a, Uint8List b) {
  final deltas = <double>[];
  for (var i = 0; i < a.length ~/ 3; i++) {
    final ya = (0.299 * a[i * 3] + 0.587 * a[i * 3 + 1] + 0.114 * a[i * 3 + 2]) / 255;
    final yb = (0.299 * b[i * 3] + 0.587 * b[i * 3 + 1] + 0.114 * b[i * 3 + 2]) / 255;
    final ua = (a[i * 3 + 2] / 255 - ya) / 1.772;
    final va = (a[i * 3] / 255 - ya) / 1.402;
    final ub = (b[i * 3 + 2] / 255 - yb) / 1.772;
    final vb = (b[i * 3] / 255 - yb) / 1.402;
    final ma = math.sqrt(ua * ua + va * va);
    final mb = math.sqrt(ub * ub + vb * vb);
    if (ma < 0.02 || mb < 0.02) continue; // 只比有色的像素。
    var d = (math.atan2(va, -ua) - math.atan2(vb, -ub)) * 180 / math.pi;
    if (d < 0) d = -d;
    if (d > 180) d = 360 - d;
    deltas.add(d);
  }
  if (deltas.isEmpty) return 0;
  deltas.sort();
  return deltas[deltas.length ~/ 2];
}

Uint8List _threePanel(
    Uint8List orig, Uint8List before, Uint8List after, int w, int h, int pad) {
  final totalW = w * 3 + pad * 4;
  final totalH = h + pad * 2;
  final out = Uint8List(totalW * totalH * 3);
  out.fillRange(0, out.length, 28);
  void blit(Uint8List src, int ox) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final si = ((pad + y) * totalW + (ox + x)) * 3;
        final pi = (y * w + x) * 3;
        out[si] = src[pi];
        out[si + 1] = src[pi + 1];
        out[si + 2] = src[pi + 2];
      }
    }
  }
  blit(orig, pad);
  blit(before, w + pad * 2);
  blit(after, (w + pad) * 2 + pad);
  return out;
}
