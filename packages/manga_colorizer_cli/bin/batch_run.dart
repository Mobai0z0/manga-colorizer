import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:manga_colorizer_cli/src/sample_page.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 固定测试集批量上色 + 定量指标留档。
///
/// dart run batch_run --palette out/character_palettes.json --out-dir out/batch
///
/// 生成 12 张确定性合成线稿 (尺寸/种子/亮度固定),逐张用角色色板上色,
/// 输出 原稿|成图 对比图与 batch_metrics.json (PSNR-Y / 色度覆盖率 / 耗时)。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('palette', defaultsTo: 'out/character_palettes.json')
    ..addOption('character', defaultsTo: 'akari')
    ..addOption('out-dir', defaultsTo: 'out/batch')
    ..addOption('count', defaultsTo: '12')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  final outDir = Directory(parsed['out-dir'] as String);
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  // 载入角色色板。
  final archive = jsonDecode(File(parsed['palette'] as String).readAsStringSync())
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

  // 固定测试集: 12 张,确定性参数 (尺寸/种子/亮度)。
  final count = int.parse(parsed['count'] as String);
  final specs = <Map<String, Object>>[];
  final sizes = [
    [512, 640],
    [480, 720],
    [560, 700],
    [1024, 1280], // 大图 → 触发分块管线
  ];
  final brights = [1.0, 1.0, 0.85, 1.0, 0.7, 1.0];
  for (var i = 0; i < count; i++) {
    final size = sizes[i % sizes.length];
    specs.add({
      'w': size[0],
      'h': size[1],
      'seed': 7 + i,
      'brightness': brights[i % brights.length],
    });
  }

  final metrics = <Map<String, Object>>[];
  var failures = 0;
  for (var i = 0; i < specs.length; i++) {
    final s = specs[i];
    final w = s['w'] as int;
    final h = s['h'] as int;
    final brightness = s['brightness'] as double;
    final tag = 'test_${(i + 1).toString().padLeft(2, '0')}_${w}x${h}'
        '${brightness < 1.0 ? "_dim${(brightness * 100).round()}" : ""}';
    try {
      final source = makeSampleManga(width: w, height: h, seed: s['seed'] as int,
          brightness: brightness);
      final slots = recommendedSampleSlots(w, h);
      final hints = paletteToHints(palette, slots);
      final options = const ColorizeOptions(maxIterations: 600);
      final watch = Stopwatch()..start();
      final TiledColorizeResult result;
      if (math.max(w, h) > 768) {
        result = colorizeMangaTiled(
            grayscaleRgb: source.rgb,
            width: w,
            height: h,
            hints: hints,
            options: options,
            tileSize: 512,
            overlap: 64);
      } else {
        final r = colorizeManga(
            grayscaleRgb: source.rgb,
            width: w,
            height: h,
            hints: hints,
            options: options);
        result = TiledColorizeResult(w, h, r.rgb, 1, 512, 64);
      }
      watch.stop();

      // 指标: PSNR-Y (结构保真) + 色度覆盖率。
      final psnr = _psnrLuminance(source.rgb, result.rgb, w, h);
      final coverage = _chromaCoverage(result.rgb, w, h);
      final ms = watch.elapsedMilliseconds;

      // 写成图 + 原稿|成图对比图。
      File('${outDir.path}/$tag.png').writeAsBytesSync(
          MangaImageIO.encodePng(rgb: result.rgb, width: w, height: h));
      const sheetPad = 6;
      final sheet = _twoPanel(source.rgb, result.rgb, w, h, sheetPad);
      File('${outDir.path}/$tag-compare.png').writeAsBytesSync(
          MangaImageIO.encodePng(
              rgb: sheet, width: w * 2 + sheetPad * 3, height: h + sheetPad * 2));

      metrics.add({
        'image': tag,
        'size': '$w x $h',
        'brightness': brightness,
        'tiles': result.tileCount,
        'psnrY_db': double.parse(psnr.toStringAsFixed(1)),
        'chromaCoverage': double.parse(coverage.toStringAsFixed(3)),
        'ms': ms,
      });
      stdout.writeln(
          '[$tag] tiles=${result.tileCount} PSNR-Y=${psnr.toStringAsFixed(1)}dB '
          'coverage=${coverage.toStringAsFixed(3)} ${ms}ms');
    } catch (e) {
      failures++;
      stderr.writeln('[$tag] 失败: $e');
      metrics.add({'image': tag, 'error': e.toString()});
    }
  }

  final report = {
    'engine': 'manga_colorizer_core 0.1.0 (tiling rev)',
    'character': palette.characterId,
    'testsetSize': specs.length,
    'failures': failures,
    'metrics': metrics,
    'generatedAt': DateTime.now().toIso8601String(),
  };
  File('${outDir.path}/batch_metrics.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(
      '批量完成: ${specs.length - failures}/${specs.length} 成功, 报告 ${outDir.path}/batch_metrics.json');
  exitCode = failures > 0 ? 70 : 0;
}

/// 亮度通道 PSNR (结构保真: 亮度保留策略下应显著高于 40dB)。
double _psnrLuminance(Uint8List a, Uint8List b, int w, int h) {
  var mse = 0.0;
  for (var i = 0; i < w * h; i++) {
    final ya = 0.299 * a[i * 3] + 0.587 * a[i * 3 + 1] + 0.114 * a[i * 3 + 2];
    final yb = 0.299 * b[i * 3] + 0.587 * b[i * 3 + 1] + 0.114 * b[i * 3 + 2];
    final d = ya - yb;
    mse += d * d;
  }
  mse /= w * h;
  if (mse < 1e-9) return 99.0;
  return 10 * math.log(255 * 255 / mse) / math.ln10;
}

/// 色度覆盖率: 可着色区域 (亮度 0.08..0.92) 中 |chroma|>0.02 的像素占比。
double _chromaCoverage(Uint8List rgb, int w, int h) {
  var tintable = 0;
  var colored = 0;
  for (var i = 0; i < w * h; i++) {
    final r = rgb[i * 3] / 255, g = rgb[i * 3 + 1] / 255, b = rgb[i * 3 + 2] / 255;
    final y = 0.299 * r + 0.587 * g + 0.114 * b;
    if (y < 0.08 || y > 0.92) continue;
    tintable++;
    final u = (b - y) / 1.772;
    final v = (r - y) / 1.402;
    if (math.sqrt(u * u + v * v) > 0.02) colored++;
  }
  return tintable == 0 ? 0 : colored / tintable;
}

/// 原稿|成图 双联对比图 (深色底)。
Uint8List _twoPanel(Uint8List orig, Uint8List colorized, int w, int h, int pad) {
  final totalW = w * 2 + pad * 3;
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
  blit(colorized, w + pad * 2);
  return out;
}
