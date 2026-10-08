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

import '../forensics.dart'
    show
        clearInferenceWill,
        describeFatalSignal,
        kHeartbeatStallThreshold,
        parseWillBacktrace,
        readInferenceHeartbeatAge,
        readInferenceLogcatFatal,
        readInferenceMapsSnapshot,
        readInferenceStderrTail,
        readInferenceWill;
import '../logs/log_bus.dart';
import 'auto_service.dart';
import 'socket_protocol.dart';

/// MainActivity 上的服务控制通道（Kotlin 侧同名注册：start/stop）。
const MethodChannel kInferenceServiceChannel =
    MethodChannel('manga_colorizer/inference');

/// v0.5.18：各 so 在 base.apk 内的数据窗口（arm64-v8a，本地 file offset）。
/// Flutter 从 APK 内直接 dlopen so，maps 里它们共享同一个 `base.apk` 路径；
/// 崩溃帧的「pgoff + (pc - 区间起)」落在哪个窗口即归属哪个 so。
/// ⚠ 窗口随构建变化（so 体积/对齐/新增 so 都会移动偏移）——发版前用
/// `python -c "import zipfile…" + LocalFileHeader` 重新核对，构建脚本
/// tool/dump_apk_so_windows.py 可自动生成此表。
const Map<String, (int, int)> kApkSoWindows = {
  'libapp.so': (393216, 6554504),
  'libapp_native.so': (6569984, 6600056),
  'libdartjni.so': (6602752, 6734152),
  'libflutter.so': (6750208, 18497736),
  'libonnxruntime.so': (18513920, 46499864),
  'libonnxruntime4j_jni.so': (46514176, 46597384),
};

(int, int) kApkSoWindow(String so) => kApkSoWindows[so] ?? (0, 0);

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
  // AMS 落退出记录可能略晚于 socket 断开信号：小间隔重试三次再下结论。
  // 三次都查到「无记录」时返回说明文字（≠ null）：进程很可能仍在运行、只是
  // 连接断开——与「通道不可用」的 null（回退到猜测性表述）明确区分。
  // v0.5.14：通道异常也透传（≠ null）——Kotlin 侧已把查询异常转诊断文字，
  // 这里再抛说明是通道本身坏了（方法缺失/绑定失败），具体错误进死亡消息，
  // 不再静默回退到猜测性表述、把取证链断在通道层。
  Object? channelError;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final reason =
          await kInferenceServiceChannel.invokeMethod<String>('exitReason');
      if (reason != null && reason.isNotEmpty) return reason;
    } on Object catch (e) {
      // 宿主测试/Windows/低版本：通道不可用（MissingPluginException 等）。
      channelError ??= e;
      if (e is MissingPluginException) return null;
      // 其他异常（PlatformException 等）：Kotlin 侧已在 handler 内兜底，
      // 这里再抛说明通道状态异常——透传一次具体错误，证据不丢。
      return '通道异常: $e';
    }
    if (attempt < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  if (channelError != null) return '通道异常: $channelError';
  return '系统无退出记录（进程可能仍在运行，仅连接断开）';
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
  // v0.5.16 取证：新 spawn＝新观察窗口，旧遗嘱是上一次死亡的证据，留着会
  // 伪证本次断连。清理尽力而为（失败读取侧还有 mtime 兜底）。
  unawaited(clearInferenceWill());
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

  /// 死亡上报前先查系统侧的退出原因（[inferenceExitReason]）与本进程自建
  /// 证据线（原生遗嘱 + 心跳文件 + stderr 镜像，v0.5.16/17）：日志页直接
  /// 看到「原生崩溃 SIGSEGV / SIGKILL 被杀 / 冻结后杀」，不再只是猜测性表述。
  ///
  /// 三条证据的定罪表：
  ///   · 遗嘱存在 → 原生崩溃（signal 编号即死因；含 bt= 行时附 so+offset
  ///     符号化结果与 stderr 尾部）；
  ///   · 遗嘱缺失 + 心跳停滞 >3s → 进程冻结后被杀（厂商省电）；
  ///   · 遗嘱缺失 + 心跳活跃 → SIGKILL（LMK/厂商直接杀，内核不给写遗嘱）；
  ///   · 全部缺失 → 回退系统退出原因/回退表述（取证未安装或旧服务端）。
  Future<void> _notifyDiedWithExitReason() async {
    var why = 'inference 进程连接断开（进程退出或被杀）';
    try {
      // 遗嘱先行：最硬的证据（崩溃 vs 被杀一锤定音）。
      final will = await readInferenceWill();
      if (will != null && will.isNotEmpty) {
        // 行格式 will signal=N addr=0x…；翻译编号为可读名。
        final line = will.split('\n').last.trim();
        final m = RegExp(r'will signal=(\d+)').firstMatch(line);
        final sigNum = m == null ? null : int.tryParse(m.group(1)!);
        final sigName = sigNum == null ? null : describeFatalSignal(sigNum);
        var detail = 'inference 进程原生崩溃'
            '${sigName == null ? '' : '（$sigName）'}：$line';
        // v0.5.17：遗嘱带 bt= 行 → maps 快照换算 so+offset（离线再对 so
        // 出符号）；崩在哪个 .so 是锁定根因的关键一步。
        final bt = parseWillBacktrace(will);
        if (bt != null && bt.isNotEmpty) {
          final maps = await readInferenceMapsSnapshot();
          if (maps != null) {
            final sym = _symbolizeBacktrace(bt, maps);
            if (sym != null && sym.isNotEmpty) {
              detail += '；调用栈(PC→so+offset)：$sym';
            }
          }
        }
        // v0.5.17：stderr 镜像尾部——abort 前 ORT/断言写的报错原文。
        final stderrTail = await readInferenceStderrTail();
        if (stderrTail != null && stderrTail.isNotEmpty) {
          detail += '；stderr 尾部：${_condense(stderrTail, 1200)}';
        }
        // v0.5.18：logcat dump（dump 即清）——ART 的 FATAL 原文
        // （Fatal signal/Abort message/tombstone 摘要）只走 logcat。
        final logcat = await readInferenceLogcatFatal();
        if (logcat != null && logcat.isNotEmpty) {
          detail += '；logcat：${_condense(logcat, 1500)}';
        }
        why = detail;
      } else {
        // 无遗嘱：看心跳——停滞 >3s＝冻结后杀；活跃＝SIGKILL 被杀。
        final age = await readInferenceHeartbeatAge();
        if (age != null) {
          why = age > kHeartbeatStallThreshold
              ? 'inference 进程连接断开；死亡前心跳已停滞 ${age.inSeconds}s'
                '（进程先被冻结后遭终止——厂商冻结策略嫌疑）'
              : 'inference 进程连接断开；死亡前心跳活跃'
                '（${age.inMilliseconds}ms 前）：无遗嘱＝非崩溃，'
                '应为 SIGKILL 直接终止（LMK/厂商杀后台）';
        }
      }
    } on Object {
      // 取证读取失败：降级到系统退出原因线（原有逻辑），证据不阻塞上报。
    }
    if (!why.contains('原生崩溃') && !why.contains('心跳')) {
      // 自建证据线无果：尝试系统退出原因（v0.5.14/15 逻辑）。
      try {
        final reason = await inferenceExitReason();
        if (reason != null && reason.isNotEmpty) {
          why = 'inference 进程连接断开；系统退出原因：$reason';
        }
      } on Object catch (e) {
        // MissingPluginException（通道不可用：宿主测试/Windows/低版本）保持
        // 回退表述；其他异常转为诊断文字进死亡消息（上报不被阻塞）。
        if (e is! MissingPluginException) {
          why = 'inference 进程连接断开；系统退出原因：查询异常: $e';
        }
      }
    }
    _onDied?.call(why);
  }

  /// v0.5.17/18：把遗嘱 backtrace 的裸 PC 列表对照 maps 快照换算成
  /// 「so 名+offset」列表。maps 行格式（第 3 列=文件内 pgoff，v0.5.18 起用）：
  /// `7a2b400000-7a2b460000 r--p 00000000 08:02 12345 /data/app/.../libonnxruntime.so`。
  ///
  /// 普通 so 帧：offset = pc - 区间起（so 内偏移）。
  /// base.apk 帧（Flutter 直接从 APK 内 dlopen，多个 so 共享同一路径）：
  /// file_off = pgoff + (pc - 区间起)，再对照 [kApkSoWindows] 的
  /// 「so 在 APK 内的数据窗口」归属到具体 so（libonnxruntime/libapp/
  /// libflutter/…）。v0.5.17 真机 #8-#10 三帧就是这样从「base.apk+0x…」
  /// 钉到 libonnxruntime.so 的。
  ///
  /// 系统库（/system/**、/apex/**，可能就是 abort 源头）照记——归属本身
  /// 就是信息。无匹配（PC 在匿名映射）返回空列表。
  /// v0.5.17：向后兼容的私有名（内部调用点不改）。
  static String? _symbolizeBacktrace(List<Uri> pcs, String maps) =>
      symbolizeBacktrace(pcs, maps);

  /// v0.5.17/18：把遗嘱 backtrace 的裸 PC 列表对照 maps 快照换算成
  /// 「so 名+offset」列表。maps 行格式（第 3 列=文件内 pgoff，v0.5.18 起用）：
  /// `7a2b400000-7a2b460000 r--p 00000000 08:02 12345 /data/app/.../libonnxruntime.so`。
  ///
  /// 普通 so 帧：offset = pc - 区间起（so 内偏移）。
  /// base.apk 帧（Flutter 直接从 APK 内 dlopen，多个 so 共享同一路径）：
  /// file_off = pgoff + (pc - 区间起)，再对照 [kApkSoWindows] 的
  /// 「so 在 APK 内的数据窗口」归属到具体 so（libonnxruntime/libapp/
  /// libflutter/…）。v0.5.17 真机 #8-#10 三帧就是这样从「base.apk+0x…」
  /// 钉到 libonnxruntime.so 的。
  ///
  /// 系统库（/system/**、/apex/**，可能就是 abort 源头）照记——归属本身
  /// 就是信息。无匹配（PC 在匿名映射）返回空列表。
  static String? symbolizeBacktrace(List<Uri> pcs, String maps) {
    // (start, end, pgoff, path)
    final ranges = <(int, int, int, String)>[];
    for (final line in maps.split('\n')) {
      final m = RegExp(
              r'^([0-9a-f]+)-([0-9a-f]+)\s+\S+\s+([0-9a-f]+)\s+\S+\s+\S+\s+(.*)$')
          .firstMatch(line);
      if (m == null) continue;
      final start = int.tryParse(m.group(1)!, radix: 16);
      final end = int.tryParse(m.group(2)!, radix: 16);
      final pgoff = int.tryParse(m.group(3)!, radix: 16);
      final path = m.group(4)!.trim();
      if (start == null || end == null || pgoff == null || path.isEmpty) {
        continue;
      }
      ranges.add((start, end, pgoff, path));
    }
    if (ranges.isEmpty) return null;
    final out = <String>[];
    for (var i = 0; i < pcs.length; i++) {
      final raw = pcs[i].toString(); // elf:0x…
      final v = int.tryParse(raw.replaceFirst('elf:0x', ''), radix: 16);
      if (v == null) continue;
      String? hit;
      for (final r in ranges) {
        if (v < r.$1 || v >= r.$2) continue;
        final path = r.$4;
        if (path.endsWith('base.apk')) {
          // APK 内嵌 so：按数据窗口归属（窗口表见 [kApkSoWindows]）。
          final fileOff = r.$3 + (v - r.$1);
          String? so;
          for (final w in kApkSoWindows.entries) {
            if (fileOff >= w.value.$1 && fileOff < w.value.$2) {
              so = w.key;
              break;
            }
          }
          hit = so == null
              ? 'base.apk!file+0x${fileOff.toRadixString(16)}'
              : '$so+0x${(fileOff - kApkSoWindow(so).$1).toRadixString(16)}'
                  '<apk>';
        } else {
          final soName = path.split('/').last;
          hit = '$soName+0x${(v - r.$1).toRadixString(16)}'
              '${path.contains('/system/') || path.contains('/apex/') ? '[system]' : ''}';
        }
        break;
      }
      out.add('#$i ${hit ?? 'anon(0x${v.toRadixString(16)})'}');
    }
    return out.isEmpty ? null : out.join(' ← ');
  }

  /// 压缩长文本进日志行：去空白行、留尾（abort 原文在最后）、总长截断。
  static String _condense(String text, int maxChars) {
    final lines = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    var joined = lines.join(' ⏎ ');
    if (joined.length > maxChars) {
      joined = '…${joined.substring(joined.length - maxChars)}';
    }
    return joined;
  }

  @override
  Future<void> kill() async {
    _stopped = true;
    _cmdRx.close();
    _socket.destroy();
    await _stopQuietly();
  }
}

/// 测试接缝：v0.5.18 so+offset 符号化（裸 PC + maps 文本 → 归属行）。
@visibleForTesting
String? symbolizeBacktraceForTest(List<Uri> pcs, String maps) =>
    _SocketBridge.symbolizeBacktrace(pcs, maps);