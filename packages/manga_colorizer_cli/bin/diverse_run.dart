import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:manga_colorizer_cli/src/manga_page_v2.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 单页多样化上色 (皮肤固定, 其余元素多样):
///
/// dart run diverse_run --palettes out/diverse_palettes.json --out-dir out/diverse
///
/// 产出: 原图归档 + 3 个变体成品 + 四联对比 + 核查记录(皮肤固定性取色/
/// 元素-颜色清单/墨线保留计数)。原图确定性生成, 可随时重做。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('palettes', defaultsTo: 'out/diverse_palettes.json')
    ..addOption('out-dir', defaultsTo: 'out/diverse')
    ..addOption('options', help: '算法参数 JSON (可省)')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  final outDir = Directory(parsed['out-dir'] as String);
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  // 1) 选定漫画页 (任取: 引擎自产日漫特征页, 免版权, 线条清晰含皮肤区)。
  const w = 900, h = 1300;
  final source = makeMangaPageV2(
      width: w, height: h, seed: 41, brightness: 1.0);
  final srcPng = MangaImageIO.encodePng(rgb: source.rgb, width: w, height: h);
  File('${outDir.path}/00-original.png').writeAsBytesSync(srcPng);
  File('${outDir.path}/00-source-note.md').writeAsStringSync('''
# 选定漫画页来源说明

- 文件: 00-original.png (900×1300, PNG, 黑白线稿含人物皮肤区域)
- 来源: manga_colorizer_cli 内置日漫特征合成页 (makeMangaPageV2, seed=41)
- 选择理由: 免版权可公开交付; 含网点/灰阶渐变/发丝高光/速度线等日漫典型元素;
  确定性生成, 任意环境可逐字节重做 (回退重做基线)
- 原图完整性: 全流程只读, 所有输出写新文件
''');

  // 2) 载入 3 套多样性配色 (皮肤固定)。
  final archive = jsonDecode(File(parsed['palettes'] as String).readAsStringSync())
      as Map<String, Object?>;
  final variants = <CharacterPalette>[];
  for (final v in archive['variants'] as List) {
    final m = v as Map;
    variants.add(CharacterPalette.fromJson({
      'characterId': m['variantId'],
      'displayName': m['displayName'],
      'parts': m['parts'],
    }));
  }
  if (variants.isEmpty) {
    stderr.writeln('错误: 配色文件无 variants');
    exitCode = 64;
    return;
  }
  final skinHex = variants.first.partByRole('skin');
  // 皮肤固定性: 3 套配色的 skin 色值必须一致。
  for (final v in variants) {
    if (v.partByRole('skin').r != skinHex.r ||
        v.partByRole('skin').g != skinHex.g ||
        v.partByRole('skin').b != skinHex.b) {
      stderr.writeln('错误: ${v.characterId} 的肤色与主配色不一致');
      exitCode = 65;
      return;
    }
  }

  final slots = mangaPageV2Slots(w, h);
  final options = const ColorizeOptions(
      maxIterations: 600, descreen: true);
  final samplePoints = <String, List<(int, int)>>{};
  for (final s in slots) {
    (samplePoints[s.role] ??= []).add((s.x, s.y));
  }

  // 3) 逐变体上色。
  final review = <String, Object>{};
  final variantRows = <Map<String, Object>>[];
  final colored = <String, Uint8List>{};
  for (final palette in variants) {
    final hints = paletteToHints(palette, slots);
    final watch = Stopwatch()..start();
    final TiledColorizeResult result;
    if (w > 768 || h > 768) {
      result = await colorizeMangaTiledAsync(
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
    colored[palette.characterId] = result.rgb;
    File('${outDir.path}/10-${palette.characterId}.png').writeAsBytesSync(
        MangaImageIO.encodePng(rgb: result.rgb, width: w, height: h));

    // 校验 (肤色固定性 + 各部位色相)。
    final check = checkImageAgainstPalette(
        rgb: result.rgb,
        width: w,
        height: h,
        palette: palette,
        samplePoints: samplePoints,
        expectedLumaAt: (x, y) =>
            (0.299 * source.rgb[(y * w + x) * 3] +
                    0.587 * source.rgb[(y * w + x) * 3 + 1] +
                    0.114 * source.rgb[(y * w + x) * 3 + 2]) /
                255);
    // 墨线保留: 原稿墨线像素在成图中仍应为暗色 (亮度 < 0.2)。
    var inkTotal = 0;
    var inkDamaged = 0;
    for (var i = 0; i < w * h; i++) {
      final y0 = (0.299 * source.rgb[i * 3] +
              0.587 * source.rgb[i * 3 + 1] +
              0.114 * source.rgb[i * 3 + 2]) /
          255;
      if (y0 <= 0.12) {
        inkTotal++;
        final y1 = (0.299 * result.rgb[i * 3] +
                0.587 * result.rgb[i * 3 + 1] +
                0.114 * result.rgb[i * 3 + 2]) /
            255;
        if (y1 > 0.2) inkDamaged++;
      }
    }
    variantRows.add({
      'variant': palette.characterId,
      'ms': watch.elapsedMilliseconds,
      'tiles': result.tileCount,
      'check': check.toJson(),
      'inkPixels': inkTotal,
      'inkDamaged': inkDamaged,
      'elementColors': {
        for (final p in palette.parts) p.role: toHexColor(p.r, p.g, p.b),
      },
    });
    stdout.writeln(
        '[${palette.characterId}] ${watch.elapsedMilliseconds}ms inkDamaged=$inkDamaged/$inkTotal '
        'check=${check.pass ? "PASS" : "FAIL"}');
    if (!check.pass) {
      for (final f in check.failures) {
        stdout.writeln('  ✗ $f');
      }
    }
  }

  // 4) 四联对比 (原稿 | A | B | C)。
  const pad = 8;
  final totalW = w * 4 + pad * 5;
  final totalH = h + pad * 2;
  final sheet = Uint8List(totalW * totalH * 3);
  sheet.fillRange(0, sheet.length, 30);
  void blit(Uint8List src, int ox) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final si = ((pad + y) * totalW + (ox + x)) * 3;
        final pi = (y * w + x) * 3;
        sheet[si] = src[pi];
        sheet[si + 1] = src[pi + 1];
        sheet[si + 2] = src[pi + 2];
      }
    }
  }
  blit(source.rgb, pad);
  var ox = w + pad * 2;
  for (final v in variants) {
    blit(colored[v.characterId]!, ox);
    ox += w + pad;
  }
  File('${outDir.path}/20-compare-4up.png').writeAsBytesSync(
      MangaImageIO.encodePng(rgb: sheet, width: totalW, height: totalH));

  // 5) 皮肤固定性: 三变体同一槽位取中值色, 应完全一致。
  final skinChecks = <Map<String, Object>>[];
  int med(List<int> v) {
    v.sort();
    return v[v.length ~/ 2];
  }
  Uint8List sampleAt(Uint8List img, int x, int y) {
    final rs = <int>[], gs = <int>[], bs = <int>[];
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final sx = (x + dx).clamp(0, w - 1);
        final sy = (y + dy).clamp(0, h - 1);
        final i = (sy * w + sx) * 3;
        rs.add(img[i]);
        gs.add(img[i + 1]);
        bs.add(img[i + 2]);
      }
    }
    return Uint8List.fromList([med(rs), med(gs), med(bs)]);
  }
  final skinSlot = slots.firstWhere((s) => s.role == 'skin');
  final refSkin = sampleAt(colored[variants.first.characterId]!, skinSlot.x, skinSlot.y);
  for (final v in variants) {
    final s = sampleAt(colored[v.characterId]!, skinSlot.x, skinSlot.y);
    skinChecks.add({
      'variant': v.characterId,
      'sampled': toHexColor(s[0], s[1], s[2]),
      'matches': s[0] == refSkin[0] && s[1] == refSkin[1] && s[2] == refSkin[2],
    });
  }

  review['source'] = {
    'file': '00-original.png',
    'origin': 'makeMangaPageV2 seed=41 (免版权合成页, 确定性可重做)',
    'size': '$w x $h',
  };
  review['skinFixed'] = {
    'fixedHex': toHexColor(skinHex.r, skinHex.g, skinHex.b),
    'perVariant': skinChecks,
    'allMatch': skinChecks.every((c) => c['matches'] == true),
  };
  review['variants'] = variantRows;
  review['diversity'] = {
    'note': '非皮肤元素逐变体颜色清单见 variants[].elementColors; '
        '3 变体 × (发/服/巾) = 9 种互不相同的非皮肤配色',
    'distinctNonSkinColors':
        variants.expand((v) => v.parts.where((p) => p.role != 'skin')).map((p) => toHexColor(p.r, p.g, p.b)).toSet().length,
  };
  review['generatedAt'] = DateTime.now().toIso8601String();
  File('${outDir.path}/30-review.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(review));
  stdout.writeln(
      '核查记录: ${outDir.path}/30-review.json · 皮肤固定 allMatch=${review['skinFixed'] == null ? false : (review['skinFixed'] as Map)['allMatch']}');
}
