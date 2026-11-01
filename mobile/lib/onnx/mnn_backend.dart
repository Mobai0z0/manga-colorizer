// MNN 推理后端（v0.6.x Stage 2）：dart:ffi 直调 libmnn_ffi.so（C ABI 封装
// mobile/android/app/src/main/cpp/mnn_ffi/mnn_ffi.cpp，内部 libMNN.so C++ API）。
//
// 与 OrtFfiBackend（backend_ffi.dart）接口逐字对齐，模型 I/O 契约、日志埋点、
// 错误文案保持一致；差异只在底层绑定：
//   · 权重走 kMnnWeightFiles（fp32 .mnn，mmap 文件背页加载——LMK 压力下可回收，
//     这是引入 MNN 的机制性收益；ORT 私有内存 arena 无此性质）；
//   · CPU 后端，无 arena/EP 概念；threads 来自 ResourceTier 分级；
//   · runSam 用一次会话运行同时取两级特征（mnn_run_multi）。
import 'dart:typed_data';

import '../mem_info.dart';
import 'backend.dart' show kDefaultIntraThreads;
import 'backend_api.dart';
import 'backend_contract.dart';
import 'backend_log.dart';
import 'mnn_ffi.dart';
import 'weights.dart';

/// 模型输入/输出名（与 backend.dart / service.py:331-342 的 feed 键逐字一致）。
const _kLbw = 'L_bw';
const _kSam0 = 'sam_level0';
const _kSam1 = 'sam_level1';
const _kWd14 = 'wd14_embedding';
const _kRgbPred = 'rgb_pred';

/// generator 的 feed 顺序（＝ 图声明顺序，仅输入位置回退用；输出侧只按名字）。
const _kGenFeedOrder = [_kLbw, _kSam0, _kSam1, _kWd14];

/// v6 模型的推理尺寸契约（与 pipeline 的 autoInfer 默认一致；模型权重固定
/// 1024² 训练分辨率，端侧不缩）。特征空间尺寸由 Stage 0 C 封装冒烟实测固化。
const int kMnnInferSize = 1024;
const int kMnnFeat0Side = 64;
const int kMnnFeat1Side = 32;

/// MNN 后端：模型 I/O 契约与日志埋点与 [OrtFfiBackend] 一致。
class MnnFfiBackend implements OnnxBackend {
  MnnFfiBackend(this._store,
      {this.threads = kDefaultIntraThreads,
      this.memoryMode = MnnMemoryMode.normal,
      this.precisionMode = MnnPrecisionMode.normal});

  final WeightsStore _store;

  /// 推理线程上限：来自 ResourceTier 设备分级（低内存档 2，默认 4）。
  final int threads;

  /// MNN 内存模式（Normal；低内存档可实验 Low+量化模型，v1 不启用）。
  final MnnMemoryMode memoryMode;

  /// 精度模式（Normal=fp32 计算；Low 会在 ARM82 上启用 fp16 计算，Stage 0
  /// 桌面对拍显示 fp16 存储已使 generator 漂移 max 17，v1 锁 Normal）。
  final MnnPrecisionMode precisionMode;

  MnnFfiSession? _sam;
  MnnFfiSession? _gen;

  @override
  Future<void> load() async {
    if (_sam != null) return;
    final mnn = MnnFfi.load();
    final sw = Stopwatch()..start();
    backendLog('encoder session 创建开始（${kMnnWeightFiles[1].name}，'
        'threads=$threads，mnn/mmap）${rssSuffix()}');
    final sam = _createSession(mnn, kMnnWeightFiles[1]);
    backendLog('encoder session 创建完成（${sw.elapsedMilliseconds}ms）'
        '${rssSuffix()}');
    try {
      final genSw = Stopwatch()..start();
      backendLog('generator session 创建开始（${kMnnWeightFiles[0].name}）'
          '${rssSuffix()}');
      _gen = _createSession(mnn, kMnnWeightFiles[0]);
      backendLog('generator session 创建完成（${genSw.elapsedMilliseconds}ms）'
          '${rssSuffix()}');
      _sam = sam;
    } on Object {
      // generator 加载失败不能把 encoder 的原生内存留在进程里。
      sam.close();
      _sam = null;
      _gen = null;
      rethrow;
    }
  }

  MnnFfiSession _createSession(MnnFfi mnn, WeightFile weight) {
    final path = _store.pathOf(weight);
    // 契约 IO 名逐字传入（Module::load 按名接线；与 backend.dart/service.py
    // 的 feed 键一致）。输入形状提示兜底动态维：SAM 两级特征在 generator 侧
    // 声明为 [1,256,-1,-1]，空间尺寸由契约定死（64/32，与 fp32 .mnn 的实测
    // 输出一致，C 侧运行时按元素数二次校验）。encoder 先建、generator 后建，
    // 失败不留孤儿。
    final isEncoder = identical(weight, kMnnWeightFiles[1]) ||
        weight.name.contains('encoder');
    try {
      final s = mnn.createSession(path,
          inputNames: isEncoder ? const ['rgb_input'] : const [_kLbw, _kSam0, _kSam1, _kWd14],
          outputNames: isEncoder ? const [_kSam0, _kSam1] : const [_kRgbPred],
          inputShapes: isEncoder
              ? const [
                  [1, 3, kMnnInferSize, kMnnInferSize],
                ]
              : const [
                  [1, 1, kMnnInferSize, kMnnInferSize],
                  [1, 256, kMnnFeat0Side, kMnnFeat0Side],
                  [1, 256, kMnnFeat1Side, kMnnFeat1Side],
                  [1, 1024],
                ],
          threads: threads,
          memoryMode: memoryMode,
          precisionMode: precisionMode);
      backendLog('${weight.name}: session 创建成功（mnn，'
          'in=${s.inputNames.length}/out=${s.outputNames.length}）');
      return s;
    } on Object catch (e) {
      backendLog('${weight.name}: session 创建失败（mnn）：$e');
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
    backendLog('SAM Run 开始（s=$s，mnn）${rssSuffix()}');
    final outputs = sam.run({names.first: (chw, [1, 3, s, s])},
        outputNames: [_kSam0, _kSam1]);
    backendLog('SAM Run 完成（${sw.elapsedMilliseconds}ms）${rssSuffix()}');
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
    backendLog('生成 Run 开始（s=$s，feed=${feed.length} 张量，mnn）'
        '${rssSuffix()}');
    final outputs = gen.run(_remapInputs(gen, feed),
        outputNames: [_kRgbPred]);
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

  MnnFfiSession _samLoaded() {
    final sam = _sam;
    if (sam == null || _gen == null) throw _notReady();
    return sam;
  }

  MnnFfiSession _genLoaded() {
    final gen = _gen;
    if (gen == null || _sam == null) throw _notReady();
    return gen;
  }

  StateError _notReady() =>
      StateError('MnnFfiBackend 未就绪：先 await load()（或 dispose() 后重新 load）');

  /// 只按名字取输出（mnn_run_multi 按请求名返回 Map；断言逻辑与插件/FFI 版一致：
  /// 名字不在即抛，绝不静默按位置取）。
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
  /// 输入侧回退是可信的：declared 来自会话创建期查询的图声明顺序。
  Map<String, (Float32List, List<int>)> _remapInputs(
      MnnFfiSession s, Map<String, (Float32List, List<int>)> feed) {
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

  /// 带计时的回传：mnn_run_multi 已把输出 memcpy 进 Dart 堆，这里是纯 Dart 收敛
  /// （flattenToFloat32 的 identity 快路径直接命中 Float32List）。计时语义
  /// 与 ORT 版对齐，便于真机日志逐段对拍。
  (Float32List, List<int>) _flattenTimed(
      (Float32List, List<int>) v, String label) {
    final sw = Stopwatch()..start();
    final out = flattenToFloat32(v.$1, v.$2, label);
    backendLog('$label 回传完成（shape=${v.$2}，'
        '${sw.elapsedMilliseconds}ms）${rssSuffix()}');
    return out;
  }
}
