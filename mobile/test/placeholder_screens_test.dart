import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/screens/logs_screen.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: child));
  final c = SettingsController(AppSettings.defaults());

  testWidgets('日志空态文案', (tester) async {
    await tester.pumpWidget(wrap(LogsScreen(controller: c)));
    expect(find.text('暂无运行日志'), findsOneWidget);
    expect(find.textContaining('即将推出'), findsOneWidget);
  });
}
