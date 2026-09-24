// 应用根：持有 SettingsController 与主题装配（含 DynamicColorBuilder 的 Material You
// 动态取色分支），home 为多页壳 AppShell。
import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'app_theme.dart';
import 'shell/app_shell.dart';

/// 设置目录：应用私有存储下的 manga-light-colorizer（与权重目录同名同址，
/// settings.json 与权重落同一处）。
Future<Directory> appSettingsDir() async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}manga-light-colorizer');
}

class MangaColorizerApp extends StatefulWidget {
  const MangaColorizerApp({super.key});

  @override
  State<MangaColorizerApp> createState() => _MangaColorizerAppState();
}

class _MangaColorizerAppState extends State<MangaColorizerApp> {
  final SettingsController _controller = SettingsController(AppSettings.defaults());

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
  }

  /// 启动读取磁盘设置；path_provider 不可用（如宿主测试）时静默保留默认值。
  Future<void> _loadSettings() async {
    try {
      final dir = await appSettingsDir();
      _controller.attachBase(dir);
      _controller.update(AppSettings.load(dir));
    } on Object {
      // 无法解析/读取设置目录：以内存默认值继续，不阻塞启动。
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final s = _controller.settings;
        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            final dyn = s.themePreset == ThemePreset.dynamic;
            return MaterialApp(
              title: 'Manga Colorizer',
              themeMode: s.themeMode.themeMode,
              theme: dyn && lightDynamic != null
                  ? ThemeData(useMaterial3: true, colorScheme: lightDynamic)
                  : buildAppTheme(s.themePreset, Brightness.light),
              darkTheme: dyn && darkDynamic != null
                  ? ThemeData(useMaterial3: true, colorScheme: darkDynamic)
                  : buildAppTheme(s.themePreset, Brightness.dark),
              home: AppShell(controller: _controller),
            );
          },
        );
      },
    );
  }
}
