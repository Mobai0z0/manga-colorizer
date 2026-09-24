import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/screens/home_screen.dart';
import 'package:manga_colorizer_mobile/shell/destinations.dart';

void main() {
  testWidgets('首页四卡 + 点卡回调', (tester) async {
    AppDestination? go;
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        controller: SettingsController(AppSettings.defaults()),
        onNavigate: (d) => go = d,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('漫画上色 · 端侧提示点 & 全自动'), findsOneWidget);
    expect(find.textContaining('CC BY-NC-SA'), findsOneWidget);
    await tester.tap(find.text('全自动').first);
    await tester.pump();
    expect(go, AppDestination.auto);
  });
}
