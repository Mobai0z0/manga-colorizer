import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';

/// 本地回环 mock 服务器对 Range 请求的响应策略。
enum _Mode {
  /// 支持 Range：带 Range 回 206（仅发余下字节），不带回 200 全量（真实服务器行为）。
  range206,

  /// 忽略 Range：任何请求都回 200 全量。
  refuseRange200,

  /// Range 一律回 416 Requested Range Not Satisfiable。
  refuseRange416,
}

void main() {
  late Uint8List payload;
  late String sha;
  late HttpServer server;
  late List<String?> ranges; // 服务端依次收到的 Range 头（null = 无该头）
  late _Mode mode;
  late Directory dir;
  late WeightFile f;

  setUp(() async {
    payload = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    sha = sha256.convert(payload).toString();
    ranges = <String?>[];
    mode = _Mode.range206;
    dir = await Directory.systemTemp.createTemp('weights');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)').firstMatch(range)!.group(1)!);
      if (range != null && mode == _Mode.refuseRange200) {
        req.response.statusCode = HttpStatus.ok;
        req.response.add(payload);
      } else if (range != null && mode == _Mode.refuseRange416) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */${payload.length}');
      } else if (range != null) {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-${payload.length - 1}/${payload.length}');
        req.response.add(payload.sublist(start));
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.add(payload);
      }
      await req.response.close();
    });
    f = WeightFile(
        name: 'gen.onnx',
        size: payload.length,
        sha256: sha,
        url: 'http://127.0.0.1:${server.port}/gen.onnx',
        mirrorUrl: 'http://127.0.0.1:${server.port}/gen.onnx');
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (_) {
      // Windows 上句柄可能尚未释放，清理失败不影响断言。
    }
  });

  WeightsStore store() => WeightsStore(dir: dir, mirrorPreferred: (_) => false);
  File partFile() => File('${dir.path}/gen.onnx.part');
  File finalFile() => File(store().pathOf(f));

  test('两段续传：真实 400 字节前缀 + 206 追加，字节级复原', () async {
    await partFile().writeAsBytes(payload.sublist(0, 400));
    await store().download(f);
    expect(ranges, ['bytes=400-'], reason: '只应发一次 Range 续传请求，不得整段重来');
    expect(finalFile().readAsBytesSync(), payload);
    expect(partFile().existsSync(), isFalse);
    expect(store().readyFor(f), isTrue);
  });

  test('服务端忽略 Range 回 200：整段重写并校验', () async {
    mode = _Mode.refuseRange200;
    await partFile().writeAsBytes(payload.sublist(0, 400));
    await store().download(f);
    expect(ranges, ['bytes=400-']);
    expect(finalFile().readAsBytesSync(), payload);
    expect(partFile().existsSync(), isFalse);
  });

  test('完整大小的 .part（内容正确）：直接校验晋升，不发任何请求', () async {
    // 模拟进程在写完最后一字节后、流式哈希完成前被杀死。
    await partFile().writeAsBytes(payload);
    await store().download(f);
    expect(ranges, isEmpty);
    expect(finalFile().readAsBytesSync(), payload);
    expect(partFile().existsSync(), isFalse);
    expect(store().readyFor(f), isTrue);
  });

  test('完整大小的 .part（内容错误）+ 416：不卡死，整段重下', () async {
    mode = _Mode.refuseRange416;
    await partFile().writeAsBytes(Uint8List(payload.length)); // 大小对、sha 错
    await store().download(f);
    expect(ranges, ['bytes=1000-', null]);
    expect(finalFile().readAsBytesSync(), payload);
    expect(partFile().existsSync(), isFalse);
  });

  test('416 不卡死：失效 offset 被丢弃后整段重来', () async {
    mode = _Mode.refuseRange416;
    await partFile().writeAsBytes(payload.sublist(0, 400));
    await store().download(f);
    expect(ranges, ['bytes=400-', null]);
    expect(finalFile().readAsBytesSync(), payload);
    expect(partFile().existsSync(), isFalse);
  });

  test('传输中断：抛 WeightsException 且 .part 原样可续传', () async {
    // 裸 loopback socket：先回真实的 200 头（声明全量 content-length），只发
    // 300 字节就正常关闭连接（FIN），客户端在流中途得到传输层错误——手机弱网
    // 断连的忠实模拟（HttpServer 会补全 chunked 收尾，无法制造这种中断）。
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sub = raw.listen((socket) async {
      socket.add(utf8.encode(
          'HTTP/1.1 200 OK\r\ncontent-length: ${payload.length}\r\n\r\n'));
      socket.add(payload.sublist(0, 300));
      await socket.flush(); // 数据已交予内核后再关闭 → 客户端先拿到 300 字节
      await socket.close();
    });
    final flaky = WeightFile(
        name: 'gen.onnx',
        size: payload.length,
        sha256: sha,
        url: 'http://127.0.0.1:${raw.port}/gen.onnx',
        mirrorUrl: 'http://127.0.0.1:${raw.port}/gen.onnx');
    await expectLater(
        store().download(flaky),
        throwsA(isA<WeightsException>()
            .having((e) => e.message, 'message', contains('gen.onnx'))));
    await sub.cancel();
    await raw.close();
    expect(partFile().existsSync(), isTrue, reason: '.part 必须保留以便续传');
    expect(partFile().lengthSync(), 300);
    // 换回正常 mock：从 300 处续传，恰好一次请求完成。
    await store().download(f);
    expect(ranges, ['bytes=300-']);
    expect(finalFile().readAsBytesSync(), payload);
    expect(partFile().existsSync(), isFalse);
  });

  test('sha256 不符：删除 .part 并抛 WeightsException', () async {
    final bad = WeightFile(
        name: 'gen.onnx',
        size: payload.length,
        sha256: '0' * 64,
        url: f.url,
        mirrorUrl: f.mirrorUrl);
    await expectLater(store().download(bad), throwsA(isA<WeightsException>()));
    expect(partFile().existsSync(), isFalse);
  });
}
