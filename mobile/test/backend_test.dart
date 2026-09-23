// OnnxBackend 契约测试：Task 5 的管线只吃这个抽象，本文件把「替身必须满足的语义」
// 钉死（数据长度与形状一致、runGen 输出为行优先、像素步长 3 的 RGB、值域 [-1,1]），
// 这样 Task 5 测试里 FakeBackend 与真实 OrtOnnxBackend 的输出布局保持一致。
// 真实后端在本机不执行任何 ORT 调用（无设备/无原生库）：只验证类型可用性与
// 纯 Dart 的 CHW→HWC 归一化布局，它正是真实后端返回给 Task 5 的那份缓冲。
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/backend.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';
import 'fake_backend.dart';

int _prod(List<int> shape) => shape.fold(1, (a, b) => a * b);

void main() {
  test('OnnxCancelled is a throwable Exception', () {
    expect(const OnnxCancelled(), isA<Exception>());
    expect(() => throw const OnnxCancelled(), throwsA(isA<OnnxCancelled>()));
  });

  test('FakeBackend satisfies OnnxBackend and records call order', () async {
    final calls = <String>[];
    final OnnxBackend b = FakeBackend(calls: calls);
    await b.load();
    final (s0, s1) = await b.runSam(Float32List(3 * 64 * 64), 64);
    await b.runGen(Float32List(64 * 64), 64, s0, s1);
    await b.dispose();
    expect(calls, ['load', 'sam:12288', 'gen:4096', 'dispose']);
  });

  test('runSam features carry data whose length matches shape', () async {
    final ((d0, sh0), (d1, sh1)) =
        await FakeBackend().runSam(Float32List(3 * 128 * 128), 128);
    expect(sh0, [1, 256, 64, 64]);
    expect(sh1, [1, 256, 32, 32]);
    expect(d0.length, _prod(sh0));
    expect(d1.length, _prod(sh1));
  });

  test('runGen returns 3*s*s interleaved row-major RGB in [-1,1]', () async {
    final b = FakeBackend();
    final ((d0, sh0), (d1, sh1)) = await b.runSam(Float32List(3 * 4 * 4), 4);
    final out = await b.runGen(Float32List(4 * 4), 4, (d0, sh0), (d1, sh1));
    expect(out, isA<Float32List>());
    expect(out.length, 3 * 4 * 4);
    for (final v in out) {
      expect(v, inInclusiveRange(-1.0, 1.0));
    }
    // 行优先、每像素 3 通道：左上角在红侧，右上角在蓝侧。
    expect(out[0], greaterThan(0)); // r of (0,0)
    expect(out[3 * 3], lessThan(0)); // r of (x=3,y=0)
    expect(out[3 * 3 + 2], greaterThan(0)); // b of (x=3,y=0)
    // 第二行首像素与第一行首像素同侧 → 值相同（证明 y 方向按行主序推进）。
    expect(out[3 * 4], out[0]);
  });

  test('runGen accepts the sam tuples untouched', () async {
    final b = FakeBackend(calls: <String>[]);
    final (s0, s1) =
        await b.runSam(Float32List(3 * 8 * 8)..fillRange(0, 8 * 8 * 3, 0.5), 8);
    final out = await b.runGen(Float32List(8 * 8), 8, s0, s1);
    expect(out.length, 3 * 8 * 8);
  });

  test('backend failure propagates to the caller', () async {
    final b = FakeBackend()..throwOnGen = true;
    final (s0, s1) = await b.runSam(Float32List(3 * 4 * 4), 4);
    await expectLater(
        b.runGen(Float32List(4 * 4), 4, s0, s1), throwsA(isA<StateError>()));
  });

  group('真实后端（无 ORT 调用）', () {
    late Directory dir;
    late OrtOnnxBackend backend;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('backend');
      backend =
          OrtOnnxBackend(WeightsStore(dir: dir, mirrorPreferred: (_) => false));
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('未 load() 前 runSam/runGen 报 StateError 而非空指针', () async {
      await expectLater(backend.runSam(Float32List(3 * 4 * 4), 4),
          throwsA(isA<StateError>()));
      final t = (Float32List(4), [1, 256, 1, 4]);
      await expectLater(
          backend.runGen(Float32List(16), 4, t, t), throwsA(isA<StateError>()));
    });

    test('dispose() 幂等（未加载 / 重复调用都不炸）', () async {
      await backend.dispose();
      await backend.dispose();
    });

    test('权重文件缺失时 load() 透传绑定异常（不静默半成品）', () async {
      await expectLater(backend.load(), throwsA(anything));
      // 失败后不得残留半个 encoder session：仍未就绪。
      await expectLater(backend.runSam(Float32List(3 * 4 * 4), 4),
          throwsA(isA<StateError>()));
    });
  });

  group('rgbChwToHwc（后端返回布局归一化）', () {
    test('通道平面 -> 行优先像素，逐元素对拍', () {
      const s = 3;
      final plane = s * s;
      final chw = Float32List(3 * plane);
      for (var c = 0; c < 3; c++) {
        for (var i = 0; i < plane; i++) {
          chw[c * plane + i] = c + 0.01 * i;
        }
      }
      final out = rgbChwToHwc(chw, s);
      expect(out.length, chw.length);
      for (var i = 0; i < plane; i++) {
        expect(out[i * 3], chw[i]); // r = 通道平面 0
        expect(out[i * 3 + 1], chw[plane + i]); // g = 通道平面 1
        expect(out[i * 3 + 2], chw[2 * plane + i]); // b = 通道平面 2
      }
    });

    test('长度不符直接 ArgumentError，不静默截断', () {
      expect(() => rgbChwToHwc(Float32List(3 * 4 * 4 + 1), 4),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('pickOutputKey（输出只按名字解析，禁止位置回退）', () {
    test('名字命中即返回，即使它在 keys 里排错位置（哈希序≠声明序）', () {
      // 模拟真实漂移：Map 迭代序是 Java HashMap 的哈希序，sam_level1 反而在前。
      expect(
          pickOutputKey(
              keys: ['sam_level1', 'sam_level0'],
              name: 'sam_level0',
              index: 0,
              expectedCount: 2),
          'sam_level0');
    });

    test('名字缺失但键非空 → null（调用方抛错），绝不按位置拿错 tensor', () {
      // 这是评审指出的静默错色路径：旧实现会返回 keys[0]，把 level1 当 level0。
      expect(
          pickOutputKey(
              keys: ['output__0_add_1', 'output__1_add_1'],
              name: 'sam_level0',
              index: 0,
              expectedCount: 2),
          isNull);
      expect(
          pickOutputKey(
              keys: <String>[], name: 'rgb_pred', index: 0, expectedCount: 1),
          isNull);
    });

    test('仅当绑定完全没名字（1:1 且全空串）才按声明下标退化', () {
      expect(
          pickOutputKey(
              keys: ['', ''], name: 'sam_level1', index: 1, expectedCount: 2),
          isNotNull);
      // 数量对不上（原生侧真丢了输出）时同样不许退化。
      expect(
          pickOutputKey(
              keys: [''], name: 'sam_level0', index: 0, expectedCount: 2),
          isNull);
      // 空串键 + 越界下标 → null。
      expect(
          pickOutputKey(
              keys: ['', ''], name: 'sam_level0', index: 2, expectedCount: 2),
          isNull);
    });
  });

  group('flattenToFloat32（asFlattenedList 收敛）', () {
    test('raw 已是 Float32List → identity 快路径，不再复制 16 MB', () {
      final raw = Float32List(2 * 3 * 4)..[0] = 0.5;
      final (data, shape) = flattenToFloat32(raw, [1, 2, 3, 4], 'x');
      expect(identical(data, raw), isTrue);
      expect(shape, [1, 2, 3, 4]);
    });

    test('普通 List 逐元素转换，值一致', () {
      final (data, shape) =
          flattenToFloat32(<dynamic>[1.5, -2.5, 3.0], [1, 1, 1, 3], 'y');
      expect(data, isA<Float32List>());
      expect(identical(data, <dynamic>[1.5, -2.5, 3.0]), isFalse);
      expect(data, [1.5, -2.5, 3.0]);
      expect(shape, [1, 1, 1, 3]);
      // 形状不可变：透传给 runGen 前不被下游篡改。
      expect(() => shape[0] = 9, throwsUnsupportedError);
    });

    test('形状/数据不符（含 Float32List 快路径）→ StateError', () {
      expect(() => flattenToFloat32(<dynamic>[1.0], [1, 2], 'z'),
          throwsStateError);
      expect(() => flattenToFloat32(Float32List(2), [1, 3], 'z'),
          throwsStateError);
    });

    test('非数值元素 → StateError，不静默转 0', () {
      expect(() => flattenToFloat32(<dynamic>[1.0, 'x'], [1, 2], 'z'),
          throwsStateError);
    });
  });

  group('FakeBackend 与真实后端共用输入守卫', () {
    final feat = (Float32List(256 * 64 * 64), [1, 256, 64, 64]);
    final feat1 = (Float32List(256 * 32 * 32), [1, 256, 32, 32]);

    test('runSam 拒绝非 3·s² 输入', () async {
      await expectLater(FakeBackend().runSam(Float32List(3 * 4 * 4 + 3), 4),
          throwsA(isA<ArgumentError>()));
    });

    test('runGen 拒绝非 s² 灰度平面（Task 5 若传成 3·s² 必须在这炸）', () async {
      await expectLater(
          FakeBackend().runGen(Float32List(3 * 4 * 4), 4, feat, feat1),
          throwsA(isA<ArgumentError>()));
    });

    test('runGen 拒绝数据/形状不一致或非 4 维的特征', () async {
      await expectLater(
          FakeBackend().runGen(
              Float32List(16), 4, (Float32List(999), [1, 256, 64, 64]), feat1),
          throwsA(isA<ArgumentError>()));
      await expectLater(
          FakeBackend()
              .runGen(Float32List(16), 4, (feat.$1, [256, 64, 64]), feat1),
          throwsA(isA<ArgumentError>()));
    });

    test('合法输入仍然通过（守卫没把 happy path 掐死）', () async {
      final b = FakeBackend();
      final (s0, s1) = await b.runSam(Float32List(3 * 128 * 128), 128);
      final out = await b.runGen(Float32List(128 * 128), 128, s0, s1);
      expect(out.length, 3 * 128 * 128);
    });
  });
}
