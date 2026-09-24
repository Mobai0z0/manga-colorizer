import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/shell/app_shell.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_store.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/shell/destinations.dart';

void main() {
  Widget boot() => MaterialApp(
      home: AppShell(
          controller: SettingsController(AppSettings.defaults()),
          gallery: GalleryStore(),
          logs: LogBus()));

  testWidgets('底栏 5 目的地，默认首页', (tester) async {
    await tester.pumpWidget(boot());
    await tester.pumpAndSettle();
    final nav = find.byType(NavigationBar);
    expect(nav, findsOneWidget);
    for (final d in AppDestination.values) {
      expect(find.descendant(of: nav, matching: find.text(d.label)),
          findsOneWidget);
    }
    expect(find.text('漫画上色 · 端侧提示点 & 全自动'), findsOneWidget);
  });

  testWidgets('点底栏“全自动”切到自动页', (tester) async {
    await tester.pumpWidget(boot());
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('全自动')));
    await tester.pump();
    expect(find.text('检查权重…'), findsOneWidget);
  });

  testWidgets('首页点“图库”卡 → 到画廊占位', (tester) async {
    await tester.pumpWidget(boot());
    await tester.pumpAndSettle();
    await tester.tap(find.text('图库').first); // 首页卡
    await tester.pumpAndSettle();
    expect(find.text('还没有作品'), findsOneWidget);
  });
}
