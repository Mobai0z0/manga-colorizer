// 各屏共享的顶部 AppBar：统一标题 + 设置齿轮（齿轮 push SettingsPage）。
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../screens/settings_screen.dart';

void openSettingsPage(BuildContext context, SettingsController controller) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => SettingsPage(controller: controller),
  ));
}

AppBar screenAppBar(
  BuildContext context, {
  required String title,
  required SettingsController controller,
  List<Widget> actions = const [],
}) {
  return AppBar(
    title: Text(title),
    backgroundColor: Theme.of(context).colorScheme.surface,
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
