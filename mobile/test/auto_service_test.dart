// isolate 服务（mobile/lib/onnx/auto_service.dart）的宿主测试：
//   · 用 startInProcessAutoWorker 在同一 isolate 里跑**与真机完全相同**的 worker
//     消息循环，后端经 autoBackendFactory 换成 FakeBackend —— 真实 ORT/网络/
//     path_provider 一律不触碰（OrtOnnxBackend 在宿主测试里根本无法构造）。
//   · RPC 线格式逐字断言：命令 ['dir',p] / ['job',g,w,h] / ['stop']；
//     事件 ['progress',double] / ['result',Uint8List?] / ['error',String]。
//   · 死亡兜底（畸形消息解码守卫 / 退出·未捕获错误→onDied）也经同一接缝驱动。
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
    autoBackendFactory = (dir) {
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
    expect(fake.calls, contains('dispose')); // 空闲/关闭即 dispose() session
  });

  test('ensureStarted is idempotent while alive', () async {
    var spawns = 0;
    autoBackendFactory = (_) => FakeBackend();
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
    autoBackendFactory = (_) => throw StateError('weights missing');
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    await expectLater(
        engine.colorize(gray40x16(), 40, 16),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('weights missing'))));
    // 出错不复位引擎：修好后同引擎可继续接单（worker 循环存活）。
    autoBackendFactory = (_) => FakeBackend();
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
  });

  test('cancel resolves running job with null and tears the worker down',
      () async {
    final fake = _GatedBackend(gate: Completer<void>());
    autoBackendFactory = (_) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    final pending = engine.colorize(gray40x16(), 40, 16);
    await waitUntil(() => fake.entered, why: 'worker 进入 runGen');
    await engine.cancel();
    expect(await pending, isNull); // 取消 → null 完结
    expect(engine.alive, isFalse); // 工作 isolate 已杀
    fake.gate.complete(); // 放闸让 in-process 循环收尾（真机随 isolate 死亡）
    await pumpEventQueue();
    // 重新 ensureStarted 后可再次完整跑通。
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
  });

  test('concurrency is 1: second colorize while busy throws', () async {
    final fake = _GatedBackend(gate: Completer<void>()..complete());
    autoBackendFactory = (_) => fake;
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
    autoBackendFactory = (_) => fake;
    final engine = AutoEngine(
        spawn: startInProcessAutoWorker,
        idleRelease: const Duration(milliseconds: 40));
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    expect(engine.alive, isTrue); // 刚结束仍常驻
    await waitUntil(() => !engine.alive, why: '空闲自动释放');
    expect(fake.calls, contains('dispose'));
  });

  test('shutdown without a live engine is a no-op', () async {
    final engine = AutoEngine(spawn: startInProcessAutoWorker);
    await engine.shutdown();
    expect(engine.alive, isFalse);
  });

  test('RPC wire format is exactly ["dir",p] / ["job",g,w,h] / ["stop"]',
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
    // 命令逐字对拍：
    expect(received, [
      ['dir', '/tmp/weights-dir'],
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
    autoBackendFactory = (_) => fake;
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
    autoBackendFactory = (_) => FakeBackend();
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
      'lets ensureStarted respawn', () async {
    final fake = _GatedBackend(gate: Completer<void>());
    autoBackendFactory = (_) => fake;
    late void Function(Object why) notifyDied;
    final engine = AutoEngine(
        spawn: (toMain, {onDied}) {
          // 生产路径里 onDied 由 spawnIsolateAutoWorker 挂的 onError/退出监听
          // 口驱动；in-process 循环没有退出事件，测试直接触发同一回调。
          notifyDied = (why) => onDied!(why);
          return startInProcessAutoWorker(toMain, onDied: onDied);
        },
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
}
