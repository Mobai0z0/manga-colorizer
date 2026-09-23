// 全自动推理的 isolate 门面：模型加载/推理都在工作 isolate；空闲 60s 释放后端归还内存。
// 事件协议（worker→main）: ['progress', double] | ['result', Uint8List?] | ['error', String]
// 命令协议（main→worker）: ['dir', String] | ['job', Uint8List, int, int] | ['stop']
//
// 设计要点（计划定版，勿改）：
//   · hint 模式的 `Isolate.run` 是一次性闭包，撑不起常驻引擎——这里用
//     spawn + ReceivePort 的 RPC，工作 isolate 跨任务存活，模型只加载一次；
//   · 空闲 60s（自上次任务结束起）自动 shutdown()：先 ['stop'] 让 worker
//     dispose() session，再回收 isolate（硬约束「空闲即 dispose()」）；
//   · cancel() 直接杀工作 isolate：kill 是即时的，worker 内当前块的
//     原生推理随 isolate 终止一并释放，进行中的 job 以 null 完结；
//   · 真实后端构造封在 ortAutoBackendFactory 一处；宿主测试经
//     startInProcessAutoWorker + autoBackendFactory 两个 @visibleForTesting
//     接缝在同一 isolate 里跑同一份 worker 消息循环（OrtOnnxBackend 依赖
//     插件、Windows 宿主测试根本无法构造，测试因此永不触碰真实 ORT）。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'backend.dart';
import 'pipeline.dart';
import 'weights.dart';

/// 后端工厂：由权重目录构造一个未 load() 的 OnnxBackend。
typedef AutoBackendFactory = OnnxBackend Function(String weightsDir);

/// 生产默认工厂：OrtOnnxBackend + WeightsStore（镜像策略与 brief 定版一致，
/// mirrorPreferred 恒 false＝直连主站）。
OnnxBackend ortAutoBackendFactory(String weightsDir) => OrtOnnxBackend(
      WeightsStore(dir: Directory(weightsDir), mirrorPreferred: (u) => false),
    );

/// worker 侧后端工厂。**可替换**：宿主测试在 setUp 里换成 FakeBackend 工厂
/// （同 isolate 的 in-process worker 读到的就是测试改后的值；真实工作
/// isolate 是新堆，永远读到生产默认值）。
@visibleForTesting
AutoBackendFactory autoBackendFactory = ortAutoBackendFactory;

/// worker 侧分块参数：默认与桌面 /colorize_auto 定版一致（1024/256）。
/// 测试调小以便毫秒级跑完多块路径；真机不改。
@visibleForTesting
int autoInfer = 1024;

@visibleForTesting
int autoOverlap = 256;

/// 工作句柄：kill() 终止 worker（生产＝杀 isolate；测试＝关命令口）。
abstract interface class AutoWorkerHandle {
  Future<void> kill();
}

/// 启动 worker：传入"worker 回报事件/握手用的主 isolate 端口"。
typedef SpawnAutoWorker = Future<AutoWorkerHandle> Function(SendPort toMain);

/// 工作 isolate 入口（Isolate.spawn 要求静态/顶层函数）。
void autoWorkerMain(SendPort main) {
  final rx = ReceivePort();
  main.send(rx.sendPort); // 握手：把命令口交给主 isolate
  unawaited(_runAutoWorker(rx, main));
}

/// 生产 spawn：真后台 isolate。
Future<AutoWorkerHandle> spawnIsolateAutoWorker(SendPort toMain) async {
  final iso =
      await Isolate.spawn(autoWorkerMain, toMain, debugName: 'auto-engine');
  return _IsolateHandle(iso);
}

class _IsolateHandle implements AutoWorkerHandle {
  _IsolateHandle(this._iso);
  final Isolate _iso;
  @override
  Future<void> kill() async {
    // kill 是即时的：worker 内当前块的原生推理随 isolate 终止释放。
    _iso.kill(priority: Isolate.beforeNextEvent);
  }
}

/// 测试接缝：在**当前 isolate**跑同一份 _runAutoWorker 消息循环。
/// 消息经真 ReceivePort/SendPort 投递（异步、带复制语义），协议行为与
/// 真 isolate 路径一致；后端由 autoBackendFactory 注入。
@visibleForTesting
Future<AutoWorkerHandle> startInProcessAutoWorker(SendPort toMain) async {
  final rx = ReceivePort();
  // _runAutoWorker 内部吞掉全部异常（逐 job try/catch），不会被 await 也无主。
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
    _rx.close(); // await-for 收到关闭事件 → 循环退出并 dispose 后端
    unawaited(_loop);
  }
}

/// worker 消息循环：dir/stop/job 三种命令，事件回主 isolate。
/// 循环整体不抛出（否则 in-process 句柄无从 await），dispose 兜底在 finally。
Future<void> _runAutoWorker(ReceivePort rx, SendPort main) async {
  OnnxBackend? b;
  String? dirPath;
  try {
    await for (final msg in rx) {
      final m = msg as List;
      if (m[0] == 'dir') {
        dirPath = m[1] as String;
        continue;
      }
      if (m[0] == 'stop') {
        // 空闲/优雅关闭：dispose 后端，b 置 null；下次 job 重建+load()。
        final cur = b;
        b = null;
        try {
          await cur?.dispose();
        } on Object catch (_) {
          // 尽力释放：dispose 失败不再回传（主侧已无待决 job，且会话对象
          // 已弃用；杀 isolate 时原生资源随进程回收）。
        }
        continue;
      }
      if (m[0] != 'job') continue;
      try {
        final backend = b ??= autoBackendFactory(dirPath!);
        await backend.load(); // 幂等；首次约模型大小级别的耗时
        final out = await autoColorize(
          gray: m[1] as Uint8List,
          width: m[2] as int,
          height: m[3] as int,
          backend: backend,
          infer: autoInfer,
          overlap: autoOverlap,
          onProgress: (p) => main.send(['progress', p]),
        );
        main.send(['result', out]);
      } on Object catch (e) {
        main.send(['error', e.toString()]);
      }
    }
  } finally {
    final cur = b;
    if (cur != null) {
      try {
        await cur.dispose();
      } on Object catch (_) {
        // 同上：循环收尾的尽力释放。
      }
    }
  }
}

/// 主 isolate 门面：工作 isolate 常驻，空闲 60s 自动释放后端。
class AutoEngine {
  AutoEngine({SpawnAutoWorker? spawn, Duration? idleRelease})
      : _spawn = spawn ?? spawnIsolateAutoWorker,
        _idleRelease = idleRelease ?? const Duration(seconds: 60);

  final SpawnAutoWorker _spawn;
  final Duration _idleRelease;

  AutoWorkerHandle? _handle;
  SendPort? _to;
  ReceivePort? _rx;
  StreamSubscription<dynamic>? _sub;
  Timer? _idle;
  Completer<Uint8List?>? _job;
  void Function(double progress)? _onProgress;

  bool get alive => _to != null;

  /// dirPath 由主 isolate 的 getApplicationSupportDirectory()/manga-light-colorizer 传入
  Future<void> ensureStarted(String dirPath) async {
    if (alive) return;
    _idle?.cancel();
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
      spawned = await _spawn(rx.sendPort);
      final to = await ready.future;
      _rx = rx;
      _sub = sub;
      _handle = spawned;
      _to = to;
      _to!.send(['dir', dirPath]);
      _armIdle(); // 从没用过也要能到期自释放
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
    switch (m[0]) {
      case 'progress':
        _onProgress?.call(m[1] as double);
      case 'result':
        final job = _job;
        _job = null;
        _onProgress = null;
        _armIdle(); // 空闲计时从"上次任务结束"起算，长任务不被中途杀
        job?.complete(m[1] as Uint8List?);
      case 'error':
        final job = _job;
        _job = null;
        _onProgress = null;
        _armIdle();
        job?.completeError(Exception(m[1] as String));
    }
  }

  Future<Uint8List?> colorize(Uint8List gray, int w, int h,
      {void Function(double)? onProgress}) async {
    if (!alive) throw StateError('先 ensureStarted');
    if (_job != null) throw StateError('并发 1：已有任务在跑');
    _idle?.cancel();
    _onProgress = onProgress;
    final job = Completer<Uint8List?>();
    _job = job;
    _to!.send(['job', gray, w, h]);
    return job.future;
  }

  /// 取消 = 杀工作 isolate（kill 是即时的，worker 内当前块推理随线程终止释放）；
  /// 下次 colorize 前重新 ensureStarted。返回时进行中的 _job 以 null 完结。
  Future<void> cancel() async {
    _idle?.cancel();
    final job = _job;
    _job = null;
    _onProgress = null;
    job?.complete(null);
    await _teardown();
  }

  /// 优雅关闭：先 ['stop'] 让 worker 走 dispose()，再回收 isolate。
  /// 进行中的 job（若有）以 null 完结，防 UI 永挂。
  Future<void> shutdown() async {
    _idle?.cancel();
    if (alive) {
      _to?.send(['stop']);
      // 给 worker 一个事件轮转的窗口去处理 stop（在飞任务下 stop 排在
      // 队尾，来不及处理就会被 kill——原生内存随 isolate 死亡回收）。
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final job = _job;
    _job = null;
    _onProgress = null;
    job?.complete(null);
    await _teardown();
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;
    _rx?.close(); // 先封口：worker 迟到的事件一律不可达引擎
    _rx = null;
    final handle = _handle;
    _handle = null;
    _to = null;
    await handle?.kill();
    _idle?.cancel();
    _idle = null;
  }
}
