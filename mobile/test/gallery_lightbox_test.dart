import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_entry.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_store.dart';
import 'package:manga_colorizer_mobile/widgets/gallery_lightbox.dart';

class _RecordingStore extends GalleryStore {
  _RecordingStore() : super();
  final List<String> deleted = [];
  @override
  String pathOf(String file) => '/nonexistent/$file';
  @override
  Future<void> delete(String id) async {
    deleted.add(id); // 不触碰磁盘
  }
}

void main() {
  final entry = GalleryEntry(
    id: 'abc',
    timeIso: '2026-09-24T10:00:00.000',
    mode: 'hints',
    width: 100,
    height: 100,
    resultFile: 'abc.png',
    sourceFile: 'abc_src.png',
    thumbFile: 'abc_thumb.jpg',
  );

  Widget boot(GalleryStore store) => MaterialApp(
      home: GalleryLightboxPage(entry: entry, gallery: store));

  testWidgets('默认结果模式，含分段控件', (tester) async {
    final store = _RecordingStore();
    await tester.pumpWidget(boot(store));
    await tester.pumpAndSettle();
    expect(find.text('结果'), findsOneWidget);
    expect(find.text('原图'), findsOneWidget);
    expect(find.text('对比'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsWidgets);
  });

  testWidgets('切到对比出现 Slider 分界', (tester) async {
    final store = _RecordingStore();
    await tester.pumpWidget(boot(store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('对比'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(ClipRect), findsWidgets);
    expect(find.byType(OverflowBox), findsOneWidget);
  });

  testWidgets('删除确认后调用 store.delete 并弹回', (tester) async {
    final store = _RecordingStore();
    await tester.pumpWidget(boot(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条图库记录？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(store.deleted, contains('abc'));
  });
}
