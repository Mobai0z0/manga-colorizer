// ONNX Runtime 推理层的唯一出入口：桌面管线同款两 session（SAM encoder → generator）。
//
// 绑定事实（flutter_onnxruntime 1.8.5，按 pub 缓存源码核对，非文档记忆）：
//   · 加载：OnnxRuntime().createSession(path)（无 createSessionFromFile）
//   · 类型：OrtSession（非 InferenceSession），有 inputNames/outputNames/close()
//   · run() 返回 Map<String, OrtValue>（键为输出名，插入顺序＝图声明顺序）
//   · OrtValue 无 .value：数据要 await value.asFlattenedList() 取回；shape 已是 List<int>
//   · OrtValue 持有原生张量，必须显式 dispose()，否则原生内存泄漏
//   · 释放 session 用 close()（无 release()）
// 模型图签名（onnx 解析实得）：encoder 输入 rgb_input[batch,3,1024,1024] →
// sam_level0[batch,256,h,w] + sam_level1[batch,256,h,w]；generator 输入
// L_bw[batch,1,h,w]、sam_level0、sam_level1、wd14_embedding[batch,1024]（全 float32）
// → rgb_pred[batch,3,h,w]。
// 以上绑定差异只允许封闭在本文件内：OnnxBackend 的方法签名是硬约束。
import 'dart:typed_data';
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

/// generator 的 feed 顺序（＝ ONNX 图声明顺序，名字漂移时按位置回退用）。
const _kGenFeedOrder = [_kLbw, _kSam0, _kSam1, _kWd14];

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
    if (chw.length != 3 * s * s) {
      throw ArgumentError('runSam 需要 $s²×3 浮点，实得 ${chw.length}');
    }
    final input = await OrtValue.fromList(chw, [1, 3, s, s]);
    Map<String, OrtValue>? outputs;
    try {
      // encoder 只有一个输入 rgb_input；用绑定名而非硬编码，防模型重导出漂移。
      final names = sam.inputNames;
      if (names.isEmpty) throw StateError('encoder session 没有输入名，绑定异常');
      outputs = await sam.run({names.first: input});
      final f0 = await _flatten(_pickOutput(outputs, _kSam0, 0), _kSam0);
      final f1 = await _flatten(_pickOutput(outputs, _kSam1, 1), _kSam1);
      return ((f0.$1, f0.$2), (f1.$1, f1.$2));
    } finally {
      await input.dispose();
      for (final v in outputs?.values ?? const <OrtValue>[]) {
        await v.dispose();
      }
    }
  }

  @override
  Future<Float32List> runGen(Float32List grayChw, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    final gen = _genLoaded();
    if (grayChw.length != s * s) {
      throw ArgumentError('runGen 的 L_bw 平面需要 $s² 浮点，实得 ${grayChw.length}');
    }
    _checkPlanar(sam0, _kSam0);
    _checkPlanar(sam1, _kSam1);
    final feed = <String, OrtValue>{
      _kLbw: await OrtValue.fromList(grayChw, [1, 1, s, s]),
      _kSam0: await OrtValue.fromList(sam0.$1, sam0.$2),
      _kSam1: await OrtValue.fromList(sam1.$1, sam1.$2),
      _kWd14: await OrtValue.fromList(Float32List(1024), [1, 1024]),
    };
    Map<String, OrtValue>? outputs;
    try {
      outputs = await gen.run(_remapInputs(gen, feed));
      final pred = _pickOutput(outputs, _kRgbPred, 0);
      final (chw, shape) = await _flatten(pred, _kRgbPred);
      if (shape.length != 4 ||
          shape[1] != 3 ||
          shape[2] != s ||
          shape[3] != s) {
        throw StateError('$_kRgbPred 形状应为 [1,3,$s,$s]，实得 $shape');
      }
      return rgbChwToHwc(chw, s);
    } finally {
      for (final v in feed.values) {
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

  /// 绑定返回的 Map 若缺名字（少数导出图无输出名），退化为图声明顺序下标。
  OrtValue _pickOutput(Map<String, OrtValue> out, String name, int index) {
    final v = out[name];
    if (v != null) return v;
    final keys = out.keys.toList();
    if (index < keys.length) return out[keys[index]]!;
    throw StateError('输出缺少 $name（绑定只给出 $keys）');
  }

  /// feed 名与模型声明一致时原样下发；漂移时按图声明顺序位置回退。
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

  void _checkPlanar((Float32List, List<int>) t, String label) {
    var n = 1;
    for (final d in t.$2) {
      n *= d;
    }
    if (t.$2.length != 4 || n != t.$1.length) {
      throw ArgumentError('$label 数据/形状不一致: ${t.$1.length} vs ${t.$2}');
    }
  }

  Future<(Float32List, List<int>)> _flatten(OrtValue v, String label) async {
    final raw = await v.asFlattenedList();
    final data = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      final e = raw[i];
      if (e is! num) {
        throw StateError('$label: 绑定回传了非数值元素 ${e.runtimeType}');
      }
      data[i] = e.toDouble();
    }
    var n = 1;
    for (final d in v.shape) {
      n *= d;
    }
    if (n != data.length) {
      throw StateError('$label: 形状 ${v.shape} 与数据 ${data.length} 不符');
    }
    return (data, List<int>.unmodifiable(v.shape));
  }
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
