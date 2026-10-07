// 主进程侧的 :inference 服务桥：实现 auto_service.dart 的 SpawnAutoWorker
// 接缝，把 AutoEngine 的 isolate RPC 消息面原样桥到 127.0.0.1 帧协议上——
// 引擎/AutoScreen/AutoPanel 零改动（事件语义一致）。kill() = 停服务进程，
// 即时且零泄漏（进程死亡 = ORT 会话全部归还）。
//
// 生命周期映射（用户选择「推理中切后台跑完」）：取消/关闭/空闲到期/内存压力
// （空闲门控）都落到「停服务」；后台保活由服务的 dataSync 前台服务承担。
// 服务启动/连接失败自动回退进程内 isolate（[defaultAutoSpawn]）。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

import '../logs/log_bus.dart';
import 'auto_service.dart';
import 'socket_protocol.dart';

/// MainActivity 上的服务控制通道（Kotlin 侧同名注册：start/stop）。
const MethodChannel kInferenceServiceChannel =
    MethodChannel('manga_colorizer/inference');

typedef ServiceStarter = Future<void> Function();
typedef ServiceStopper = Future<void> Function();

Future<void> _startViaChannel() => kInferenceServiceChannel.invokeMethod('start');

Future<void> _stopViaChannel() async {
  try {
    await kInferenceServiceChannel.invokeMethod('stop');
  } on MissingPluginException {
    // 宿主测试/未集成环境：静默。
  }
}

/// 测试接缝：默认经 MainActivity 平台通道起停前台服务。
@visibleForTesting
ServiceStarter startInferenceService = _startViaChannel;
@visibleForTesting
ServiceStopper stopInferenceService = _stopViaChannel;

/// 测试接缝：默认生产端口表（与 socket_protocol 的绑定表一致）。
@visibleForTesting
List<int> inferenceCandidatePorts = List<int>.unmodifiable(
    [for (var i = 0; i < kInferencePortSpan; i++) kInferencePortBase + i]);

/// 测试接缝：连接+握手的总预算（引擎冷启动百毫秒级，10s 已极宽裕）。
@visibleForTesting
Duration inferenceConnectBudget = const Duration(seconds: 10);

/// 测试接缝：查询 :inference 进程上次的系统退出原因（生产＝MainActivity 经
/// ApplicationExitInfo；null＝不可用）。worker 死亡消息据此从猜测性表述升级
/// 为可行动的根因（LMK / 原生崩溃 / ANR）；查询失败绝不妨碍死亡上报本身。
@visibleForTesting
Future<String?> Function() inferenceExitReason = _exitReasonViaChannel;

Future<String?> _exitReasonViaChannel() async {
  try {
    return await kInferenceServiceChannel
        .invokeMethod<String>('exitReason')
        .timeout(const Duration(seconds: 2));
  } on Object {
    // 通道缺失（宿主测试/Windows）/超时/低版本：不可用。
    return null;
  }
}

/// 生产默认是否优先独立进程：Android 开启；Windows/宿主测试天然走 isolate。
@visibleForTesting
bool preferInferenceService = Platform.isAndroid;

/// 测试接缝：回退 spawn（默认真 isolate；宿主测试注入 startInProcessAutoWorker
/// ——真 isolate 是新堆，走生产工厂直达 ORT/插件世界，宿主测试不可达，
/// 与 auto_service_test 的边界一致）。
@visibleForTesting
SpawnAutoWorker fallbackAutoSpawn = spawnIsolateAutoWorker;

Future<void> _stopQuietly() async {
  try {
    await stopInferenceService();
  } on Object catch (_) {
    // 停服务失败不阻塞拆机：进程兜底有 idle 自裁。
  }
}

/// 生产默认 spawn：Android 优先 :inference 独立进程（local-dream 架构——
/// 推理崩溃/被杀只终结推理进程，UI 存活可报错重试）；启动失败（OEM 后台
/// 限制、非标准设备等）自动回退进程内 isolate。
Future<AutoWorkerHandle> defaultAutoSpawn(SendPort toMain,
    {void Function(Object error)? onDied}) async {
  if (preferInferenceService) {
    try {
      return await spawnInferenceServiceWorker(toMain, onDied: onDied);
    } on Object catch (e) {
      LogBus.current?.warn('auto', '推理进程启动失败，回退进程内 isolate：$e');
    }
  }
  return fallbackAutoSpawn(toMain, onDied: onDied);
}

/// 起 :inference 服务 → 连接 → hello 握手（帧级健康检查）→ 桥接 RPC。
/// 任何失败都会先拆桥/停服务再抛（别留一个空转前台服务）。
Future<AutoWorkerHandle> spawnInferenceServiceWorker(SendPort toMain,
    {void Function(Object error)? onDied}) async {
  await startInferenceService();
  Socket socket;
  try {
    socket = await connectInferenceSocket(
        ports: inferenceCandidatePorts, budget: inferenceConnectBudget);
  } on Object {
    await _stopQuietly();
    rethrow;
  }
  final cmdRx = ReceivePort();
  final bridge = _SocketBridge(socket, cmdRx, toMain, onDied);
  try {
    await bridge.handshake();
  } on Object {
    await bridge.kill();
    rethrow;
  }
  toMain.send(cmdRx.sendPort); // 握手：引擎把 cmdRx 当 worker 命令口
  return bridge;
}

class _SocketBridge implements AutoWorkerHandle {
  _SocketBridge(this._socket, this._cmdRx, this._toMain, this._onDied);

  final Socket _socket;
  final ReceivePort _cmdRx;
  final SendPort _toMain;
  final void Function(Object error)? _onDied;

  String? _dir;
  int? _threads;
  bool? _arena;
  int _jobId = 0;
  bool _handshaked = false;
  Completer<void>? _handshakeWaiter;
  bool _stopped = false; // 引擎已发起停止：不再报意外死亡
  bool _dead = false;

  /// 帧级健康检查：写 hello，等 helloOk。**必须先于握手完成挂上读链**——
  /// dart:io 套接字流只许一次订阅，握手帧与业务帧共用同一条 readFrames
  /// 消费链（首帧在 _onFrame 里校验）。
  Future<void> handshake() async {
    _handshakeWaiter = Completer<void>();
    listen();
    writeFrame(_socket,
        const Frame(FrameType.hello, data: {'version': kInferenceProtocolVersion}));
    await _handshakeWaiter!.future.timeout(inferenceConnectBudget, onTimeout: () {
      throw StateError('推理服务握手超时（helloOk 未达）');
    });
  }

  void listen() {
    // ReceivePort 的事件是 dynamic：只认 List 命令面（引擎保证只发 List；
    // 其余类型静默丢弃，绝不让桥抛未捕获错误）。
    _cmdRx.listen((m) {
      if (m is List<Object?>) _onCommand(m);
    });
    readFrames(_socket).listen(_onFrame,
        onDone: _onDisconnected, onError: (Object _) => _onDisconnected());
  }

  void _onCommand(List<Object?> m) {
    if (_stopped || _dead) return;
    switch (m[0]) {
      case 'dir':
        _dir = m[1] as String?;
        _threads = (m[2] as num?)?.toInt();
        _arena = m[3] as bool?;
        writeFrame(
            _socket,
            Frame(FrameType.config,
                data: {'dir': _dir, 'threads': _threads, 'arena': _arena}));
      case 'job':
        _jobId++;
        writeFrame(
            _socket,
            Frame(FrameType.job,
                jobId: _jobId,
                data: {'width': m[2] as int, 'height': m[3] as int},
                bytes: m[1] as Uint8List));
      case 'stop':
        if (_stopped) return;
        _stopped = true;
        // 停止 = 停服务进程（即时、零泄漏）：先断连接（在飞任务随断开弃置）
        // 再停服务——下一个 ensureStarted 的 start 必得全新进程，绝不复用
        // 正在处理已取消任务的旧核心。ack 由本桥合成，引擎据此完成拆机。
        _cmdRx.close();
        _socket.destroy();
        unawaited(_stopQuietly());
        _toMain.send(['stopped']);
      default:
        break;
    }
  }

  void _onFrame(Frame f) {
    if (_stopped || _dead) return;
    if (!_handshaked) {
      // 首帧必须是协议匹配的 helloOk（帧级健康检查）。
      final version = f.data['version'];
      if (f.type != FrameType.helloOk || version != kInferenceProtocolVersion) {
        _handshakeWaiter?.completeError(
            StateError('推理服务协议不匹配: $f'));
        return;
      }
      _handshaked = true;
      _handshakeWaiter?.complete();
      return;
    }
    switch (f.type) {
      case FrameType.progress:
        _toMain.send(['progress', (f.data['p'] as num).toDouble()]);
      case FrameType.log:
        _toMain.send(['log', f.data['line'] as String? ?? '']);
      case FrameType.result:
        _toMain.send(['result', f.bytes]);
      case FrameType.error:
        _toMain.send(['error', f.data['message'] as String? ?? '推理进程错误']);
      default:
        break; // hello 系列已在 connectInferenceServer 握手消费
    }
  }

  void _onDisconnected() {
    if (_stopped || _dead) return;
    _dead = true;
    _cmdRx.close();
    final waiter = _handshakeWaiter;
    if (waiter != null && !waiter.isCompleted) {
      // 握手期断开：让 handshake() 抛错走 spawn 失败路径（服务会被停掉、
      // 引擎回退 isolate），onDied 不触发（引擎还没接管）。
      waiter.completeError(StateError('推理服务连接断开（握手期）'));
      return;
    }
    // 服务进程退出/被杀（LMK、原生崩溃）：引擎按 worker 死亡处理——在飞
    // job 由引擎自动重启重试（预算内），耗尽才报错完单；UI 不受连坐。
    unawaited(_notifyDiedWithExitReason());
  }

  /// 死亡上报前先查系统侧的退出原因（[inferenceExitReason]）：日志页直接
  /// 看到「LMK 回收 / 原生崩溃(signal n)」，不再只是猜测性表述。
  Future<void> _notifyDiedWithExitReason() async {
    var why = 'inference 进程连接断开（进程退出或被杀）';
    try {
      final reason = await inferenceExitReason();
      if (reason != null && reason.isNotEmpty) {
        why = 'inference 进程连接断开；系统退出原因：$reason';
      }
    } on Object {
      // 查询替身抛错也保持原表述。
    }
    _onDied?.call(why);
  }

  @override
  Future<void> kill() async {
    _stopped = true;
    _cmdRx.close();
    _socket.destroy();
    await _stopQuietly();
  }
}
