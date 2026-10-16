// 各屏共享的顶部 AppBar：液态玻璃栏（暖纸设计系统）+ 设置齿轮
// （齿轮 push SettingsPage）。
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../screens/settings_screen.dart';
import '../theme/glass.dart';

void openSettingsPage(BuildContext context, SettingsController controller) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => SettingsPage(controller: controller),
  ));
}

/// 玻璃 AppBar：返回键按路由自动推断（壳层各屏不显示，push 进来的页面显示）。
GlassAppBar screenAppBar(
  BuildContext context, {
  required String title,
  required SettingsController controller,
  List<Widget> actions = const [],
}) {
  return GlassAppBar(
    title: title,
    actions: [
      ...actions,
      IconButton(
        onPressed: () => openSettingsPage(context, controller),
        icon: const Icon(Icons.settings_outlined),
        tooltip: '设置',
      ),
    ],
  );
}
