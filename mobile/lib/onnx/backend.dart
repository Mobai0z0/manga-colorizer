// ONNX Runtime 推理层的唯一出入口：桌面管线同款两 session（SAM encoder → generator）。
//
// 绑定事实（flutter_onnxruntime 1.8.5，按 pub 缓存源码核对，非文档记忆）：
//   · 加载：OnnxRuntime().createSession(path)（无 createSessionFromFile）
//   · 类型：OrtSession（非 InferenceSession），有 inputNames/outputNames/close()
//   · run() 返回 Map<String, OrtValue>（键为输出名）。注意：该 Map 由原生侧 Java
//     HashMap 灌入（FlutterOnnxruntimePlugin.kt:438），Dart 侧迭代顺序＝字符串哈希序，
//     **不是**图声明顺序，因此输出只允许按名字取（见 pickOutputKey）。
//     输入侧不同：session.inputNames 是 ORT 实得的声明顺序，_remapInputs 可按位置回退。
//   · OrtValue 无 .value：数据要 await value.asFlattenedList() 取回；shape 已是 List<int>
//   · OrtValue 持有原生张量，必须显式 dispose()，否则原生内存泄漏
//   · 释放 session 用 close()（无 release()）
// 模型图签名（onnx 解析实得）：encoder 输入 rgb_input[batch,3,1024,1024] →
// sam_level0[batch,256,h,w] + sam_level1[batch,256,h,w]；generator 输入
// L_bw[batch,1,h,w]、sam_level0、sam_level1、wd14_embedding[batch,1024]（全 float32）
// → rgb_pred[batch,3,h,w]。
// 以上绑定差异只允许封闭在本文件内：OnnxBackend 的方法签名是硬约束。
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'backend_api.dart';
import 'weights.dart';

export 'backend_api.dart';

/// 模型输入/输出名（与 service.py:331-342 的 feed 键逐字一致）。
const _kLbw = 'L_bw';
const _kSam0 = 'sam_level0';
const _kSam1 = 'sam_level1';
const _kWd14 = 'wd14_embedding';
const _kRgbPred = 'rgb_pred';

/// generator 的 feed 顺序（＝ encoder/generator 图声明顺序，仅 `_remapInputs` 对
/// **输入**做位置回退用；输出侧不做位置回退，原因见 pickOutputKey）。
const _kGenFeedOrder = [_kLbw, _kSam0, _kSam1, _kWd14];

/// SAM encoder 输入契约：长度必须是 3·s²（[1,3,S,S] CHW）。
/// 真实后端与 FakeBackend 共用，保证宿主测试检验的就是真机上的那份契约。
@visibleForTesting
void requireSamInput(Float32List chw, int s) {
  if (chw.length != 3 * s * s) {
    throw ArgumentError('runSam 需要 $s²×3 浮点，实得 ${chw.length}');
  }
}

/// generator 的 L_bw 输入契约：长度必须是 s²（[1,1,S,S] 平面，非三通道）。
@visibleForTesting
void requireGrayPlane(Float32List plane, int s) {
  if (plane.length != s * s) {
    throw ArgumentError('runGen 的 L_bw 平面需要 $s² 浮点，实得 ${plane.length}');
  }
}

/// runSam→runGen 透传特征的一致性契约：4 维形状且元素数与数据长度一致。
@visibleForTesting
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
/// 不做一般位置回退：run() 的 Map 由原生 Java HashMap 灌入
/// （FlutterOnnxruntimePlugin.kt:438），迭代顺序＝字符串哈希序、不是图声明顺序，
/// 恰恰在名字漂移的那种模型上，按位置回退会静默调换 sam_level0/1 → 错色且无异常。
/// 返回 null 表示解析失败，调用方必须抛错（宁可崩，不可悄悄换 tensor）。
@visibleForTesting
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

/// 把 `OrtValue.asFlattenedList()` 的回传收敛为 (Float32List, 不可变形状)。
///
/// identity 快路径：已是 Float32List 时原样返回。没有它，1024² 的 sam_level0
/// （≈16 MB / 419 万元素）每次都要再复制一份并做 419 万次动态下标读取——
/// 真机验收要量峰值 RSS，这个常数因子直接进测量。
@visibleForTesting
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

class OrtOnnxBackend implements OnnxBackend {
  OrtOnnxBackend(this._store);

  final WeightsStore _store;
  OrtSession? _sam;
  OrtSession? _gen;

  @override
  Future<void> load() async {
    if (_sam != null) return;
    final ort = OnnxRuntime();
    // 权重绝不入 APK/assets：只从 WeightsStore 的下载目录按文件路径加载。
    final sam = await ort.createSession(_store.pathOf(kWeightFiles[1]));
    try {
      _gen = await ort.createSession(_store.pathOf(kWeightFiles[0]));
      _sam = sam;
    } on Object {
      // generator 加载失败不能把 encoder 的 100MB+ 原生内存留在进程里。
      await sam.close();
      _sam = null;
      _gen = null;
      rethrow;
    }
  }

  @override
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(
      Float32List chw, int s) async {
    final sam = _samLoaded();
    requireSamInput(chw, s);
    final input = await OrtValue.fromList(chw, [1, 3, s, s]);
    Map<String, OrtValue>? outputs;
    try {
      // encoder 只有一个输入 rgb_input；用绑定名而非硬编码，防模型重导出漂移。
      final names = sam.inputNames;
      if (names.isEmpty) throw StateError('encoder session 没有输入名，绑定异常');
      outputs = await sam.run({names.first: input});
      final f0 = await _flatten(_pickOutput(outputs, _kSam0, 0, 2), _kSam0);
      final f1 = await _flatten(_pickOutput(outputs, _kSam1, 1, 2), _kSam1);
      return ((f0.$1, f0.$2), (f1.$1, f1.$2));
    } finally {
      await input.dispose();
      for (final v in outputs?.values ?? const <OrtValue>[]) {
        await v.dispose();
      }
    }
  }

  @override
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    final gen = _genLoaded();
    requireGrayPlane(grayPlane, s);
    requirePlanar(sam0, _kSam0);
    requirePlanar(sam1, _kSam1);
    // feed 的构建必须在 try 内并登记每个已建 OrtValue：OrtValue.fromList 一旦把原生
    // 张量注册进插件全局缓存（Kotlin `ortValues`），只有其 Dart 包装被 dispose 才会
    // 移除，而 closeSession 并不清该缓存（FlutterOnnxruntimePlugin.kt:477-489）。
    // 若第 2~4 个 fromList 抛出（真实触发：16 MB 的 sam_level0 原生 OOM），map 字面量
    // 整体失败、feed 根本不存在，未登记的张量将活到进程结束。
    final created = <OrtValue>[];
    Map<String, OrtValue>? outputs;
    try {
      Future<OrtValue> make(Float32List data, List<int> shape) async {
        final v = await OrtValue.fromList(data, shape);
        created.add(v);
        return v;
      }

      final feed = <String, OrtValue>{
        _kLbw: await make(grayPlane, [1, 1, s, s]),
        _kSam0: await make(sam0.$1, sam0.$2),
        _kSam1: await make(sam1.$1, sam1.$2),
        _kWd14: await make(Float32List(1024), [1, 1024]),
      };
      outputs = await gen.run(_remapInputs(gen, feed));
      final pred = _pickOutput(outputs, _kRgbPred, 0, 1);
      final (chw, shape) = await _flatten(pred, _kRgbPred);
      if (shape.length != 4 ||
          shape[1] != 3 ||
          shape[2] != s ||
          shape[3] != s) {
        throw StateError('$_kRgbPred 形状应为 [1,3,$s,$s]，实得 $shape');
      }
      return rgbChwToHwc(chw, s);
    } finally {
      for (final v in created) {
        await v.dispose();
      }
      for (final v in outputs?.values ?? const <OrtValue>[]) {
        await v.dispose();
      }
    }
  }

  @override
  Future<void> dispose() async {
    final sam = _sam;
    final gen = _gen;
    _sam = null;
    _gen = null;
    // 两个都要关掉：单个 close 抛错时也不能把另一个留成孤儿 session。
    Object? first;
    if (sam != null) {
      try {
        await sam.close();
      } on Object catch (e) {
        first = e;
      }
    }
    if (gen != null) {
      try {
        await gen.close();
      } on Object catch (e) {
        first ??= e;
      }
    }
    if (first != null) throw first;
  }

  OrtSession _samLoaded() {
    final sam = _sam;
    if (sam == null || _gen == null) throw _notReady();
    return sam;
  }

  OrtSession _genLoaded() {
    final gen = _gen;
    if (gen == null || _sam == null) throw _notReady();
    return gen;
  }

  StateError _notReady() =>
      StateError('OrtOnnxBackend 未就绪：先 await load()（或 dispose() 后重新 load）');

  /// 只按名字取输出；仅当绑定完全没给名字时按声明顺序退化（见 pickOutputKey）。
  OrtValue _pickOutput(
      Map<String, OrtValue> out, String name, int index, int expectedCount) {
    final keys = out.keys.toList();
    final key = pickOutputKey(
        keys: keys, name: name, index: index, expectedCount: expectedCount);
    if (key == null) {
      throw StateError('输出缺少 $name（绑定只给出 $keys；run() 的 Map 顺序来自原生 '
          'HashMap、不是图声明顺序，禁止按位置回退）');
    }
    return out[key]!;
  }

  /// feed 名与模型声明一致时原样下发；漂移时按声明顺序位置回退。
  /// 输入侧回退是可信的：declared 来自 `session.inputNames`，即 ORT 实得的图声明顺序
  /// （与输出侧 Java HashMap 的哈希序不同，故 runGen 的 feed 序 `_kGenFeedOrder` 成立）。
  Map<String, OrtValue> _remapInputs(OrtSession s, Map<String, OrtValue> feed) {
    final declared = s.inputNames;
    if (declared.every(feed.containsKey)) return feed;
    if (declared.length != feed.length) {
      throw StateError('输入数不符：模型 $declared vs feed ${feed.keys.toList()}');
    }
    final ordered = _kGenFeedOrder.map((n) => feed[n]!).toList();
    return {
      for (var i = 0; i < declared.length; i++) declared[i]: ordered[i],
    };
  }

  Future<(Float32List, List<int>)> _flatten(OrtValue v, String label) async =>
      flattenToFloat32(await v.asFlattenedList(), v.shape, label);
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
