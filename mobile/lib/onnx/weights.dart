// 权重仓储：首启下载（Range 断点续传 + sha256 校验）。权重 CC BY-NC-SA 4.0，
// 不随 APK 分发，由使用者自行下载；下载源可选主站/镜像/自动（自动=主站失败回退镜像）。
import 'dart:io';
import 'package:crypto/crypto.dart';

/// 权重下载源选择。
enum DownloadSource {
  /// 优先主站（huggingface.co），传输失败自动回退镜像（hf-mirror.com）。
  auto,

  /// 仅走主站，不回退。
  primary,

  /// 仅走镜像。
  mirror,
}

/// 单个权重文件的清单条目（大小/哈希/URL 均为逐字定值，改动即视同换版本）。
class WeightFile {
  const WeightFile({
    required this.name,
    required this.size,
    required this.sha256,
    required this.url,
    required this.mirrorUrl,
  });

  /// 文件名，同时是权重目录下的落盘名。
  final String name;

  /// 精确字节数：就绪探测与下载进度 total 都以此为准（不打开文件算哈希）。
  final int size;

  /// 小写十六进制 sha256，下载完成后流式校验，通过才晋升为正式文件。
  final String sha256;

  /// 主站（huggingface.co）resolve 直链。
  final String url;

  /// 镜像站（hf-mirror.com）直链——`auto` 回退与 `mirror` 源使用。
  final String mirrorUrl;
}

/// 端侧全自动模式需要的两个权重（generator + SAM encoder），合计约 300 MB。
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

/// 权重仓储的唯一对外异常类型：HTTP 非 2xx、传输中断（折叠原始错误文本）、
/// 大小不符、sha256 校验失败都只以它出现，调用方无需感知底层异常。
class WeightsException implements Exception {
  WeightsException(this.message);
  final String message;
  @override
  String toString() => 'WeightsException: $message';
}

/// 权重仓储：在 [dir] 下按 [source] 管理 [kWeightFiles] 的就绪探测与断点续传下载。
/// 不读不写内存缓存，状态全部以磁盘上的正式文件 / `<name>.part` 为准。
class WeightsStore {
  WeightsStore({required this.dir, this.source = DownloadSource.auto});

  /// 权重目录（应用私有存储路径，[download] 时按需创建）。
  final Directory dir;

  /// 下载源策略，见 [DownloadSource]。
  final DownloadSource source;

  /// 权重文件的落盘路径（不校验存在性）。
  String pathOf(WeightFile f) => '${dir.path}/${f.name}';

  /// 单个文件是否就绪：存在且字节数 == [WeightFile.size]。
  /// 只看大小、不校验哈希（哈希在 [download] 收尾做）。
  bool readyFor(WeightFile f) {
    final x = File(pathOf(f));
    return x.existsSync() && x.lengthSync() == f.size;
  }

  /// [kWeightFiles] 是否全部就绪（逐项 [readyFor]）。
  Future<bool> get ready async {
    for (final f in kWeightFiles) {
      if (!readyFor(f)) return false;
    }
    return true;
  }

  /// 按 [source] 得到候选 URL 的尝试顺序；主站与镜像相同则去重。
  List<String> _urlsFor(WeightFile f) {
    switch (source) {
      case DownloadSource.primary:
        return [f.url];
      case DownloadSource.mirror:
        return [f.mirrorUrl];
      case DownloadSource.auto:
        return f.url == f.mirrorUrl ? [f.url] : [f.url, f.mirrorUrl];
    }
  }

  /// 下载单个权重到 [pathOf]，可续传且幂等：
  /// 半截进度落 `<name>.part`，带 `Range: bytes=<offset>-` 续传；服务端回
  /// 416 或收尾大小不符 → 丢弃 .part 整段重来（至多一次）；流式 sha256
  /// 校验通过后 rename **晋升**为正式文件（先删同名旧档），失败则删 .part。
  /// [source] 为 auto 时，前一个 URL 传输失败会以剩余 .part 续传改试下一个 URL，
  /// 仅当所有候选 URL 都失败才抛出最后一个 [WeightsException]。
  Future<void> download(
    WeightFile f, {
    void Function(int done, int total)? onProgress,
    void Function(WeightFile file, String failedUrl, String nextUrl, String reason)?
        onFallback,
  }) async {
    final urls = _urlsFor(f);
    for (var i = 0; i < urls.length; i++) {
      final client = HttpClient();
      try {
        await _downloadFrom(client, Uri.parse(urls[i]), f, onProgress);
        return;
      } on WeightsException catch (e) {
        if (i == urls.length - 1) rethrow;
        // 尚有候选 URL（auto 回退）：记一条回退告警再静默切到下一个。
        // 传输中断时 .part 已保留，下一轮从中续传；若上一轮因大小/sha 失败，
        // _downloadFrom 已删 .part，下一轮从 0 整段重下。
        onFallback?.call(f, urls[i], urls[i + 1], e.message);
      } finally {
        client.close(force: true);
      }
    }
  }

  /// 用单个 [url] 完成一次下载尝试（含完整大小 .part 的晋升短路）。
  /// 成功即晋升并返回；任何契约内失败以 [WeightsException] 抛出，且已按语义
  /// 处理 .part（保留以便续传，或丢弃以便整段重来）。
  Future<void> _downloadFrom(
    HttpClient client,
    Uri url,
    WeightFile f,
    void Function(int done, int total)? onProgress,
  ) async {
    final part = File('${pathOf(f)}.part');
    var start = part.existsSync() ? part.lengthSync() : 0;
    if (start > f.size) {
      await part.delete();
      start = 0;
    }
    // 上次进程若在写完最后一字节后、流式哈希完成前被杀死，.part 已是完整大小：
    // 再发 `Range: bytes=<size>-` 只会收到 416 而永久卡死（桌面侧
    // downloader.rs 对非 206 一律丢弃重开）。这里先校验并晋升，内容不对则
    // 走下面的 416/大小不符路径整段重来。
    if (start == f.size && start > 0 && await _shaOf(part) == f.sha256) {
      await _promote(part, f);
      return;
    }
    var done = await _fetch(client, url, part, start, f, onProgress);
    if (done < 0) {
      // 416：服务端不认这个 offset → 丢弃 .part 整段重来（同桌面语义）
      await part.delete();
      done = await _fetch(client, url, part, 0, f, onProgress);
    }
    if (done != f.size) {
      // .part 可能过期损坏：整段重下一次（唯一一次），仍不对则抛
      await part.delete();
      done = await _fetch(client, url, part, 0, f, onProgress);
      if (done != f.size) {
        await part.delete();
        throw WeightsException('${f.name}: 大小 $done != ${f.size}');
      }
    }
    // 流式 sha256 校验（大文件不整读进内存）
    if (await _shaOf(part) != f.sha256) {
      await part.delete();
      throw WeightsException('${f.name}: sha256 校验失败');
    }
    await _promote(part, f);
  }

  Future<String> _shaOf(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();

  Future<void> _promote(File part, WeightFile f) async {
    final out = File(pathOf(f));
    if (out.existsSync()) await out.delete(); // Windows 上 rename 不覆盖已存在文件
    await part.rename(out.path);
  }

  /// 拉取一次（可选 Range 续传）。返回完成后的 .part 大小；`-1` 表示服务端对
  /// 该 offset 回了 416（由调用方丢弃 .part 后整段重来）。
  Future<int> _fetch(
    HttpClient client,
    Uri url,
    File part,
    int start,
    WeightFile f,
    void Function(int done, int total)? onProgress,
  ) async {
    IOSink? sink;
    try {
      final req = await client.getUrl(url);
      if (start > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      final res = await req.close();
      if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await res.drain<void>();
        return -1;
      }
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.drain<void>();
        throw WeightsException('${f.name}: HTTP ${res.statusCode}');
      }
      // 206 = 续传（在 .part 后追加）；200 = 服务端忽略 Range，整段重写
      final append = res.statusCode == 206;
      sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var done = append ? start : 0;
      await for (final chunk in res) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, f.size);
      }
      await sink.flush();
      final out = sink;
      sink = null;
      await out.close();
      return part.lengthSync();
    } on WeightsException {
      rethrow;
    } on Object catch (e) {
      // 传输层错误（SocketException/HttpException 等）不得逃逸本契约：调用方
      // （下载 UI / isolate 服务）只按 WeightsException 处理。已收到的字节随
      // .part 保留在磁盘，下次调用从该 offset 续传；原始错误文本并入 message
      // 以便排查。
      try {
        await sink?.close(); // flush 已缓冲字节后落盘
      } on Object catch (_) {
        // 关闭失败不覆盖原始错误
      }
      throw WeightsException('${f.name}: 传输中断: $e');
    }
  }
}
