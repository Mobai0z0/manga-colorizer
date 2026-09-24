import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/app_theme.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';
import 'package:manga_colorizer_mobile/screens/settings_screen.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mc-set'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (_) {}
  });

  Widget wrap(SettingsController c) => MaterialApp(home: SettingsPage(controller: c));

  testWidgets('三段呈现：外观/下载源/关于', (tester) async {
    final c = SettingsController(AppSettings.defaults(), base: dir);
    await tester.pumpWidget(wrap(c));
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('配色主题'), findsOneWidget);
    expect(find.text('模型下载源'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('切深色 → 控制器更新且落盘', (tester) async {
    final c = SettingsController(AppSettings.defaults(), base: dir);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.text('深色'));
    await tester.pump();
    expect(c.settings.themeMode, AppThemeMode.dark);
    expect(AppSettings.load(dir).themeMode, AppThemeMode.dark);
  });

  testWidgets('选下载源仅镜像 → 落盘含 mirror', (tester) async {
    final c = SettingsController(AppSettings.defaults(), base: dir);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.text('仅镜像'));
    await tester.pump();
    expect(c.settings.downloadSource, DownloadSource.mirror);
    expect(File('${dir.path}/settings.json').readAsStringSync(),
        contains('mirror'));
  });
}
