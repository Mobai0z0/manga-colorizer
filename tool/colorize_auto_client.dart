/// Dart 客户端: 调用 Python 模型服务的 /colorize_auto 端点。
/// 用法: dart run tool/colorize_backend.dart -i <输入> -o <输出> [--infer-size 768]
/// 服务启动: python -m uvicorn tool.colorizer_service.service:app --port 8788
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

Future<void> main(List<String> args) async {
  String? input, output;
  var inferSize = 768;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-i':
        input = args[++i];
      case '-o':
        output = args[++i];
      case '--infer-size':
        inferSize = int.parse(args[++i]);
      default:
        stderr.writeln('未知参数: ${args[i]}');
        exitCode = 64;
        return;
    }
  }
  if (input == null || output == null) {
    stderr.writeln('用法: dart run tool/colorize_auto_client.dart -i 输入 -o 输出 [--infer-size 768]');
    exitCode = 64;
    return;
  }

  final watch = Stopwatch()..start();
  final uri = Uri.parse('http://127.0.0.1:8788/colorize_auto');
  final request = http.MultipartRequest('POST', uri)
    ..files.add(await http.MultipartFile.fromPath('image', input))
    ..fields['infer_size'] = '$inferSize';
  final streamed = await request.send().timeout(const Duration(minutes: 10));
  final body = await streamed.stream.toBytes();
  if (streamed.statusCode != 200) {
    stderr.writeln('服务错误 ${streamed.statusCode}: ${utf8.decode(body, allowMalformed: true)}');
    exitCode = 70;
    return;
  }
  // 服务直接返回 image/png 二进制 (FastAPI Response)
  final contentType = streamed.headers['content-type'] ?? '';
  if (!contentType.contains('image/png')) {
    stderr.writeln('意外的响应类型: $contentType');
    exitCode = 70;
    return;
  }
  final png = body;
  File(output).writeAsBytesSync(png);
  // 本地计算亮度保真
  final orig = img.decodePng(File(input).readAsBytesSync())!;
  final colored = img.decodePng(png)!;
  var kept = 0;
  final n = orig.width * orig.height;
  for (var i = 0; i < n; i++) {
    final o = orig.getPixel(i % orig.width, i ~/ orig.width);
    final c = colored.getPixel(i % colored.width, i ~/ colored.width);
    final y0 = 0.299 * o.r + 0.587 * o.g + 0.114 * o.b;
    final y1 = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    if ((y1 - y0).abs() < 0.5) kept++;
  }
  stdout.writeln('完成: ${watch.elapsedMilliseconds}ms, '
      '亮度保持 ${(100 * kept / n).toStringAsFixed(1)}%, 输出 $output');
}
