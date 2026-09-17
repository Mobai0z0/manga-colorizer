import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:manga_colorizer_cli/src/manga_page_v2.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 日漫精细上色逐页管线 (v0.5):
///
/// dart run colorize_fine --palette out/character_palettes.json \
///   --character akari --pages 10 --out-dir out/fine
///
/// 每页产出: 成图 PNG + 赛璐璐 4 层 RGBA PNG + 三联对比图 + 200% 放大复核图,
/// 台账 fine_ledger.json 记录每页状态/参数/版本。原稿参数确定性可复现。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('palette', defaultsTo: 'out/character_palettes.json')
    ..addOption('character', defaultsTo: 'akari')
    ..addOption('pages', defaultsTo: '10')
    ..addOption('out-dir', defaultsTo: 'out/fine')
    ..addOption('options', help: '算法参数 JSON (可省)')
    ..addFlag('sample-only', abbr: 's', negatable: false, help: '只出前 2 页样张')
    ..addFlag('no-descreen', negatable: false, help: '关闭网点去噪 (对比用)')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  final outDir = Directory(parsed['out-dir'] as String);
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final layersDir = Directory('${outDir.path}/layers');
  if (!layersDir.existsSync()) layersDir.createSync(recursive: true);
  final compareDir = Directory('${outDir.path}/compare');
  if (!compareDir.existsSync()) compareDir.createSync(recursive: true);

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
  // 色板自检 (肤色常识)。
  for (final part in palette.parts) {
    if (part.role == 'skin' && !isNaturalSkinRgb(part.r, part.g, part.b)) {
      stderr.writeln('错误: 肤色 ${toHexColor(part.r, part.g, part.b)} 不在自然扇区');
      exitCode = 65;
      return;
    }
  }

  final pages = int.parse(parsed['pages'] as String);
  final sampleOnly = parsed['sample-only'] as bool;
  final descreen = !(parsed['no-descreen'] as bool);
  final options = _parseOptions(parsed['options'] as String?) ??
      const ColorizeOptions(
          maxIterations: 600, descreen: true);
  final effective =
      descreen ? options : _copyWithDescreen(options, false);
  final version = 'v0.5-descreen${effective.descreen ? 'on' : 'off'}';

  final ledger = <Map<String, Object>>[];
  var failures = 0;
  final pageIds = [for (var i = 1; i <= pages; i++) 'p${i.toString().padLeft(2, '0')}'];
  for (var i = 0; i < pageIds.length; i++) {
    final id = pageIds[i];
    final entry = <String, Object>{
      'page': id,
      'version': version,
      'palette': palette.characterId,
    };
    try {
      final w = 900;
      final h = 1300;
      final source = makeMangaPageV2(
          width: w,
          height: h,
          seed: 31 + i,
          brightness: (i % 3 == 1) ? 0.85 : 1.0,
          screentone: true,
          gradientBg: true);
      final slots = mangaPageV2Slots(w, h);
      final hints = paletteToHints(palette, slots);

      final watch = Stopwatch()..start();
      final TiledColorizeResult result;
      if (w > 768 || h > 768) {
        result = await colorizeMangaTiledAsync(
            grayscaleRgb: source.rgb,
            width: w,
            height: h,
            hints: hints,
            options: effective,
            tileSize: 512,
            overlap: 64);
      } else {
        final r = colorizeManga(
            grayscaleRgb: source.rgb,
            width: w,
            height: h,
            hints: hints,
            options: effective);
        result = TiledColorizeResult(w, h, r.rgb, 1, 512, 64);
      }
      watch.stop();

      // 赛璐璐分层。
      final layers = decomposeCelLayers(
          result.rgb, source.rgb, w, h);
      void writeLayer(String name, Uint8List rgba) {
        File('${layersDir.path}/$id-$name.png').writeAsBytesSync(
            MangaImageIO.encodePngRgba(rgba, w, h));
      }
      writeLayer('flat', layers.flat);
      writeLayer('shadow', layers.shadow);
      writeLayer('highlight', layers.highlight);
      writeLayer('line', layers.line);

      // 成图。
      File('${outDir.path}/$id.png').writeAsBytesSync(
          MangaImageIO.encodePng(rgb: result.rgb, width: w, height: h));

      // 三联对比 (原稿|成图|放大复核) + 200% 放大图 (头发/脸部区)。
      const pad = 6;
      final zoom = _zoom2x(source.rgb, result.rgb, w, h,
          (w * 0.36).round(), (h * 0.33).round(), 120);
      File('${compareDir.path}/$id-zoom200.png').writeAsBytesSync(
          MangaImageIO.encodePng(
              rgb: zoom,
              width: 240 * 2 + 6 * 3,
              height: 240 + 6 * 2));
      final sheet = _twoPanel(source.rgb, result.rgb, w, h, pad);
      File('${compareDir.path}/$id-compare.png').writeAsBytesSync(
          MangaImageIO.encodePng(
              rgb: sheet, width: w * 2 + pad * 3, height: h + pad * 2));

      // 校验。
      final samplePoints = <String, List<(int, int)>>{};
      for (final s in slots) {
        (samplePoints[s.role] ??= []).add((s.x, s.y));
      }
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

      entry['status'] = check.pass ? 'success' : 'need-confirm';
      entry['ms'] = watch.elapsedMilliseconds;
      entry['tiles'] = result.tileCount;
      entry['descreen'] = effective.descreen;
      entry['check'] = check.toJson();
      if (!check.pass) failures++;
      stdout.writeln(
          '[$id] ${check.pass ? "OK" : "NEED-CONFIRM"} ${watch.elapsedMilliseconds}ms tiles=${result.tileCount}');
    } catch (e) {
      failures++;
      entry['status'] = 'failed';
      entry['error'] = e.toString();
      stderr.writeln('[$id] 失败: $e');
    }
    ledger.add(entry);
  }

  File('${outDir.path}/fine_ledger.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'version': version,
        'palette': palette.characterId,
        'pages': pages,
        'sampleOnly': sampleOnly,
        'failures': failures,
        'ledger': ledger,
        'generatedAt': DateTime.now().toIso8601String(),
      }));
  stdout.writeln(
      '完成: ${pages - failures}/$pages 成功, 台账 ${outDir.path}/fine_ledger.json');
  exitCode = failures > 0 ? 70 : 0;
}

ColorizeOptions? _parseOptions(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final text = File(raw).existsSync() ? File(raw).readAsStringSync() : raw;
  return ColorizeOptions.fromJson(jsonDecode(text) as Object?);
}

ColorizeOptions _copyWithDescreen(ColorizeOptions o, bool v) => ColorizeOptions(
      sigma: o.sigma,
      epsilon: o.epsilon,
      maxIterations: o.maxIterations,
      sorOmega: o.sorOmega,
      tolerance: o.tolerance,
      lockPureMonochrome: o.lockPureMonochrome,
      adaptHintChromaToLuminance: o.adaptHintChromaToLuminance,
      regionChromaCorrection: o.regionChromaCorrection,
      chromaMagnitudeGain: o.chromaMagnitudeGain,
      hueCorrectionStrength: o.hueCorrectionStrength,
      regionLuminanceWeight: o.regionLuminanceWeight,
      enforceNaturalSkin: o.enforceNaturalSkin,
      descreen: v,
      monochromeLowThreshold: o.monochromeLowThreshold,
      monochromeHighThreshold: o.monochromeHighThreshold,
    );

/// 从原稿/成图各裁 (cx,cy) 处 120×120, 放大 2×, 并排。
Uint8List _zoom2x(Uint8List gray, Uint8List color, int w, int h, int cx, int cy,
    int half) {
  const out2 = 240;
  final zoomedA = Uint8List(out2 * out2 * 3);
  final zoomedB = Uint8List(out2 * out2 * 3);
  void zoomInto(Uint8List src, Uint8List dst) {
    for (var y = 0; y < out2; y++) {
      final sy = (cy - half + y ~/ 2).clamp(0, h - 1);
      for (var x = 0; x < out2; x++) {
        final sx = (cx - half + x ~/ 2).clamp(0, w - 1);
        final si = (sy * w + sx) * 3;
        final di = (y * out2 + x) * 3;
        dst[di] = src[si];
        dst[di + 1] = src[si + 1];
        dst[di + 2] = src[si + 2];
      }
    }
  }
  zoomInto(gray, zoomedA);
  zoomInto(color, zoomedB);
  const pad = 6;
  final totalW = out2 * 2 + pad * 3;
  final totalH = out2 + pad * 2;
  final out = Uint8List(totalW * totalH * 3);
  out.fillRange(0, out.length, 28);
  void blit(Uint8List p, int ox, int oy) {
    for (var y = 0; y < out2; y++) {
      for (var x = 0; x < out2; x++) {
        final si = (y * out2 + x) * 3;
        final di = ((oy + y) * totalW + (ox + x)) * 3;
        out[di] = p[si];
        out[di + 1] = p[si + 1];
        out[di + 2] = p[si + 2];
      }
    }
  }
  blit(zoomedA, pad, pad);
  blit(zoomedB, out2 + pad * 2, pad);
  return out;
}

Uint8List _twoPanel(Uint8List a, Uint8List b, int w, int h, int pad) {
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
  blit(a, pad);
  blit(b, w + pad * 2);
  return out;
}
