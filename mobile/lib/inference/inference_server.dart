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

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../mem_info.dart';
import '../onnx/backend.dart';
import '../onnx/backend_log.dart';
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

  /// 是否有在飞任务：断连取证用（「推理中断连」与「空闲断连」的区分）。
  bool get busy => _busy;

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
    // job 范围内安装 backend 阶段日志：log 帧（日志页可见）+ stderr 镜像
    // （logcat 可检索 `[manga-inference]`；进程死亡后这是唯一取证来源）。
    // 前一条日志带时间戳，配合下一帧的间隔能把「死亡发生在哪两步之间」
    // 钉死到具体阶段（Run 内/回传拷贝/dispose）。
    void jobLog(String line) {
      final stamped = '[backend] $line';
      stderr.writeln('[manga-inference] $stamped');
      send(Frame(FrameType.log, jobId: f.jobId, data: {'line': stamped}));
    }

    backendLogSink = jobLog;
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
        onLog: (line) {
          stderr.writeln('[manga-inference] [pipeline] $line');
          send(Frame(FrameType.log, jobId: f.jobId, data: {'line': line}));
        },
      );
      // socket 路径没有「取消返回 null」：取消=主进程停服务进程，进程死亡
      // 前本任务不会收到 stop。out 为 null 属协议异常，按 result(null) 透传
      // 让引擎以「已取消」完单。
      send(Frame(FrameType.result, jobId: f.jobId, bytes: out));
    } on Object catch (e, st) {
      // 任务级异常同步镜像 stderr：error 帧只对活着的连接有意义，logcat
      // 侧的完整堆栈才是进程死亡前的最后痕迹。
      stderr.writeln('[manga-inference] 任务异常: $e\n$st');
      send(Frame(FrameType.error, jobId: f.jobId, data: {'message': e.toString()}));
    } finally {
      backendLogSink = null;
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

/// 进程级「上次断连」档案（库级变量：同进程内引擎重启也保留）。服务端视角
/// 的断连证据——EOF（对端有序关闭）还是读错误（重置/网络层）、断开时是否
/// 任务在飞——是「进程死亡 vs 仅连接断开」定罪的关键一面，系统退出记录
/// （ApplicationExitInfo）只是另一面。同步落 stderr（logcat 可检索，本进程
/// 无 LogBus）。
(String note, DateTime at)? _lastDisconnect;

void noteDisconnect(String why, {required bool busy}) {
  // busy 标记必须进档案本体：问候帧/测试断言消费的是存储文本，stderr 只是
  // logcat 侧的同步痕迹。
  _lastDisconnect = (
    '${busy ? '任务在飞中断连' : '空闲断连'}：$why',
    DateTime.now(),
  );
  stderr.writeln(
      '[manga-inference] 连接断开${busy ? '（任务在飞）' : ''}: $why');
}

/// 新连接问候用：取上次断连档案与距今时长（不消费，进程存活期间反复可见）。
(String note, Duration age)? lastDisconnect() {
  final d = _lastDisconnect;
  if (d == null) return null;
  return (d.$1, DateTime.now().difference(d.$2));
}

/// 测试隔离：清空断连档案（库级变量跨用例存活，会污染后续用例的首帧断言）。
@visibleForTesting
void clearLastDisconnect() => _lastDisconnect = null;

/// 服务单个客户端连接直到断开（在飞任务随断开弃置：resetConnection 由
/// 收尾统一调，写帧失败静默——客户端已不在）。首个帧处理后补发「上次断连
/// 问候」（若有）——必须在 helloOk **之后**（桥的握手只认首帧 helloOk），
/// greeting 作为普通 log 帧直达日志页。断开时记录 EOF/读错误 + 任务在飞标记。
Future<void> serveClient(Socket client, InferenceServerCore core) async {
  var greeted = false;
  // 异步写错误必须有监听者：socket.add 是缓冲写，写失败（对端重置/缓冲区
  // 冲刷出错）稍后浮出——无人接住就是根 isolate 的未处理异步错误（headless
  // 引擎里可能终结 isolate，外观＝连接断开但进程未死）。done 在正常关闭时
  // 正常完成、写失败时带错完成，这里一并接住。
  unawaited(client.done.then((_) {}, onError: (Object _) {}));
  try {
    await for (final f in readFrames(client)) {
      unawaited(core.handle(f, (r) => sendFrame(client, r)));
      if (!greeted) {
        greeted = true;
        final last = lastDisconnect();
        if (last != null) {
          final (note, age) = last;
          sendFrame(
              client,
              Frame(FrameType.log,
                  data: {'line': '上次连接断开（${age.inSeconds}s 前）：$note'}));
        }
      }
    }
    noteDisconnect('EOF（对端有序关闭连接）', busy: core.busy);
  } on Object catch (e) {
    noteDisconnect('读错误（对端重置/网络层）: $e', busy: core.busy);
  } finally {
    core.resetConnection();
    client.destroy();
  }
}

/// 写帧兜底：连接已死时静默销毁（调用方各自的错误面不受影响）。add 的异步
/// 写错误由 serveClient 挂的 client.done 监听统一接住。
void sendFrame(Socket client, Frame r) {
  try {
    writeFrame(client, r);
  } on Object catch (_) {
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
