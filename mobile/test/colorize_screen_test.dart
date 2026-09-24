import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/screens/colorize_screen.dart';

void main() {
  testWidgets('上色屏空态 + 工具条 + 本地动作按钮', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ColorizeScreen(controller: SettingsController(AppSettings.defaults())),
    ));
    await tester.pumpAndSettle();
    // AppBar 动作（不再依赖页签 index）
    expect(find.byTooltip('从相册选图'), findsOneWidget);
    expect(find.byTooltip('内置样例'), findsOneWidget);
    // 工具条主按钮 + 空态引导
    expect(find.text('上色'), findsWidgets); // AppBar 标题“上色”与按钮“上色”
    expect(find.text('加载内置样例试试'), findsOneWidget);
  });
}
