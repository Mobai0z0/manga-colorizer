// dart:ffi 版 ORT 推理后端（v0.5.19）：与 backend.dart（flutter_onnxruntime
// 插件版）接口逐字对齐，ORT 调用全部换成 ort_ffi.dart 的 C API 直调。
//
// 为什么要有两份：v0.5.16~18 真机取证钉死根因——卓易通（HarmonyOS NEXT
// Android 兼容层）的 ART 在 ORT Java JNI 桥路径（libonnxruntime4j_jni.so）
// 触发 CHECK 失败 → abort（SIGABRT），threads=4/1 均崩、offset 确定性一致、
// ORT 1.26/1.27/1.28 版本轴均复现。修复＝从调用链剔除 Java/JNI/libart：
// dart:ffi 直调 libonnxruntime.so 的版本化 C API，该 so 无 JVM 依赖。
//
// 与插件版的差异（刻意保持的等价物）：
//   · OrtValue.fromList → OrtFfi.run 的输入张量（malloc 拷入，见 ort_ffi.dart
//     文件头内存安全约定）；
//   · asFlattenedList → run() 返回值已是 memcpy 拷出的 Float32List（无大数组
//     跨通道拷贝，回传计时语义保留）；
//   · useArena=false → AppendExecutionProvider_CPU(options, 0)；arena=true 的
//     shrinkage 走 AddSessionConfigEntry（run-options 键在 FFI 路径不适用，
//     缩减语义由每次 Run 后显式收缩改为「本后端固定 no-arena 使用方式」——
//     v0.5.14 起全档位 no-arena，两者本就等价）。
//   · 输出解析沿用 pickOutputKey 语义（FFI run 按名字返回 Map，无 HashMap 序
//     问题，但断言逻辑保持一致）。
import 'dart:typed_data';

import '../mem_info.dart';
import 'backend.dart' show kDefaultIntraThreads;
import 'backend_api.dart';
import 'backend_contract.dart';
import 'backend_log.dart';
import 'ort_ffi.dart';
import 'weights.dart';

/// 模型输入/输出名（与 backend.dart / service.py:331-342 的 feed 键逐字一致）。
const _kLbw = 'L_bw';
const _kSam0 = 'sam_level0';
const _kSam1 = 'sam_level1';
const _kWd14 = 'wd14_embedding';
const _kRgbPred = 'rgb_pred';

/// generator 的 feed 顺序（＝ 图声明顺序，仅输入位置回退用；输出侧只按名字）。
const _kGenFeedOrder = [_kLbw, _kSam0, _kSam1, _kWd14];

/// FFI 后端：模型 I/O 契约、日志埋点、错误文案与插件版 [OrtOnnxBackend] 一致。
class OrtFfiBackend implements OnnxBackend {
  OrtFfiBackend(this._store,
      {this.intraThreads = kDefaultIntraThreads, this.useArena = false});

  final WeightsStore _store;

  /// intra-op 线程上限：来自 ResourceTier 设备分级（低内存档 2，默认 4）。
  final int intraThreads;

  /// arena 策略：v0.5.14 起全档位 no-arena（时间换峰值）；FFI 路径走
  /// AppendExecutionProvider_CPU(options, useArena?1:0)。
  final bool useArena;

  OrtFfiSession? _sam;
  OrtFfiSession? _gen;

  @override
  Future<void> load() async {
    if (_sam != null) return;
    final ort = OrtFfi.load();
    final sw = Stopwatch()..start();
    backendLog('encoder session 创建开始（${kWeightFiles[1].name}，'
        'threads=$intraThreads，arena=$useArena，ffi）${rssSuffix()}');
    final sam = _createSession(ort, kWeightFiles[1]);
    backendLog('encoder session 创建完成（${sw.elapsedMilliseconds}ms）'
        '${rssSuffix()}');
    try {
      final genSw = Stopwatch()..start();
      backendLog('generator session 创建开始（${kWeightFiles[0].name}）'
          '${rssSuffix()}');
      _gen = _createSession(ort, kWeightFiles[0]);
      backendLog('generator session 创建完成（${genSw.elapsedMilliseconds}ms）'
          '${rssSuffix()}');
      _sam = sam;
    } on Object {
      // generator 加载失败不能把 encoder 的 100MB+ 原生内存留在进程里。
      sam.close();
      _sam = null;
      _gen = null;
      rethrow;
    }
  }

  /// 会话创建：FFI 同步路径。arena 语义与插件版等价（no-arena=append CPU EP
  /// 且 use_arena=0）；shrinkage config 键是 run-options 语义，FFI 路径不用。
  OrtFfiSession _createSession(OrtFfi ort, WeightFile weight) {
    final path = _store.pathOf(weight);
    try {
      final s = ort.createSession(path,
          intraThreads: intraThreads, useArena: useArena);
      backendLog('${weight.name}: session 创建成功（ffi，arena=$useArena）');
      return s;
    } on Object catch (e) {
      backendLog('${weight.name}: session 创建失败（ffi）：$e');
      rethrow;
    }
  }

  @override
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(
      Float32List chw, int s) async {
    final sam = _samLoaded();
    requireSamInput(chw, s);
    final sw = Stopwatch()..start();
    // encoder 只有一个输入 rgb_input；用绑定名而非硬编码，防模型重导出漂移。
    final names = sam.inputNames;
    if (names.isEmpty) throw StateError('encoder session 没有输入名，绑定异常');
    backendLog('SAM Run 开始（s=$s，ffi）${rssSuffix()}');
    Map<String, (Float32List, List<int>)> outputs;
    try {
      outputs = sam.run({names.first: (chw, [1, 3, s, s])});
      backendLog('SAM Run 完成（${sw.elapsedMilliseconds}ms）${rssSuffix()}');
    } finally {
      // 输入缓冲由 ort_ffi.run 内部管理（malloc 拷入，Run 返回后释放），
      // 输出已 memcpy 拷出——这里无原生资源可泄漏，无需 dispose。
    }
    final f0 = _flattenTimed(_pickOutput(outputs, _kSam0, 0, 2), _kSam0);
    final f1 = _flattenTimed(_pickOutput(outputs, _kSam1, 1, 2), _kSam1);
    return ((f0.$1, f0.$2), (f1.$1, f1.$2));
  }

  @override
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    final gen = _genLoaded();
    requireGrayPlane(grayPlane, s);
    requirePlanar(sam0, _kSam0);
    requirePlanar(sam1, _kSam1);
    final sw = Stopwatch()..start();
    final feed = <String, (Float32List, List<int>)>{
      _kLbw: (grayPlane, [1, 1, s, s]),
      _kSam0: sam0,
      _kSam1: sam1,
      _kWd14: (Float32List(1024), [1, 1024]),
    };
    backendLog('生成 Run 开始（s=$s，feed=${feed.length} 张量，ffi）'
        '${rssSuffix()}');
    final outputs = gen.run(_remapInputs(gen, feed));
    backendLog('生成 Run 完成（${sw.elapsedMilliseconds}ms）${rssSuffix()}');
    final (chw, shape) = _flattenTimed(_pickOutput(outputs, _kRgbPred, 0, 1),
        _kRgbPred);
    if (shape.length != 4 || shape[1] != 3 || shape[2] != s || shape[3] != s) {
      throw StateError('$_kRgbPred 形状应为 [1,3,$s,$s]，实得 $shape');
    }
    return rgbChwToHwc(chw, s);
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
        sam.close();
      } on Object catch (e) {
        first = e;
      }
    }
    if (gen != null) {
      try {
        gen.close();
      } on Object catch (e) {
        first ??= e;
      }
    }
    if (first != null) throw first;
  }

  OrtFfiSession _samLoaded() {
    final sam = _sam;
    if (sam == null || _gen == null) throw _notReady();
    return sam;
  }

  OrtFfiSession _genLoaded() {
    final gen = _gen;
    if (gen == null || _sam == null) throw _notReady();
    return gen;
  }

  StateError _notReady() =>
      StateError('OrtFfiBackend 未就绪：先 await load()（或 dispose() 后重新 load）');

  /// 只按名字取输出（FFI run 的 Map 按请求名返回，键序=请求序；断言与插件版
  /// 一致：名字不在即抛，绝不静默按位置取）。
  (Float32List, List<int>) _pickOutput(Map<String, (Float32List, List<int>)> out,
      String name, int index, int expectedCount) {
    final keys = out.keys.toList();
    final key = pickOutputKey(
        keys: keys, name: name, index: index, expectedCount: expectedCount);
    if (key == null) {
      throw StateError('输出缺少 $name（绑定只给出 $keys）');
    }
    return out[key]!;
  }

  /// feed 名与模型声明一致时原样下发；漂移时按声明顺序位置回退。
  /// 输入侧回退是可信的：declared 来自 FFI ioNames（ORT 实得的图声明顺序）。
  Map<String, (Float32List, List<int>)> _remapInputs(
      OrtFfiSession s, Map<String, (Float32List, List<int>)> feed) {
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

  /// 带计时的回传：FFI run 已把输出 memcpy 进 Dart 堆，这里是纯 Dart 收敛
  /// （flattenToFloat32 的 identity 快路径直接命中 Float32List）。计时语义
  /// 与插件版对齐，便于真机日志逐段对拍。
  (Float32List, List<int>) _flattenTimed(
      (Float32List, List<int>) v, String label) {
    final sw = Stopwatch()..start();
    final out = flattenToFloat32(v.$1, v.$2, label);
    backendLog('$label 回传完成（shape=${v.$2}，'
        '${sw.elapsedMilliseconds}ms）${rssSuffix()}');
    return out;
  }
}
