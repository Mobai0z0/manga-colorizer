// dart:ffi 直调 libmnn_ffi.so（本仓库 mobile/android/app/src/main/cpp/mnn_ffi/
// 的薄 C ABI 封装，内部走 libMNN.so 的 C++ API）。
//
// 为什么再要一层 FFI：MNN 的公开 API 是 C++（Interpreter/Tensor），dart:ffi
// 无法直调 C++ 类方法；libmnn_ffi.so 把「按名喂入 → runSession → 按名拷出」
// 收敛成 9 个 C 函数。内存安全约定与 ort_ffi.dart 同源：
//   · 输入：Dart 侧 malloc 缓冲 memcpy 拷入（FFI 取不到 GC 堆地址），Run 返回
//     后在外层 finally 释放；
//   · 输出：形状创建期查询（静态模型），缓冲由 Dart 分配、原生 memcpy 拷出；
//     容量不足时原生返回 kErrShape 并带回所需大小，Dart 侧重试一次。
// 加载失败/错误全部以 [MnnFfiException] 出现；create 失败的原文经 msg 缓冲带回。
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'backend_log.dart';

/// 错误码（与 mnn_ffi.cpp 的常量逐字对应）。
class MnnFfiException implements Exception {
  const MnnFfiException(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'MnnFfiException(code=$code): $message';
}

// ---- C ABI 签名（mnn_ffi.cpp 逐条对应）----

typedef _CreateC = Pointer<Void> Function(
    Pointer<Utf8> path,
    Int32 threads,
    Int32 memoryMode,
    Int32 precision,
    Pointer<Pointer<Utf8>> inNames,
    Int32 inCount,
    Pointer<Int64> inShapeLens,
    Pointer<Int64> inShapesFlat,
    Pointer<Pointer<Utf8>> outNames,
    Int32 outCount,
    Pointer<Int32> errCode,
    Pointer<Utf8> msg,
    Int32 msgCap);
typedef _CreateD = Pointer<Void> Function(
    Pointer<Utf8>,
    int,
    int,
    int,
    Pointer<Pointer<Utf8>>,
    int,
    Pointer<Int64>,
    Pointer<Int64>,
    Pointer<Pointer<Utf8>>,
    int,
    Pointer<Int32>,
    Pointer<Utf8>,
    int);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);
typedef _CountC = Int32 Function(Pointer<Void>);
typedef _CountD = int Function(Pointer<Void>);
typedef _NameC = Int32 Function(
    Pointer<Void>, Int32 index, Pointer<Utf8> buf, Int32 cap);
typedef _NameD = int Function(Pointer<Void>, int, Pointer<Utf8>, int);
typedef _ShapeC = Int32 Function(Pointer<Void>, Pointer<Utf8> name,
    Int32 isInput, Pointer<Int64> dims, Int32 cap, Pointer<Int32> rank);
typedef _ShapeD = int Function(
    Pointer<Void>, Pointer<Utf8>, int, Pointer<Int64>, int, Pointer<Int32>);
typedef _RunMultiC = Int32 Function(
    Pointer<Void>,
    Pointer<Pointer<Utf8>> inNames,
    Pointer<Pointer<Float>> inData,
    Pointer<Int64> inSizes,
    Int32 inCount,
    Pointer<Pointer<Utf8>> outNames,
    Pointer<Pointer<Float>> outBufs,
    Pointer<Int64> outCaps,
    Pointer<Int64> outElements,
    Int32 outCount);
typedef _RunMultiD = int Function(
    Pointer<Void>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Float>>,
    Pointer<Int64>,
    int,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Float>>,
    Pointer<Int64>,
    Pointer<Int64>,
    int);

/// BackendConfig 内存/精度模式（MNNForwardType.h 枚举值）。
enum MnnMemoryMode { normal, high, low }

enum MnnPrecisionMode { normal, high, low }

/// libmnn_ffi.so 的进程级单例：函数指针一次解析。
/// 同进程多 isolate 各自 load 也安全（DynamicLibrary.open 同 so 同句柄）。
class MnnFfi {
  MnnFfi._(this._lib);

  static MnnFfi? _instance;

  final DynamicLibrary _lib;

  late final _CreateD _create =
      _lib.lookupFunction<_CreateC, _CreateD>('mnn_create');
  late final _DestroyD _destroy =
      _lib.lookupFunction<_DestroyC, _DestroyD>('mnn_destroy');
  late final _CountD _inputCount =
      _lib.lookupFunction<_CountC, _CountD>('mnn_input_count');
  late final _CountD _outputCount =
      _lib.lookupFunction<_CountC, _CountD>('mnn_output_count');
  late final _NameD _inputName =
      _lib.lookupFunction<_NameC, _NameD>('mnn_input_name');
  late final _NameD _outputName =
      _lib.lookupFunction<_NameC, _NameD>('mnn_output_name');
  late final _ShapeD _tensorShape =
      _lib.lookupFunction<_ShapeC, _ShapeD>('mnn_tensor_shape');
  late final _RunMultiD _runMulti =
      _lib.lookupFunction<_RunMultiC, _RunMultiD>('mnn_run_multi');

  /// 打开 libmnn_ffi.so（缺 so 时 ArgumentError 原样透传）。
  static MnnFfi load() {
    final cached = _instance;
    if (cached != null) return cached;
    backendLog('[mnn-ffi] 打开 libmnn_ffi.so…');
    final f = MnnFfi._(DynamicLibrary.open('libmnn_ffi.so'));
    backendLog('[mnn-ffi] so 已打开');
    _instance = f;
    return f;
  }

  /// 创建会话（Module API，创建期含零输入探测前向＝预热+输出形状学习）。
  /// [inputNames]/[outputNames] 为契约 IO 名（与模型张量名逐字一致）。模型声明
  /// 含动态维（-1）时用 [inputShapes] 里对应输入的形状兜底（null = 无提示）。
  MnnFfiSession createSession(String path,
      {required List<String> inputNames,
      required List<String> outputNames,
      List<List<int>?> inputShapes = const [],
      required int threads,
      MnnMemoryMode memoryMode = MnnMemoryMode.normal,
      MnnPrecisionMode precisionMode = MnnPrecisionMode.normal}) {
    final pathC = path.toNativeUtf8();
    final err = malloc<Int32>();
    final msg = malloc<Uint8>(512);
    final inCs = [for (final n in inputNames) n.toNativeUtf8()];
    final outCs = [for (final n in outputNames) n.toNativeUtf8()];
    final inArr = malloc<Pointer<Utf8>>(inCs.length);
    final outArr = malloc<Pointer<Utf8>>(outCs.length);
    for (var i = 0; i < inCs.length; i++) {
      inArr[i] = inCs[i];
    }
    for (var i = 0; i < outCs.length; i++) {
      outArr[i] = outCs[i];
    }
    // 形状提示：逐输入的秩 + 拼接维度（秩 0 = 无提示）。
    final lens = <int>[];
    final flat = <int>[];
    for (var i = 0; i < inputNames.length; i++) {
      final shape =
          i < inputShapes.length ? inputShapes[i] : null;
      if (shape == null || shape.isEmpty) {
        lens.add(0);
      } else {
        lens.add(shape.length);
        flat.addAll(shape);
      }
    }
    final lensArr = malloc<Int64>(lens.length);
    final flatArr = malloc<Int64>(flat.length);
    for (var i = 0; i < lens.length; i++) {
      lensArr[i] = lens[i];
    }
    for (var i = 0; i < flat.length; i++) {
      flatArr[i] = flat[i];
    }
    Pointer<Void>? handle;
    try {
      handle = _create(pathC, threads, memoryMode.index, precisionMode.index,
          inArr, inCs.length, lensArr, flatArr, outArr, outCs.length, err,
          msg.cast<Utf8>(), 512);
      if (handle == nullptr) {
        final m = msg.cast<Utf8>().toDartString();
        throw MnnFfiException(err.value, 'mnn_create 失败: $m');
      }
      final session = MnnFfiSession._(this, handle);
      handle = null;
      session._init();
      return session;
    } finally {
      if (handle != null) _destroy(handle);
      malloc.free(pathC);
      malloc.free(err);
      malloc.free(msg);
      for (final p in inCs) {
        malloc.free(p);
      }
      for (final p in outCs) {
        malloc.free(p);
      }
      malloc.free(inArr);
      malloc.free(outArr);
      malloc.free(lensArr);
      malloc.free(flatArr);
    }
  }
}

/// 一个已就绪的 MNN session（IO 名与形状缓存 + 同步 run + close）。
class MnnFfiSession {
  MnnFfiSession._(this._ffi, this._handle);

  final MnnFfi _ffi;
  Pointer<Void> _handle;

  late final List<String> inputNames;
  late final List<String> outputNames;
  late final Map<String, List<int>> inputShapes;
  late final Map<String, List<int>> outputShapes;

  bool get closed => _handle == nullptr;

  void _init() {
    inputNames = _names(input: true);
    outputNames = _names(input: false);
    inputShapes = {
      for (final n in inputNames) n: _queryShape(n, input: true),
    };
    outputShapes = {
      for (final n in outputNames) n: _queryShape(n, input: false),
    };
  }

  List<String> _names({required bool input}) {
    final count = input ? _ffi._inputCount(_handle) : _ffi._outputCount(_handle);
    final buf = malloc<Uint8>(256);
    final names = <String>[];
    try {
      for (var i = 0; i < count; i++) {
        final rc = input
            ? _ffi._inputName(_handle, i, buf.cast<Utf8>(), 256)
            : _ffi._outputName(_handle, i, buf.cast<Utf8>(), 256);
        if (rc != 0) {
          throw MnnFfiException(2, '第 $i 个${input ? "输入" : "输出"}名读取失败');
        }
        final view = buf.asTypedList(256);
        final end = view.indexOf(0);
        names.add(utf8.decode(view.sublist(0, end < 0 ? 256 : end)));
      }
      return names;
    } finally {
      malloc.free(buf);
    }
  }

  List<int> _queryShape(String name, {required bool input}) {
    final nameC = name.toNativeUtf8();
    final dims = malloc<Int64>(8);
    final rank = malloc<Int32>();
    try {
      final rc = _ffi._tensorShape(
          _handle, nameC, input ? 1 : 0, dims, 8, rank);
      if (rc != 0) {
        throw MnnFfiException(rc, '形状查询失败（$name，err=$rc）');
      }
      return List<int>.generate(rank.value, (i) => dims[i]);
    } finally {
      malloc.free(nameC);
      malloc.free(dims);
      malloc.free(rank);
    }
  }

  /// 同步推理：inputs=名字→(数据, 形状)；按 [outputNames] 取输出，
  /// 返回 名字→(拷贝数据, 形状)。一次会话运行取全部所需输出（encoder 的
  /// sam_level0/1 必须同批）。
  ///
  /// 输入长度必须与创建期查询的声明形状元素数一致；输出缓冲按创建期形状分配，
  /// 容量不足（kErrShape）时按原生回传的所需大小整体重试一次（会重跑会话，
  /// 静态模型下不应发生，仅为鲁棒兜底）。
  Map<String, (Float32List, List<int>)> run(
      Map<String, (Float32List, List<int>)> inputs,
      {List<String>? outputNames}) {
    final h = _handle;
    if (h == nullptr) throw StateError('MnnFfiSession 已 close');
    final outs = outputNames ?? this.outputNames;
    for (final n in outs) {
      if (!outputShapes.containsKey(n)) {
        throw StateError('输出 $n 不在会话声明中（${this.outputNames}）');
      }
    }
    // 输入缓冲 malloc 拷入（同步调用期间地址稳定；Run 返回后 finally 释放）。
    final nameCs = <Pointer<Utf8>>[];
    final lengths = <int>[];
    final dataTmp = <Pointer<Float>>[];
    final outNameCs = <Pointer<Utf8>>[];
    final outTmp = <Pointer<Float>>[];
    final outData = <String, Float32List>{};
    Pointer<Pointer<Utf8>>? inNamesArr;
    Pointer<Pointer<Float>>? dataArr;
    Pointer<Int64>? sizesArr;
    Pointer<Pointer<Utf8>>? outNamesArr;
    Pointer<Pointer<Float>>? outBufsArr;
    Pointer<Int64>? capsArr;
    try {
      for (final e in inputs.entries) {
        nameCs.add(e.key.toNativeUtf8());
        final data = e.value.$1;
        final declared = inputShapes[e.key];
        var expected = 1;
        for (final d in declared ?? const <int>[]) {
          expected *= d;
        }
        if (declared != null && expected != data.length) {
          throw MnnFfiException(
              3, '输入 ${e.key} 长度 ${data.length} != 声明 $expected');
        }
        final buf = malloc<Float>(data.length);
        dataTmp.add(buf);
        buf.asTypedList(data.length).setAll(0, data);
        lengths.add(data.length);
      }
      for (final n in outs) {
        outNameCs.add(n.toNativeUtf8());
      }
      int capOf(String n) =>
          outputShapes[n]!.fold<int>(1, (a, d) => d > 0 ? a * d : a);
      var outCaps = {for (final n in outs) n: capOf(n)};
      for (final n in outs) {
        outData[n] = Float32List(outCaps[n]!);
        outTmp.add(malloc<Float>(outCaps[n]!));
      }
      final needed = malloc<Int64>(outs.length);

      // 数组一次分配（输入侧与输出名恒定；重试只更新 caps 与输出缓冲指针）。
      inNamesArr = malloc<Pointer<Utf8>>(nameCs.length);
      dataArr = malloc<Pointer<Float>>(nameCs.length);
      sizesArr = malloc<Int64>(nameCs.length);
      for (var i = 0; i < nameCs.length; i++) {
        inNamesArr[i] = nameCs[i];
        dataArr[i] = dataTmp[i];
        sizesArr[i] = lengths[i];
      }
      outNamesArr = malloc<Pointer<Utf8>>(outs.length);
      outBufsArr = malloc<Pointer<Float>>(outs.length);
      capsArr = malloc<Int64>(outs.length);
      for (var i = 0; i < outs.length; i++) {
        outNamesArr[i] = outNameCs[i];
        outBufsArr[i] = outTmp[i];
        capsArr[i] = outCaps[outs[i]]!;
      }

      var attempt = 0;
      while (true) {
        attempt++;
        if (attempt > 2) {
          throw const MnnFfiException(3, '输出容量重试两次仍不足（形状契约破坏）');
        }
        final rc = _ffi._runMulti(h, inNamesArr, dataArr, sizesArr,
            nameCs.length, outNamesArr, outBufsArr, capsArr, needed,
            outs.length);
        if (rc == 0) {
          for (var i = 0; i < outs.length; i++) {
            outData[outs[i]]!
                .setAll(0, outTmp[i].asTypedList(outCaps[outs[i]]!));
          }
          break;
        }
        if (rc == 3) {
          // 容量不足：按原生回传的所需大小重建输出缓冲后重试一次。
          var grew = false;
          for (var i = 0; i < outs.length; i++) {
            final need = needed[i];
            if (need > outCaps[outs[i]]!) {
              outCaps[outs[i]] = need;
              outData[outs[i]] = Float32List(need);
              grew = true;
            }
          }
          if (!grew) {
            throw const MnnFfiException(3, 'mnn_run 返回 kErrShape 但无容量缺口');
          }
          for (final p in outTmp) {
            malloc.free(p);
          }
          outTmp.clear();
          for (var i = 0; i < outs.length; i++) {
            outTmp.add(malloc<Float>(outCaps[outs[i]]!));
            outBufsArr[i] = outTmp[i];
            capsArr[i] = outCaps[outs[i]]!;
          }
          continue;
        }
        throw MnnFfiException(rc, 'mnn_run 失败（outputs=$outs）');
      }
      return {
        for (final n in outs) n: (outData[n]!, outputShapes[n]!),
      };
    } finally {
      for (final p in dataTmp) {
        malloc.free(p);
      }
      for (final c in nameCs) {
        malloc.free(c);
      }
      for (final c in outNameCs) {
        malloc.free(c);
      }
      for (final p in outTmp) {
        malloc.free(p);
      }
      final a1 = inNamesArr;
      if (a1 != null) malloc.free(a1);
      final a2 = dataArr;
      if (a2 != null) malloc.free(a2);
      final a3 = sizesArr;
      if (a3 != null) malloc.free(a3);
      final a4 = outNamesArr;
      if (a4 != null) malloc.free(a4);
      final a5 = outBufsArr;
      if (a5 != null) malloc.free(a5);
      final a6 = capsArr;
      if (a6 != null) malloc.free(a6);
    }
  }

  /// 释放 session（幂等）。
  void close() {
    final h = _handle;
    if (h == nullptr) return;
    _handle = nullptr;
    _ffi._destroy(h);
  }
}
