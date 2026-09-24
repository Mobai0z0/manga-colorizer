// 全自动目的地：持有 AutoEngine 生命周期（后台释放），承载 AutoTab 编排。
// 全自动成功后经 AutoTab 的 onCompleted 回调把结果非阻塞入库（GalleryStore）。
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../gallery/gallery_store.dart';
import '../logs/log_bus.dart';
import '../onnx/auto_service.dart';
import '../shell/screen_chrome.dart';
import '../auto_panel.dart';

class AutoScreen extends StatefulWidget {
  const AutoScreen({
    super.key,
    required this.controller,
    required this.gallery,
    required this.logs,
  });
  final SettingsController controller;

  /// 端侧图库：全自动成功后由 AutoTab 回调触发非阻塞入库。
  final GalleryStore gallery;

  /// 端侧运行日志总线：由应用根持有并下发，本屏只透传不释放。
  final LogBus logs;

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
      body: AutoTab(
        engine: _engine,
        controller: widget.controller,
        onCompleted: ({
          required Uint8List resultPng,
          required Uint8List sourcePng,
          required int width,
          required int height,
        }) {
          unawaited(widget.gallery.add(
            resultPng: resultPng,
            sourcePng: sourcePng,
            width: width,
            height: height,
            mode: 'auto',
          ));
        },
      ),
    );
  }
}
