// 推理服务核心（mobile/lib/inference/inference_server.dart）的宿主测试：
// 真实 loopback 套接字 + serveClient 全链路，后端经 auto_service 的
// autoBackendFactory/autoInfer/autoOverlap 接缝换 FakeBackend（与 isolate
// worker 测试共享同一替身，真实 ORT 一律不触碰）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/inference/inference_server.dart';
import 'package:manga_colorizer_mobile/onnx/auto_service.dart';
import 'package:manga_colorizer_mobile/onnx/socket_protocol.dart';

import 'fake_backend.dart';

Uint8List gray40x16() => Uint8List(40 * 16)..fillRange(0, 40 * 16, 128);

/// runGen 前挂闸门：把服务钉在"任务进行中"。blockOnlyFirst 时只拦第一次
/// 进入（测断开弃置：被拦的是弃置的旧 job，新连接的 job 必须畅通）。
class _GatedBackend extends FakeBackend {
  _GatedBackend({required this.gate, this.blockOnlyFirst = false});
  final Completer<void> gate;
  final bool blockOnlyFirst;
  bool entered = false;
  int _entries = 0;

  @override
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1) async {
    final shouldBlock = !blockOnlyFirst || _entries++ == 0;
    if (shouldBlock) entered = true;
    if (shouldBlock) await gate.future;
    return super.runGen(grayPlane, s, sam0, sam1);
  }
}

void main() {
  late AutoBackendFactory origFactory;
  late int origInfer, origOverlap;

  setUp(() {
    origFactory = autoBackendFactory;
    origInfer = autoInfer;
    origOverlap = autoOverlap;
    // 与 auto_service_test 同款小分块：40×16、infer=16、overlap=8 → 4 块。
    autoInfer = 16;
    autoOverlap = 8;
    // 断连档案是库级变量，跨用例存活：清掉再跑，防问候帧污染首帧断言。
    clearLastDisconnect();
  });
  tearDown(() {
    autoBackendFactory = origFactory;
    autoInfer = origInfer;
    autoOverlap = origOverlap;
  });

  /// 起一条「服务端（serveClient+核心）↔ 客户端（帧协议）」的全链路，
  /// 返回客户端套接字与其帧流、服务端与核心。握手由调用方发送。
  Future<(Socket, Stream<Frame>, ServerSocket, InferenceServerCore)> startEnv() async {
    final core = InferenceServerCore();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      // 客户端销毁后 serveClient 的读端会抛 SocketException：测试里吞掉
      // （生产路径由 inferenceServerMain 的 onError 兜底）。
      serveClient(s, core).onError<Object>((_, __) {});
    });
    final conn = await Socket.connect(
        InternetAddress.loopbackIPv4, server.port,
        timeout: const Duration(seconds: 5));
    return (conn, readFrames(conn), server, core);
  }

  void handshake(Socket conn) {
    writeFrame(conn, const Frame(FrameType.hello,
        data: {'version': kInferenceProtocolVersion}));
    writeFrame(conn,
        const Frame(FrameType.config, data: {'dir': '/tmp/weights'}));
  }

  test('hello → helloOk（协议版本回传）', () async {
    final (conn, frames, server, core) = await startEnv();
    writeFrame(conn, const Frame(FrameType.hello,
        data: {'version': kInferenceProtocolVersion}));
    final first = await frames.first
        .timeout(const Duration(seconds: 5), onTimeout: () => throw '超时');
    expect(first.type, FrameType.helloOk);
    expect(first.data['version'], kInferenceProtocolVersion);
    conn.destroy();
    await server.close();
    await core.dispose();
  });

  test('config + job：进度逐块上报、result 字节齐全、config 注入工厂参数',
      () async {
    final fake = FakeBackend();
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) {
      expect(intraThreads, 3);
      expect(useArena, isFalse);
      return fake;
    };
    final (conn, frames, server, core) = await startEnv();
    writeFrame(conn, const Frame(FrameType.hello,
        data: {'version': kInferenceProtocolVersion}));
    writeFrame(conn, const Frame(FrameType.config,
        data: {'dir': '/tmp/weights', 'threads': 3, 'arena': false}));
    writeFrame(conn, Frame(FrameType.job, jobId: 9,
        data: const {'width': 40, 'height': 16}, bytes: gray40x16()));
    final got = <Frame>[];
    await for (final f in frames) {
      got.add(f);
      if (f.type == FrameType.result) break;
    }
    expect(got.first.type, FrameType.helloOk);
    expect(got.map((f) => f.type), contains(FrameType.result));
    expect(got.where((f) => f.type == FrameType.progress).map((f) => f.data['p']),
        [0.25, 0.5, 0.75, 1.0]); // 按块上报、终值 1.0
    expect(fake.calls.where((c) => c == 'load').length, 1);
    final result = got.lastWhere((f) => f.type == FrameType.result);
    expect(result.jobId, 9);
    expect(result.bytes, hasLength(40 * 16 * 3));
    conn.destroy();
    await server.close();
    await core.dispose();
  });

  test('job 出错 → error 帧（引擎侧在飞完单）', () async {
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) =>
        throw StateError('weights missing');
    final (conn, frames, server, core) = await startEnv();
    handshake(conn);
    writeFrame(conn, Frame(FrameType.job,
        data: const {'width': 40, 'height': 16}, bytes: gray40x16()));
    final got = <Frame>[];
    await for (final f in frames) {
      got.add(f);
      if (f.type == FrameType.error) break;
    }
    expect(got.last.type, FrameType.error);
    expect(got.last.data['message'], contains('weights missing'));
    conn.destroy();
    await server.close();
    await core.dispose();
  });

  test('并发守卫：在飞任务期间第二个 job 回 error、不崩核心', () async {
    final gate = Completer<void>();
    final fake = _GatedBackend(gate: gate);
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final (conn, frames, server, core) = await startEnv();
    handshake(conn);
    writeFrame(conn, Frame(FrameType.job,
        data: const {'width': 40, 'height': 16}, bytes: gray40x16()));
    final sw = Stopwatch()..start();
    while (!fake.entered && sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    writeFrame(conn, Frame(FrameType.job, jobId: 2,
        data: const {'width': 40, 'height': 16}, bytes: gray40x16()));
    // 关键时序：闸门还拦着 job1 时，先让服务端的事件循环读到 job2 并回
    // error（FakeBackend 全在微任务里瞬间跑完，若先放闸，job2 会被排到
    // job1 完全结束之后、busy 已复位——真机上一块跑数秒，不存在此窗口）。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final got = <Frame>[];
    gate.complete(); // 第一个 job 放行收尾
    // job2 的拒单 error 与 job1 的 result 到达顺序有竞态（job2 帧的处理与
    // 放行几乎同时）：收集到两者齐全或超时为止。
    var hasResult = false;
    var hasMidError = false;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    await for (final f in frames) {
      got.add(f);
      hasResult |= f.type == FrameType.result;
      hasMidError |= f.type == FrameType.error && f.jobId == 2;
      if (hasResult && hasMidError) break;
      if (DateTime.now().isAfter(deadline)) fail('等待 result+error 超时: $got');
    }
    final midError = got.where((f) => f.type == FrameType.error).toList();
    expect(midError, hasLength(1));
    expect(midError.single.jobId, 2);
    final result = got.lastWhere((f) => f.type == FrameType.result);
    expect(result.jobId, 0); // 第一个 job（缺省 jobId=0）正常完单
    conn.destroy();
    await server.close();
    await core.dispose();
  });

  test('断开弃置：在飞任务中客户端断开，新连接可立即接单', () async {
    final gate = Completer<void>();
    final fake = _GatedBackend(gate: gate, blockOnlyFirst: true);
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final core = InferenceServerCore();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => serveClient(s, core).onError<Object>((_, __) {}));

    Future<(Socket, Stream<Frame>)> connectClient() async {
      final c = await Socket.connect(
          InternetAddress.loopbackIPv4, server.port,
          timeout: const Duration(seconds: 5));
      writeFrame(c, const Frame(FrameType.hello,
          data: {'version': kInferenceProtocolVersion}));
      writeFrame(c,
          const Frame(FrameType.config, data: {'dir': '/tmp/weights'}));
      return (c, readFrames(c));
    }

    // 连接 A：在飞中直接断开（等价服务端崩溃前的 UI 侧断连）。
    final (a, _) = await connectClient();
    writeFrame(a, Frame(FrameType.job,
        data: const {'width': 40, 'height': 16}, bytes: gray40x16()));
    final sw = Stopwatch()..start();
    while (!fake.entered && sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    a.destroy();
    await pumpEventQueue();

    // 连接 B：旧 job 被弃置，立即接单跑完。
    final (b, bFrames) = await connectClient();
    writeFrame(b, Frame(FrameType.job,
        data: const {'width': 40, 'height': 16}, bytes: gray40x16()));
    Frame? result;
    await for (final f in bFrames) {
      if (f.type == FrameType.result) {
        result = f;
        break;
      }
    }
    expect(result, isNotNull);
    expect(result!.bytes, hasLength(40 * 16 * 3));
    gate.complete(); // 弃置的旧 job 收尾（写帧失败静默，不影响新代）
    await pumpEventQueue();
    b.destroy();
    await server.close();
    await core.dispose();
  });

  test('bindInferenceServer：端口表首位被占则顺延', () async {
    final blocker =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, kInferencePortBase);
    final s = await bindInferenceServer();
    expect(s.port, kInferencePortBase + 1);
    await s.close();
    await blocker.close();
  });

  test('断连取证：EOF 落档案（含任务在飞）、重连问候帧在 helloOk 之后', () async {
    final gate = Completer<void>();
    final fake = _GatedBackend(gate: gate, blockOnlyFirst: true);
    autoBackendFactory = (_, {int? intraThreads, bool? useArena}) => fake;
    final core = InferenceServerCore();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => serveClient(s, core).onError<Object>((_, __) {}));

    // 连接 A：job 在飞中直接断开（等价「推理中断连、进程未必死」的服务端视角）。
    final a = await Socket.connect(InternetAddress.loopbackIPv4, server.port,
        timeout: const Duration(seconds: 5));
    writeFrame(a, const Frame(FrameType.hello,
        data: {'version': kInferenceProtocolVersion}));
    writeFrame(a,
        const Frame(FrameType.config, data: {'dir': '/tmp/weights'}));
    writeFrame(a, Frame(FrameType.job,
        data: const {'width': 40, 'height': 16}, bytes: gray40x16()));
    final sw = Stopwatch()..start();
    while (!fake.entered && sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(core.busy, isTrue); // 任务在飞：断连取证要带上这个标记
    a.destroy();
    // 上个用例（或本用例早前）销毁连接的 EOF 事件可能跨 await 晚到覆盖档案：
    // 轮询等到带「任务在飞」的本用例记录为止（EOF/读错误皆可能，平台相关）。
    while (!(lastDisconnect()?.$1 ?? '').contains('任务在飞') &&
        sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final (note, _) = lastDisconnect()!;
    // Windows 上 destroy（RST）且服务端还有帧在写会落成写错误，Linux 多为
    // EOF——两者都是有效取证，关键是「任务在飞」标记必须带上。
    expect(note, anyOf(contains('EOF'), contains('读错误')));
    expect(note, contains('任务在飞'));

    // 连接 B：问候帧必须在 helloOk 之后（桥的握手只认首帧 helloOk），且内容
    // 带上一次断连情况——这就是「连接断开但进程还活着」时日志页能拿到的证据。
    final b = await Socket.connect(InternetAddress.loopbackIPv4, server.port,
        timeout: const Duration(seconds: 5));
    writeFrame(b, const Frame(FrameType.hello,
        data: {'version': kInferenceProtocolVersion}));
    final it = StreamIterator(readFrames(b));
    expect(await it.moveNext(), isTrue);
    final first = it.current;
    expect(first.type, FrameType.helloOk);
    expect(await it.moveNext(), isTrue);
    final second = it.current;
    expect(second.type, FrameType.log);
    expect(second.data['line'], contains('上次连接断开'));
    expect(second.data['line'], contains('任务在飞'));
    await it.cancel();

    gate.complete(); // 弃置的旧 job 收尾（写帧静默失败）
    await pumpEventQueue();
    b.destroy();
    a.destroy();
    await server.close();
    await core.dispose();
    clearLastDisconnect(); // 不把本用例的档案漏给后续用例
  });
}
