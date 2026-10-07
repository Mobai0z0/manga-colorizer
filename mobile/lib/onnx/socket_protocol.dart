// :inference 进程与主进程之间的本地套接字帧协议。
//
// 布局（参考 local-dream 的 BackendService HTTP 契约，但走裸 TCP 免依赖）：
//   帧  = u32(payloadLen, LE) | payload
//   payload = u8(type) | u32(jobId, LE) | u32(jsonLen, LE) | json(utf8) | binary
//
//   · json 是 Map<String, Object?>（控制字段：version/dir/threads/arena/
//     width/height/p/line/message）；binary 是大块载荷（job 的 gray、result
//     的 rgb8）——两者分离让控制面永远只经 JSON、数据面零重组地传引用切片。
//   · 张量走 127.0.0.1 TCP 是有意的：Binder 事务限 1MB，而 gray/result 单帧
//     4–17MB；loopback 吞吐 GB/s 级，一块图 50ms 量级，不构成瓶颈。
//   · 纯 Dart、无 flutter 依赖：宿主测试用真 loopback 套接字逐字对拍。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 协议版本：握手不匹配立即失败（防新旧混跑）。
const int kInferenceProtocolVersion = 1;

/// 端口探测表：ServerSocket 冲突时逐个后移；客户端按同表扫描连接。
const int kInferencePortBase = 48765;
const int kInferencePortSpan = 11;

enum FrameType {
  hello, // client→server {version}
  helloOk, // server→client {version}
  config, // client→server {dir, threads, arena}
  job, // client→server {width, height} + binary=gray(w*h)
  progress, // server→client {p}
  log, // server→client {line}
  result, // server→client {} + binary=rgb8(w*h*3)
  error, // server→client {message}
}

class Frame {
  const Frame(this.type, {this.jobId = 0, this.data = const {}, this.bytes});

  final FrameType type;
  final int jobId;
  final Map<String, Object?> data;
  final Uint8List? bytes;

  @override
  String toString() =>
      'Frame(${type.name}, job=$jobId, data=$data, bytes=${bytes?.length ?? 0}B)';
}

/// 按协议布局编码一帧（head+json+binary 合并单缓冲）。
Uint8List encodeFrame(Frame frame) {
  final json = utf8.encode(jsonEncode(frame.data));
  final bytesLen = frame.bytes?.length ?? 0;
  final payloadLen = 1 + 4 + 4 + json.length + bytesLen;
  final head = Uint8List(13);
  final bd = ByteData.view(head.buffer);
  bd.setUint32(0, payloadLen, Endian.little);
  head[4] = frame.type.index + 1;
  bd.setUint32(5, frame.jobId, Endian.little);
  bd.setUint32(9, json.length, Endian.little);
  final out = Uint8List(13 + json.length + bytesLen)
    ..setRange(0, head.length, head)
    ..setRange(head.length, head.length + json.length, json);
  if (frame.bytes != null) {
    out.setRange(head.length + json.length, out.length, frame.bytes!);
  }
  return out;
}

/// 把一帧写成套接字（add 是缓冲写，单帧最大 ~17MB 无需分块）。
void writeFrame(Socket socket, Frame frame) => socket.add(encodeFrame(frame));

/// 增量帧解析器：网络分块任意切分都能正确拼帧。
class FrameReader {
  Uint8List _buf = Uint8List(0);
  int _start = 0;

  /// 喂入一个网络分块，返回其中解析出的完整帧（0 个或多个）。
  List<Frame> push(List<int> chunk) {
    // 压实未消费前缀后拼接新分块（单帧最大 ~17MB、整帧内 ~200 个分块，
    // 逐块合并的均摊拷贝成本可忽略）。
    if (_start > 0) {
      _buf = Uint8List.fromList(Uint8List.sublistView(_buf, _start));
      _start = 0;
    }
    final merged = Uint8List(_buf.length + chunk.length)
      ..setRange(0, _buf.length, _buf)
      ..setRange(_buf.length, _buf.length + chunk.length, chunk);
    _buf = merged;
    final frames = <Frame>[];
    var offset = 0;
    while (_buf.length - offset >= 4) {
      final payloadLen =
          ByteData.sublistView(_buf, offset).getUint32(0, Endian.little);
      if (payloadLen < 9) {
        throw FormatException('帧载荷过短: $payloadLen');
      }
      if (_buf.length - offset - 4 < payloadLen) break; // 半帧：等下个分块
      frames.add(parseFrame(
          Uint8List.sublistView(_buf, offset + 4, offset + 4 + payloadLen)));
      offset += 4 + payloadLen;
    }
    _start = offset;
    return frames;
  }
}

/// 按协议布局解析 payload；任何越界/坏类型抛 FormatException。
Frame parseFrame(Uint8List payload) {
  if (payload.length < 9) throw FormatException('载荷过短: ${payload.length}');
  final typeIdx = payload[0];
  if (typeIdx < 1 || typeIdx > FrameType.values.length) {
    throw FormatException('未知帧类型: $typeIdx');
  }
  final bd = ByteData.sublistView(payload);
  final jobId = bd.getUint32(1, Endian.little);
  final jsonLen = bd.getUint32(5, Endian.little);
  if (payload.length < 9 + jsonLen) {
    throw FormatException('json 长度越界: $jsonLen > ${payload.length - 9}');
  }
  final data = jsonLen == 0
      ? const <String, Object?>{}
      : (jsonDecode(utf8.decode(Uint8List.sublistView(payload, 9, 9 + jsonLen)))
              as Map)
          .cast<String, Object?>();
  final bytes = payload.length > 9 + jsonLen
      ? Uint8List.sublistView(payload, 9 + jsonLen)
      : null;
  return Frame(FrameType.values[typeIdx - 1],
      jobId: jobId, data: data, bytes: bytes);
}

/// 从套接字读出帧流；连接断开时流自然结束。
Stream<Frame> readFrames(Socket socket) async* {
  final reader = FrameReader();
  await for (final chunk in socket) {
    for (final f in reader.push(chunk)) {
      yield f;
    }
  }
}

/// 连接扫描：服务由 FlutterEngineGroup 冷启动，端口就绪有延迟——100ms 起步
/// 指数退避（local-dream ModelRunSupport 的健康检查模式），[budget] 内连上
/// TCP 即返回。**帧级 hello 握手不在这里做**：dart:io 套接字流只许一次订阅，
/// 握手必须与后续业务帧共用调用方的同一条 readFrames 消费链（见
/// socket_worker.dart 的 _SocketBridge.handshake），否则 .first 取消底层订阅
/// 之后业务帧永远读不到（v0.5.9 开发期真踩过）。
Future<Socket> connectInferenceSocket(
    {List<int>? ports, Duration budget = const Duration(seconds: 10)}) async {
  final candidatePorts = ports ??
      [for (var i = 0; i < kInferencePortSpan; i++) kInferencePortBase + i];
  final deadline = DateTime.now().add(budget);
  var delay = const Duration(milliseconds: 50);
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    for (final port in candidatePorts) {
      try {
        return await Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: const Duration(milliseconds: 200));
      } on Object catch (e) {
        lastError = e;
      }
    }
    await Future<void>.delayed(delay);
    delay = delay * 2 > const Duration(milliseconds: 500)
        ? const Duration(milliseconds: 500)
        : delay * 2;
  }
  throw StateError('推理服务连接超时（${candidatePorts.first} 起）：$lastError');
}
