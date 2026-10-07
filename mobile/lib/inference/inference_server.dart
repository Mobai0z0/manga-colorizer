// :inference 独立进程内的推理服务（参考 xororz/local-dream 的独立后端进程
// 架构）：一个进程常驻一个 [InferenceServerCore]（ORT 双 session 随进程存续，
// 进程死亡即全部原生内存归还——这是「会话永无泄漏」的兜底），逐客户端服务
// 帧协议命令。模型加载/分块推理复用 auto_service.dart 的管线与工厂接缝
// （autoBackendFactory/autoInfer/autoOverlap），与 isolate worker 共享同一套
// 宿主测试替身。
//
// 核心逻辑纯 Dart（不触 dart:ui），宿主测试直测；backend.dart 的 ORT 绑定
// 仅在真机/集成环境被工厂实例化，宿主测试经 serving_seams 换替身。
import 'dart:async';
import 'dart:io';

import '../mem_info.dart';
import '../onnx/backend.dart';
import '../onnx/pipeline.dart';
import '../onnx/serving_seams.dart';
import '../onnx/socket_protocol.dart';

/// 最后一个客户端断开后的自裁宽限：正常关闭由主进程 stop 服务驱动，这只是
/// 「主进程死了/连接异常」时的兜底——别让一个空载前台服务挂着。
const Duration kInferenceIdleExit = Duration(seconds: 15);

/// 单客户端命令核心：hello/config/job → progress/log/result/error。
/// 并发 1（引擎侧保证；双发防御性回 error）。
class InferenceServerCore {
  OnnxBackend? _backend;
  String? _dir;
  int _threads = kDefaultIntraThreads;
  bool _arena = true;
  bool _busy = false;

  /// 连接代数：客户端断开时在飞任务被弃置，其收尾 finally 不得复位新一代
  /// 连接的 busy（否则两个 job 并发跑，内存翻倍）。
  int _gen = 0;

  /// 客户端断开/新连接接入前调用：弃置在飞任务，允许下一连接接单。
  void resetConnection() {
    _gen++;
    _busy = false;
  }

  /// 供测试与语义补全：进程正常靠 exit(0) 归还全部内存，这里是显式路径。
  Future<void> dispose() async {
    final b = _backend;
    _backend = null;
    try {
      await b?.dispose();
    } on Object catch (_) {
      // 尽力释放。
    }
  }

  Future<void> handle(Frame f, void Function(Frame) send) async {
    switch (f.type) {
      case FrameType.hello:
        send(const Frame(FrameType.helloOk,
            data: {'version': kInferenceProtocolVersion}));
      case FrameType.config:
        _dir = f.data['dir'] as String?;
        _threads = (f.data['threads'] as num?)?.toInt() ?? kDefaultIntraThreads;
        _arena = (f.data['arena'] as bool?) ?? true;
      case FrameType.job:
        await _runJob(f, send);
      default:
        // stop 不存在（取消=主进程直接停服务进程）；其余帧都是协议错误。
        send(Frame(FrameType.error, jobId: f.jobId,
            data: {'message': '意外帧: ${f.type.name}'}));
    }
  }

  Future<void> _runJob(Frame f, void Function(Frame) send) async {
    if (_busy) {
      send(Frame(FrameType.error, jobId: f.jobId,
          data: {'message': '并发 1：已有任务在跑'}));
      return;
    }
    _busy = true;
    final gen = _gen;
    try {
      final gray = f.bytes;
      final width = (f.data['width'] as num?)?.toInt() ?? 0;
      final height = (f.data['height'] as num?)?.toInt() ?? 0;
      final dir = _dir;
      if (gray == null || gray.length != width * height) {
        throw ArgumentError(
            'job 缺 gray 或尺寸不符: ${gray?.length}B vs ${width}x$height');
      }
      if (dir == null) throw StateError('config 未就绪（缺 weights 目录）');
      final backend = _backend ??=
          autoBackendFactory(dir, intraThreads: _threads, useArena: _arena);
      await backend.load(); // 幂等；首次约模型大小级别的耗时
      send(Frame(FrameType.log, jobId: f.jobId, data: {
        'line': '双 session 加载完成（threads=$_threads，'
            'arena=${_arena ? '开启+每次Run收缩' : '关闭·时间换峰值'}，'
            '独立进程）${rssSuffix()}'
      }));
      final out = await autoColorize(
        gray: gray,
        width: width,
        height: height,
        backend: backend,
        infer: autoInfer,
        overlap: autoOverlap,
        onProgress: (p) => send(
            Frame(FrameType.progress, jobId: f.jobId, data: {'p': p})),
        onLog: (line) =>
            send(Frame(FrameType.log, jobId: f.jobId, data: {'line': line})),
      );
      // socket 路径没有「取消返回 null」：取消=主进程停服务进程，进程死亡
      // 前本任务不会收到 stop。out 为 null 属协议异常，按 result(null) 透传
      // 让引擎以「已取消」完单。
      send(Frame(FrameType.result, jobId: f.jobId, bytes: out));
    } on Object catch (e) {
      send(Frame(FrameType.error, jobId: f.jobId, data: {'message': e.toString()}));
    } finally {
      if (gen == _gen) _busy = false;
    }
  }
}

/// 在绑定端口上服务：绑定 [kInferencePortBase] 起的第一个空闲口。
Future<ServerSocket> bindInferenceServer() async {
  Object? lastError;
  for (var i = 0; i < kInferencePortSpan; i++) {
    try {
      return await ServerSocket.bind(
          InternetAddress.loopbackIPv4, kInferencePortBase + i);
    } on Object catch (e) {
      lastError = e;
    }
  }
  throw StateError('推理服务绑定端口失败：$lastError');
}

/// 服务单个客户端连接直到断开（在飞任务随断开弃置：resetConnection 由
/// 收尾统一调，写帧失败静默——客户端已不在）。
Future<void> serveClient(Socket client, InferenceServerCore core) async {
  try {
    await for (final f in readFrames(client)) {
      unawaited(core.handle(f, (r) {
        try {
          writeFrame(client, r);
        } on Object catch (_) {
          client.destroy();
        }
      }));
    }
  } finally {
    core.resetConnection();
    client.destroy();
  }
}

/// 进程入口粘合（inferenceMain 调用）：单客户端、空闲自裁。宿主测试不跑
/// 这里（exit(0) 会杀测试进程），只跑 [bindInferenceServer]/[serveClient]/
/// [InferenceServerCore]。
Future<void> inferenceServerMain() async {
  final server = await bindInferenceServer();
  final core = InferenceServerCore();
  var active = 0;
  Timer? idleTimer;
  void armIdleExit() {
    idleTimer?.cancel();
    idleTimer = Timer(kInferenceIdleExit, () {
      if (active == 0) exit(0); // 进程死亡即全部原生内存归还
    });
  }

  armIdleExit(); // 服务起了但主进程一直没连上：也别空载挂着
  server.listen((client) {
    idleTimer?.cancel();
    if (active > 0) {
      client.destroy(); // 单客户端：拒绝后来者（引擎保证并发 1）
      return;
    }
    active++;
    serveClient(client, core)
        .onError<Object>((_, __) {})
        .whenComplete(() {
      active--;
      armIdleExit();
    });
  }, onError: (_) => exit(0), onDone: () => exit(0));
}
