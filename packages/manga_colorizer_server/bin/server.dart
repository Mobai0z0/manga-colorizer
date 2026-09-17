import 'dart:io';

import 'package:args/args.dart';
import 'package:manga_colorizer_server/manga_colorizer_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8787', help: '监听端口')
    ..addOption('host', defaultsTo: '127.0.0.1', help: '监听地址')
    ..addOption('demo-root',
        help: '演示页静态目录 (默认使用包内 demo/)')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final port = int.tryParse(parsed['port'] as String);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('错误: --port 必须是 1..65535 的整数');
    exitCode = 64;
    return;
  }
  final host = parsed['host'] as String;
  final demoRoot = (parsed['demo-root'] as String?) ??
      _defaultDemoRoot();

  final handler = buildApp(demoRoot: demoRoot);
  final server = await shelf_io.serve(handler, host, port);
  stdout.writeln('manga-colorizer 后端已启动: http://$host:${server.port}');
  stdout.writeln('  健康检查:  http://$host:${server.port}/api/health');
  stdout.writeln('  上色 API:  POST http://$host:${server.port}/api/colorize');
  stdout.writeln('  色调 API:  POST http://$host:${server.port}/api/tint');
  if (demoRoot != null) {
    stdout.writeln('  演示页:    http://$host:${server.port}/');
  }
  stdout.writeln('Ctrl+C 停止。');
}

String? _defaultDemoRoot() {
  // 先找包内 demo 目录 (运行于源码仓库时),找不到则不挂演示页。
  final candidates = [
    Directory('demo'),
    Directory('../manga_colorizer_server/demo'),
    Directory('packages/manga_colorizer_server/demo'),
  ];
  for (final dir in candidates) {
    if (dir.existsSync()) return dir.path;
  }
  return null;
}
