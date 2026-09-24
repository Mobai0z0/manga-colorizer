import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/screens/logs_screen.dart';

Widget boot(LogBus logs) => MaterialApp(
      home: LogsScreen(
          controller: SettingsController(AppSettings.defaults()), logs: logs),
    );

/// 控制台列表自己的滚动位置。直接取挂在 [ListView] 上的 controller：
/// 每行的 SelectableText 内部也自带 Scrollable，按类型找会命中十几个。
ScrollPosition consolePosition(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!.position;

/// 写入足够多的一行式记录，让列表超过视口高度，跟随行为才可测。
void backfill(LogBus logs, String prefix, int count) {
  for (var i = 0; i < count; i++) {
    logs.info('startup', '$prefix$i');
  }
}

/// 让列表超过一屏并完成首帧贴底，返回贴底时的最大滚动值。
Future<double> fillAndSettle(WidgetTester tester, LogBus logs) async {
  await tester.pumpWidget(boot(logs));
  await tester.pumpAndSettle();
  final pos = consolePosition(tester);
  expect(pos.maxScrollExtent, greaterThan(pos.viewportDimension),
      reason: '列表需超过一屏，否则跟随断言无意义');
  return pos.maxScrollExtent;
}

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

  testWidgets('不同级别的行前景色不同，警告用固定橙', (tester) async {
    final logs = LogBus();
    logs.info('auto', 'I_ROW');
    logs.warn('auto', 'W_ROW');
    logs.error('auto', 'E_ROW');
    await tester.pumpWidget(boot(logs));
    // 级别标记是带 style.color 的 Text，比对色值最稳（消息行的根 TextSpan 无色）。
    Color labelColor(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;
    final info = labelColor('信息');
    final warning = labelColor('警告');
    final error = labelColor('错误');
    expect(info, isNot(error));
    expect(warning, isNot(info));
    expect(warning, isNot(error));
    // 本仓库锁定的 Flutter 3.47 ColorScheme 无 warning 令牌，警告档故为固定橙；
    // 若日后改用主题色替换，此断言会失败并要求有意识地重新决策。
    expect(warning, Colors.orange.shade800);
    logs.dispose();
  });

  group('滚动跟随', () {
    testWidgets('回填超过一屏时首帧即贴底，最新行在视口内', (tester) async {
      final logs = LogBus();
      backfill(logs, 'BACKFILL_', 80);
      final max = await fillAndSettle(tester, logs);
      final pos = consolePosition(tester);
      expect(pos.pixels, max,
          reason: '打开控制台应停在最新一行，而不是停在最旧的行');
      final list = tester.getRect(find.byType(ListView));
      final newest = tester.getRect(find.textContaining('BACKFILL_79'));
      expect(newest.top, greaterThanOrEqualTo(list.top));
      expect(newest.bottom, lessThanOrEqualTo(list.bottom));
      expect(find.textContaining('BACKFILL_0'), findsNothing,
          reason: '贴底时最旧的行已被回收出视口');
      logs.dispose();
    });

    testWidgets('贴底时追加新行自动跟随到新的底部', (tester) async {
      final logs = LogBus();
      backfill(logs, 'FOLLOW_', 80);
      final max = await fillAndSettle(tester, logs);
      logs.warn('auto', 'FOLLOW_TAIL');
      await tester.pump();
      await tester.pumpAndSettle();
      final pos = consolePosition(tester);
      expect(pos.pixels, greaterThan(max), reason: '跟随后应停到新增行之上');
      expect(pos.pixels, pos.maxScrollExtent);
      final list = tester.getRect(find.byType(ListView));
      final tail = tester.getRect(find.textContaining('FOLLOW_TAIL'));
      expect(tail.bottom, lessThanOrEqualTo(list.bottom));
      logs.dispose();
    });

    testWidgets('上翻阅读历史时新行不抢滚动', (tester) async {
      final logs = LogBus();
      backfill(logs, 'HISTORY_', 80);
      await fillAndSettle(tester, logs);
      // 往下拖：内容下移、露出更早的行，离开底部 40px 阈值之外。
      await tester.drag(find.byType(ListView), const Offset(0, 150));
      await tester.pumpAndSettle();
      final pos = consolePosition(tester);
      final resting = pos.pixels;
      expect(pos.maxScrollExtent - resting, greaterThan(40),
          reason: '前置条件：确实已离开底部 40px 阈值');
      expect(resting, greaterThan(0));

      logs.error('auto', 'HISTORY_TAIL');
      await tester.pump();
      await tester.pumpAndSettle();

      expect(consolePosition(tester).pixels, resting,
          reason: '用户上翻时追加不得把视图拽回底部');
      expect(find.textContaining('HISTORY_TAIL'), findsNothing,
          reason: '未跟随时新行不该出现在视口里');
      // 反证上一句是「停在历史处所以没渲染」，而非「整屏没刷新」：
      // 手动翻回底部，新行就在贴底的视口里。
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      final back = consolePosition(tester);
      expect(back.pixels, back.maxScrollExtent);
      final list = tester.getRect(find.byType(ListView));
      final tail = tester.getRect(find.textContaining('HISTORY_TAIL'));
      expect(tail.top, greaterThanOrEqualTo(list.top));
      expect(tail.bottom, lessThanOrEqualTo(list.bottom));
      logs.dispose();
    });

    testWidgets('阈值内（离底不足 40px）仍跟随', (tester) async {
      final logs = LogBus();
      backfill(logs, 'NEAR_', 80);
      await fillAndSettle(tester, logs);
      await tester.drag(find.byType(ListView), const Offset(0, 30));
      await tester.pumpAndSettle();
      final pos = consolePosition(tester);
      expect(pos.maxScrollExtent - pos.pixels, lessThan(40),
          reason: '前置条件：距底不足 40px');
      expect(pos.maxScrollExtent - pos.pixels, greaterThan(0),
          reason: '前置条件：30px 拖动确实离开了底部');
      logs.warn('auto', 'NEAR_TAIL');
      await tester.pump();
      await tester.pumpAndSettle();
      final after = consolePosition(tester);
      expect(after.pixels, after.maxScrollExtent,
          reason: '阈值内视为已贴底，应继续跟随');
      logs.dispose();
    });
  });

  group('纯实时控制台：无过滤/清空/导出/分享入口', () {
    testWidgets('工具栏与浮层都不提供这些动作', (tester) async {
      final logs = LogBus();
      logs.info('startup', 'CONSOLE_ONLY');
      logs.warn('weights', 'CONSOLE_ONLY_WARN');
      logs.error('auto', 'CONSOLE_ONLY_ERROR');
      await tester.pumpWidget(boot(logs));
      await tester.pumpAndSettle();

      for (final icon in [
        Icons.filter_alt,
        Icons.filter_alt_outlined,
        Icons.filter_list,
        Icons.tune,
        Icons.delete,
        Icons.delete_outline,
        Icons.clear,
        Icons.close,
        Icons.share,
        Icons.share_outlined,
        Icons.download,
        Icons.download_outlined,
        Icons.ios_share,
      ]) {
        expect(find.byIcon(icon), findsNothing, reason: '${icon.codePoint}');
      }
      for (final label in ['过滤', '筛选', '清空', '清除', '导出', '分享', '全部']) {
        expect(find.text(label), findsNothing, reason: label);
        expect(find.byTooltip(label), findsNothing, reason: label);
      }
      // 这些动作通常落在 FAB / 溢出菜单 / 筛选 chips 上，一并确认没被塞进来。
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(PopupMenuButton<dynamic>), findsNothing);
      expect(find.byType(PopupMenuEntry<dynamic>), findsNothing);
      expect(find.byType(Chip), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byType(SegmentedButton<dynamic>), findsNothing);
      expect(find.byType(DropdownButton<dynamic>), findsNothing);
      logs.dispose();
    });
  });
}
