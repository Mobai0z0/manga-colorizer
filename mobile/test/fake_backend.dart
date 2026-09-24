import 'dart:typed_data';
import 'package:manga_colorizer_mobile/onnx/backend.dart';

/// 常数场替身: 特征固定形状, rgb 输出按像素 x 左红右蓝。
///
/// 输入守卫与真实后端 OrtOnnxBackend 共用同一组函数（requireSamInput /
/// requireGrayPlane / requirePlanar）：管线若把缓冲尺寸算错（例如给 runGen 传
/// 3·S² 而非 S²，或特征元组被截断），宿主测试就会炸，而不是只换到真机才失败。
class FakeBackend implements OnnxBackend {
  /// 默认值必须是**可变**列表：换成 `const []` 会让最常见的 `FakeBackend()`
  /// 默认用法在第一次 `calls.add` 就抛 UnsupportedError，全部管线用例连坐。
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
    requireSamInput(chw, s);
    calls.add('sam:${chw.length}');
    final a = Float32List(256 * 64 * 64)..fillRange(0, 256 * 64 * 64, 0.1);
    final b = Float32List(256 * 32 * 32)..fillRange(0, 256 * 32 * 32, 0.1);
    return ((a, [1, 256, 64, 64]), (b, [1, 256, 32, 32]));
  }

  @override
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    requireGrayPlane(grayPlane, s);
    requirePlanar(sam0, 'sam0');
    requirePlanar(sam1, 'sam1');
    if (throwOnGen) throw StateError('boom');
    calls.add('gen:${grayPlane.length}');
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
