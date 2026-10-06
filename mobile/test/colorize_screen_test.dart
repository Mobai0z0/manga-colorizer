import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_store.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';
import 'package:manga_colorizer_mobile/screens/colorize_screen.dart';

void main() {
  testWidgets('上色屏空态 + 工具条 + 本地动作按钮', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ColorizeScreen(
          controller: SettingsController(AppSettings.defaults()),
          gallery: GalleryStore(),
          logs: LogBus()),
    ));
    await tester.pumpAndSettle();
    // AppBar 动作（不再依赖页签 index）
    expect(find.byTooltip('从相册选图'), findsOneWidget);
    expect(find.byTooltip('内置样例'), findsOneWidget);
    // 工具条主按钮 + 空态引导
    expect(find.text('上色'), findsWidgets); // AppBar 标题“上色”与按钮“上色”
    expect(find.text('加载内置样例试试'), findsOneWidget);
  });

  // 回归：_loadBytes 的 Isolate.run 闭包曾在实例方法作用域创建，被同方法内
  // 捕获 this 的 setState 闭包经共享 context 污染——闭包连 _AutoTabState
  // 一起序列化，SendPort 抛 "object is unsendable"，选图/样例必失败。
  // 闭包必须留在 static 作用域（无 this 可捕），本测试走真实 isolate 发送路径。
  testWidgets('内置样例经 isolate 解码加载成功', (tester) async {
    final logs = LogBus();
    await tester.pumpWidget(MaterialApp(
      home: ColorizeScreen(
          controller: SettingsController(AppSettings.defaults()),
          gallery: GalleryStore(),
          logs: logs),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('内置样例'));
    // rootBundle + Isolate.run + 图片解码是真实异步，假时钟 pumpAndSettle 等
    // 不到：用 runAsync 轮询真实事件循环，每轮 pump 一帧应用 setState。
    var loaded = false;
    for (var i = 0; i < 150 && !loaded; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      loaded = find.byType(Image).evaluate().isNotEmpty;
    }
    expect(loaded, isTrue);
    expect(find.text('读取失败'), findsNothing);
    expect(logs.entries.where((e) => e.level == LogLevel.error), isEmpty);
  });
}
