// 推理服务共用配置接缝：isolate worker（auto_service.dart）与独立进程服务
// （inference/inference_server.dart）两条服务路径共享的后端工厂与分块参数。
// 不标 @visibleForTesting——它们是双路径的正式注入点：真机走生产默认
// ortAutoBackendFactory，宿主测试换 FakeBackend 并把 autoInfer/autoOverlap
// 调小（「改后必须恢复」的纪律由各测试的 setUp/tearDown 保证）。
import 'dart:io';

import '../app_settings.dart' show InferenceBackend;
import 'backend.dart';
import 'backend_ffi.dart';
import 'backend_log.dart';
import 'mnn_backend.dart';
import 'weights.dart';

/// 后端工厂：由权重目录构造一个未 load() 的后端；intraThreads/useArena 来自
/// 设备分级（ResourceTier → ensureStarted → ['dir'] 消息/帧 → 服务方）。
typedef AutoBackendFactory = OnnxBackend Function(String weightsDir,
    {int? intraThreads, bool? useArena});

/// 生产默认工厂：OrtFfiBackend + WeightsStore（仅用于推理时按 pathOf 定位
/// 已就绪权重，不参与下载选路，故下载源用默认值即可）。
///
/// v0.5.19 起默认走 dart:ffi 直调 libonnxruntime.so 的 C API：鸿蒙卓易通环境
/// 实证 ART CHECK 在 ORT Java JNI 桥（libonnxruntime4j_jni.so）路径 abort
/// （v0.5.18 遗嘱 backtrace 决胜证据），FFI 路径从调用链剔除 Java/JNI/libart。
/// useArena 默认 false（v0.5.14 起全档位 no-arena，标定数据见 resource_tier.dart）。
OnnxBackend ortAutoBackendFactory(String weightsDir,
        {int? intraThreads, bool? useArena}) =>
    OrtFfiBackend(
      WeightsStore(dir: Directory(weightsDir)),
      intraThreads: intraThreads ?? kDefaultIntraThreads,
      useArena: useArena ?? false,
    );

/// MNN 工厂的生产实现（v0.6.x Stage 2）：MnnFfiBackend + kMnnWeightFiles
/// （fp32 .mnn，mmap 文件背页加载）。useArena 对 MNN 无意义（无 arena 概念），
/// 接受并忽略以保持工厂签名同构；精度 v1 锁 Normal（Stage 0：fp16 存储已使
/// generator 漂移 max 17，见 docs/mnn-research.zh.md 附录 A）。
OnnxBackend _productionMnnAutoBackendFactory(String weightsDir,
        {int? intraThreads, bool? useArena}) =>
    MnnFfiBackend(
      WeightsStore(dir: Directory(weightsDir), files: kMnnWeightFiles),
      threads: intraThreads ?? kDefaultIntraThreads,
    );

/// worker/服务侧 MNN 工厂（可替换注入，与 [autoBackendFactory] 对称）。
AutoBackendFactory mnnAutoBackendFactory = _productionMnnAutoBackendFactory;

/// worker/服务侧后端工厂（可替换注入）。
AutoBackendFactory autoBackendFactory = ortAutoBackendFactory;

/// 按 ['dir']/config 帧携带的具体选择（'ort'|'mnn'，由调用方先解析 auto 规则）
/// 构造后端。测试注入走 autoBackendFactory / mnnAutoBackendFactory 两个槽。
OnnxBackend buildBackend(
        {required String choice,
        required String weightsDir,
        int? intraThreads,
        bool? useArena}) =>
    choice == 'mnn'
        ? mnnAutoBackendFactory(weightsDir,
            intraThreads: intraThreads, useArena: useArena)
        : autoBackendFactory(weightsDir,
            intraThreads: intraThreads, useArena: useArena);

/// auto 规则解析（主 isolate，ensureStarted 前）：MNN 权重集全部就绪（存在且
/// 字节数吻合，与 WeightsStore.readyFor 同判据）→ 'mnn'，否则回退 'ort'。
/// 显式 ort/mnn 原样透传（mnn 权重缺失时由 load 阶段报错，UI 已就绪门控）。
String resolveBackendChoice(String weightsDir, InferenceBackend choice) {
  switch (choice) {
    case InferenceBackend.ort:
      return 'ort';
    case InferenceBackend.mnn:
      return 'mnn';
    case InferenceBackend.auto:
      for (final f in kMnnWeightFiles) {
        final x = File('$weightsDir/${f.name}');
        if (!x.existsSync() || x.lengthSync() != f.size) return 'ort';
      }
      return 'mnn';
  }
}

/// 构造并加载后端；**MNN 加载失败自动回退 ORT**（桌面 service.py 同语义）。
/// 回退是一次性的：返回给调用方缓存的已是 ORT 后端，后续 job 不再重试 MNN。
/// choice=='ort' 时失败原样抛出（无更弱的回退级）。
Future<OnnxBackend> loadBackendWithFallback(
    {required String choice,
    required String weightsDir,
    int? intraThreads,
    bool? useArena}) async {
  final backend = buildBackend(
      choice: choice,
      weightsDir: weightsDir,
      intraThreads: intraThreads,
      useArena: useArena);
  try {
    await backend.load();
    return backend;
  } on Object {
    if (choice != 'mnn') rethrow;
    backendLog('MNN 后端加载失败，回退 ORT 后端（本次会话不再重试 MNN）');
  }
  // MNN load 失败可能留下半加载状态（encoder 已建），dispose 兜底（幂等）。
  try {
    await backend.dispose();
  } on Object {
    // 尽力释放。
  }
  final ort = buildBackend(
      choice: 'ort',
      weightsDir: weightsDir,
      intraThreads: intraThreads,
      useArena: useArena);
  await ort.load();
  return ort;
}

/// worker/服务侧分块参数：默认与桌面 /colorize_auto 一致（1024/256）。
/// 测试调小以便毫秒级跑完多块路径；真机不改。
int autoInfer = 1024;

int autoOverlap = 256;
