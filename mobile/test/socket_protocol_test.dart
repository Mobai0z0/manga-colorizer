// 帧协议（mobile/lib/onnx/socket_protocol.dart）的宿主测试：真 loopback
// 套接字逐字对拍 + 任意分块拼帧 + 坏输入拒绝 + 握手扫描。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/socket_protocol.dart';

Frame _sampleJob(int grayLen) => Frame(FrameType.job,
    jobId: 7,
    data: const {'width': 3, 'height': 4},
    bytes: Uint8List(grayLen)..fillRange(0, grayLen, 42));

/// encodeFrame 产物是「长度前缀+载荷」的完整线上帧；parseFrame 只吃载荷。
Frame _decodeWire(Uint8List raw) {
  final len = ByteData.sublistView(raw).getUint32(0, Endian.little);
  return parseFrame(Uint8List.sublistView(raw, 4, 4 + len));
}

void main() {
  test('encode/parse round trip：全类型 + 空 json + 无 binary', () {
    const frames = [
      Frame(FrameType.hello, data: {'version': 1}),
      Frame(FrameType.helloOk, data: {'version': 1}),
      Frame(FrameType.config,
          data: {'dir': '/tmp/w', 'threads': 4, 'arena': true}),
      Frame(FrameType.progress, jobId: 3, data: {'p': 0.5}),
      Frame(FrameType.log, data: {'line': '块 1/4 耗时 1.2s'}),
      Frame(FrameType.error, data: {'message': 'boom'}),
    ];
    for (final f in frames) {
      final parsed = _decodeWire(encodeFrame(f));
      expect(parsed.type, f.type);
      expect(parsed.jobId, f.jobId);
      expect(parsed.data, f.data);
      expect(parsed.bytes, isNull);
    }
    // 带 binary 的 job / result：
    final job = _sampleJob(12);
    final parsedJob = _decodeWire(encodeFrame(job));
    expect(parsedJob.type, FrameType.job);
    expect(parsedJob.data, job.data);
    expect(parsedJob.bytes, hasLength(12));
    expect(parsedJob.bytes, everyElement(42));
  });

  test('FrameReader 任意分块拼帧：逐字节喂也能拼出完整帧', () {
    final raw = encodeFrame(_sampleJob(1000));
    final reader = FrameReader();
    final got = <Frame>[];
    for (final b in raw) {
      got.addAll(reader.push([b]));
    }
    expect(got, hasLength(1));
    expect(got.single.type, FrameType.job);
    expect(got.single.jobId, 7);
    expect(got.single.bytes, hasLength(1000));
  });

  test('FrameReader 多帧同块 + 半帧跨界', () {
    final raw = [...encodeFrame(_sampleJob(10)), ...encodeFrame(_sampleJob(20))];
    final reader = FrameReader();
    // 前半块含两帧的头部与部分载荷，后半块收尾：
    final got = [
      ...reader.push(raw.sublist(0, 30)),
      ...reader.push(raw.sublist(30, 60)),
      ...reader.push(raw.sublist(60)),
    ];
    expect(got, hasLength(2));
    expect(got[0].bytes, hasLength(10));
    expect(got[1].bytes, hasLength(20));
  });

  test('坏帧拒绝：未知类型 / 载荷过短 / json 越界都抛 FormatException', () {
    expect(() => parseFrame(Uint8List(8)), throwsA(isA<FormatException>()));
    expect(
        () => parseFrame(Uint8List.fromList([99, 0, 0, 0, 0, 0, 0, 0, 0])),
        throwsA(isA<FormatException>()));
    // jsonLen 声称 10 但载荷只有 9：
    final bad = Uint8List(9)
      ..[0] = FrameType.log.index + 1
      ..buffer.asByteData().setUint32(5, 10, Endian.little);
    expect(() => parseFrame(bad), throwsA(isA<FormatException>()));
  });

  test('真 loopback 双向往返：client→server 与 server→client 都逐字可读',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fromClient = <Frame>[];
    final gotAll = Completer<void>();
    late Socket serverSide;
    server.listen((s) {
      serverSide = s;
      readFrames(s).listen((f) {
        fromClient.add(f);
        if (fromClient.length == 2 && !gotAll.isCompleted) gotAll.complete();
      });
    });
    final client = await Socket.connect(
        InternetAddress.loopbackIPv4, server.port,
        timeout: const Duration(seconds: 5));
    final fromServer = <Frame>[];
    final gotReply = Completer<void>();
    readFrames(client).listen((f) {
      fromServer.add(f);
      if (fromServer.isNotEmpty && !gotReply.isCompleted) gotReply.complete();
    });

    writeFrame(client, const Frame(FrameType.hello, data: {'version': 1}));
    writeFrame(client, _sampleJob(2048));
    await client.flush();
    await gotAll.future.timeout(const Duration(seconds: 5));
    expect(fromClient, hasLength(2));
    expect(fromClient[0].type, FrameType.hello);
    expect(fromClient[1].bytes, hasLength(2048));

    writeFrame(serverSide, Frame(FrameType.result, bytes: Uint8List(16)));
    await serverSide.flush();
    await gotReply.future.timeout(const Duration(seconds: 5));
    expect(fromServer.single.type, FrameType.result);
    expect(fromServer.single.bytes, hasLength(16));

    client.destroy();
    serverSide.destroy();
    await server.close();
  });

  test('connectInferenceSocket：端口扫描连上 + 全端口拒绝则超时', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // TCP 连上即返回（帧级握手在调用方的读链上做，见 socket_worker）。
    final socket = await connectInferenceSocket(
        ports: [server.port], budget: const Duration(seconds: 5));
    expect(socket.remoteAddress.address, anyOf('127.0.0.1', '::1'));
    socket.destroy();

    // 全端口都连不上：budget 内抛 StateError。
    final freePort = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = freePort.port;
    await freePort.close();
    await expectLater(
        connectInferenceSocket(
            ports: [closedPort], budget: const Duration(milliseconds: 300)),
        throwsA(isA<StateError>()));
    await server.close();
  });
}
