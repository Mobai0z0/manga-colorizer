// dart:ffi 直调 libonnxruntime.so 的 ORT C API——卓易通（HarmonyOS NEXT Android
// 兼容层）环境下的修复路径。
//
// 根因（v0.5.16~18 真机取证链）：:inference 进程恒在首个 ORT Run 中 SIGABRT，
// 调用栈恒为 libapp_native(遗嘱) ← libc(pthread_kill) ← libart ← libbase
// (android::base::LogMessage 析构＝平台 CHECK/LOG(FATAL) 指纹) ← libart ←
// libonnxruntime4j_jni.so+0x9730/0xb330/0xf848（ORT Java JNI 桥）← libart 托管帧
// ——ART 层 CHECK 在 ORT 的 Java/JNI 桥路径触发 abort；threads=4/1 均崩、offset
// 确定性一致（并发假设出局），ORT 1.26/1.27/1.28 版本轴出局。修复＝从调用链
// 剔除 Java/JNI/libart：dart:ffi 直调 libonnxruntime.so 的版本化 C API
// （OrtGetApiBase()->GetApi(ORT_API_VERSION)），该 so 无 JVM 依赖。
//
// 绑定事实（vendor 的 1.27.0 header mobile/android/app/src/main/cpp/ort/
// onnxruntime_c_api.h，ORT_API_VERSION=27；构建期脚本对 31 个用到的 OrtApi
// 序号逐一核对过，成员总数 412）：OrtApi 是纯函数指针数组，第 i 个成员取
// api.cast<Pointer<Pointer<NativeFunction>>>().elementAt(i)。OrtApiBase 结构
// 逐字核对：GetApi 是第 0 槽、GetVersionString 第 1 槽。ORTCHAR_T 在非
// Windows 平台 = char。OrtSessionOptionsAppendExecutionProvider_CPU 不在
// OrtApi 结构体内，是独立 C 导出（AAR 实证 libonnxruntime.so 导出该符号；
// 插件 Kotlin addCPU 最终也走它），签名 OrtStatus*(OrtSessionOptions*, int
// use_arena)。不 append 也走默认 CPU EP 且 arena 默认开——因此 useArena=false
// 必须显式 append(options, 0)。
//
// 内存安全约定：CreateTensorWithDataAsOrtValue 不拷贝数据、直接引用调用方缓冲
// （header: _Inout_ void* p_data），而 dart:ffi 无法取 GC 堆内 TypedData 的地址
// ——因此输入先 malloc 原生缓冲 memcpy 拷入再交给 ORT；所有 Run 均为**同步**
// FFI 调用，输入缓冲在 Run 返回后才在外层 finally 释放。输出张量由 ORT 分配
// （outputs 槽位预填 nullptr），GetTensorMutableData 读出后立即 memcpy 进 Dart
// Float32List 并 ReleaseValue，杜绝悬垂。
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'backend_log.dart';

/// ORT C API 版本（vendor header ORT_API_VERSION）——与 gradle force 的
/// onnxruntime-android 1.27.0 一致。GetApi 版本不匹配时 ORT 返回 nullptr。
const int kOrtApiVersion = 27;

/// ort_ffi 层异常：携带 ORT 错误码与原文（GetErrorMessage）。
class OrtFfiException implements Exception {
  const OrtFfiException(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'OrtFfiException(code=$code): $message';
}

// ---- OrtApi 成员的 C 签名（与 header 逐条对应；不透明句柄一律 Pointer<Void>）----

typedef _CreateEnvC = Pointer<Void> Function(
    Int32 loggingLevel, Pointer<Utf8> logId, Pointer<Pointer<Void>> out);
typedef _CreateSessionOptionsC = Pointer<Void> Function(
    Pointer<Pointer<Void>> out);
typedef _SetIntraOpNumThreadsC = Pointer<Void> Function(
    Pointer<Void> options, Int32 threads);
typedef _AppendExecutionProviderCpuC = Pointer<Void> Function(
    Pointer<Void> options, Int32 useArena);
typedef _AddConfigEntryC = Pointer<Void> Function(
    Pointer<Void> options, Pointer<Utf8> key, Pointer<Utf8> value);
typedef _CreateSessionC = Pointer<Void> Function(Pointer<Void> env,
    Pointer<Utf8> modelPath, Pointer<Void> options, Pointer<Pointer<Void>> out);
typedef _SessionGetIOCountC = Pointer<Void> Function(
    Pointer<Void> session, Pointer<Size> out);
typedef _SessionGetIONameC = Pointer<Void> Function(Pointer<Void> session,
    Size index, Pointer<Void> allocator, Pointer<Pointer<Utf8>> out);
typedef _CreateCpuMemoryInfoC = Pointer<Void> Function(
    Int32 allocatorType, Int32 memType, Pointer<Pointer<Void>> out);
typedef _CreateTensorWithDataC = Pointer<Void> Function(
    Pointer<Void> info,
    Pointer<Void> pData,
    Size pDataLen,
    Pointer<Int64> shape,
    Size shapeLen,
    Int32 type,
    Pointer<Pointer<Void>> out);
typedef _RunC = Pointer<Void> Function(
    Pointer<Void> session,
    Pointer<Void> runOptions,
    Pointer<Pointer<Utf8>> inputNames,
    Pointer<Pointer<Void>> inputs,
    Size inputLen,
    Pointer<Pointer<Utf8>> outputNames,
    Size outputNamesLen,
    Pointer<Pointer<Void>> outputs);
typedef _GetTensorTypeAndShapeC = Pointer<Void> Function(
    Pointer<Void> value, Pointer<Pointer<Void>> out);
typedef _GetDimensionsCountC = Pointer<Void> Function(
    Pointer<Void> info, Pointer<Size> out);
typedef _GetDimensionsC = Pointer<Void> Function(
    Pointer<Void> info, Pointer<Int64> dims, Size dimsLen);
typedef _GetTensorMutableDataC = Pointer<Void> Function(
    Pointer<Void> value, Pointer<Pointer<Void>> out);
typedef _GetAllocatorWithDefaultOptionsC = Pointer<Void> Function(
    Pointer<Pointer<Void>> out);
typedef _AllocatorFreeC = Pointer<Void> Function(
    Pointer<Void> allocator, Pointer<Void> p);
typedef _GetApiC = Pointer<Void> Function(Uint32 version);
typedef _GetErrorCodeC = Int32 Function(Pointer<Void> status);
typedef _GetErrorMessageC = Pointer<Utf8> Function(Pointer<Void> status);
typedef _ReleaseC = Void Function(Pointer<Void> p);

// ---- 对应的 Dart 侧签名 ----

typedef _CreateEnvD = Pointer<Void> Function(
    int, Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CreateSessionOptionsD = Pointer<Void> Function(
    Pointer<Pointer<Void>>);
typedef _SetThreadsD = Pointer<Void> Function(Pointer<Void>, int);
typedef _AppendEpCpuD = Pointer<Void> Function(Pointer<Void>, int);
typedef _AddConfigEntryD = Pointer<Void> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _CreateSessionD = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetIOCountD = Pointer<Void> Function(Pointer<Void>, Pointer<Size>);
typedef _GetIONameD = Pointer<Void> Function(
    Pointer<Void>, int, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _CreateCpuMemoryInfoD = Pointer<Void> Function(
    int, int, Pointer<Pointer<Void>>);
typedef _CreateTensorWithDataD = Pointer<Void> Function(Pointer<Void>,
    Pointer<Void>, int, Pointer<Int64>, int, int, Pointer<Pointer<Void>>);
typedef _RunD = Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Void>>,
    int,
    Pointer<Pointer<Utf8>>,
    int,
    Pointer<Pointer<Void>>);
typedef _GetTypeAndShapeD = Pointer<Void> Function(
    Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetDimCountD = Pointer<Void> Function(Pointer<Void>, Pointer<Size>);
typedef _GetDimsD = Pointer<Void> Function(
    Pointer<Void>, Pointer<Int64>, int);
typedef _GetMutableDataD = Pointer<Void> Function(
    Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetAllocatorD = Pointer<Void> Function(Pointer<Pointer<Void>>);
typedef _AllocatorFreeD = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _ReleaseD = void Function(Pointer<Void>);

/// ONNXTensorElementDataType_FLOAT（header 枚举值 1）。
const int _kTensorFloat = 1;

/// OrtAllocatorType：OrtDeviceAllocator=0（header 枚举）。
const int _kOrtDeviceAllocator = 0;

/// OrtMemType：OrtMemTypeDefault=0。
const int _kOrtMemTypeDefault = 0;

/// OrtLoggingLevel：WARNING=2（ORT 内部告警进 stderr，取证需要）。
const int _kOrtLoggingWarning = 2;

/// ORT C API 的进程级单例：GetApi 只调一次，所有成员函数指针一次取齐。
///
/// 同进程多 isolate 各自 [load] 也安全：DynamicLibrary.open 对同一 so 返回同
/// 句柄，函数指针表只读；OrtEnv 全进程一个（ORT 允许多 env，单例更省）。
class OrtFfi {
  OrtFfi._(this._lib, this._api, this._env);

  static OrtFfi? _instance;

  /// 打开 libonnxruntime.so、解析 OrtApi、创建进程级 OrtEnv。
  /// so 缺失时抛 ArgumentError（原样透传，调用方按需包装）。
  ///
  /// v0.5.20 分步取证：真机/模拟器实测 load() 内秒死（SIGSEGV，无任何
  /// backend 日志）——每一步完成即打点（backendLog → 日志页 + stderr 镜像），
  /// 死点可钉到 open/GetApiBase/GetApi/bind/CreateEnv 具体一步。
  static OrtFfi load() {
    final cached = _instance;
    if (cached != null) return cached;
    void step(String m) => backendLog('[ffi-load] $m');
    step('打开 libonnxruntime.so…');
    final lib = DynamicLibrary.open('libonnxruntime.so');
    step('so 已打开，lookup OrtGetApiBase…');
    final getApiBase = lib
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'OrtGetApiBase')();
    if (getApiBase == nullptr) {
      // 不加这层检查就是「读 null+第0槽」→ SIGSEGV 秒死且无任何 Dart 栈
      // （模拟器首战死法）。lookup 成功但调用返回 null 属异常环境，明确报错。
      throw const OrtFfiException(
          -1, 'OrtGetApiBase() 返回 null：libonnxruntime.so 加载异常');
    }
    step('OrtGetApiBase 已调用，读 GetApi（第 0 槽）…');
    // OrtApiBase 第 0 槽 = GetApi（header 逐字核对：GetApi 在前）。
    final slots = getApiBase.cast<Pointer<Pointer<NativeFunction<_GetApiC>>>>();
    final getApi = slots[0].value.asFunction<Pointer<Void> Function(int)>();
    // v0.5.22 槽位自检：MuMu x86_64 实测死在「GetVersionString（第 1 槽）调用中」
    // 之后、遗嘱 SIGSEGV addr=0x0——跳到空指针的指纹（call 0x0 取指失败）。
    // 静态分析：AAR 的 .data.rel.ro 里 OrtApiBase 模板两槽文件值=0，真值靠
    // 标准 RELA 重定位（已实证 RELA 表含 off=0x1fe9598/0x1fe95a0 → addend
    // 0xa651e0/0xa65220）。若某环境的 linker 未应用 RELA，两槽运行时=0，
    // 第一个被调用的槽函数指针就跳 0。这里直接读原始指针值打日志：0 = 铁证。
    final slot0raw = slots[0].value;
    final slot1raw = getApiBase
        .cast<Pointer<Pointer<NativeFunction<Pointer<Utf8> Function()>>>>()[1]
        .value;
    step('槽位自检：slot0(GetApi)=0x${slot0raw.address.toRadixString(16)}、'
        'slot1(GetVersionString)=0x${slot1raw.address.toRadixString(16)}');
    if (slot0raw == nullptr || slot1raw == nullptr) {
      throw OrtFfiException(
          -2, 'OrtApiBase 槽位为空（slot0=${slot0raw.address}，'
          'slot1=${slot1raw.address}）：libonnxruntime.so 的 RELA 重定位未生效'
          '（linker 兼容问题），FFI 查表路径不可用');
    }
    // v0.5.21 鉴别：GetApi 之前先调 GetVersionString（第 1 槽，纯静态串）。
    // 它成功 = OrtApiBase 基址有效，崩点只可能在 GetApi 调用本身；
    // 它崩 = OrtApiBase 指针就是垃圾（so 加载/重定位层问题）。
    step('GetVersionString（第 1 槽）调用中…');
    final ver = slot1raw.asFunction<Pointer<Utf8> Function()>()();
    step('GetVersionString 成功：${ver.toDartString()}');
    step('GetApi($kOrtApiVersion) 调用中…');
    final api = getApi(kOrtApiVersion);
    if (api == nullptr) {
      throw OrtFfiException(
          -1, 'OrtGetApiBase()->GetApi($kOrtApiVersion) 返回 null：运行时 ORT '
          '版本低于 vendor header 的 API 版本');
    }
    step('OrtApi 指针已取得，绑定 31 个成员…');
    final f = OrtFfi._(lib, api, nullptr);
    f._bind();
    step('成员绑定完成，versionString=${f.versionString()}');
    // CreateEnv（WARNING 级，logid 与 logcat 前缀同名便于归并）。
    final logId = 'manga-inference'.toNativeUtf8();
    final envOut = malloc<Pointer<Void>>();
    try {
      step('CreateEnv 调用中…');
      f.check(f._createEnv(_kOrtLoggingWarning, logId, envOut));
      f._env = envOut.value;
      step('CreateEnv 完成：OrtFfi.load() 全部成功');
    } finally {
      malloc.free(logId);
      malloc.free(envOut);
    }
    _instance = f;
    return f;
  }

  final DynamicLibrary _lib;
  final Pointer<Void> _api;
  Pointer<Void> _env = nullptr;

  // OrtApi 成员索引（构建期脚本对 header 全表核对，idx 从 0 起；
  // GetErrorCode/GetErrorMessage/CreateStatus 是裸函数指针成员而非宏）。
  static const _idxCreateEnv = 3;
  static const _idxGetErrorCode = 1;
  static const _idxGetErrorMessage = 2;
  static const _idxCreateSession = 7;
  static const _idxRun = 9;
  static const _idxCreateSessionOptions = 10;
  static const _idxSetIntraOpNumThreads = 24;
  static const _idxSessionGetInputCount = 30;
  static const _idxSessionGetOutputCount = 31;
  static const _idxSessionGetInputName = 36;
  static const _idxSessionGetOutputName = 37;
  static const _idxCreateTensorWithDataAsOrtValue = 49;
  static const _idxGetTensorMutableData = 51;
  static const _idxGetDimensionsCount = 61;
  static const _idxGetDimensions = 62;
  static const _idxGetTensorTypeAndShape = 65;
  static const _idxCreateCpuMemoryInfo = 69;
  static const _idxAllocatorFree = 76;
  static const _idxGetAllocatorWithDefaultOptions = 78;
  static const _idxReleaseEnv = 92;
  static const _idxReleaseStatus = 93;
  static const _idxReleaseMemoryInfo = 94;
  static const _idxReleaseSession = 95;
  static const _idxReleaseValue = 96;
  static const _idxReleaseTensorTypeAndShapeInfo = 99;
  static const _idxReleaseSessionOptions = 100;
  static const _idxAddSessionConfigEntry = 130;

  late final _CreateEnvD _createEnv;
  late final _CreateSessionOptionsD _createSessionOptions;
  late final _SetThreadsD _setIntraOpNumThreads;
  late final _AddConfigEntryD _addSessionConfigEntry;
  late final _CreateSessionD _createSession;
  late final _GetIOCountD _sessionGetInputCount;
  late final _GetIOCountD _sessionGetOutputCount;
  late final _GetIONameD _sessionGetInputName;
  late final _GetIONameD _sessionGetOutputName;
  late final _CreateCpuMemoryInfoD _createCpuMemoryInfo;
  late final _CreateTensorWithDataD _createTensorWithData;
  late final _RunD _run;
  late final _GetTypeAndShapeD _getTensorTypeAndShape;
  late final _GetDimCountD _getDimensionsCount;
  late final _GetDimsD _getDimensions;
  late final _GetMutableDataD _getTensorMutableData;
  late final _GetAllocatorD _getAllocatorWithDefaultOptions;
  late final _AllocatorFreeD _allocatorFree;
  late final int Function(Pointer<Void>) _getErrorCode;
  late final Pointer<Utf8> Function(Pointer<Void>) _getErrorMessage;
  late final _ReleaseD _releaseEnv;
  late final _ReleaseD _releaseStatus;
  late final _ReleaseD _releaseMemoryInfo;
  late final _ReleaseD _releaseSession;
  late final _ReleaseD _releaseValue;
  late final _ReleaseD _releaseSessionOptions;
  late final _ReleaseD _releaseTensorTypeAndShapeInfo;

  /// 独立 C 导出：OrtSessionOptionsAppendExecutionProvider_CPU(options,
  /// use_arena)——不在 OrtApi 结构体内（AAR 实证），必须单独 lookup。
  late final _AppendEpCpuD _appendExecutionProviderCpu;

  /// 取 OrtApi 第 idx 槽的函数指针（OrtApi 是纯函数指针数组；asFunction 是
  /// `Pointer<NativeFunction>` 的扩展方法，所以这里返回指针而不是解引用值）。
  Pointer<NativeFunction<T>> _slot<T extends Function>(int idx) {
    final slots = _api.cast<Pointer<Pointer<NativeFunction<T>>>>();
    return slots[idx].value;
  }

  void _bind() {
    Pointer<NativeFunction<T>> member<T extends Function>(int idx) =>
        _slot<T>(idx);
    _createEnv = member<_CreateEnvC>(_idxCreateEnv).asFunction<_CreateEnvD>();
    _createSessionOptions = member<_CreateSessionOptionsC>(
            _idxCreateSessionOptions)
        .asFunction<_CreateSessionOptionsD>();
    _setIntraOpNumThreads = member<_SetIntraOpNumThreadsC>(
            _idxSetIntraOpNumThreads)
        .asFunction<_SetThreadsD>();
    _addSessionConfigEntry = member<_AddConfigEntryC>(_idxAddSessionConfigEntry)
        .asFunction<_AddConfigEntryD>();
    _createSession =
        member<_CreateSessionC>(_idxCreateSession).asFunction<_CreateSessionD>();
    _sessionGetInputCount = member<_SessionGetIOCountC>(
            _idxSessionGetInputCount)
        .asFunction<_GetIOCountD>();
    _sessionGetOutputCount = member<_SessionGetIOCountC>(
            _idxSessionGetOutputCount)
        .asFunction<_GetIOCountD>();
    _sessionGetInputName = member<_SessionGetIONameC>(_idxSessionGetInputName)
        .asFunction<_GetIONameD>();
    _sessionGetOutputName =
        member<_SessionGetIONameC>(_idxSessionGetOutputName)
            .asFunction<_GetIONameD>();
    _createCpuMemoryInfo = member<_CreateCpuMemoryInfoC>(
            _idxCreateCpuMemoryInfo)
        .asFunction<_CreateCpuMemoryInfoD>();
    _createTensorWithData = member<_CreateTensorWithDataC>(
            _idxCreateTensorWithDataAsOrtValue)
        .asFunction<_CreateTensorWithDataD>();
    _run = member<_RunC>(_idxRun).asFunction<_RunD>();
    _getTensorTypeAndShape = member<_GetTensorTypeAndShapeC>(
            _idxGetTensorTypeAndShape)
        .asFunction<_GetTypeAndShapeD>();
    _getDimensionsCount = member<_GetDimensionsCountC>(_idxGetDimensionsCount)
        .asFunction<_GetDimCountD>();
    _getDimensions =
        member<_GetDimensionsC>(_idxGetDimensions).asFunction<_GetDimsD>();
    _getTensorMutableData = member<_GetTensorMutableDataC>(
            _idxGetTensorMutableData)
        .asFunction<_GetMutableDataD>();
    _getAllocatorWithDefaultOptions = member<_GetAllocatorWithDefaultOptionsC>(
            _idxGetAllocatorWithDefaultOptions)
        .asFunction<_GetAllocatorD>();
    _allocatorFree =
        member<_AllocatorFreeC>(_idxAllocatorFree).asFunction<_AllocatorFreeD>();
    _getErrorCode = member<_GetErrorCodeC>(_idxGetErrorCode)
        .asFunction<int Function(Pointer<Void>)>();
    _getErrorMessage = member<_GetErrorMessageC>(_idxGetErrorMessage)
        .asFunction<Pointer<Utf8> Function(Pointer<Void>)>();
    _releaseEnv = member<_ReleaseC>(_idxReleaseEnv).asFunction<_ReleaseD>();
    _releaseStatus =
        member<_ReleaseC>(_idxReleaseStatus).asFunction<_ReleaseD>();
    _releaseMemoryInfo =
        member<_ReleaseC>(_idxReleaseMemoryInfo).asFunction<_ReleaseD>();
    _releaseSession =
        member<_ReleaseC>(_idxReleaseSession).asFunction<_ReleaseD>();
    _releaseValue =
        member<_ReleaseC>(_idxReleaseValue).asFunction<_ReleaseD>();
    _releaseSessionOptions =
        member<_ReleaseC>(_idxReleaseSessionOptions).asFunction<_ReleaseD>();
    _releaseTensorTypeAndShapeInfo =
        member<_ReleaseC>(_idxReleaseTensorTypeAndShapeInfo)
            .asFunction<_ReleaseD>();
    _appendExecutionProviderCpu = _lib
        .lookupFunction<_AppendExecutionProviderCpuC, _AppendEpCpuD>(
            'OrtSessionOptionsAppendExecutionProvider_CPU');
  }

  /// ORT 运行时版本串（OrtApiBase::GetVersionString，第 1 槽；诊断日志用）。
  String versionString() {
    final p = _slot<Pointer<Utf8> Function()>(1);
    return p.asFunction<Pointer<Utf8> Function()>()().toDartString();  }

  /// 状态检查：非 null status → 取码+原文并释放，抛 [OrtFfiException]。
  void check(Pointer<Void> status) {
    if (status == nullptr) return;
    final code = _getErrorCode(status);
    final msg = _getErrorMessage(status).toDartString();
    _releaseStatus(status);
    throw OrtFfiException(code, msg);
  }

  /// 创建 session（同步）。[useArena]=false 时显式 append CPU EP 关 arena
  /// （默认 CPU EP 的 arena 是开的）；[sessionConfigs] 逐条 AddSessionConfigEntry。
  OrtFfiSession createSession(String path,
      {required int intraThreads,
      required bool useArena,
      Map<String, String> sessionConfigs = const {}}) {
    final optOut = malloc<Pointer<Void>>();
    final pathC = path.toNativeUtf8();
    // options 无论 createSession 成败都必须 ReleaseSessionOptions
    // （CreateSession 内部持有的是 options 的拷贝，不接管调用方句柄）。
    Pointer<Void>? options;
    try {
      check(_createSessionOptions(optOut));
      options = optOut.value;
      check(_setIntraOpNumThreads(options, intraThreads));
      // arena 开关统一走 AppendExecutionProvider_CPU 的 use_arena 参数
      // （与插件 Kotlin addCPU(useArena)/setCPUArenaAllocator 等价）。
      check(_appendExecutionProviderCpu(options, useArena ? 1 : 0));
      for (final e in sessionConfigs.entries) {
        final k = e.key.toNativeUtf8();
        final v = e.value.toNativeUtf8();
        try {
          check(_addSessionConfigEntry(options, k, v));
        } finally {
          malloc.free(k);
          malloc.free(v);
        }
      }
      final sessOut = malloc<Pointer<Void>>();
      try {
        check(_createSession(_env, pathC, options, sessOut));
        return OrtFfiSession(this, sessOut.value);
      } finally {
        malloc.free(sessOut);
      }
    } finally {
      if (options != null) _releaseSessionOptions(options);
      malloc.free(pathC);
      malloc.free(optOut);
    }
  }

  /// 释放进程级 env（测试收尾用；生产进程生命周期=进程，无需调）。
  void releaseEnv() {
    if (_env != nullptr) {
      _releaseEnv(_env);
      _env = nullptr;
    }
  }

  Pointer<Void> get env => _env;

  // ---- 内部原语（backend 层复用）----

  void releaseSession(Pointer<Void> session) => _releaseSession(session);
  void releaseValue(Pointer<Void> value) => _releaseValue(value);

  /// 读 session 输入/输出名（GetIOName 经默认 allocator 分配，读完即还）。
  List<String> ioNames(Pointer<Void> session, {required bool input}) {
    final countOut = malloc<Size>();
    final nameOut = malloc<Pointer<Utf8>>();
    final allocatorOut = malloc<Pointer<Void>>();
    try {
      check((input ? _sessionGetInputCount : _sessionGetOutputCount)(
          session, countOut));
      final n = countOut.value;
      check(_getAllocatorWithDefaultOptions(allocatorOut));
      final allocator = allocatorOut.value;
      final names = <String>[];
      for (var i = 0; i < n; i++) {
        check((input ? _sessionGetInputName : _sessionGetOutputName)(
            session, i, allocator, nameOut));
        names.add(nameOut.value.toDartString());
        _allocatorFree(allocator, nameOut.value.cast());
      }
      return names;
    } finally {
      malloc.free(countOut);
      malloc.free(nameOut);
      malloc.free(allocatorOut);
    }
  }

  /// 同步 Run：inputs=名字→(数据, 形状)；返回名字→(拷贝数据, 形状)。
  ///
  /// 输入张量直接引用 Dart 缓冲（同步调用期间地址稳定，见文件头安全约定）；
  /// 输出由 ORT 分配、读完立即 memcpy + Release。任何一步失败都保证已创建的
  /// OrtValue 全部释放。
  Map<String, (Float32List, List<int>)> run(
      Pointer<Void> session,
      Map<String, (Float32List, List<int>)> inputs,
      List<String> outputNames) {
    // 准备 memory info（输入张量用，结束释放）。
    final infoOut = malloc<Pointer<Void>>();
    Pointer<Void> memInfo = nullptr;
    final inputValues = <Pointer<Void>>[];
    final outputValues = <Pointer<Void>>[];
    try {
      check(_createCpuMemoryInfo(
          _kOrtDeviceAllocator, _kOrtMemTypeDefault, infoOut));
      memInfo = infoOut.value;

      // 输入名 C 串与名指针数组。
      final nameCs = <Pointer<Utf8>>[];
      Pointer<Pointer<Utf8>> inNamesArr = nullptr;
      Pointer<Pointer<Utf8>> outNamesArr = nullptr;
      Pointer<Pointer<Void>> inValsArr = nullptr;
      Pointer<Pointer<Void>> outValsArr = nullptr;
      try {
        final inNames = inputs.keys.toList();
        for (final name in inNames) {
          nameCs.add(name.toNativeUtf8());
        }
        for (final name in outputNames) {
          nameCs.add(name.toNativeUtf8());
        }
        inNamesArr = malloc<Pointer<Utf8>>(inNames.length);
        for (var i = 0; i < inNames.length; i++) {
          inNamesArr[i] = nameCs[i];
        }
        outNamesArr = malloc<Pointer<Utf8>>(outputNames.length);
        for (var i = 0; i < outputNames.length; i++) {
          outNamesArr[i] = nameCs[inNames.length + i];
        }

        // 输入张量：数据 malloc 拷入（CreateTensorWithData 直接引用调用方
        // 缓冲，而 dart:ffi 取不到 GC 堆内 TypedData 地址，见文件头约定），
        // FLOAT=1；缓冲与 OrtValue 都在 finally 统一释放。
        inValsArr = malloc<Pointer<Void>>(inputs.length);
        final shapeTmp = <Pointer<Int64>>[];
        final dataTmp = <Pointer<Float>>[];
        try {
          var i = 0;
          for (final e in inputs.entries) {
            final data = e.value.$1;
            final shape = e.value.$2;
            final shapeC = malloc<Int64>(shape.length);
            shapeTmp.add(shapeC);
            for (var d = 0; d < shape.length; d++) {
              shapeC[d] = shape[d];
            }
            final buf = malloc<Float>(data.length);
            dataTmp.add(buf);
            buf.asTypedList(data.length).setAll(0, data);
            final vOut = malloc<Pointer<Void>>();
            try {
              check(_createTensorWithData(
                  memInfo,
                  buf.cast<Void>(),
                  data.lengthInBytes,
                  shapeC,
                  shape.length,
                  _kTensorFloat,
                  vOut));
              inputValues.add(vOut.value);
              inValsArr[i] = vOut.value;
            } finally {
              malloc.free(vOut);
            }
            i++;
          }

          // 输出槽位预填 nullptr，由 ORT 在 Run 内分配。
          outValsArr = malloc<Pointer<Void>>(outputNames.length);
          for (var i = 0; i < outputNames.length; i++) {
            outValsArr[i] = nullptr;
          }

          check(_run(session, nullptr, inNamesArr, inValsArr, inNames.length,
              outNamesArr, outputNames.length, outValsArr));

          // 读取输出：shape + memcpy；读完后立即 Release 原生张量
          // （成功路径就地释放，失败路径走外层 catch 统一释放）。
          final out = <String, (Float32List, List<int>)>{};
          for (var i = 0; i < outputNames.length; i++) {
            final v = outValsArr[i];
            if (v == nullptr) {
              throw OrtFfiException(-2,
                  'Run 成功但输出 ${outputNames[i]} 槽位为 null（ORT 契约破坏）');
            }
            outputValues.add(v);
            out[outputNames[i]] = _readTensor(v);
          }
          for (final v in outputValues) {
            _releaseValue(v);
          }
          outputValues.clear();
          return out;
        } finally {
          for (final p in shapeTmp) {
            malloc.free(p);
          }
          for (final p in dataTmp) {
            malloc.free(p);
          }
        }
      } finally {
        for (final c in nameCs) {
          malloc.free(c);
        }
        if (inNamesArr != nullptr) malloc.free(inNamesArr);
        if (outNamesArr != nullptr) malloc.free(outNamesArr);
        if (inValsArr != nullptr) malloc.free(inValsArr);
        if (outValsArr != nullptr) malloc.free(outValsArr);
      }
    } on Object {
      // 失败路径释放输出张量（成功路径已就地释放并清空此列表）。
      for (final v in outputValues) {
        if (v != nullptr) _releaseValue(v);
      }
      rethrow;
    } finally {
      for (final v in inputValues) {
        _releaseValue(v);
      }
      final mi = memInfo;
      if (mi != nullptr) _releaseMemoryInfo(mi);
      malloc.free(infoOut);
    }
  }

  /// 读一个 float 张量：shape + 数据 memcpy 进新 Float32List。
  /// （输出 OrtValue 的释放由 [run] 统一负责。）
  (Float32List, List<int>) _readTensor(Pointer<Void> value) {
    final infoOut = malloc<Pointer<Void>>();
    final dimCountOut = malloc<Size>();
    try {
      check(_getTensorTypeAndShape(value, infoOut));
      final info = infoOut.value;
      if (info == nullptr) {
        throw const OrtFfiException(-2, 'GetTensorTypeAndShape 返回 null info');
      }
      try {
        check(_getDimensionsCount(info, dimCountOut));
        final rank = dimCountOut.value;
        final dimsC = malloc<Int64>(rank);
        try {
          check(_getDimensions(info, dimsC, rank));
          final shape = List<int>.generate(rank, (i) => dimsC[i]);
          var count = 1;
          for (final d in shape) {
            count *= d;
          }
          final dataOut = malloc<Pointer<Void>>();
          try {
            check(_getTensorMutableData(value, dataOut));
            final src = dataOut.value.cast<Float>();
            final out = Float32List(count);
            out.setAll(0, src.asTypedList(count));
            return (out, shape);
          } finally {
            malloc.free(dataOut);
          }
        } finally {
          malloc.free(dimsC);
        }
      } finally {
        _releaseTensorTypeAndShapeInfo(info);
      }
    } finally {
      malloc.free(infoOut);
      malloc.free(dimCountOut);
    }
  }
}

/// 一个已就绪的 ORT session（FFI 句柄包装）：IO 名缓存 + 同步 run + close。
class OrtFfiSession {
  OrtFfiSession(this._ffi, this._handle) {
    inputNames = _ffi.ioNames(_handle, input: true);
    outputNames = _ffi.ioNames(_handle, input: false);
  }

  final OrtFfi _ffi;
  Pointer<Void> _handle;

  late final List<String> inputNames;
  late final List<String> outputNames;

  bool get closed => _handle == nullptr;

  /// 同步推理：inputs=名字→(数据, 形状)；输出按 [outputs] 指定的名字返回。
  /// 传 null 时用 session 声明的全部输出名。
  Map<String, (Float32List, List<int>)> run(
      Map<String, (Float32List, List<int>)> inputs,
      {List<String>? outputs}) {
    final h = _handle;
    if (h == nullptr) throw StateError('OrtFfiSession 已 close');
    return _ffi.run(h, inputs, outputs ?? outputNames);
  }

  /// 释放 session（幂等）。
  void close() {
    final h = _handle;
    if (h == nullptr) return;
    _handle = nullptr;
    _ffi.releaseSession(h);
  }
}
