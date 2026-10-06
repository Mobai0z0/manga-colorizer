// 上色目的地（E-壳阶段）：提示点纯 Dart 引擎工作台。
//   · 选图 → 在画布上落彩色提示点 → isolate 中运行 manga_colorizer_core
//     的色度扩散求解（亮度完整保留）→ 保存/分享结果。
// 本屏只负责单张图的「落点 → 上色 → 分享」，并在有效上色成功后非阻塞入库
// （经注入的 GalleryStore）；引擎生命周期属 AutoScreen，
// 顶部导航与切页属 AppShell，故此处无全局导航态耦合。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';

import '../app_settings.dart';
import '../gallery/gallery_store.dart';
import '../logs/log_bus.dart';
import '../shell/screen_chrome.dart';

/// Color 通道（0..1 double）→ 8bit 整数。替代已弃用的 `.red/.green/.blue`
/// 访问器（其弃用说明给出的等价式即 `(*.c * 255.0).round().clamp(0, 255)`；
/// 对本应用的 8bit 调色板色二者逐值相同）。
int _channel(double v) => (v * 255.0).round().clamp(0, 255).toInt();

class _HintPoint {
  final Offset pos; // normalized within image rect 0..1
  final Color color;
  _HintPoint(this.pos, this.color);
}

class ColorizeScreen extends StatefulWidget {
  const ColorizeScreen({
    super.key,
    required this.controller,
    required this.gallery,
    required this.logs,
  });

  /// 全局设置控制器（主题 + 下载源），由壳/宿主持有并下发。
  final SettingsController controller;

  /// 端侧图库：上色成功后非阻塞入库。由壳/宿主持有并下发。
  final GalleryStore gallery;

  /// 端侧运行日志总线：由应用根持有并下发，本屏只写入不释放。
  final LogBus logs;

  @override
  State<ColorizeScreen> createState() => _ColorizeScreenState();
}

enum _ViewMode { original, colorized }

class _ColorizeScreenState extends State<ColorizeScreen> {
  final ImagePicker _picker = ImagePicker();
  final List<_HintPoint> _hints = [];

  DecodedImage? _source;
  Uint8List? _sourcePng;
  Uint8List? _resultPng;
  Color _brush = const Color(0xFF1E88E5);
  _ViewMode _mode = _ViewMode.original;
  bool _busy = false;
  String _status = '从相册选图，或点右上「内置样例」加载示例';
  String? _elapsed;

  static const _palette = <Color>[
    Color(0xFF1E88E5),
    Color(0xFFE53935),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF8E24AA),
    Color(0xFFF48FB1),
    Color(0xFF6D4C41),
    Color(0xFF212121),
  ];

  // isolate 计算入口**必须 static**：闭包若在实例方法作用域创建，会被同方法内
  // 捕获 this 的 setState 闭包经共享 context 污染——SendPort 序列化闭包时沿
  // context 父链连 State（整棵 widget 树）一起走，抛 "object is unsendable"，
  // 选图/上色必失败。static 作用域无 this 可捕。

  /// 解码 + 灰度 + 原稿 PNG 编码，合并在一个工作 isolate 内完成。
  static Future<({DecodedImage decoded, Uint8List png})> _loadImageIsolate(
      Uint8List bytes) {
    return Isolate.run(() {
      final decoded = MangaImageIO.decodeGrayscale(bytes);
      final png = MangaImageIO.encodePng(
          rgb: decoded.rgb, width: decoded.width, height: decoded.height);
      return (decoded: decoded, png: png);
    });
  }

  /// 色度扩散求解 + 结果 PNG 编码（在工作 isolate 执行）。
  static Future<({Uint8List bytes, int iterations, int hintCount})>
      _colorizeIsolate(DecodedImage src, List<ColorHint> hints) {
    return Isolate.run(() {
      final result = colorizeManga(
        grayscaleRgb: src.rgb,
        width: src.width,
        height: src.height,
        hints: hints,
      );
      return (
        bytes: MangaImageIO.encodePng(
            rgb: result.rgb, width: result.width, height: result.height),
        iterations: result.iterations,
        hintCount: result.hintCount,
      );
    });
  }

  Future<void> _loadBytes(Uint8List bytes, String label) async {
    setState(() {
      _busy = true;
      _status = '读取图片…';
      _resultPng = null;
      _hints.clear();
      _mode = _ViewMode.original;
    });
    try {
      final loaded = await _loadImageIsolate(bytes);
      setState(() {
        _source = loaded.decoded;
        _sourcePng = loaded.png;
        _status =
            '$label ${loaded.decoded.width}×${loaded.decoded.height}。点按图片落提示点，然后「上色」。';
      });
    } catch (e) {
      widget.logs.error('hints', '读取图片失败：$e');
      setState(() => _status = '读取失败：$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pickImage() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    // 用 XFile.readAsBytes 而非 File(path).readAsBytes：部分 Android 设备上
    // 相册返回的是 content:// URI，XFile.path 并非真实文件路径，直接 File()
    // 读取会失败；readAsBytes 经平台通道解析该 URI。
    await _loadBytes(await file.readAsBytes(), '已加载');
  }

  Future<void> _loadBundledSample() async {
    final bytes = await rootBundle.load('assets/sample_bw.png');
    await _loadBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        '内置样例已加载');
  }

  Future<void> _colorize() async {
    final src = _source;
    if (src == null || _busy) return;
    final hints = _hints
        .map((h) => ColorHint(
              x: (h.pos.dx * (src.width - 1)).round(),
              y: (h.pos.dy * (src.height - 1)).round(),
              r: _channel(h.color.r),
              g: _channel(h.color.g),
              b: _channel(h.color.b),
            ))
        .toList();
    setState(() {
      _busy = true;
      _status = '上色中（色度扩散求解，亮度完整保留）…';
    });
    final sw = Stopwatch()..start();
    try {
      final png = await _colorizeIsolate(src, hints);
      sw.stop();
      setState(() {
        _resultPng = png.bytes;
        _mode = _ViewMode.colorized;
        _elapsed = '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
        _status = png.hintCount == 0
            ? '完成（无提示点，输出为原图）。请落点后重新上色。'
            : '上色完成：${png.hintCount} 个提示点，迭代 ${png.iterations} 次。';
      });
      widget.logs.info('hints',
          '提示点上色完成 ${src.width}×${src.height}，${png.hintCount} 个提示点，耗时 $_elapsed');
      // 有提示点才入库：0 提示点的输出即原图，存进去只是噪音，故跳过。
      final srcImg = _source;
      final srcPng = _sourcePng;
      if (png.hintCount > 0 && srcImg != null && srcPng != null) {
        unawaited(widget.gallery.add(
          resultPng: png.bytes,
          sourcePng: srcPng,
          width: srcImg.width,
          height: srcImg.height,
          mode: 'hints',
          elapsedS: sw.elapsedMilliseconds / 1000.0,
          hintCount: png.hintCount,
        ));
      }
    } catch (e) {
      widget.logs.error('hints', '上色失败：$e');
      setState(() => _status = '上色失败：$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _shareResult() async {
    final png = _resultPng;
    if (png == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final f = File(
          '${dir.path}/colorized_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png);
      await Share.shareXFiles([XFile(f.path)], text: 'Manga Colorizer 上色结果');
    } catch (e) {
      setState(() => _status = '分享失败：$e');
    }
  }

  Rect _imageRect(Size box, int iw, int ih) {
    final a = iw / ih;
    var w = box.width, h = box.width / a;
    if (h > box.height) {
      h = box.height;
      w = h * a;
    }
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final src = _source;
    return Scaffold(
      appBar: screenAppBar(
        context,
        title: '上色',
        controller: widget.controller,
        // 「相册选图 / 内置样例」经 _loadBytes 改写画布（清提示点、切预览态），
        // 属本屏局部动作，仅以 _busy 门控。
        actions: [
          IconButton(
              onPressed: _busy ? null : _pickImage,
              icon: const Icon(Icons.photo_library_outlined),
              tooltip: '从相册选图'),
          IconButton(
              onPressed: _busy ? null : _loadBundledSample,
              icon: const Icon(Icons.image_outlined),
              tooltip: '内置样例'),
        ],
      ),
      body: Column(children: [
        Expanded(child: src == null ? _buildEmpty() : _buildCanvas(src)),
        _buildToolbar(),
      ]),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.palette_outlined,
              size: 56,
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(_status,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          OutlinedButton.icon(
              onPressed: _busy ? null : _loadBundledSample,
              icon: const Icon(Icons.image_outlined),
              label: const Text('加载内置样例试试')),
        ]),
      ),
    );
  }

  Widget _buildCanvas(DecodedImage src) {
    return LayoutBuilder(builder: (context, cons) {
      final box = Size(cons.maxWidth, cons.maxHeight);
      final rect = _imageRect(box, src.width, src.height);
      void placeHint(Offset global) {
        final ro = context.findRenderObject()! as RenderBox;
        final local = ro.globalToLocal(global);
        if (!rect.contains(local)) return;
        final nx = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
        final ny = ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
        setState(() => _hints.add(_HintPoint(Offset(nx, ny), _brush)));
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          if (!_busy) placeHint(d.globalPosition);
        },
        onDoubleTapDown: (d) {
          final ro = context.findRenderObject()! as RenderBox;
          final local = ro.globalToLocal(d.globalPosition);
          if (!rect.contains(local)) return;
          final p = Offset((local.dx - rect.left) / rect.width,
              (local.dy - rect.top) / rect.height);
          _hints.removeWhere((h) => (h.pos - p).distance < 0.045);
          setState(() {});
        },
        child: Stack(children: [
          Positioned.fromRect(
            rect: rect,
            child: _mode == _ViewMode.colorized && _resultPng != null
                ? Image.memory(_resultPng!,
                    fit: BoxFit.fill, gaplessPlayback: true)
                : Image.memory(_sourcePng!,
                    fit: BoxFit.fill, gaplessPlayback: true),
          ),
          ..._hints.map((h) => Positioned(
                left: rect.left + h.pos.dx * rect.width - 9,
                top: rect.top + h.pos.dy * rect.height - 9,
                child: IgnorePointer(
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: h.color.withValues(alpha: 0.85),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              )),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: IgnorePointer(
                child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                if (_mode == _ViewMode.colorized)
                  Text('上色结果',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600)),
              ]),
            )),
          ),
        ]),
      );
    });
  }

  Widget _buildToolbar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border:
              Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                for (final c in _palette)
                  GestureDetector(
                    onTap: () => setState(() => _brush = c),
                    child: Container(
                        width: 26,
                        height: 26,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c,
                            border: Border.all(
                                color: _brush == c
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                                width: 2.5))),
                  ),
                const Spacer(),
                Text(_elapsed ?? '',
                    style: Theme.of(context).textTheme.labelSmall),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_source == null || _busy) ? null : _colorize,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.palette_outlined),
                    label: Text(_busy ? '处理中…' : '上色'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed:
                      (_resultPng == null || _busy) ? null : _shareResult,
                  icon: const Icon(Icons.ios_share),
                  tooltip: '分享 / 保存',
                ),
                IconButton.filledTonal(
                  onPressed: (_resultPng == null || _busy)
                      ? null
                      : () => setState(() => _mode = _mode == _ViewMode.original
                          ? _ViewMode.colorized
                          : _ViewMode.original),
                  icon: Icon(_mode == _ViewMode.original
                      ? Icons.auto_fix_high
                      : Icons.image_outlined),
                  tooltip: '原图 / 上色切换',
                ),
                Badge(
                  isLabelVisible: _hints.isNotEmpty,
                  label: Text('${_hints.length}'),
                  child: IconButton.filledTonal(
                    onPressed: _hints.isEmpty
                        ? null
                        : () => setState(() => _hints.clear()),
                    icon: const Icon(Icons.layers_clear_outlined),
                    tooltip: '清空提示点',
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(_status, style: Theme.of(context).textTheme.bodySmall),
            ]),
      ),
    );
  }
}
