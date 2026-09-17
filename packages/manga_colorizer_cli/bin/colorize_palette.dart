import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:manga_colorizer_cli/src/sample_page.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 色板驱动上色 + 一致性校验:
///
/// dart run colorize_palette --palette characters.json --character akari \
///   --scene single --out-dir out
///
/// scene: single(单人日常) | single-dim(单人暗光 0.8) | duo(双人同框)
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('palette', mandatory: true, help: '色板档案 JSON (含 characters 数组)')
    ..addOption('character', mandatory: true, help: '角色 characterId')
    ..addOption('scene', defaultsTo: 'single', help: 'single | single-dim | duo')
    ..addOption('out-dir', defaultsTo: 'out', help: '输出目录')
    ..addOption('options', help: '算法参数 JSON (可省)')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  final outDir = Directory(parsed['out-dir'] as String);
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  // 1) 载入色板档案。
  final archiveText = File(parsed['palette'] as String).readAsStringSync();
  final archive = jsonDecode(archiveText) as Object?;
  if (archive is! Map || archive['characters'] is! List) {
    stderr.writeln('错误: 色板档案需要 {"characters": [...]}');
    exitCode = 64;
    return;
  }
  CharacterPalette? palette;
  for (final entry in (archive['characters'] as List)) {
    final p = CharacterPalette.fromJson(entry);
    if (p.characterId == parsed['character']) palette = p;
  }
  if (palette == null) {
    stderr.writeln('错误: 找不到角色 ${parsed['character']}');
    exitCode = 66;
    return;
  }

  // 2) 色板自检: 肤色条目必须落在自然肤色扇区。
  final skinPart = palette.parts.where((p) => p.role == 'skin').toList();
  for (final part in skinPart) {
    if (!isNaturalSkinRgb(part.r, part.g, part.b)) {
      stderr.writeln(
          '错误: 角色 ${palette.characterId} 的肤色 ${toHexColor(part.r, part.g, part.b)} 不在自然肤色扇区');
      exitCode = 65;
      return;
    }
  }

  // 3) 生成场景与槽位。
  final scene = parsed['scene'] as String;
  final DecodedImage source;
  final List<(CharacterPalette, List<HintSlot>)> plan;
  switch (scene) {
    case 'single':
      source = makeSampleManga();
      plan = [(palette, recommendedSampleSlots(source.width, source.height))];
    case 'single-dim':
      source = makeSampleManga(brightness: 0.8);
      plan = [(palette, recommendedSampleSlots(source.width, source.height))];
    case 'duo':
      source = makeSceneTwoCharacters();
      final otherId = palette.characterId == 'akari' ? 'ren' : 'akari';
      CharacterPalette? other;
      for (final entry in (archive['characters'] as List)) {
        final p = CharacterPalette.fromJson(entry);
        if (p.characterId == otherId) other = p;
      }
      if (other == null) {
        stderr.writeln('错误: duo 场景还需要角色 $otherId 在色板档案中');
        exitCode = 66;
        return;
      }
      plan = [
        (palette, sceneTwoSlotsA(source.width, source.height)),
        (other, sceneTwoSlotsB(source.width, source.height)),
      ];
    default:
      stderr.writeln('错误: 未知场景 $scene');
      exitCode = 64;
      return;
  }

  // 4) 合并提示点 (颜色严格取自各自色板)。
  final hints = <ColorHint>[];
  for (final (p, slots) in plan) {
    hints.addAll(paletteToHints(p, slots));
  }
  final options = _parseOptions(parsed['options'] as String?);
  final watch = Stopwatch()..start();
  final result = colorizeManga(
    grayscaleRgb: source.rgb,
    width: source.width,
    height: source.height,
    hints: hints,
    options: options,
  );
  watch.stop();

  // 5) 写成图 (区分版本目录,支持回滚)。
  final tag = '${parsed['character']}-$scene';
  final png = MangaImageIO.encodePng(
      rgb: result.rgb, width: result.width, height: result.height);
  final outFile = File('${outDir.path}/$tag.png');
  outFile.writeAsBytesSync(png);
  stdout.writeln(
      '成图: ${outFile.path} (${result.width}x${result.height}, ${watch.elapsedMilliseconds}ms, 提示点 ${hints.length})');

  // 6) 校验: 每个角色的槽位即取样点。
  final report = <String, Object>{};
  var allPass = true;
  for (final (p, slots) in plan) {
    final samplePoints = <String, List<(int, int)>>{};
    for (final s in slots) {
      (samplePoints[s.role] ??= []).add((s.x, s.y));
    }
    final check = checkImageAgainstPalette(
      rgb: result.rgb,
      width: result.width,
      height: result.height,
      palette: p,
      samplePoints: samplePoints,
      // 亮度保留策略: 成图亮度应贴合原稿 (线稿/环境光),色相才是色板契约。
      expectedLumaAt: (x, y) =>
          (0.299 * source.rgb[(y * source.width + x) * 3] +
                  0.587 * source.rgb[(y * source.width + x) * 3 + 1] +
                  0.114 * source.rgb[(y * source.width + x) * 3 + 2]) /
              255,
    );
    report[p.characterId] = check.toJson();
    if (!check.pass) allPass = false;
  }
  report['scene'] = scene;
  report['allPass'] = allPass;
  final reportFile = File('${outDir.path}/$tag-check.json');
  reportFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('校验: ${reportFile.path} → ${allPass ? "PASS" : "FAIL"}');
  if (!allPass) {
    for (final (p, _) in plan) {
      final r = report[p.characterId] as Map<String, Object>;
      for (final f in (r['failures'] as List)) {
        stdout.writeln('  ✗ $f');
      }
    }
    exitCode = 70;
  }
}

ColorizeOptions _parseOptions(String? raw) {
  if (raw == null || raw.isEmpty) return const ColorizeOptions();
  final text = File(raw).existsSync() ? File(raw).readAsStringSync() : raw;
  return ColorizeOptions.fromJson(jsonDecode(text) as Object?);
}
