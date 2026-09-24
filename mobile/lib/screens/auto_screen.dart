// 全自动目的地：持有 AutoEngine 生命周期（后台释放），承载 AutoTab 编排。
import 'dart:async';
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../onnx/auto_service.dart';
import '../shell/screen_chrome.dart';
import '../auto_panel.dart';

class AutoScreen extends StatefulWidget {
  const AutoScreen({super.key, required this.controller});
  final SettingsController controller;

  @override
  State<AutoScreen> createState() => _AutoScreenState();
}

class _AutoScreenState extends State<AutoScreen> with WidgetsBindingObserver {
  final AutoEngine _engine = AutoEngine();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_engine.shutdown());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_engine.shutdown());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: screenAppBar(context, title: '全自动', controller: widget.controller),
      body: AutoTab(engine: _engine, controller: widget.controller),
    );
  }
}
