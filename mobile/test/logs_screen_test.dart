import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/screens/logs_screen.dart';

Widget boot(LogBus logs) => MaterialApp(
      home: LogsScreen(
          controller: SettingsController(AppSettings.defaults()), logs: logs),
    );

void main() {
  testWidgets('空态文案', (tester) async {
    final logs = LogBus();
    await tester.pumpWidget(boot(logs));
    expect(find.text('暂无运行日志'), findsOneWidget);
    expect(find.text('本次启动后的事件会显示在这里'), findsOneWidget);
    logs.dispose();
  });

  testWidgets('渲染已写入的行：N 条 → N 个行', (tester) async {
    final logs = LogBus();
    logs.info('startup', 'START_MARK');
    logs.error('auto', 'FAIL_MARK');
    await tester.pumpWidget(boot(logs));
    expect(find.textContaining('START_MARK'), findsOneWidget);
    expect(find.textContaining('FAIL_MARK'), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(2));
    logs.dispose();
  });

  testWidgets('追加即实时刷新，无需重建 widget', (tester) async {
    final logs = LogBus();
    await tester.pumpWidget(boot(logs));
    expect(find.textContaining('LIVE_MARK'), findsNothing);
    logs.warn('weights', 'LIVE_MARK');
    await tester.pump();
    expect(find.textContaining('LIVE_MARK'), findsOneWidget);
    logs.dispose();
  });

  testWidgets('不同级别的行前景色不同', (tester) async {
    final logs = LogBus();
    logs.info('auto', 'I_ROW');
    logs.error('auto', 'E_ROW');
    await tester.pumpWidget(boot(logs));
    // 级别标记是带 style.color 的 Text，比对色值最稳（消息行的根 TextSpan 无色）。
    Color labelColor(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;
    expect(labelColor('信息'), isNot(labelColor('错误')));
    logs.dispose();
  });
}
