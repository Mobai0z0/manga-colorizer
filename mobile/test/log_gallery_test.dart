import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_colorizer_mobile/gallery/gallery_store.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';

Uint8List _png(int w, int h) =>
    Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)));

void main() {
  late Directory tmp;
  late LogBus bus;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gallery_log');
    bus = LogBus();
    // 图库入库/删除在回调深处执行，拿不到注入参数，降级写入经静态指针兜底投递。
    LogBus.current = bus;
  });
  tearDown(() {
    LogBus.current = null;
    bus.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('缩略图编码失败：记 warn 且整条不入库', () async {
    final store = GalleryStore(dir: tmp);
    final junk = Uint8List.fromList([1, 2, 3, 4, 5]); // 非 PNG，decodePng 返回 null
    await store.add(
        resultPng: junk, sourcePng: junk, width: 4, height: 4, mode: 'auto');
    expect(bus.entries, hasLength(1));
    expect(bus.entries.single.level, LogLevel.warning);
    expect(bus.entries.single.tag, 'gallery');
    expect(bus.entries.single.message, contains('缩略图'));
    // 整条不入库：缓存视图里没有这一条。
    expect(store.entries, isEmpty);
  });

  test('账本写入失败：记 error 且缓存不增长', () async {
    // 占住账本路径：同名**目录**存在时 append 写入必抛（各平台一致）。
    Directory('${tmp.path}${Platform.pathSeparator}gallery')
        .createSync(recursive: true);
    Directory('${tmp.path}${Platform.pathSeparator}gallery'
            '${Platform.pathSeparator}gallery.jsonl')
        .createSync();
    final store = GalleryStore(dir: tmp);
    await store.add(
        resultPng: _png(40, 40),
        sourcePng: _png(40, 40),
        width: 40,
        height: 40,
        mode: 'hints');
    expect(bus.entries.single.level, LogLevel.error);
    expect(bus.entries.single.message, contains('入库失败'));
    // 账本没写进去，缓存也不该长出这一条。
    expect(store.entries, isEmpty);
  });
}
