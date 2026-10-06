// 应用根：持有 SettingsController、GalleryStore、LogBus（端侧运行日志唯一真源）
// 及主题装配（含 DynamicColorBuilder 的 Material You 动态取色分支），
// home 为多页壳 AppShell。
import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'app_theme.dart';
import 'gallery/gallery_store.dart';
import 'logs/log_bus.dart';
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

class _MangaColorizerAppState extends State<MangaColorizerApp>
    with WidgetsBindingObserver {
  final SettingsController _controller = SettingsController(AppSettings.defaults());

  /// 端侧图库唯一真源：解析到设置目录后 attachDir + load，透传给各屏。
  final GalleryStore _gallery = GalleryStore();

  /// 端侧运行日志唯一真源：进程内环形缓冲，随应用根同生命周期。
  final LogBus _logs = LogBus();

  /// 全局图片缓存上限（默认 100MB）：上色应用里解码过的预览/缩略图纹理
  /// 都进这块缓存，压到 48MB 让浏览历史图时的常驻纹理有硬顶。
  static const int _kImageCacheBytes = 48 << 20;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 先于异步加载把总线置入静态指针：加载调用图深处的写入方拿不到注入参数，
    // 只能经 LogBus.current 取总线，须保证它们运行时指针已就绪。
    LogBus.current = _logs;
    PaintingBinding.instance.imageCache.maximumSizeBytes = _kImageCacheBytes;
    unawaited(_loadSettings());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 系统内存压力（Android onTrimMemory）：系统在升级到杀进程之前会先发这个
  /// 警告——此刻主动让步是「不卡退」的直接手段。清图片缓存（已解码纹理可
  /// 随时重解码）；空闲中的推理会话由 AutoScreen 的同名回调自行释放
  /// （推理进行中绝不能动：中途释放等于取消用户的任务）。
  @override
  void didHaveMemoryPressure() {
    final before = PaintingBinding.instance.imageCache.currentSizeBytes;
    PaintingBinding.instance.imageCache.clear();
    _logs.info('startup',
        '系统内存压力：已清理图片缓存（释放 ${(before / (1 << 20)).round()}MB 纹理）');
  }

  /// 启动读取磁盘设置；path_provider 不可用（如宿主测试）时静默保留默认值。
  Future<void> _loadSettings() async {
    _logs.info('startup', '应用启动');
    try {
      final dir = await appSettingsDir();
      _controller.attachBase(dir);
      _controller.update(AppSettings.load(dir));
      // dir = .../manga-light-colorizer；store 内部再拼 gallery 子目录，
      // 与 attachBase 传同一基目录，账本/图片落在其 gallery 子目录。
      _gallery.attachDir(dir);
      await _gallery.load();
    } on Object catch (e) {
      // 无法解析/读取设置目录：以内存默认值继续，不阻塞启动。
      _logs.error('startup', '加载设置/图库目录失败：$e');
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
              home: AppShell(
                  controller: _controller, gallery: _gallery, logs: _logs),
            );
          },
        );
      },
    );
  }
}
