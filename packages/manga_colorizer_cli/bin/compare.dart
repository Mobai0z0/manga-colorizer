import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

import 'package:manga_colorizer_cli/src/cli_io.dart';

/// 生成 原稿 | 提示点 | 上色结果 三联对比图。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('input', abbr: 'i', mandatory: true, help: '输入黑白漫画图片')
    ..addOption('output', abbr: 'o', mandatory: true, help: '输出对比图 PNG')
    ..addOption('output-colorized', help: '同时单独输出上色结果 PNG')
    ..addOption('hints', mandatory: true, help: '提示点 JSON (内联或文件)')
    ..addOption('options', help: '算法参数 JSON')
    ..addOption('padding', defaultsTo: '12', help: '面板间距')
    ..addOption('label-height', defaultsTo: '34', help: '标签栏高度')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln('用法: dart run compare -i 原稿.png -o 对比图.png --hints "[...]"');
    stdout.writeln(parser.usage);
    return;
  }

  final source = CliIo.readGrayscale(parsed['input'] as String);
  final hints = _parseHints(parsed['hints'] as String, source.width, source.height);
  if (hints.isEmpty) {
    stderr.writeln('错误: 至少需要 1 个提示点');
    exitCode = 64;
    return;
  }
  final options = _parseOptions(parsed['options'] as String?);

  // 1) 上色。
  final result = colorizeManga(
    grayscaleRgb: source.rgb,
    width: source.width,
    height: source.height,
    hints: hints,
    options: options,
  );
  stdout.writeln(
      '上色: 迭代 ${result.iterations} 次, 收敛残差 ${result.maxDelta.toStringAsFixed(6)}, '
      '提示点 ${result.hintCount}, 锁定黑白像素 ${result.lockedMonochromeCount}');
  if (parsed['output-colorized'] != null) {
    CliIo.writePng(
        parsed['output-colorized'] as String, result.rgb, result.width, result.height);
    stdout.writeln('已写入上色结果: ${parsed['output-colorized']}');
  }

  // 2) 拼三联图: 原稿(灰度) | 原稿+提示点 | 上色结果。
  final panelW = source.width;
  final panelH = source.height;
  final pad = int.parse(parsed['padding'] as String);
  final labelH = int.parse(parsed['label-height'] as String);
  final totalW = panelW * 3 + pad * 4;
  final totalH = panelH + labelH + pad * 2;
  final sheet = Uint8List(totalW * totalH * 3);
  void fillAll(int v) {
    for (var i = 0; i < sheet.length; i++) {
      sheet[i] = v;
    }
  }

  void blit(Uint8List rgb, int ox, int oy) {
    for (var y = 0; y < panelH; y++) {
      for (var x = 0; x < panelW; x++) {
        final si = ((oy + y) * totalW + (ox + x)) * 3;
        final pi = (y * panelW + x) * 3;
        sheet[si] = rgb[pi];
        sheet[si + 1] = rgb[pi + 1];
        sheet[si + 2] = rgb[pi + 2];
      }
    }
  }

  fillAll(28); // 深色底。
  blit(source.rgb, pad, pad + labelH);
  blit(
      drawHintMarkers(
          rgb: source.rgb, width: panelW, height: panelH, hints: hints),
      panelW + pad * 2,
      pad + labelH);
  blit(result.rgb, (panelW + pad) * 2 + pad, pad + labelH);
  _drawLabels(sheet, totalW, totalH, pad, labelH, ['原稿', '提示点', '上色结果']);

  CliIo.writePng(parsed['output'] as String, sheet, totalW, totalH);
  stdout.writeln(
      '已写入对比图: ${parsed['output']} (${totalW}x${totalH}, 面板 $panelW x $panelH x3)');
}

void _drawLabels(
    Uint8List sheet, int totalW, int totalH, int pad, int labelH, List<String> labels) {
  // 5x7 像素点阵字体 (仅本图需要的汉字/字母以极简笔画近似:
  // 直接用绘制函数画简笔标记 + 文本说明由交付文档承载)。
  // 这里绘制每个面板顶部的小色块编号,文字标签在 HTML 报告中呈现。
  final panelW = (totalW - pad * 4) ~/ 3;
  final colors = [
    [200, 200, 200],
    [230, 176, 60],
    [86, 156, 214],
  ];
  for (var p = 0; p < 3; p++) {
    final ox = p == 0 ? pad : (panelW + pad) * p + pad;
    for (var y = pad + 6; y < pad + labelH - 8; y++) {
      for (var x = ox; x < ox + 18; x++) {
        final i = (y * totalW + x) * 3;
        sheet[i] = colors[p][0];
        sheet[i + 1] = colors[p][1];
        sheet[i + 2] = colors[p][2];
      }
    }
  }
}

List<ColorHint> _parseHints(String raw, int width, int height) {
  final text = File(raw).existsSync() ? File(raw).readAsStringSync() : raw;
  final decoded = _decodeJson(text, 'hints');
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
        throw FormatException('坐标 (${hint.x},${hint.y}) 超出图像 ${width}x$height');
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

ColorizeOptions _parseOptions(String? raw) {
  if (raw == null || raw.isEmpty) return const ColorizeOptions();
  final text = File(raw).existsSync() ? File(raw).readAsStringSync() : raw;
  final decoded = _decodeJson(text, 'options');
  return ColorizeOptions.fromJson(decoded);
}

Object? _decodeJson(String text, String what) {
  try {
    return jsonDecode(text) as Object?;
  } on FormatException catch (e) {
    stderr.writeln('错误: $what JSON 解析失败: ${e.message}');
    exitCode = 64;
    rethrow;
  }
}
