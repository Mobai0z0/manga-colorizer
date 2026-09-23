import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';

void main() {
  late HttpServer server;
  late Uint8List payload;
  late String sha;
  var hits = 0;
  setUp(() async {
    payload = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    sha = sha256.convert(payload).toString();
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits++;
      final range = req.headers.value('range');
      final start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)').firstMatch(range)!.group(1)!);
      if (range != null && hits == 1) {
        // 首次续传请求直接拒绝 → 应整段回 200
        req.response.statusCode = HttpStatus.ok;
        req.response.add(payload);
      } else {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-${payload.length - 1}/${payload.length}');
        req.response.add(payload.sublist(start));
      }
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('download with resume + sha256 verify', () async {
    final dir = await Directory.systemTemp.createTemp('weights');
    final store = WeightsStore(dir: dir, mirrorPreferred: (_) => false);
    final f = WeightFile(
        name: 'gen.onnx',
        size: payload.length,
        sha256: sha,
        url: 'http://127.0.0.1:${server.port}/gen.onnx',
        mirrorUrl: 'http://127.0.0.1:${server.port}/gen.onnx');
    // 预置 .part 前 400 字节 → 触发 Range 续传路径
    await File('${dir.path}/gen.onnx.part')
        .writeAsBytes(payload.sublist(0, 400));
    await store.download(f);
    expect(store.readyFor(f), isTrue);
    expect(File(store.pathOf(f)).readAsBytesSync(), payload);
  });

  test('bad sha deletes part and throws', () async {
    final dir = await Directory.systemTemp.createTemp('weights');
    final store = WeightsStore(dir: dir, mirrorPreferred: (_) => false);
    final f = WeightFile(
        name: 'gen.onnx',
        size: payload.length,
        sha256: '0' * 64,
        url: 'http://127.0.0.1:${server.port}/gen.onnx',
        mirrorUrl: 'http://127.0.0.1:${server.port}/gen.onnx');
    await expectLater(store.download(f), throwsA(isA<WeightsException>()));
    expect(File('${dir.path}/gen.onnx.part').existsSync(), isFalse);
  });
}
