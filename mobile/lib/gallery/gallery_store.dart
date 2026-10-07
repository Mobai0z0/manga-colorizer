// 端侧图库唯一真源：账本 gallery.jsonl（一行一条 GalleryEntry）+ 平铺图片文件。
// 每次成功上色/全自动经 add() 非阻塞入库；删除经 delete() 逐项移除。
// 所有磁盘 IO 失败一律降级、绝不打断调用方（如上色屏）。日志仅记 add/delete
// 的三个出口（缩略图无法编码、入库异常、账本整写失败，各经 [LogBus.current]
// 补一条运行日志供事后排查；_makeThumb 内部吞掉编码异常，失败统一由调用方
// 记这一条）；load 启动期的容错（畸形行跳过、账本不可读时维持空态）与删除时
// 对已不存在文件的 unlink 忽略静默不记——前者是「以磁盘为准」的既定恢复语义，
// 后者是逐项删除的正常分支。add/delete 经内部 Future 链串行化，避免并发写账本
// 相互覆盖。dir 由宿主异步解析后 attachDir 注入
// （宿主测试可直接传入临时目录，绕开 path_provider）。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

// Uint8List 经 foundation 传递可用，无需另引 dart:typed_data。
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../logs/log_bus.dart';
import 'gallery_entry.dart';

/// 软上限：超过仅提示用户手动清理，绝不自动删除。
const int kGallerySoftCap = 300;

class GalleryStore extends ChangeNotifier {
  GalleryStore({Directory? dir}) : _dir = dir;

  Directory? _dir;
  final List<GalleryEntry> _chronological = []; // 旧 → 新
  Future<void> _tail = Future.value();

  static const _ledgerName = 'gallery.jsonl';
  static const _thumbMax = 320;
  static const _thumbQuality = 82;

  Directory? get directory => _dir;

  /// 解析到图库目录后注入（在其之前 add/load 以内存为准）。
  void attachDir(Directory dir) => _dir = dir;

  /// 图库根目录（settings 同级的 gallery 子目录）。
  Directory? get _galleryDir {
    final d = _dir;
    if (d == null) return null;
    return Directory('${d.path}${Platform.pathSeparator}gallery');
  }

  File get _ledger => File('${_galleryDir!.path}${Platform.pathSeparator}$_ledgerName');

  /// 拼图库目录内的绝对路径（供 Image.file / share / 存在性检查）。
  String pathOf(String file) =>
      '${_galleryDir?.path ?? ''}${Platform.pathSeparator}$file';

  /// 最新在前的缓存视图。
  List<GalleryEntry> get entries => List.unmodifiable(_chronological.reversed);

  bool get overSoftCap => _chronological.length > kGallerySoftCap;

  /// 从磁盘账本恢复：跳过畸形行，丢弃 result 文件缺失项。整体降级不抛。
  Future<void> load() async {
    final dir = _galleryDir;
    if (dir == null) return;
    try {
      final f = File('${dir.path}${Platform.pathSeparator}$_ledgerName');
      if (!f.existsSync()) return;
      final restored = <GalleryEntry>[];
      for (final line in await f.readAsLines()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map) continue;
          final e = GalleryEntry.fromJson(decoded.cast<String, Object?>());
          // 账本与磁盘不一致时以文件为准：结果图丢失则丢弃该条。
          if (!File(pathOf(e.resultFile)).existsSync()) continue;
          restored.add(e);
        } on Object {
          continue; // 畸形行跳过
        }
      }
      _chronological
        ..clear()
        ..addAll(restored);
      notifyListeners();
    } on Object {
      // 账本不可读：保持当前（通常为空）状态。
    }
  }

  /// 非阻塞入库：写三文件 + 追账本 + 更新缓存 + 广播。
  /// 任何 IO 失败只记运行日志、绝不向调用方抛出。
  Future<void> add({
    required Uint8List resultPng,
    required Uint8List sourcePng,
    required int width,
    required int height,
    required String mode,
    double? elapsedS,
    int? hintCount,
    String? sourceLabel,
  }) {
    final op = _tail.then((_) async {
      await _doAdd(
        resultPng: resultPng,
        sourcePng: sourcePng,
        width: width,
        height: height,
        mode: mode,
        elapsedS: elapsedS,
        hintCount: hintCount,
        sourceLabel: sourceLabel,
      );
    });
    // 保持链存活：_doAdd 内部已吞异常，这里再兜一层防 then 本身抛出。
    _tail = op.catchError((_) {});
    return op;
  }

  Future<void> _doAdd({
    required Uint8List resultPng,
    required Uint8List sourcePng,
    required int width,
    required int height,
    required String mode,
    double? elapsedS,
    int? hintCount,
    String? sourceLabel,
  }) async {
    final dir = _galleryDir;
    if (dir == null) return;
    try {
      dir.createSync(recursive: true);
      final id = _newId();
      final resultFile = '$id.png';
      final sourceFile = '${id}_src.png';
      final thumbFile = '${id}_thumb.jpg';
      await File(pathOf(resultFile)).writeAsBytes(resultPng, flush: true);
      await File(pathOf(sourceFile)).writeAsBytes(sourcePng, flush: true);
      final thumb = await _makeThumb(resultPng);
      if (thumb == null) {
        LogBus.current?.warn('gallery', '缩略图编码失败，本条未入库');
        return; // 无法编码缩略图则整条不入库（保持一致）
      }
      await File(pathOf(thumbFile)).writeAsBytes(thumb, flush: true);
      final entry = GalleryEntry(
        id: id,
        timeIso: DateTime.now().toIso8601String(),
        mode: mode,
        width: width,
        height: height,
        elapsedS: elapsedS,
        hintCount: hintCount,
        sourceLabel: sourceLabel,
        resultFile: resultFile,
        sourceFile: sourceFile,
        thumbFile: thumbFile,
      );
      await _ledger.writeAsString(
          '${jsonEncode(entry.toJson())}\n', mode: FileMode.append, flush: true);
      _chronological.add(entry);
      notifyListeners();
    } on Object catch (e) {
      LogBus.current?.error('gallery', '入库失败：$e');
      // 入库失败静默：上色结果照常展示。
    }
  }

  /// 逐项删除：账本整写（临时文件 + rename 原子替换）+ unlink 三文件。
  Future<void> delete(String id) {
    final op = _tail.then((_) => _doDelete(id));
    _tail = op.catchError((_) {});
    return op;
  }

  Future<void> _doDelete(String id) async {
    final dir = _galleryDir;
    if (dir == null) return;
    final target = _chronological.where((e) => e.id == id).toList();
    if (target.isEmpty) return;
    _chronological.removeWhere((e) => e.id == id);
    try {
      final tmpPath = '${dir.path}${Platform.pathSeparator}$_ledgerName.tmp';
      final rewritten = _chronological
          .map((e) => '${jsonEncode(e.toJson())}\n')
          .join();
      await File(tmpPath).writeAsString(rewritten, flush: true);
      await File(tmpPath).rename(_ledger.path);
    } on Object catch (e) {
      LogBus.current?.warn('gallery', '账本重写降级：$e');
      // 账本重写失败：内存已删，下次 load 以磁盘为准可能复活，可接受降级。
    }
    for (final e in target) {
      for (final f in [e.resultFile, e.sourceFile, e.thumbFile]) {
        try {
          await File(pathOf(f)).delete();
        } on Object {
          // 文件本就不存在或不可删：忽略。
        }
      }
    }
    notifyListeners();
  }

  /// 以结果为源生成 JPEG 缩略图（最长边 320）；失败返回 null。
  /// 解码走 dart:ui 引擎线程并按目标尺寸缩容（ImageDescriptor.encoded +
  /// instantiateCodec(targetWidth/Height)）：主 isolate 不再同步全量
  /// decodePng——2048² 时 16.8MB 位图 + 主线程 resize/编码是入库期的掉帧与
  /// 峰值大户（恰逢 ORT 会话尚未释放的窗口）。解码产物只有 320² 级别
  /// （~0.4MB），随后的小图 JPEG 编码毫秒级。必须在主 isolate 调用。
  Future<Uint8List?> _makeThumb(Uint8List resultPng) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(resultPng);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final longest = max(descriptor.width, descriptor.height);
      // 与旧实现同规则：最长边压到 _thumbMax（宽高同比、round 取整），
      // 不超限则原尺寸解码（放大无意义）。
      final targetW = longest > _thumbMax
          ? (descriptor.width * _thumbMax / longest).round()
          : descriptor.width;
      final targetH = longest > _thumbMax
          ? (descriptor.height * _thumbMax / longest).round()
          : descriptor.height;
      codec = await descriptor.instantiateCodec(
          targetWidth: targetW, targetHeight: targetH);
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final rgba =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final decoded = img.Image.fromBytes(
          width: targetW,
          height: targetH,
          bytes: rgba.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba);
      return Uint8List.fromList(
          img.encodeJpg(decoded, quality: _thumbQuality));
    } on Object {
      return null;
    } finally {
      // 逆序释放：image/codec/descriptor 还引用 buffer，最后才放。
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  String _newId() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    final rnd = Random.secure();
    final suffix =
        List.generate(4, (_) => chars[rnd.nextInt(chars.length)]).join();
    return '${stamp}_$suffix';
  }
}
