import 'dart:io';

import 'package:args/args.dart';
import 'package:manga_colorizer_cli/src/cli_io.dart';
import 'package:manga_colorizer_cli/src/sample_page.dart';

/// 生成一张自绘日漫风格示例页（墨线 + 网点 + 速度线），供无原稿时试用/回归。
/// 用法见 --help。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('output', abbr: 'o', defaultsTo: 'sample_manga.png', help: '输出 PNG 路径')
    ..addOption('width', defaultsTo: '512', help: '画布宽')
    ..addOption('height', defaultsTo: '640', help: '画布高')
    ..addOption('seed', defaultsTo: '7', help: '随机种子 (速度线布局)')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln('用法: dart run make_sample [-o 输出.png] [--width N] [--height N]');
    stdout.writeln(parser.usage);
    return;
  }
  final width = int.tryParse(parsed['width'] as String);
  final height = int.tryParse(parsed['height'] as String);
  final seed = int.tryParse(parsed['seed'] as String);
  if (width == null || width < 64 || width > 4096 || height == null || height < 64 || height > 4096) {
    stderr.writeln('错误: width/height 必须在 64..4096');
    exitCode = 64;
    return;
  }
  final sample = makeSampleManga(
      width: width, height: height, seed: seed ?? 7);
  CliIo.writePng(parsed['output'] as String, sample.rgb, sample.width, sample.height);
  stdout.writeln('已生成合成样例: ${parsed['output']} (${width}x${height})');
  stdout.writeln('推荐提示点槽位 (配合 colorize-palette 的角色色板使用):');
  stdout.writeln('  ${[
    for (final s in recommendedSampleSlots(width, height))
      {'role': s.role, 'x': s.x, 'y': s.y}
  ]}');
}
