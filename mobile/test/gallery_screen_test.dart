import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_entry.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_store.dart';
import 'package:manga_colorizer_mobile/screens/gallery_screen.dart';

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 60)));

/// 真实写盘必须经 runAsync：testWidgets 的 fake async 不驱动事件循环，
/// 直接 await GalleryStore.add 里的 writeAsBytes 会永久挂起。
Future<GalleryStore> _storeWith(WidgetTester tester, int n, Directory dir) async {
  final store = await tester.runAsync(() async {
    final s = GalleryStore(dir: dir);
    for (var i = 0; i < n; i++) {
      await s.add(
          resultPng: _png(),
          sourcePng: _png(),
          width: 40,
          height: 60,
          mode: i.isEven ? 'hints' : 'auto');
    }
    return s;
  });
  return store!;
}

/// 让 Image.file 发起的真实文件读在真事件循环里完成并关闭句柄，
/// 避免 Windows 下 tearDown 删除临时目录时命中文件锁（errno 32）。
Future<void> _flushImageIo(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
}

void main() {
  late Directory tmp;
  final c = SettingsController(AppSettings.defaults());
  setUp(() => tmp = Directory.systemTemp.createTempSync('gallery_screen'));
  tearDown(() {
    for (var i = 0; i < 10; i++) {
      try {
        tmp.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });

  Widget boot(GalleryStore g) => MaterialApp(
      home: GalleryScreen(controller: c, gallery: g));

  testWidgets('空态文案', (tester) async {
    await tester.pumpWidget(boot(GalleryStore(dir: tmp)));
    await tester.pumpAndSettle();
    expect(find.text('还没有作品'), findsOneWidget);
    expect(
        find.text('上色 / 全自动完成后会自动保存在这里'), findsOneWidget);
  });

  testWidgets('有数据时网格渲染 cell（数量匹配）', (tester) async {
    final g = await _storeWith(tester, 3, tmp);
    await tester.pumpWidget(boot(g));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('还没有作品'), findsNothing);
    await _flushImageIo(tester);
  });

  testWidgets('超过软上限显示提示条', (tester) async {
    // 用可覆盖 overSoftCap 的替身，避免真造 301 条。
    final g = _StoreWithFlag(await _storeWith(tester, 1, tmp));
    await tester.pumpWidget(boot(g));
    await tester.pumpAndSettle();
    expect(find.textContaining('占用较多存储'), findsOneWidget);
    await _flushImageIo(tester);
  });
}

/// 仅覆写 overSoftCap 与 entries 以测试提示条出现：overSoftCap 恒为 true，
/// entries 委托内层实例（其已真实写入至少一条记录），保证网格非空、
/// 提示条分支被真实命中；dir 与内层共享，pathOf 能解析到磁盘上的缩略图。
class _StoreWithFlag extends GalleryStore {
  _StoreWithFlag(this._inner) : super(dir: _inner.directory);
  final GalleryStore _inner;
  @override
  bool get overSoftCap => true;
  @override
  List<GalleryEntry> get entries => _inner.entries;
}
