import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';

void main() {
  // 两个候选 URL 都指向本机 1 号端口：连接必被拒，_fetch 折叠成 WeightsException，
  // 于是不碰真实网络就能走满「主站失败 → 回退 → 末位仍抛出」这条完整路径。
  const bogus = WeightFile(
    name: 'bogus.onnx',
    size: 4,
    sha256: '0000000000000000000000000000000000000000000000000000000000000000',
    url: 'http://127.0.0.1:1/a.onnx',
    mirrorUrl: 'http://127.0.0.1:1/b.onnx',
  );
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('weights_log'));
  tearDown(
      () {if (dir.existsSync()) dir.deleteSync(recursive: true);});

  test('首个 URL 失败触发一次 onFallback，回传结构化数据', () async {
    final calls = <(WeightFile, String, String, String)>[];
    await expectLater(
      WeightsStore(dir: dir).download(
        bogus,
        onFallback: (f, from, next, why) => calls.add((f, from, next, why)),
      ),
      throwsA(isA<WeightsException>()),
    );
    expect(calls.length, 1); // 只在真正回退时记一次
    expect(calls.single.$1.name, 'bogus.onnx');
    expect(calls.single.$2, endsWith('a.onnx'));
    expect(calls.single.$3, endsWith('b.onnx'));
    expect(calls.single.$4, contains('bogus.onnx')); // 原因串自带文件名
  });

  test('不传 onFallback 时契约不变', () async {
    await expectLater(WeightsStore(dir: dir).download(bogus),
        throwsA(isA<WeightsException>()));
  });
}
