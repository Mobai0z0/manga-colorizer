// isolate 服务（mobile/lib/onnx/auto_service.dart）的宿主测试：
//   · 用 startInProcessAutoWorker 在同一 isolate 里跑**与真机完全相同**的 worker
//     消息循环，后端经 autoBackendFactory 换成 FakeBackend —— 真实 ORT/网络/
//     path_provider 一律不触碰（OrtOnnxBackend 在宿主测试里根本无法构造）。
//   · RPC 线格式逐字断言：命令 ['dir',p] / ['job',g,w,h] / ['stop']；
//     事件 ['progress',double] / ['result',Uint8List?] / ['error',String] /
//     ['stopped']（优雅收尾 ack）。
//   · 死亡兜底（畸形消息解码守卫 / 退出·未捕获错误→onDied）也经同一接缝驱动。
//   · 优雅停止契约：cancel/shutdown = UI 立即复位 + worker 做完当前块（或
//     load）→ dispose → ['stopped'] → 才回收句柄；ensureStarted 等拆机落地。
//     kill 只在宽限超时（原生挂死）兜底。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/auto_service.dart';

import 'fake_backend.dart';

/// runGen 前挂闸门：确定性地把 worker 钉在"任务进行中"，测取消/并发守卫。
class _GatedBackend extends FakeBackend {
  _GatedBackend({required this.gate});
  final Completer<void> gate;
  bool entered = false;

  @override
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    entered = true;
    await gate.future;
    return super.runGen(grayPlane, s, sam0, sam1);
  }
}

/// 前 N 次 runGen 挂闸、之后直通：死亡重试用例用——第一次（死亡前）钉在飞，
/// 重试那次放行跑完；预算用例把重试那次也钉住。
class _GateFirstNBackend extends FakeBackend {
  _GateFirstNBackend({required this.gate, required this.gatedEntries});
  final Completer<void> gate;
  final int gatedEntries;
  bool entered = false;
  int entries = 0;

  @override
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    entries++;
    if (entries <= gatedEntries) {
      entered = true;
      await gate.future;
    }
    return super.runGen(grayPlane, s, sam0, sam1);
  }
}

/// load() 前挂闸门：钉在"模型加载中"——真机 P0 场景（加载中切后台/取消）
/// 的确定性复现：旧实现 kill 不执行 dispose()，~300MB 会话滞留。
class _GatedLoadBackend extends FakeBackend {
  _GatedLoadBackend({required this.gate});
  final Completer<void> gate;
  bool enteredLoad = false;

  @override
  Future<void> load() async {
    enteredLoad = true;
    await gate.future;
    return super.load();
  }
}

/// 只关命令口的轻量句柄：脚本化工人用（不跑管线，只收发消息）。
class _ScriptedHandle implements AutoWorkerHandle {
  _ScriptedHandle(this._rx);
  final ReceivePort _rx;
  bool killed = false;
  @override
  Future<void> kill() async {
    killed = true;
    _rx.close();
  }
}

Uint8List gray40x16() => Uint8List(40 * 16)..fillRange(0, 40 * 16, 128);

Future<void> waitUntil(bool Function() cond, {required String why}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 10)) fail('等待超时：$why');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late AutoBackendFactory origFactory;
  late int origInfer, origOverlap;

  setUp(() {
    origFactory = autoBackendFactory;
    origInfer = autoInfer;
    origOverlap = autoOverlap;
    // 小分块：40×16、infer=16、overlap=8 → x 轴 4 块、y 轴 1 块
    // （tileBounds 末块触边收尾），FakeBackend 毫秒级跑完且能断言逐块进度。
    autoInfer = 16;
    autoOverlap = 8;
  });
  tearDown(() {
    autoBackendFactory = origFactory;
    autoInfer = origInfer;
    autoOverlap = origOverlap;
  });

  test('ensureStarted+colorize round trip: result + per-tile progress',
      () async {
    final fake = FakeBackend();
    final seenDirs = <String>[];
    autoBackendFactory = (dir, {int? intraThreads, bool? useArena}) {
      seenDirs.add(dir);
      return fake;
    };
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    expect(engine.alive, isFalse);
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(engine.alive, isTrue);
    final progress = <double>[];
    final out =
        await engine.colorize(gray40x16(), 40, 16, onProgress: progress.add);
    expect(out, isNotNull);
    expect(out!.length, 40 * 16 * 3);
    expect(progress, [0.25, 0.5, 0.75, 1.0]); // 按块上报、终值 1.0
    expect(seenDirs, [Directory.systemTemp.path]); // ['dir',p] 被 worker 消费
    expect(fake.calls.where((c) => c == 'load').length, 1);
    expect(fake.calls.where((c) => c.startsWith('sam:')).toList(),
        ['sam:768', 'sam:768', 'sam:768', 'sam:768']); // 3·16² 浮点×4 块
    expect(fake.calls.where((c) => c.startsWith('gen:')).length, 4);
    await engine.shutdown();
    expect(engine.alive, isFalse);
    // 优雅停止：ack 回来后才回收句柄，dispose 在后台落地。
    await waitUntil(() => fake.calls.contains('dispose'),
        why: 'shutdown 后 dispose 落地');
    expect(fake.calls, contains('dispose')); // 空闲/关闭即 dispose() session
  });

  test('ensureStarted is idempotent while alive', () async {
    var spawns = 0;
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => FakeBackend();
    final engine = AutoEngine(
        spawn: (main, {onDied}) {
          spawns++;
          return startInProcessAutoWorker(main, onDied: onDied);
        },
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(spawns, 1);
    await engine.cancel();
  });

  test('colorize before ensureStarted throws StateError', () async {
    final engine = AutoEngine(spawn: startInProcessAutoWorker);
    await expectLater(
        engine.colorize(gray40x16(), 40, 16), throwsA(isA<StateError>()));
    await engine.shutdown();
  });

  test('worker errors surface as Exception on the job future', () async {
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => throw StateError('weights missing');
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    await expectLater(
        engine.colorize(gray40x16(), 40, 16),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('weights missing'))));
    // 出错不复位引擎：修好后同引擎可继续接单（worker 循环存活）。
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => FakeBackend();
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
  });

  test('cancel resolves running job with null and tears the worker down',
      () async {
    final fake = _GatedBackend(gate: Completer<void>());
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    final pending = engine.colorize(gray40x16(), 40, 16);
    await waitUntil(() => fake.entered, why: 'worker 进入 runGen');
    await engine.cancel();
    expect(await pending, isNull); // 取消 → null 完结（UI 立即复位）
    expect(engine.alive, isFalse); // 引擎已标记死亡
    fake.gate.complete(); // 当前块跑完 → 余块取消 → dispose → ['stopped']
    // 重新 ensureStarted 会等拆机落地（含 dispose）后再次完整跑通。
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(fake.calls, contains('dispose')); // 优雅收尾已执行
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
    await waitUntil(() => fake.calls.where((c) => c == 'dispose').length >= 2,
        why: '第二轮 shutdown 的 dispose');
  });

  test('working getter: true only while a job is in flight (内存压力门控)',
      () async {
    final fake = _GatedBackend(gate: Completer<void>());
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    expect(engine.working, isFalse); // 未启动
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(engine.working, isFalse); // 已启动、无任务：内存压力可释放会话
    final pending = engine.colorize(gray40x16(), 40, 16);
    await waitUntil(() => fake.entered, why: 'worker 进入 runGen');
    expect(engine.working, isTrue); // 在飞：内存压力绝不能释放会话
    fake.gate.complete();
    expect(await pending, isNotNull);
    expect(engine.working, isFalse); // 完结：恢复可释放
    await engine.shutdown();
  });

  test('concurrency is 1: second colorize while busy throws', () async {
    final fake = _GatedBackend(gate: Completer<void>()..complete());
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    final first = engine.colorize(gray40x16(), 40, 16);
    await expectLater(
        engine.colorize(gray40x16(), 40, 16), throwsA(isA<StateError>()));
    expect(await first, isNotNull);
    await engine.shutdown();
  });

  test('idle release fires after idleRelease and disposes the backend',
      () async {
    final fake = FakeBackend();
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(milliseconds: 40));
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    expect(engine.alive, isTrue); // 刚结束仍常驻
    await waitUntil(() => !engine.alive, why: '空闲自动释放');
    await waitUntil(() => fake.calls.contains('dispose'),
        why: '空闲释放走优雅停止：dispose 落地');
  });

  test('shutdown without a live engine is a no-op', () async {
    final engine = AutoEngine(spawn: startInProcessAutoWorker);
    await engine.shutdown();
    expect(engine.alive, isFalse);
  });

  test(
      'RPC wire format is exactly ["dir",p,threads,arena] / ["job",g,w,h] / ["stop"]',
      () async {
    final received = <Object?>[];
    late SendPort engineMain; // worker→引擎 事件口
    final engine = AutoEngine(
        idleRelease: const Duration(minutes: 5),
        spawn: (toMain, {onDied}) async {
          final rx = ReceivePort();
          rx.listen(received.add);
          toMain.send(rx.sendPort); // 握手：worker 交还命令口
          engineMain = toMain;
          return _ScriptedHandle(rx);
        });
    await engine.ensureStarted('/tmp/weights-dir');
    final gray = gray40x16();
    final progress = <double>[];
    final job = engine.colorize(gray, 40, 16, onProgress: progress.add);
    await pumpEventQueue();
    // 命令逐字对拍（threads/arena＝设备分级的 intra-op 线程数与 arena 策略，
    // 默认档 4/true）：
    expect(received, [
      ['dir', '/tmp/weights-dir', 4, true],
      ['job', gray, 40, 16],
    ]);
    // 事件逐字对拍（worker→main）：
    engineMain.send(['progress', 0.5]);
    engineMain.send([
      'result',
      Uint8List.fromList([1, 2, 3])
    ]);
    await pumpEventQueue();
    expect(await job, Uint8List.fromList([1, 2, 3]));
    expect(progress, [0.5]);
    // error 事件 → 引擎侧以 Exception 完单。注意：必须在事件到来**前**
    // 挂上监听，否则 Completer.completeError 会把异常上报给 zone。
    final job2 = engine.colorize(gray, 40, 16);
    final job2Check = expectLater(job2, throwsA(isA<Exception>()));
    await pumpEventQueue();
    engineMain.send(['error', 'boom']);
    await job2Check;
    // shutdown → 先发 ['stop']（让 worker 优雅 dispose）再回收 isolate
    await engine.shutdown();
    await pumpEventQueue();
    expect(received.last, ['stop']);
  });

  test('shutdown with an in-flight job resolves it with null (no hang)',
      () async {
    final fake = _GatedBackend(gate: Completer<void>());
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    final pending = engine.colorize(gray40x16(), 40, 16);
    await waitUntil(() => fake.entered, why: 'worker 进入 runGen');
    // 优雅关闭：在飞 job 以 null 完结（UI 侧语义＝"已取消"，绝不永挂）。
    await engine.shutdown();
    expect(await pending, isNull);
    expect(engine.alive, isFalse);
    fake.gate.complete(); // 放闸让旧循环收尾（真机随 isolate 死亡）
    await waitUntil(() => fake.calls.contains('dispose'),
        why: '循环退出时 dispose 兜底');
  });

  test(
      'malformed worker messages are answered with error and never kill '
      'the loop', () async {
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => FakeBackend();
    late SendPort cmd; // worker 命令口（仅测试注入畸形消息用）
    late ReceivePort relay;
    final workerEvents = <Object?>[];
    final engine = AutoEngine(
        spawn: (toMain, {onDied}) async {
          relay = ReceivePort();
          relay.listen((m) {
            if (m is SendPort) {
              cmd = m;
            } else {
              workerEvents.add(m);
            }
            toMain.send(m); // 原样中继：引擎看到的就是 worker 真实事件
          });
          return startInProcessAutoWorker(relay.sendPort, onDied: onDied);
        },
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    cmd
      ..send(123) // 非 List
      ..send(<Object?>[]); // 空命令（m[0] 会越界）
    await pumpEventQueue();
    // 每条畸形消息回一条 error 事件（有在飞 job 即报错完结；此处无则被
    // 引擎忽略），且解码守卫接住异常后循环继续运转。
    expect(workerEvents, hasLength(2));
    for (final e in workerEvents) {
      expect(e, isA<List<Object?>>().having((l) => l[0], 'kind', 'error'));
    }
    // 循环没静默死亡的证明：之后仍能完整跑通一个 job。
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
    relay.close();
  });

  test(
      'worker death (exit/onError path) fails the in-flight job and '
      'lets ensureStarted respawn（关闭重试预算的历史语义）', () async {
    final fake = _GatedBackend(gate: Completer<void>());
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    late void Function(Object why) notifyDied;
    final engine = AutoEngine(
        spawn: (toMain, {onDied}) {
          // 生产路径里 onDied 由 spawnIsolateAutoWorker 挂的 onError/退出监听
          // 口驱动；in-process 循环没有退出事件，测试直接触发同一回调。
          notifyDied = (why) => onDied!(why);
          return startInProcessAutoWorker(toMain, onDied: onDied);
        },
        maxWorkerRetries: 0, // 本测试钉住「预算耗尽」的历史语义，重试见专用用例
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    final pending = engine.colorize(gray40x16(), 40, 16);
    // 监听器必须先于错误完结挂上（见 RPC 测试注释的 Completer 语义）。
    final pendingCheck = expectLater(
        pending,
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('意外终止'))));
    await waitUntil(() => fake.entered, why: 'worker 进入 runGen');
    notifyDied('worker isolate 已退出');
    await pendingCheck; // 在飞 job 报错完结，不再永挂
    expect(engine.alive, isFalse); // 引擎已标记死亡并拆净
    fake.gate.complete(); // 放闸让旧循环收尾（真机随 isolate 死亡）
    await pumpEventQueue();
    // 复活：ensureStarted 重新 spawn 后可再次完整跑通。
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
  });

  test('worker 死亡 → 自动重启重发当前图，结果转交原始 job（预算内）', () async {
    final gate = Completer<void>();
    // gatedEntries=1：死亡前那次钉在飞，重启后的重试直通跑完。
    final fake = _GateFirstNBackend(gate: gate, gatedEntries: 1);
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final diedTriggers = <void Function(Object why)>[];
    final cmds = <List<Object?>>[]; // 每个 worker 收到的命令（经记录中转）
    final engine = AutoEngine(
        idleRelease: const Duration(minutes: 5),
        spawn: (toMain, {onDied}) {
          diedTriggers.add((why) => onDied!(why));
          final events = ReceivePort();
          final cmdRelay = ReceivePort();
          SendPort? workerCmd;
          events.listen((m) {
            if (m is SendPort) {
              workerCmd = m;
              cmdRelay.listen((c) {
                if (c is List) cmds.add(List<Object?>.from(c));
                workerCmd!.send(c); // 记录后转发给真 worker 命令口
              });
              toMain.send(cmdRelay.sendPort); // 引擎命令口＝记录中转
              return;
            }
            toMain.send(m); // worker 事件原样转发引擎
          });
          return startInProcessAutoWorker(events.sendPort, onDied: onDied);
        });
    await engine.ensureStarted('/tmp/weights-dir',
        intraThreads: 2, useArena: false);
    final progress = <double>[];
    final pending =
        engine.colorize(gray40x16(), 40, 16, onProgress: progress.add);
    await waitUntil(
        () => cmds.any((m) => m[0] == 'job'), why: '首个 job 下发');
    diedTriggers[0](
        'inference 进程连接断开；系统退出原因：系统低内存回收(LMK)（8s 前）');
    final out = await pending; // 重试自动跑完：UI 只看到进度回零再走完
    expect(out, isNotNull);
    expect(out!.length, 40 * 16 * 3);
    expect(diedTriggers, hasLength(2)); // 死亡触发了一次自动重启
    // 新 worker 按原档位重配置（dir/threads/arena 原样重发），同一张图重发。
    expect(cmds.where((m) => m[0] == 'dir'),
        everyElement(equals(['dir', '/tmp/weights-dir', 2, false])));
    expect(cmds.where((m) => m[0] == 'job'), hasLength(2));
    expect(progress, [0.25, 0.5, 0.75, 1.0]); // 进度回调跨重启延续
    await engine.shutdown();
    gate.complete(); // 放闸让死亡前的旧循环收尾
    await pumpEventQueue();
  });

  test('死亡重试预算耗尽：原始 job 以错误完单，不再无限复活', () async {
    final gate = Completer<void>();
    // gatedEntries=2：首次与重试都钉在飞，第二次死亡时预算已耗尽。
    final fake = _GateFirstNBackend(gate: gate, gatedEntries: 2);
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final diedTriggers = <void Function(Object why)>[];
    final engine = AutoEngine(
        maxWorkerRetries: 1,
        idleRelease: const Duration(minutes: 5),
        spawn: (toMain, {onDied}) {
          diedTriggers.add((why) => onDied!(why));
          return startInProcessAutoWorker(toMain, onDied: onDied);
        });
    await engine.ensureStarted('/tmp/weights-dir');
    final pending = engine.colorize(gray40x16(), 40, 16);
    final pendingCheck = expectLater(
        pending,
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('自动重启重试失败'))));
    await waitUntil(() => fake.entered, why: '首个 job 进入 runGen');
    diedTriggers[0]('第一次死亡'); // 预算 1→0：自动重启
    await waitUntil(() => fake.entries >= 2, why: '重试 job 进入 runGen');
    diedTriggers[1]('第二次死亡'); // 预算耗尽：报错完单
    await pendingCheck;
    expect(engine.alive, isFalse); // 已拆净：ensureStarted 复活语义保留
    gate.complete();
    await pumpEventQueue();
    await engine.ensureStarted('/tmp/weights-dir');
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
  });

  test('重试窗口内用户取消：job 以 null 完结，重启出的引擎被立即拆掉', () async {
    final gate = Completer<void>();
    final fake = _GateFirstNBackend(gate: gate, gatedEntries: 1);
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final diedTriggers = <void Function(Object why)>[];
    var spawns = 0;
    final spawnGate = Completer<void>(); // 钉住 revive 的第二次 spawn
    final engine = AutoEngine(
        idleRelease: const Duration(minutes: 5),
        spawn: (toMain, {onDied}) async {
          spawns++;
          if (spawns == 2) await spawnGate.future;
          diedTriggers.add((why) => onDied!(why));
          return startInProcessAutoWorker(toMain, onDied: onDied);
        });
    await engine.ensureStarted('/tmp/weights-dir');
    final pending = engine.colorize(gray40x16(), 40, 16);
    await waitUntil(() => fake.entered, why: '首个 job 进入 runGen');
    diedTriggers[0]('进程被杀');
    await pumpEventQueue(); // revive 启动：旧 worker 收尸，卡在第二次 spawn
    await engine.cancel(); // 用户取消：epoch 前进
    spawnGate.complete(); // 放行 revive——它必须中止而不是复活出推理
    expect(await pending, isNull); // 按取消语义完单，绝不报错
    expect(engine.alive, isFalse); // 重启出的引擎被立即拆掉
    expect(engine.working, isFalse);
    gate.complete();
    await pumpEventQueue();
  });

  test(
      'cancel during load still disposes sessions（真机 P0 回归：加载中取消/'
      '切后台不再泄漏 ~300MB 会话）', () async {
    final gate = Completer<void>();
    final fake = _GatedLoadBackend(gate: gate);
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    final pending = engine.colorize(gray40x16(), 40, 16);
    await waitUntil(() => fake.enteredLoad, why: 'worker 进入 load');
    await engine.cancel();
    expect(await pending, isNull); // UI 立即复位
    expect(engine.alive, isFalse);
    // 拆机未落地前重开：ensureStarted 必须等待，绝不新旧会话叠加。
    final restarted = engine.ensureStarted(Directory.systemTemp.path);
    await pumpEventQueue();
    expect(engine.alive, isFalse); // 仍在等拆机落地
    gate.complete(); // load 放行：job 以 null 收尾 → dispose → ['stopped']
    await waitUntil(() => fake.calls.contains('dispose'),
        why: 'load 收尾后 dispose');
    await restarted; // 拆机落地后才 spawn 新 worker
    expect(engine.alive, isTrue);
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
    await waitUntil(() => fake.calls.where((c) => c == 'dispose').length >= 2,
        why: '第二轮 shutdown 的 dispose');
  });

  test('shutdown waits for ["stopped"] ack before killing the handle',
      () async {
    _ScriptedHandle? handle;
    final engine = AutoEngine(
        idleRelease: const Duration(minutes: 5),
        spawn: (toMain, {onDied}) async {
          final rx = ReceivePort();
          rx.listen((m) {
            // 模拟真实 worker：收到 stop → dispose（此处无会话）→ 回 ack。
            if (m is List && m.isNotEmpty && m[0] == 'stop') {
              toMain.send(['stopped']);
            }
          });
          toMain.send(rx.sendPort);
          handle = _ScriptedHandle(rx);
          return handle!;
        });
    await engine.ensureStarted('/tmp/weights-dir');
    await engine.shutdown();
    expect(engine.alive, isFalse);
    await waitUntil(() => handle!.killed, why: 'ack 到达后才 kill');
  });

  test('grace timeout falls back to kill when worker never acks', () async {
    _ScriptedHandle? handle;
    final engine = AutoEngine(
        idleRelease: const Duration(minutes: 5),
        stopGrace: const Duration(milliseconds: 30),
        spawn: (toMain, {onDied}) async {
          final rx = ReceivePort();
          rx.listen((m) {
            // 挂死病态的替身：收到 stop 也不 ack。
          });
          toMain.send(rx.sendPort);
          handle = _ScriptedHandle(rx);
          return handle!;
        });
    await engine.ensureStarted('/tmp/weights-dir');
    await engine.shutdown();
    await waitUntil(() => handle!.killed, why: '宽限超时回退 kill');
  });

  test(
      'spawnIsolateAutoWorker（真 isolate）引导握手：'
      '_WorkerBoot 携 RootIsolateToken + 进口 ensureInitialized', () async {
    // 只验证真 spawn 的引导路径可用（这正是 v0.5.2 真机「Bad state:
    // BackgroundIsolateBinaryMessenger…」的缺口）：引导若失败（token 不可发送
    // /进口抛错），worker 会在握手前死于未捕获错误 → onDied 先到、握手永不到。
    // 故不发 job——一旦走平台通道就是 ORT/插件世界，宿主测试不可达（见文件头）。
    final toMain = ReceivePort();
    Object? died;
    final handle = await spawnIsolateAutoWorker(toMain.sendPort,
        onDied: (e) => died = e);
    final first = await toMain.first.timeout(const Duration(seconds: 10),
        onTimeout: () => fail('worker 握手超时（died=$died）'));
    expect(first, isA<SendPort>());
    expect(died, isNull); // 握手前无未捕获错误：引导路径干净
    await handle.kill();
    toMain.close();
  });
}
