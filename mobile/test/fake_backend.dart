import 'dart:typed_data';
import 'package:manga_colorizer_mobile/onnx/backend.dart';

/// 常数场替身: 特征固定形状, rgb 输出按像素 x 左红右蓝。
class FakeBackend implements OnnxBackend {
  /// 默认值必须是**可变**列表：`const []` 会让 `calls.add` 在 `FakeBackend()`
  /// 的默认用法下抛 UnsupportedError（计划原文即如此，Task 5 的用例必踩）。
  FakeBackend({List<String>? calls}) : calls = calls ?? [];
  final List<String> calls;
  bool throwOnGen = false;

  @override
  Future<void> load() async {
    calls.add('load');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }

  @override
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(
      Float32List chw, int s) async {
    calls.add('sam:${chw.length}');
    final a = Float32List(256 * 64 * 64)..fillRange(0, 256 * 64 * 64, 0.1);
    final b = Float32List(256 * 32 * 32)..fillRange(0, 256 * 32 * 32, 0.1);
    return ((a, [1, 256, 64, 64]), (b, [1, 256, 32, 32]));
  }

  @override
  Future<Float32List> runGen(Float32List l, int s, (Float32List, List<int>) a,
      (Float32List, List<int>) b) async {
    if (throwOnGen) throw StateError('boom');
    calls.add('gen:${l.length}');
    final out = Float32List(3 * s * s);
    for (var y = 0; y < s; y++) {
      for (var x = 0; x < s; x++) {
        final i = (y * s + x) * 3;
        final redSide = x < s ~/ 2;
        out[i] = redSide ? 0.9 : -0.3; // r
        out[i + 1] = -0.5; // g
        out[i + 2] = redSide ? -0.5 : 0.9; // b
      }
    }
    return out;
  }
}
