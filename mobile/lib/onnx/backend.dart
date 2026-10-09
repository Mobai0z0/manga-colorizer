// ONNX Runtime 推理层的唯一出入口：桌面管线同款两 session（SAM encoder → generator）。
//
// 绑定事实（flutter_onnxruntime 1.9.0，按 pub 缓存源码逐条核对，非文档记忆；
// 1.9.0 起 ORT 原生层为 1.28.x）：
//   · 加载：OnnxRuntime().createSession(path)（无 createSessionFromFile）；
//     Kotlin 层 createSession(modelPath, options) 路径直达 ORT，无字节双拷贝
//   · 类型：OrtSession（非 InferenceSession），有 inputNames/outputNames/close()
//   · run() 返回 Map<String, OrtValue>（键为输出名）。注意：该 Map 由原生侧
//     Java HashMap 灌入，Dart 侧迭代顺序＝字符串哈希序，**不是**图声明顺序，
//     因此输出只允许按名字取（见 pickOutputKey）。
//     输入侧不同：session.inputNames 是 ORT 实得的声明顺序，_remapInputs 可按位置回退。
//   · OrtValue 无 .value：数据要 await value.asFlattenedList() 取回；shape 已是 List<int>
//   · OrtValue 持有原生张量，必须显式 dispose()，否则原生内存泄漏
//   · 释放 session 用 close()（无 release()）；closeSession **不清** Kotlin 全局
//     ortValues 缓存（只有引擎 detach 才清）——fromList 出来的值必须逐个 dispose
//   · session options：intraOpNumThreads/interOpNumThreads/providers/useArena/
//     deviceId/sessionConfigs（1.9.0 新增，Kotlin 逐条 addConfigEntry）；
//     run() 另有可选 OrtRunOptions（仅 log/terminate，无 config entries——
//     arena shrinkage 因此只能走 sessionConfigs）
// 模型图签名（onnx 解析实得）：encoder 输入 rgb_input[batch,3,1024,1024] →
// sam_level0[batch,256,h,w] + sam_level1[batch,256,h,w]；generator 输入
// L_bw[batch,1,h,w]、sam_level0、sam_level1、wd14_embedding[batch,1024]（全 float32）
// → rgb_pred[batch,3,h,w]。
// 以上绑定差异只允许封闭在本文件内：OnnxBackend 的方法签名是硬约束。
//
// v0.5.19：模型 I/O 契约辅助（requireSamInput/requireGrayPlane/requirePlanar/
// pickOutputKey/flattenToFloat32/rgbChwToHwc）已提升到 backend_contract.dart
// ——FFI 后端 backend_ffi.dart 与宿主测试替身同用一份；本文件经 import+export
// 保持既有使用点（backend_test/fake_backend）不变。
import 'dart:typed_data';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import '../mem_info.dart';
import 'backend_api.dart';
import 'backend_contract.dart';
import 'backend_log.dart';
import 'weights.dart';

export 'backend_api.dart';
export 'backend_contract.dart';

/// 模型输入/输出名（与 service.py:331-342 的 feed 键逐字一致）。
const _kLbw = 'L_bw';
const _kSam0 = 'sam_level0';
const _kSam1 = 'sam_level1';
const _kWd14 = 'wd14_embedding';
const _kRgbPred = 'rgb_pred';

/// generator 的 feed 顺序（＝ encoder/generator 图声明顺序，仅 `_remapInputs` 对
/// **输入**做位置回退用；输出侧不做位置回退，原因见 pickOutputKey）。
const _kGenFeedOrder = [_kLbw, _kSam0, _kSam1, _kWd14];

/// ORT CPU EP 的 intra-op 线程默认上限：ORT 默认按可用大核数开线程，每线程
/// 各持执行缓冲与栈；手机端限 4 压原生内存峰值，也避免与 Flutter UI 线程抢核。
/// 分块推理是串行的（并发 1），4 线程已足够喂饱 1024² 单块。低内存设备由
/// ResourceTier 降到 2（构造参数传入）。
const kDefaultIntraThreads = 4;

/// arena 策略（v0.5.6）：arena 开启保证块内分配零 malloc 开销，同时经 session
/// config entry 打开 **arena shrinkage**——每次 Run 后把工作区还给 OS，块间
/// RSS 回落。这替换了 v0.5.5 的 useArena:false（全程 malloc、逐块变慢）：
/// 块内同样快、块间同样低，是内存/速度的两全解（ORT RunOptions config 键
/// memory.enable_memory_arena_shrinkage，值=要收缩的 device，cpu:0）。
/// 若 ORT 拒绝该键（版本行为差异），[load] 的降级阶梯自动退回 useArena:false。
const _kShrinkageConfigs = {'memory.enable_memory_arena_shrinkage': 'cpu:0'};

class OrtOnnxBackend implements OnnxBackend {
  OrtOnnxBackend(this._store,
      {this.intraThreads = kDefaultIntraThreads, this.useArena = true});

  final WeightsStore _store;

  /// intra-op 线程上限：来自 ResourceTier 设备分级（低内存档 2，默认 4）。
  final int intraThreads;

  /// arena 策略：来自 ResourceTier 设备分级。false＝关闭 arena（单块原生
  /// 峰值最低，时间换峰值，见 resource_tier.dart）；true＝arena+shrinkage。
  final bool useArena;

  OrtSession? _sam;
  OrtSession? _gen;

  @override
  Future<void> load() async {
    if (_sam != null) return;
    final ort = OnnxRuntime();
    // 权重绝不入 APK/assets：只从 WeightsStore 的下载目录按文件路径加载
    // （插件 Kotlin 层 createSession(modelPath, options)——路径直达 ORT，
    // 不经 Java 字节数组双拷贝）。
    final sw = Stopwatch()..start();
    backendLog('encoder session 创建开始（${kWeightFiles[1].name}，'
        'threads=$intraThreads，arena=$useArena）${rssSuffix()}');
    final sam = await _createSession(ort, kWeightFiles[1]);
    backendLog('encoder session 创建完成（${sw.elapsedMilliseconds}ms）'
        '${rssSuffix()}');
    try {
      final genSw = Stopwatch()..start();
      backendLog('generator session 创建开始（${kWeightFiles[0].name}）'
          '${rssSuffix()}');
      _gen = await _createSession(ort, kWeightFiles[0]);
      backendLog('generator session 创建完成（${genSw.elapsedMilliseconds}ms）'
          '${rssSuffix()}');
      _sam = sam;
    } on Object {
      // generator 加载失败不能把 encoder 的 100MB+ 原生内存留在进程里。
      await sam.close();
      _sam = null;
      _gen = null;
      rethrow;
    }
  }

  /// 会话创建：按设备分级走 arena 开启或关闭两条路。
  ///
  /// arena 开启时必须带 shrinkage（每次 Run 后把工作区还给 OS）；若 ORT 拒绝
  /// 该键（版本行为差异），降级到 arena 关闭——绝不静默落到「arena 常驻
  /// 不还」的默认行为，那是低内存设备被系统杀进程的直接原因。
  Future<OrtSession> _createSession(OnnxRuntime ort, WeightFile weight) async {
    final path = _store.pathOf(weight);
    if (!useArena) {
      // 时间换峰值：malloc 每分配即还，无高水位、无 2^n 扩展过冲。
      return ort.createSession(path,
          options: OrtSessionOptions(
              intraOpNumThreads: intraThreads, useArena: false));
    }
    try {
      final s = await ort.createSession(path,
          options: OrtSessionOptions(
              intraOpNumThreads: intraThreads,
              useArena: true,
              sessionConfigs: _kShrinkageConfigs));
      backendLog('${weight.name}: arena+shrinkage 会话创建成功');
      return s;
    } on Object catch (e) {
      backendLog('${weight.name}: arena+shrinkage 被拒（$e），降级 no-arena');
      return await ort.createSession(path,
          options: OrtSessionOptions(
              intraOpNumThreads: intraThreads, useArena: false));
    }
  }

  @override
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(
      Float32List chw, int s) async {
    final sam = _samLoaded();
    requireSamInput(chw, s);
    final input = await OrtValue.fromList(chw, [1, 3, s, s]);
    Map<String, OrtValue>? outputs;
    final sw = Stopwatch()..start();
    try {
      // encoder 只有一个输入 rgb_input；用绑定名而非硬编码，防模型重导出漂移。
      final names = sam.inputNames;
      if (names.isEmpty) throw StateError('encoder session 没有输入名，绑定异常');
      backendLog('SAM Run 开始（s=$s）${rssSuffix()}');
      outputs = await sam.run({names.first: input});
      backendLog('SAM Run 完成（${sw.elapsedMilliseconds}ms）${rssSuffix()}');
      final f0 = await _flattenTimed(_pickOutput(outputs, _kSam0, 0, 2), _kSam0);
      final f1 = await _flattenTimed(_pickOutput(outputs, _kSam1, 1, 2), _kSam1);
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
    // 移除，而 closeSession 并不清该缓存（1.9.0 源码复核仍如此，见文件头绑定事实）。
    // 若第 2~4 个 fromList 抛出（真实触发：16 MB 的 sam_level0 原生 OOM），map 字面量
    // 整体失败、feed 根本不存在，未登记的张量将活到进程结束。
    final created = <OrtValue>[];
    Map<String, OrtValue>? outputs;
    final sw = Stopwatch()..start();
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
      backendLog('生成 Run 开始（s=$s，feed=${created.length} 张量）'
          '${rssSuffix()}');
      outputs = await gen.run(_remapInputs(gen, feed));
      backendLog('生成 Run 完成（${sw.elapsedMilliseconds}ms）${rssSuffix()}');
      final pred = _pickOutput(outputs, _kRgbPred, 0, 1);
      final (chw, shape) = await _flattenTimed(pred, _kRgbPred);
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

  /// 带计时的回传：asFlattenedList 是「原生堆 → Dart 堆」的大数组跨通道拷贝，
  /// 真机断连若发生在 Run 完成之后、这一步之中，日志能把死亡位置钉死在拷贝段。
  Future<(Float32List, List<int>)> _flattenTimed(
      OrtValue v, String label) async {
    final shape = v.shape;
    final sw = Stopwatch()..start();
    final data = await v.asFlattenedList();
    final out = flattenToFloat32(data, shape, label);
    backendLog('$label 回传完成（shape=$shape，'
        '${sw.elapsedMilliseconds}ms）${rssSuffix()}');
    return out;
  }
}


