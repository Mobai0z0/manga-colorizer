// 权重仓储：首启下载（Range 断点续传 + sha256 校验）。权重 CC BY-NC-SA 4.0，
// 不随 APK 分发，由使用者自行下载；镜像站 hf-mirror 供国内网络直连。
import 'dart:io';
import 'package:crypto/crypto.dart';

class WeightFile {
  const WeightFile({
    required this.name,
    required this.size,
    required this.sha256,
    required this.url,
    required this.mirrorUrl,
  });
  final String name;
  final int size;
  final String sha256;
  final String url;
  final String mirrorUrl;
}

const kWeightFiles = <WeightFile>[
  WeightFile(
    name: 'v6_generator.onnx',
    size: 191335312,
    sha256: '48284fcf0b7a606270702630f559af88eecf95bc6cdec1ff8bce8663d12b4bb6',
    url:
        'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/v6_generator.onnx',
    mirrorUrl:
        'https://hf-mirror.com/sharky172/manga-light-colorizer/resolve/main/models/v6_generator.onnx',
  ),
  WeightFile(
    name: 'v6_sam_encoder.onnx',
    size: 108983556,
    sha256: '97c4cad5814e1fb12c13d1b23d3969dd9e2fce92d818539fe7db575140333a34',
    url:
        'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/v6_sam_encoder.onnx',
    mirrorUrl:
        'https://hf-mirror.com/sharky172/manga-light-colorizer/resolve/main/models/v6_sam_encoder.onnx',
  ),
];

class WeightsException implements Exception {
  WeightsException(this.message);
  final String message;
  @override
  String toString() => 'WeightsException: $message';
}

class WeightsStore {
  WeightsStore({required this.dir, required this.mirrorPreferred});
  final Directory dir;
  final bool Function(String url) mirrorPreferred;

  String pathOf(WeightFile f) => '${dir.path}/${f.name}';

  bool readyFor(WeightFile f) {
    final x = File(pathOf(f));
    return x.existsSync() && x.lengthSync() == f.size;
  }

  Future<bool> get ready async {
    for (final f in kWeightFiles) {
      if (!readyFor(f)) return false;
    }
    return true;
  }

  Future<void> download(
    WeightFile f, {
    void Function(int done, int total)? onProgress,
  }) async {
    final part = File('${pathOf(f)}.part');
    var start = part.existsSync() ? part.lengthSync() : 0;
    if (start > f.size) {
      await part.delete();
      start = 0;
    }
    final client = HttpClient();
    try {
      final url = mirrorPreferred(f.url) ? f.mirrorUrl : f.url;
      var done =
          await _fetch(client, Uri.parse(url), part, start, f, onProgress);
      if (done != f.size) {
        // .part 可能过期损坏：整段重下一次（唯一一次），仍不对则抛
        await part.delete();
        done = await _fetch(client, Uri.parse(url), part, 0, f, onProgress);
        if (done != f.size) {
          await part.delete();
          throw WeightsException('${f.name}: 大小 $done != ${f.size}');
        }
      }
      // 流式 sha256 校验（大文件不整读进内存）
      final digest = (await sha256.bind(part.openRead()).first).toString();
      if (digest != f.sha256) {
        await part.delete();
        throw WeightsException('${f.name}: sha256 校验失败');
      }
      final out = File(pathOf(f));
      if (out.existsSync()) await out.delete();
      await part.rename(out.path);
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _fetch(
    HttpClient client,
    Uri url,
    File part,
    int start,
    WeightFile f,
    void Function(int done, int total)? onProgress,
  ) async {
    final req = await client.getUrl(url);
    if (start > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    final res = await req.close();
    if (res.statusCode != 200 && res.statusCode != 206) {
      throw WeightsException('${f.name}: HTTP ${res.statusCode}');
    }
    // 206 = 续传（在 .part 后追加）；200 = 服务端忽略 Range，整段重写
    final append = res.statusCode == 206;
    final sink =
        part.openWrite(mode: append ? FileMode.append : FileMode.write);
    var done = append ? start : 0;
    await for (final chunk in res) {
      sink.add(chunk);
      done += chunk.length;
      onProgress?.call(done, f.size);
    }
    await sink.flush();
    await sink.close();
    return part.lengthSync();
  }
}
