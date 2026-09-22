import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

import 'package:manga_colorizer_cli/src/cli_io.dart';

/// CLI 主入口: 提示点/预设/调色板驱动的漫画上色。
/// 用法见 --help。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('input', abbr: 'i', mandatory: true, help: '输入黑白漫画图片')
    ..addOption('output', abbr: 'o', mandatory: true, help: '输出 PNG 路径')
    ..addOption('hints', help: '提示点 JSON 数组文件路径或内联 JSON')
    ..addOption('preset', help: '整图色调预设: sepia | warm-dawn | moonlit')
    ..addOption('palette', help: '自定义调色板 JSON (优先于 preset)')
    ..addOption('options', help: '算法参数 JSON (sigma/maxIterations 等)')
    ..addFlag('show-hints', negatable: false, help: '输出图上叠加提示点标记')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln('用法: dart run colorize -i <输入图> -o <输出图> [提示点/预设参数]');
    stdout.writeln(parser.usage);
    return;
  }

  final source = CliIo.readGrayscale(parsed['input'] as String);
  final hints = _parseHints(parsed['hints'] as String?, source.width, source.height);
  final preset = parsed['preset'] as String?;
  final paletteRaw = parsed['palette'] as String?;
  final optionsRaw = parsed['options'] as String?;
  final watch = Stopwatch()..start();

  if (paletteRaw != null || preset != null) {
    final palette = _resolvePalette(paletteRaw, preset);
    final tintOptions = _parseJson(
        optionsRaw, (json) => TintOptions.fromJson(json), const TintOptions());
    final rgb = applyTint(
      grayscaleRgb: source.rgb,
      width: source.width,
      height: source.height,
      palette: palette,
      options: tintOptions,
    );
    _writeOutput(parsed['output'] as String, rgb, source, hints,
        showHints: parsed['show-hints'] as bool, timing: watch.elapsedMilliseconds);
    return;
  }

  if (hints.isEmpty) {
    stderr.writeln('错误: 需要提供 --hints (提示点扩散上色) 或 --preset/--palette (整图色调)');
    exitCode = 64;
    return;
  }
  final options = _parseJson(
      optionsRaw, (json) => ColorizeOptions.fromJson(json), const ColorizeOptions());
  final result = colorizeManga(
    grayscaleRgb: source.rgb,
    width: source.width,
    height: source.height,
    hints: hints,
    options: options,
  );
  final rgb = parsed['show-hints'] as bool
      ? drawHintMarkers(
          rgb: result.rgb,
          width: result.width,
          height: result.height,
          hints: hints)
      : result.rgb;
  _writeOutput(parsed['output'] as String, rgb, source, hints,
      showHints: parsed['show-hints'] as bool, timing: watch.elapsedMilliseconds);
  stdout.writeln(
      '上色完成: 迭代 ${result.iterations} 次, 收敛残差 ${result.maxDelta.toStringAsFixed(6)}');
}

void _writeOutput(String path, Uint8List rgb, DecodedImage source,
    List<ColorHint> hints,
    {required bool showHints, required int timing}) {
  CliIo.writePng(path, rgb, source.width, source.height);
  stdout.writeln('已写入 $path (${source.width}x${source.height}, 耗时 ${timing}ms)');
}

List<ColorHint> _parseHints(String? raw, int width, int height) {
  if (raw == null || raw.isEmpty) return const [];
  final decoded = _readJsonArgument(raw);
  if (decoded is! List) {
    stderr.writeln('错误: hints 必须是 JSON 数组');
    exitCode = 64;
    throw StateError('bad hints');
  }
  final hints = <ColorHint>[];
  for (var i = 0; i < decoded.length; i++) {
    try {
      final hint = ColorHint.fromJson(decoded[i]);
      if (hint.x >= width || hint.y >= height) {
        throw FormatException(
            '坐标 (${hint.x},${hint.y}) 超出图像 ${width}x$height');
      }
      hints.add(hint);
    } on FormatException catch (e) {
      stderr.writeln('错误: hints[$i] 无效: ${e.message}');
      exitCode = 64;
      rethrow;
    }
  }
  return hints;
}

List<TintStop> _resolvePalette(String? paletteRaw, String? preset) {
  if (paletteRaw != null && paletteRaw.isNotEmpty) {
    final decoded = _readJsonArgument(paletteRaw);
    if (decoded is! List) {
      stderr.writeln('错误: palette 必须是 JSON 数组');
      exitCode = 64;
      throw StateError('bad palette');
    }
    return decoded.map((e) => TintStop.fromJson(e)).toList();
  }
  if (preset != null && preset.isNotEmpty) {
    final palette = kTintPresets[preset];
    if (palette == null) {
      stderr.writeln('错误: 未知 preset "$preset",可用: ${kTintPresets.keys.join(", ")}');
      exitCode = 64;
      throw StateError('bad preset');
    }
    return palette;
  }
  stderr.writeln('错误: 需要 --preset 或 --palette');
  exitCode = 64;
  throw StateError('missing palette');
}

T _parseJson<T>(String? raw, T Function(Object?) fromJson, T fallback) {
  if (raw == null || raw.isEmpty) return fallback;
  final decoded = _readJsonArgument(raw);
  return fromJson(decoded);
}

Object? _readJsonArgument(String raw) {
  final text = File(raw).existsSync() ? File(raw).readAsStringSync() : raw;
  try {
    return jsonDecode(text) as Object?;
  } on FormatException catch (e) {
    stderr.writeln('错误: JSON 解析失败: ${e.message}');
    exitCode = 64;
    rethrow;
  }
}
