// 全自动推理的 isolate 门面：模型加载/推理都在工作 isolate；空闲 60s 释放后端归还内存。
// 事件协议（worker→main）: ['progress', double] | ['result', Uint8List?] |
//   ['error', String] | ['log', String]（worker 侧内存/耗时观测 → LogBus，
//   工作 isolate 是新堆拿不到 LogBus 引用，只能走事件）|
//   ['stopped']（优雅收尾 ack：dispose() 完成即回，然后 worker 退出）
// 命令协议（main→worker）: ['dir', String, int threads, bool useArena] |
//   ['job', Uint8List, int, int] | ['stop']
// spawn 引导（main→worker 首条消息）: _WorkerBoot(RootIsolateToken, SendPort)——
// worker 进口先 BackgroundIsolateBinaryMessenger.ensureInitialized，平台通道才可用。
//
// 设计不变量（改动须保持 RPC/生命周期测试全绿）：
//   · hint 模式的 `Isolate.run` 是一次性闭包，撑不起常驻引擎——这里用
//     spawn + ReceivePort 的 RPC，工作 isolate 跨任务存活，模型只加载一次；
//   · 空闲 60s（自上次任务结束起）自动 shutdown()：['stop'] → worker
//     dispose() → ['stopped'] ack → 回收句柄（硬约束「空闲即 dispose()」）；
//   · cancel()/shutdown() = 优雅停止：UI 侧立即完单复位（在飞 job 以 null
//     完结、引擎同步标记已死），worker 收到 ['stop'] 后做完当前块（原生运行
//     不可中断）→ dispose() → ['stopped'] → 退出；引擎等 ack（宽限见
//     [AutoEngine.stopGrace]）后才回收句柄，且 ensureStarted 会先等上一轮
//     拆机落地——杜绝新旧两份会话叠加。旧实现的 kill 即时但不执行 worker 的
//     dispose()：flutter_onnxruntime 插件在 Kotlin 侧持有的双 session
//     （~300MB）只在显式 close 或引擎销毁时释放，kill 路径就此滞留，下次
//     再叠一份新会话——真机「开始上色就闪退」的复现路径。仅宽限超时（原生
//     挂死的病态情形）才回退 kill，接受一次泄漏；
//   · worker 循环绝不静默死亡：畸形消息被解码守卫拦下（跳过并回
//     ['error']，在飞 job 得以完单）；isolate 意外退出由 spawn 挂的
//     onError/退出监听口捕获，引擎先按预算自动重启重发当前图（见
//     AutoEngine 类注释），预算耗尽才报错完结并标记已死，ensureStarted
//     仍可复活；
//   · 真实后端构造封在 ortAutoBackendFactory 一处；宿主测试经
//     startInProcessAutoWorker + autoBackendFactory 两个 @visibleForTesting
//     接缝在同一 isolate 里跑同一份 worker 消息循环（OrtOnnxBackend 依赖
//     插件、Windows 宿主测试根本无法构造，测试因此永不触碰真实 ORT）。
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;

import '../logs/log_bus.dart';
import '../mem_info.dart';
import 'backend.dart';
import 'backend_log.dart';
import 'pipeline.dart';
import 'serving_seams.dart';

// 工厂与分块接缝在 serving_seams.dart（isolate worker 与独立进程服务共用），
// 这里 re-export 保持既有测试导入路径不变。
export 'serving_seams.dart'
    show AutoBackendFactory, ortAutoBackendFactory, autoBackendFactory,
        autoInfer, autoOverlap;

/// 工作句柄：kill() 终止 worker（生产＝杀 isolate；测试＝关命令口）。
abstract interface class AutoWorkerHandle {
  Future<void> kill();
}

/// 启动 worker：传入"worker 回报事件/握手用的主 isolate 端口"和 `onDied`——
/// worker 意外死亡（生产＝isolate 退出/未捕获致命错；测试接缝＝自行斟酌
/// 触发）时调用，引擎据此让在飞 job 报错完结并标记 worker 已死。
typedef SpawnAutoWorker = Future<AutoWorkerHandle> Function(SendPort toMain,
    {void Function(Object error)? onDied});

/// spawn 引导包：把主 isolate 的 RootIsolateToken 随命令口一起带给 worker。
/// RootIsolateToken 是 dart:ui 定义的**可发送**类型，专用于此场景。
class _WorkerBoot {
  _WorkerBoot(this.token, this.main);
  final RootIsolateToken token;
  final SendPort main;
}

/// 工作 isolate 入口（Isolate.spawn 要求静态/顶层函数）。
/// 进口先 ensureInitialized：OrtOnnxBackend 经 flutter_onnxruntime 的
/// MethodChannel 推理，裸 spawn 的后台 isolate 二进制信使未初始化，
/// 不先初始化首个 createSession 即抛 "Bad state: The
/// BackgroundIsolateBinaryMessenger.instance value is invalid…"（v0.5.2
/// 真机必现的全自动失败）。
void _autoWorkerMain(_WorkerBoot boot) {
  BackgroundIsolateBinaryMessenger.ensureInitialized(boot.token);
  final rx = ReceivePort();
  boot.main.send(rx.sendPort); // 握手：把命令口交给主 isolate
  unawaited(_runAutoWorker(rx, boot.main));
}

/// 生产 spawn：真后台 isolate。`onError`（未捕获错误）+ `addOnExitListener`
/// （isolate 任意终结：崩溃/被系统回收/正常退出——`Isolate.spawn` 没有
/// spawnUri 式 exitCode 参数，退出监听是等价通道）两个回报口兜住 worker
/// 的意外死亡——任一事件都经 [onDied] 通知引擎，让在飞 job 报错完结、
/// 引擎可被 ensureStarted 复活。
Future<AutoWorkerHandle> spawnIsolateAutoWorker(SendPort toMain,
    {void Function(Object error)? onDied}) async {
  final errRx = ReceivePort();
  final exitRx = ReceivePort();
  errRx.listen((e) => onDied?.call('worker isolate 未捕获错误: $e'));
  exitRx.listen((_) => onDied?.call('worker isolate 已退出'));
  final Isolate iso;
  try {
    iso = await Isolate.spawn(
        _autoWorkerMain, _WorkerBoot(RootIsolateToken.instance!, toMain),
        debugName: 'auto-engine', onError: errRx.sendPort);
    iso.addOnExitListener(exitRx.sendPort);
  } on Object {
    errRx.close();
    exitRx.close();
    rethrow;
  }
  return _IsolateHandle(iso, errRx, exitRx);
}

class _IsolateHandle implements AutoWorkerHandle {
  _IsolateHandle(this._iso, this._errRx, this._exitRx);
  final Isolate _iso;
  final ReceivePort _errRx;
  final ReceivePort _exitRx;
  @override
  Future<void> kill() async {
    // 仅在优雅停止宽限超时（原生挂死）兜底：kill 即时但不执行 worker 的
    // dispose()，插件持有的会话就此滞留——正常路径都先走 ['stopped'] ack。
    _iso.kill(priority: Isolate.beforeNextEvent);
    _errRx.close();
    _exitRx.close();
  }
}

/// 测试接缝：在**当前 isolate**跑同一份 _runAutoWorker 消息循环。
/// 消息经真 ReceivePort/SendPort 投递（异步、带复制语义），协议行为与
/// 真 isolate 路径一致；后端由 autoBackendFactory 注入。
/// in-process 循环没有 isolate 退出事件，[onDied] 由测试自行触发以模拟
/// worker 死亡（生产路径的 onError/退出监听接线见 spawnIsolateAutoWorker）。
@visibleForTesting
Future<AutoWorkerHandle> startInProcessAutoWorker(SendPort toMain,
    {void Function(Object error)? onDied}) async {
  final rx = ReceivePort();
  // _runAutoWorker 内部吞掉全部异常（畸形消息有守卫 + 逐 job try/catch），
  // 不会被 await 也无主。
  final loop = _runAutoWorker(rx, toMain);
  toMain.send(rx.sendPort);
  return _InProcessHandle(rx, loop);
}

class _InProcessHandle implements AutoWorkerHandle {
  _InProcessHandle(this._rx, this._loop);
  final ReceivePort _rx;
  final Future<void> _loop;
  @override
  Future<void> kill() async {
    _rx.close(); // worker 侧 onDone 收到关闭事件 → 兜底 dispose 后退出
    unawaited(_loop);
  }
}

/// worker 消息循环：dir/stop/job 三种命令，事件回主 isolate。
/// 监听式分发（非 `await for` 串行）：['stop'] 必须能在 job 在飞时**并发**
/// 到达并置位 stopRequested——管线据此在块间收步（当前块的原始运行不可中断，
/// 这是优雅取消的延迟下限）；除此之外的事件处理仍是串行语义（job 处理期间
/// 迟到的 job/dir 不可能：引擎保证并发 1 且拆机后不再发 job）。
/// 循环整体不抛出（否则 in-process 句柄无从 await，真 isolate 也会静默死亡、
/// 引擎侧 _job 永挂），dispose 兜底在 ack 路径与 onDone 各一道。
Future<void> _runAutoWorker(ReceivePort rx, SendPort main) async {
  OnnxBackend? b;
  String? dirPath;
  // ['dir'] 消息携带设备分级的线程数与 arena 策略（消息缺省时用默认档，
  // 兼容旧测试）。
  int intraThreads = kDefaultIntraThreads;
  bool useArena = true;
  var stopRequested = false; // 'stop' 已到：在飞任务做完当前块即收，不再接新块
  var jobInFlight = false;
  var draining = false; // 收尾流程已启动（封口 + dispose + ack）

  Future<void> disposeBackend() async {
    final cur = b;
    b = null;
    try {
      await cur?.dispose();
    } on Object catch (_) {
      // 尽力释放：dispose 失败不再回传（会话对象已弃用；真 isolate 即将退出）。
    }
  }

  /// 优雅收尾：置 draining 拒新活 → dispose() → 关端口（真 isolate 自然退出，
  /// 退出监听在引擎侧幂等空转；onDone 兜底因 draining 已置而空转）→ 回 ack。
  /// 幂等（stop 与 job 收尾竞争时只有先到者生效）。
  Future<void> drainAndAck() async {
    if (draining) return;
    draining = true;
    await disposeBackend();
    rx.close();
    main.send(['stopped']);
  }

  rx.listen((msg) async {
    // 畸形消息（非 List / 空命令）绝不让循环猝死：回 ['error', …]——
    // 若引擎侧有在飞 job 即报错完结（无则被忽略），跳过该消息继续。
    if (msg is! List || msg.isEmpty) {
      main.send(['error', 'auto worker 收到畸形消息: $msg']);
      return;
    }
    final m = msg;
    if (m[0] == 'dir') {
      dirPath = m[1] as String;
      if (m.length > 2) intraThreads = m[2] as int;
      if (m.length > 3) useArena = m[3] as bool;
      return;
    }
    if (m[0] == 'stop') {
      stopRequested = true;
      if (!jobInFlight) await drainAndAck();
      return;
    }
    if (m[0] != 'job' || draining) return;
    if (jobInFlight) return; // 并发守卫：引擎保证并发 1，此处防畸形序列
    jobInFlight = true;
    try {
      final backend = b ??= autoBackendFactory(dirPath!,
          intraThreads: intraThreads, useArena: useArena);
      // job 范围内安装 backend 阶段日志（isolate 路径无 stderr 取证需求，
      // 直达 ['log'] 事件 → LogBus）。
      backendLogSink = (line) => main.send(['log', '[backend] $line']);
      await backend.load(); // 幂等；首次约模型大小级别的耗时
      main.send([
        'log',
        '双 session 加载完成（threads=$intraThreads，'
            'arena=${useArena ? '开启+每次Run收缩' : '关闭·时间换峰值'}）'
            '${rssSuffix()}'
      ]);
      final out = await autoColorize(
        gray: m[1] as Uint8List,
        width: m[2] as int,
        height: m[3] as int,
        backend: backend,
        infer: autoInfer,
        overlap: autoOverlap,
        // stop 到达时做完当前块即收（管道在块间查此标志）。
        cancelled: () => stopRequested,
        onProgress: (p) => main.send(['progress', p]),
        onLog: (line) => main.send(['log', line]),
      );
      main.send(['result', out]);
    } on Object catch (e) {
      main.send(['error', e.toString()]);
    } finally {
      backendLogSink = null;
      jobInFlight = false;
      if (stopRequested) {
        await drainAndAck();
      }
    }
  }, onDone: () async {
    // rx 被关闭（句柄 kill / 测试脚本）：兜底 dispose，绝不静默泄漏。
    if (!draining) {
      draining = true;
      await disposeBackend();
    }
  });
}

/// 主 isolate 门面：工作 isolate 常驻，空闲 60s 自动释放后端。
///
/// worker 意外死亡（:inference 进程被 LMK 回收/原生崩溃、isolate 终止）时，
/// 在飞 job 不再直接失败：引擎按 [maxWorkerRetries] 自动收尸 → 重新
/// ensureStarted → 重发当前图（从零重跑该图，分块进度回到 0）。用户取消/
/// 关闭会中止在途的重试。重试预算按「用户发起的一次 colorize」计，耗尽后
/// 恢复原有语义（job 以错误完结，引擎拆净可复活）。
class AutoEngine {
  AutoEngine(
      {SpawnAutoWorker? spawn,
      Duration? idleRelease,
      Duration? stopGrace,
      int maxWorkerRetries = 2,
      LogBus? logBus})
      : _spawn = spawn ?? spawnIsolateAutoWorker,
        _idleRelease = idleRelease ?? const Duration(seconds: 60),
        _stopGrace = stopGrace ?? const Duration(seconds: 90),
        _maxWorkerRetries = maxWorkerRetries,
        _logBus = logBus;

  final SpawnAutoWorker _spawn;
  Duration _idleRelease;

  /// 当前任务的 worker 死亡自动重试预算（见类注释）。用户每次 colorize 重置；
  /// 重试内部走 [_sendJob] 不重置，死亡循环最多消耗 [_maxWorkerRetries] 次。
  final int _maxWorkerRetries;
  int _reviveAttempt = 0;

  /// 用户主动拆机（cancel/shutdown/空闲/内存压力）的代数： revive 在途时用户
  /// 取消 → 代数不匹配 → 重试中止、job 以 null 完结（绝不复活出用户已放弃的
  /// 推理）。
  int _epoch = 0;

  /// 最近一次 ensureStarted 的参数：死亡自动重启按原档位复活。
  String? _lastDir;
  bool? _lastArena;

  /// 在飞 job 的入参：worker 死亡后重发当前图用（与 UI 侧持有的 _gray 同一份
  /// 字节，无额外拷贝；任务完结/拆机即清）。
  Uint8List? _pendingGray;
  int _pendingW = 0, _pendingH = 0;

  /// 优雅停止的宽限：覆盖「当前块跑完 + dispose()」。原生运行不可中断，真机
  /// 上一块可达 10–30s、load() 可达 10–20s，90s 已是宽裕上限；超时意味着
  /// 原生侧挂死（病态），回退 kill 接受一次会话滞留。
  final Duration _stopGrace;
  final LogBus? _logBus;

  AutoWorkerHandle? _handle;
  SendPort? _to;
  ReceivePort? _rx;
  StreamSubscription<dynamic>? _sub;
  Timer? _idle;
  Completer<Uint8List?>? _job;
  void Function(double progress)? _onProgress;

  /// 优雅拆机（cancel/shutdown 共用）的状态：_stopAck 等 ['stopped']，
  /// _teardown 是完整拆机的 Future——ensureStarted 必须先等它，否则旧 worker
  /// 的会话还没 dispose、新 worker 又 load 一份，~600MB 叠加直接被杀。
  Completer<void>? _stopAck;
  Future<void>? _teardown;

  bool get alive => _to != null;

  /// 是否有在飞任务：内存压力回调据此决定「释放会话」还是「绝不动推理」。
  bool get working => _job != null;

  /// dirPath 由主 isolate 的 getApplicationSupportDirectory()/manga-light-colorizer
  /// 传入；intraThreads/useArena 来自 ResourceTier 设备分级，随 ['dir'] 带给 worker；
  /// idleRelease 同源下发（高档 5min：连续多图不重付 10-20s 加载；低档 60s）。
  Future<void> ensureStarted(String dirPath,
      {int intraThreads = kDefaultIntraThreads,
      bool useArena = true,
      Duration? idleRelease}) async {
    if (alive) return;
    await _teardown; // 上一轮优雅拆机落地前绝不 spawn 新 worker
    _idle?.cancel();
    if (idleRelease != null) _idleRelease = idleRelease;
    _lastDir = dirPath;
    _lastArena = useArena;
    final rx = ReceivePort();
    // 握手：worker 把它的命令口作为第一条消息发回（见 autoWorkerMain）；
    // 监听器必须先于 spawn 建立，之后同一监听分发 SendPort/事件。
    final ready = Completer<SendPort>();
    final sub = rx.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      _onEvent(msg as List<Object?>);
    });
    AutoWorkerHandle? spawned;
    try {
      spawned = await _spawn(rx.sendPort, onDied: _onWorkerDied);
      final to = await ready.future;
      _rx = rx;
      _sub = sub;
      _handle = spawned;
      _to = to;
      _to!.send(['dir', dirPath, intraThreads, useArena]);
      _armIdle(); // 从没用过也要能到期自释放
      _logBus?.info('auto', '引擎已启动（worker 握手完成）');
    } on Object {
      await sub.cancel();
      rx.close();
      await spawned?.kill();
      rethrow;
    }
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(_idleRelease, shutdown);
  }

  void _onEvent(List<Object?> m) {
    if (_stopAck != null) {
      // 拆机期：只认 log（块耗时观测仍有价值）与 stopped ack；其余事件属于
      // 已被 null 完结的旧 job，一律丢弃。
      switch (m[0]) {
        case 'log':
          _logBus?.info('auto', m[1] as String);
        case 'stopped':
          final ack = _stopAck;
          if (ack != null && !ack.isCompleted) ack.complete();
      }
      return;
    }
    switch (m[0]) {
      case 'log':
        // worker 侧观测（加载完成/每块耗时+RSS）：worker 是新堆拿不到
        // LogBus 引用，只能走事件；bus 缺失（宿主测试）时静默丢弃。
        _logBus?.info('auto', m[1] as String);
      case 'progress':
        _onProgress?.call(m[1] as double);
      case 'result':
        final job = _job;
        _job = null;
        _onProgress = null;
        _pendingGray = null;
        _armIdle(); // 空闲计时从"上次任务结束"起算，长任务不被中途杀
        job?.complete(m[1] as Uint8List?);
      case 'error':
        final job = _job;
        _job = null;
        _onProgress = null;
        _pendingGray = null;
        _armIdle();
        job?.completeError(Exception(m[1] as String));
    }
  }

  Future<Uint8List?> colorize(Uint8List gray, int w, int h,
      {void Function(double)? onProgress}) async {
    // 保持 async：守卫错误以失败 Future 出现（调用方/测试按 await 或
    // expectLater(future, throwsA) 消费，同步抛出会破坏该契约）。
    if (!alive) throw StateError('先 ensureStarted');
    if (_job != null) throw StateError('并发 1：已有任务在跑');
    _reviveAttempt = 0; // 新的用户任务：死亡重试预算重置
    return _sendJob(gray, w, h, onProgress: onProgress);
  }

  /// 下发 job（colorize 与死亡自动重试共用）：重试路径**不得**重置重试预算，
  /// 否则「加载→推理→死亡」的确定性循环会无限复活。
  Future<Uint8List?> _sendJob(Uint8List gray, int w, int h,
      {void Function(double)? onProgress}) {
    _idle?.cancel();
    _onProgress = onProgress;
    final job = Completer<Uint8List?>();
    _job = job;
    _pendingGray = gray;
    _pendingW = w;
    _pendingH = h;
    _to!.send(['job', gray, w, h]);
    return job.future;
  }

  /// worker 意外死亡（生产＝退出监听/未捕获错误事件/:inference 连接断开；
  /// 测试＝onDied 直调）：预算内且当前有在飞 job → 自动收尸重启重发当前图
  /// （用户在 UI 上只是进度回零、日志页多一条 warn）；预算耗尽或无在飞 job
  /// 时保持原语义——在飞 job 以错误完结、引擎拆净，ensureStarted 可复活。
  void _onWorkerDied(Object why) {
    final ack = _stopAck;
    if (ack != null) {
      if (!ack.isCompleted) ack.complete();
      return; // 拆机进行中：其余字段已由 _beginTeardown 接管
    }
    if (!alive) return; // 已拆净：死亡事件幂等空转
    final job = _job;
    final gray = _pendingGray;
    if (job != null && gray != null && _reviveAttempt < _maxWorkerRetries) {
      _reviveAttempt++;
      _logBus?.warn('auto',
          'worker 意外终止（$why），自动重启引擎重试当前图'
          '（第 $_reviveAttempt/$_maxWorkerRetries 次）');
      final w = _pendingW, h = _pendingH, onProgress = _onProgress;
      unawaited(_reviveAndRetry(_epoch, job, gray, w, h, onProgress));
      return;
    }
    _logBus?.error('auto', 'worker isolate 意外终止: $why');
    unawaited(_beginTeardown(workerDied: true));
  }

  /// 死亡自动重启：收尸（job 由本方法接管，不在拆机中完单）→ 降单线程复活 →
  /// 重发当前图并把结果转交给原始 job。用户在重试窗口内取消/关闭（_epoch
  /// 变化）→ 中止重试：已复活的引擎立即拆掉，job 以 null 完结（按取消语义）。
  ///
  /// v0.5.16 鉴别实验 → v0.5.17 全重试降级：SIGABRT 实锤后（真机遗嘱命中，
  /// will signal=6 addr=0x279b00008415），每次重试都降 intraThreads=1——
  /// 单线程照死与否是「多线程并发缺陷」假设的直接判据，且不必等到末次才
  /// 拿证据（SIGABRT 场景下第 2 次重试大概率照死，预算耗尽全败）。同时是
  /// 生产自愈：单线程慢但若能完成，用户的图不至于全败。
  Future<void> _reviveAndRetry(
      int epoch,
      Completer<Uint8List?> job,
      Uint8List gray,
      int w,
      int h,
      void Function(double)? onProgress) async {
    try {
      await _beginTeardown(workerDied: true, keepJob: true);
      if (_epoch != epoch) {
        job.complete(null);
        return;
      }
      // 全部重试降单线程（鉴别实验 + 自愈）：ensureStarted 会把该值记进
      // _lastThreads，之后的 revive 按已降档位原样复活。
      const threads = 1;
      _logBus?.warn('auto',
          '重试降级单线程推理（threads=1）：成功＝多线程并发缺陷实锤，'
          '照死＝并发假设出局');
      await ensureStarted(_lastDir!,
          intraThreads: threads,
          useArena: _lastArena ?? true,
          idleRelease: _idleRelease);
      if (_epoch != epoch) {
        await shutdown();
        job.complete(null);
        return;
      }
      final out = await _sendJob(gray, w, h, onProgress: onProgress);
      job.complete(out);
    } on Object catch (e) {
      job.completeError(Exception('自动重启重试失败: $e'));
    }
  }

  /// 取消 = 优雅停止：UI 侧立即复位（在飞 job 以 null 完结、引擎同步标记
  /// 已死），worker 做完当前块 → dispose() → ['stopped'] 后才真正回收——
  /// 旧实现 kill isolate 即时，但 kill 不执行 worker 的 dispose()，Kotlin
  /// 插件侧的 ~300MB 双 session 就此滞留。下次 colorize 前 ensureStarted
  /// 会先等拆机落地。
  Future<void> cancel() => _beginTeardown();

  /// 优雅关闭（生命周期 paused / 空闲到期 / 内存压力共用）：语义同 [cancel]。
  Future<void> shutdown() => _beginTeardown();

  /// 拆机（cancel/shutdown/空闲到期/worker 死亡共用）：
  ///   · UI 侧立即完单复位，引擎同步标记已死（alive 门即刻生效）；
  ///   · 存活的 worker：发 ['stop']，等 ['stopped'] ack（或死亡）直到宽限
  ///     [_stopGrace] 超时，再封口 + kill——保证 dispose() 已执行过；
  ///   · 已死亡的 worker（workerDied）：不会也无需 ack，立即放行收尸；
  ///     [keepJob]（死亡自动重试专用）：在飞 job 不在此完单，由 revive 接管
  ///     转交——拆机只负责收尸与字段复位；
  ///   · 全程记录到 [_teardown]，重入幂等，ensureStarted 先等它落地。
  Future<void> _beginTeardown(
      {bool workerDied = false, bool keepJob = false}) async {
    _idle?.cancel();
    _idle = null;
    _onProgress = null;
    final job = _job;
    _job = null;
    _pendingGray = null;
    if (!workerDied) _epoch++; // 用户/系统主动拆机：在途 revive 据此中止
    if (workerDied && !keepJob) {
      job?.completeError(Exception('auto worker 意外终止'));
    } else if (!workerDied) {
      job?.complete(null);
    }
    if (_teardown != null) return; // 已在收尾：重入安全
    final handle = _handle;
    final rx = _rx;
    final sub = _sub;
    final to = _to;
    _handle = null;
    _rx = null;
    _sub = null;
    _to = null; // 同步标记已死：alive/colorize/ensureStarted 门立即生效
    if (handle == null || rx == null || sub == null) return;
    final ack = Completer<void>();
    _stopAck = ack;
    if (workerDied) {
      ack.complete(); // 死亡后 worker 永远不会 ack：直接放行收尸
    } else {
      to?.send(['stop']); // 在飞做完当前块 → dispose → ['stopped'] → 退出
    }
    final t = () async {
      try {
        await ack.future.timeout(_stopGrace, onTimeout: () {
          // 原生挂死等病态：放弃等待，回退 kill（接受一次会话滞留）。
          _logBus?.warn('auto',
              '优雅停止超时（${_stopGrace.inSeconds}s），强制回收 worker');
        });
      } finally {
        _stopAck = null;
        try {
          await sub.cancel();
          rx.close(); // 先封口：worker 迟到的事件一律不可达引擎
          await handle.kill();
        } on Object catch (_) {
          // 收尾三连的尽力而为：任何一步失败都不阻塞拆机完成。
        }
      }
    }();
    _teardown = t;
    unawaited(t.whenComplete(() {
      if (identical(_teardown, t)) _teardown = null;
    }));
  }
}
