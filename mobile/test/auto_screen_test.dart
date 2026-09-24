import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_store.dart';
import 'package:manga_colorizer_mobile/screens/auto_screen.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mc-auto'));
  tearDown(() {
    try { dir.deleteSync(recursive: true); } on FileSystemException catch (_) {}
  });

  testWidgets('AutoScreen 承载 AutoTab 首帧检查权重', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AutoScreen(
          controller: SettingsController(AppSettings.defaults()),
          gallery: GalleryStore()),
    ));
    await tester.pump(); // 不 pumpAndSettle：AutoTab 首帧显示“检查权重…”
    expect(find.text('检查权重…'), findsOneWidget);
  });
}
