// 主进程桥（mobile/lib/onnx/socket_worker.dart）的宿主测试：
//   · 引擎级集成：AutoEngine(spawn: spawnInferenceServiceWorker) ↔ 真实
//     loopback 套接字 ↔ serveClient + InferenceServerCore ↔ FakeBackend，
//     验证 RPC 消息面（progress/result/log）跨进程协议等价、stop 合成 ack、
//     kill 停服务、服务进程断开按 worker 死亡处理。
//   · defaultAutoSpawn：服务启动失败自动回退进程内 isolate。
// 服务起停经 @visibleForTesting 接缝注入（不触碰真 MethodChannel/前台服务）。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/inference/inference_server.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/onnx/auto_service.dart';
import 'package:manga_colorizer_mobile/onnx/socket_protocol.dart';
import 'package:manga_colorizer_mobile/onnx/socket_worker.dart';

import 'fake_backend.dart';

Uint8List gray40x16() => Uint8List(40 * 16)..fillRange(0, 40 * 16, 128);

void main() {
  late AutoBackendFactory origFactory;
  late int origInfer, origOverlap;
  late ServiceStarter origStart;
  late ServiceStopper origStop;
  late List<int> origPorts;
  late Duration origBudget;
  late bool origPrefer;
  late SpawnAutoWorker origFallback;

  setUp(() {
    origFactory = autoBackendFactory;
    origInfer = autoInfer;
    origOverlap = autoOverlap;
    origStart = startInferenceService;
    origStop = stopInferenceService;
    origPorts = inferenceCandidatePorts;
    origBudget = inferenceConnectBudget;
    origPrefer = preferInferenceService;
    origFallback = fallbackAutoSpawn;
    autoInfer = 16;
    autoOverlap = 8;
  });
  tearDown(() {
    autoBackendFactory = origFactory;
    autoInfer = origInfer;
    autoOverlap = origOverlap;
    startInferenceService = origStart;
    stopInferenceService = origStop;
    inferenceCandidatePorts = origPorts;
    inferenceConnectBudget = origBudget;
    preferInferenceService = origPrefer;
    fallbackAutoSpawn = origFallback;
  });

  /// 起一个真实推理服务（serveClient + 核心 + FakeBackend 工厂），把起停
  /// 接缝注入到它，返回端口与停服记录器。
  Future<(int, List<String>)> startFakeService(FakeBackend backend) async {
    final core = InferenceServerCore();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => serveClient(s, core));
    final stopped = <String>[];
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => backend;
    inferenceCandidatePorts = [server.port];
    startInferenceService = () async {};
    stopInferenceService = () async {
      stopped.add('stop');
      await server.close();
    };
    return (server.port, stopped);
  }

  test('引擎级集成：colorize 全链路（进度/结果跨协议等价）', () async {
    final fake = FakeBackend();
    final (_, stopped) = await startFakeService(fake);
    final bus = LogBus();
    final engine = AutoEngine(
        spawn: spawnInferenceServiceWorker,
        idleRelease: const Duration(minutes: 5),
        logBus: bus);
    await engine.ensureStarted('/tmp/weights-dir');
    final progress = <double>[];
    final out =
        await engine.colorize(gray40x16(), 40, 16, onProgress: progress.add);
    expect(out, isNotNull);
    expect(out!.length, 40 * 16 * 3);
    expect(progress, [0.25, 0.5, 0.75, 1.0]); // 与 isolate 路径同协议
    expect(fake.calls.where((c) => c == 'load').length, 1);
    expect(fake.calls.where((c) => c.startsWith('sam:')).length, 4);
    expect(fake.calls.where((c) => c.startsWith('gen:')).length, 4);
    await engine.shutdown();
    expect(engine.alive, isFalse);
    await waitStopped(stopped);
    for (final e in bus.entries) { print('BUS: ${e.level} ${e.message}'); }
  });

  test('在飞任务 cancel：ack 合成、job 以 null 完结、服务被停（零泄漏）',
      () async {
    final gate = Completer<void>();
    final fake = _BlockingBackend(gate: gate);
    final (_, stopped) = await startFakeService(fake);
    final engine = AutoEngine(
        spawn: spawnInferenceServiceWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted('/tmp/weights-dir');
    final pending = engine.colorize(gray40x16(), 40, 16);
    final sw = Stopwatch()..start();
    while (!fake.entered && sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await engine.cancel(); // 桥合成立即 ack，引擎拆机不等待推理收尾
    expect(await pending, isNull);
    expect(engine.alive, isFalse);
    await waitStopped(stopped);
    gate.complete(); // 服务侧在飞任务收尾（写帧失败静默）
    await pumpEventQueue();
  });

  test('服务进程断开 → onDied：在飞 job 报错完单、引擎可复活', () async {
    final gate = Completer<void>();
    final fake = _BlockingBackend(gate: gate);
    final core = InferenceServerCore();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // ServerSocket.close() 只停止 accept、不断已建立的连接——推理进程死亡
    // 的等价物是 destroy 服务端套接字（连接重置）。
    Socket? serverSide;
    server.listen((s) {
      serverSide = s;
      serveClient(s, core).onError<Object>((_, __) {});
    });
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    inferenceCandidatePorts = [server.port];
    startInferenceService = () async {};
    stopInferenceService = () async {};
    final engine = AutoEngine(
        spawn: spawnInferenceServiceWorker,
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted('/tmp/weights-dir');
    final pending = engine.colorize(gray40x16(), 40, 16);
    final pendingCheck = expectLater(pending, throwsA(isA<Exception>()));
    final sw = Stopwatch()..start();
    while (!fake.entered && sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    serverSide!.destroy(); // 等价推理进程死亡：连接重置
    await pendingCheck;
    await server.close();
    expect(engine.alive, isFalse);
    gate.complete();
    await pumpEventQueue();
    // 复活（换新假服务）：
    final (_, stopped2) = await startFakeService(FakeBackend());
    await engine.ensureStarted('/tmp/weights-dir');
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
    await waitStopped(stopped2);
  });

  test('defaultAutoSpawn：服务启动失败自动回退进程内 isolate', () async {
    preferInferenceService = true; // Windows 宿主上强制走"优先独立进程"分支
    startInferenceService = () async => throw StateError('FGS 被禁');
    // 回退路径换成 in-process worker（真 isolate 是新堆 → 生产工厂 → ORT/
    // 插件世界，宿主测试不可达，与 auto_service_test 同一边界）。
    fallbackAutoSpawn = startInProcessAutoWorker;
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => FakeBackend();
    final engine = AutoEngine(
        spawn: defaultAutoSpawn, idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    final progress = <double>[];
    final out = await engine.colorize(gray40x16(), 40, 16,
        onProgress: progress.add);
    expect(out, isNotNull); // 回退后完整跑通
    expect(progress, [0.25, 0.5, 0.75, 1.0]);
    await engine.shutdown();
  });

  test('defaultAutoSpawn：连接超时也回退（端口拒绝连接）', () async {
    preferInferenceService = true;
    startInferenceService = () async {};
    stopInferenceService = () async {};
    inferenceConnectBudget = const Duration(milliseconds: 300);
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = blocker.port;
    await blocker.close(); // 关闭后端口拒绝连接：connect 快速失败重试到超时
    inferenceCandidatePorts = [closedPort];
    fallbackAutoSpawn = startInProcessAutoWorker;
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => FakeBackend();
    final engine = AutoEngine(
        spawn: defaultAutoSpawn, idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(await engine.colorize(gray40x16(), 40, 16), isNotNull);
    await engine.shutdown();
  });

  test('握手失败（协议版本不匹配）→ spawn 抛错并停服务', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      readFrames(s).listen((f) {
        if (f.type == FrameType.hello) {
          writeFrame(
              s, const Frame(FrameType.helloOk, data: {'version': 999}));
        }
      });
    });
    inferenceCandidatePorts = [server.port];
    startInferenceService = () async {};
    var stopped = 0;
    stopInferenceService = () async => stopped++;
    final toMain = ReceivePort();
    await expectLater(
        spawnInferenceServiceWorker(toMain.sendPort),
        throwsA(isA<StateError>()));
    expect(stopped, 1); // spawn 失败也要停服务，别留空转前台服务
    toMain.close();
    await server.close();
  });

  test('桥接日志透传：log 帧经事件流进入 LogBus', () async {
    final bus = LogBus();
    final fake = FakeBackend();
    final (_, stopped) = await startFakeService(fake);
    final engine = AutoEngine(
        spawn: spawnInferenceServiceWorker,
        idleRelease: const Duration(minutes: 5),
        logBus: bus);
    await engine.ensureStarted('/tmp/weights-dir');
    await engine.colorize(gray40x16(), 40, 16);
    await engine.shutdown();
    await waitStopped(stopped);
    expect(
        bus.entries.map((e) => e.message).any((t) => t.contains('双 session 加载完成')),
        isTrue);
  });
}

Future<void> waitStopped(List<String> stopped) async {
  final sw = Stopwatch()..start();
  while (stopped.isEmpty && sw.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(stopped, isNotEmpty, reason: '服务应被停止');
}

/// runGen 前挂闸门（与 inference_server_test 的替身同款，只拦第一次进入）。
class _BlockingBackend extends FakeBackend {
  _BlockingBackend({required this.gate});
  final Completer<void> gate;
  bool entered = false;
  int _entries = 0;

  @override
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    final shouldBlock = _entries++ == 0;
    if (shouldBlock) {
      entered = true;
      await gate.future;
    }
    return super.runGen(grayPlane, s, sam0, sam1);
  }
}
