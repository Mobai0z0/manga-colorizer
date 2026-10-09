// 两个 ORT 后端（backend.dart 插件版 / backend_ffi.dart FFI 版）与宿主测试
// 替身（test/fake_backend.dart）共用的模型 I/O 契约辅助：输入尺寸守卫、输出
// 名解析、回传收敛、布局转换。原本住在 backend.dart 并标 @visibleForTesting
// ——FFI 后端（同为生产 lib 代码）也要用同一份契约，@visibleForTesting 会在
// lib→lib 引用处报 warning，故提升为独立文件、转正为公共 API。
//
// 契约与 service.py:331-342 的 feed 键/布局逐字对齐；改动任何一条都要同步
// 桌面参考实现与测试对拍数据。
import 'dart:typed_data';


/// SAM encoder 输入契约：长度必须是 3·s²（[1,3,S,S] CHW）。
/// 真实后端与 FakeBackend 共用，保证宿主测试检验的就是真机上的那份契约。
void requireSamInput(Float32List chw, int s) {
  if (chw.length != 3 * s * s) {
    throw ArgumentError('runSam 需要 $s²×3 浮点，实得 ${chw.length}');
  }
}

/// generator 的 L_bw 输入契约：长度必须是 s²（[1,1,S,S] 平面，非三通道）。
void requireGrayPlane(Float32List plane, int s) {
  if (plane.length != s * s) {
    throw ArgumentError('runGen 的 L_bw 平面需要 $s² 浮点，实得 ${plane.length}');
  }
}

/// runSam→runGen 透传特征的一致性契约：4 维形状且元素数与数据长度一致。
void requirePlanar((Float32List, List<int>) t, String label) {
  var n = 1;
  for (final d in t.$2) {
    n *= d;
  }
  if (t.$2.length != 4 || n != t.$1.length) {
    throw ArgumentError('$label 数据/形状不一致: ${t.$1.length} vs ${t.$2}');
  }
}

/// 输出名解析：只按名字命中。唯一的退化条件是绑定**完全没给名字**（键数量与期望
/// 输出 1:1 且全为空串），此时按下标取是唯一可行的选择。
///
/// 不做一般位置回退：插件版 run() 的 Map 由原生 Java HashMap 灌入
/// （FlutterOnnxruntimePlugin.kt:438），迭代顺序＝字符串哈希序、不是图声明顺序，
/// 恰恰在名字漂移的那种模型上，按位置回退会静默调换 sam_level0/1 → 错色且无异常。
/// 返回 null 表示解析失败，调用方必须抛错（宁可崩，不可悄悄换 tensor）。
String? pickOutputKey({
  required List<String> keys,
  required String name,
  required int index,
  required int expectedCount,
}) {
  if (keys.contains(name)) return name;
  if (keys.length == expectedCount &&
      index < keys.length &&
      keys.every((k) => k.isEmpty)) {
    return keys[index];
  }
  return null;
}

/// 把绑定回传（插件版 asFlattenedList / FFI 版已 memcpy 的 Float32List）
/// 收敛为 (Float32List, 不可变形状)。
///
/// identity 快路径：已是 Float32List 时原样返回。没有它，1024² 的 sam_level0
/// （≈16 MB / 419 万元素）每次都要再复制一份并做 419 万次动态下标读取——
/// 真机验收要量峰值 RSS，这个常数因子直接进测量。
(Float32List, List<int>) flattenToFloat32(
    List<dynamic> raw, List<int> shape, String label) {
  var n = 1;
  for (final d in shape) {
    n *= d;
  }
  if (raw is Float32List) {
    if (n != raw.length) {
      throw StateError('$label: 形状 $shape 与数据 ${raw.length} 不符');
    }
    return (raw, List<int>.unmodifiable(shape));
  }
  final data = Float32List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    final e = raw[i];
    if (e is! num) {
      throw StateError('$label: 绑定回传了非数值元素 ${e.runtimeType}');
    }
    data[i] = e.toDouble();
  }
  if (n != data.length) {
    throw StateError('$label: 形状 $shape 与数据 ${data.length} 不符');
  }
  return (data, List<int>.unmodifiable(shape));
}

/// 模型原生 `rgb_pred [1,3,S,S]` → 行优先、像素步长 3 的 RGB（值域不变）。
///
/// 纯 Dart、无原生依赖，因此宿主测试可直接对拍（真实后端与 FakeBackend 共用此布局）。
Float32List rgbChwToHwc(Float32List chw, int s) {
  final plane = s * s;
  if (chw.length != 3 * plane) {
    throw ArgumentError('rgbChwToHwc 需要 ${3 * plane} 浮点，实得 ${chw.length}');
  }
  final out = Float32List(chw.length);
  for (var i = 0; i < plane; i++) {
    out[i * 3] = chw[i];
    out[i * 3 + 1] = chw[plane + i];
    out[i * 3 + 2] = chw[2 * plane + i];
  }
  return out;
}
