// 推理服务共用配置接缝：isolate worker（auto_service.dart）与独立进程服务
// （inference/inference_server.dart）两条服务路径共享的后端工厂与分块参数。
// 不标 @visibleForTesting——它们是双路径的正式注入点：真机走生产默认
// ortAutoBackendFactory，宿主测试换 FakeBackend 并把 autoInfer/autoOverlap
// 调小（「改后必须恢复」的纪律由各测试的 setUp/tearDown 保证）。
import 'dart:io';

import 'backend.dart';
import 'backend_ffi.dart';
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

/// worker/服务侧后端工厂（可替换注入）。
AutoBackendFactory autoBackendFactory = ortAutoBackendFactory;

/// worker/服务侧分块参数：默认与桌面 /colorize_auto 一致（1024/256）。
/// 测试调小以便毫秒级跑完多块路径；真机不改。
int autoInfer = 1024;

int autoOverlap = 256;
