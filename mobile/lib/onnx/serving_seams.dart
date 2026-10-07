// 推理服务共用配置接缝：isolate worker（auto_service.dart）与独立进程服务
// （inference/inference_server.dart）两条服务路径共享的后端工厂与分块参数。
// 不标 @visibleForTesting——它们是双路径的正式注入点：真机走生产默认
// ortAutoBackendFactory，宿主测试换 FakeBackend 并把 autoInfer/autoOverlap
// 调小（「改后必须恢复」的纪律由各测试的 setUp/tearDown 保证）。
import 'dart:io';

import 'backend.dart';
import 'weights.dart';

/// 后端工厂：由权重目录构造一个未 load() 的后端；intraThreads/useArena 来自
/// 设备分级（ResourceTier → ensureStarted → ['dir'] 消息/帧 → 服务方）。
typedef AutoBackendFactory = OnnxBackend Function(String weightsDir,
    {int? intraThreads, bool? useArena});

/// 生产默认工厂：OrtOnnxBackend + WeightsStore（仅用于推理时按 pathOf 定位
/// 已就绪权重，不参与下载选路，故下载源用默认值即可）。
OnnxBackend ortAutoBackendFactory(String weightsDir,
        {int? intraThreads, bool? useArena}) =>
    OrtOnnxBackend(
      WeightsStore(dir: Directory(weightsDir)),
      intraThreads: intraThreads ?? kDefaultIntraThreads,
      useArena: useArena ?? true,
    );

/// worker/服务侧后端工厂（可替换注入）。
AutoBackendFactory autoBackendFactory = ortAutoBackendFactory;

/// worker/服务侧分块参数：默认与桌面 /colorize_auto 一致（1024/256）。
/// 测试调小以便毫秒级跑完多块路径；真机不改。
int autoInfer = 1024;

int autoOverlap = 256;
