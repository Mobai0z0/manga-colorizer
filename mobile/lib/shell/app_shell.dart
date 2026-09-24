// 多页壳：外层 Scaffold 只管 IndexedStack + NavigationBar；各屏自带 AppBar。
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../gallery/gallery_store.dart';
import '../logs/log_bus.dart';
import '../screens/auto_screen.dart';
import '../screens/colorize_screen.dart';
import '../screens/gallery_screen.dart';
import '../screens/home_screen.dart';
import '../screens/logs_screen.dart';
import 'destinations.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    required this.gallery,
  });
  final SettingsController controller;
  final GalleryStore gallery;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  // 临时：AppShell 尚未接收注入的 LogBus，此处构造本地实例，故日志屏在
  // 接线完成前恒为空态。放在 State 上以免每次 build 都换新总线。
  late final LogBus _logs = LogBus();

  @override
  void dispose() {
    _logs.dispose();
    super.dispose();
  }

  void _go(AppDestination dest) => setState(() => _index = dest.index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(controller: widget.controller, onNavigate: _go),
          ColorizeScreen(controller: widget.controller, gallery: widget.gallery),
          AutoScreen(controller: widget.controller, gallery: widget.gallery),
          GalleryScreen(controller: widget.controller, gallery: widget.gallery),
          LogsScreen(controller: widget.controller, logs: _logs),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in AppDestination.values)
            NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}
