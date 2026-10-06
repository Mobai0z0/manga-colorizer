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
  late final AutoEngine _engine;

  @override
  void initState() {
    super.initState();
    _engine = AutoEngine(logBus: widget.logs);
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

  /// 系统内存压力（Android onTrimMemory）：系统升级到杀进程前的警告——
  /// 空闲的推理会话（~300MB 原生内存）此刻就该归还，不等 60s 空闲计时。
  /// 推理进行中绝不动（working 门控）：中途释放等于取消用户的任务，
  /// 且重新加载模型的时间比省下的内存更伤。
  @override
  void didHaveMemoryPressure() {
    if (_engine.alive && !_engine.working) {
      widget.logs.info('auto', '系统内存压力：提前释放空闲推理会话');
      unawaited(_engine.shutdown());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: screenAppBar(context, title: '全自动', controller: widget.controller),
      body: AutoTab(
        engine: _engine,
        controller: widget.controller,
        logs: widget.logs,
        onCompleted: ({
          required Uint8List resultPng,
          required Uint8List sourcePng,
          required int width,
          required int height,
        }) {
          widget.logs.info('auto', '全自动完成 $width×$height');
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
