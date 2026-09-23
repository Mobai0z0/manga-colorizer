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

import 'auto_panel.dart';
import 'onnx/auto_service.dart';

/// 移动端工作台：两个页签——
///   · 提示点：选图 → 提示点上色（纯 Dart 引擎 manga_colorizer_core，
///     推理在 isolate 中执行，不依赖后端服务）→ 保存/分享结果；
///   · 全自动：ONNX 端侧推理（AutoEngine 工作 isolate，见 onnx/auto_service.dart）。
void main() => runApp(const MangaColorizerApp());

const _accent = Color(0xFF2F6D5E);

/// Color 通道（0..1 double）→ 8bit 整数。替代已弃用的 `.red/.green/.blue`
/// 访问器（其弃用说明给出的等价式即 `(*.c * 255.0).round().clamp(0, 255)`；
/// 对本应用的 8bit 调色板色二者逐值相同）。
int _channel(double v) => (v * 255.0).round().clamp(0, 255).toInt();

class MangaColorizerApp extends StatelessWidget {
  const MangaColorizerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: _accent);
    return MaterialApp(
      title: 'Manga Colorizer',
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: const WorkbenchPage(),
    );
  }
}

class _HintPoint {
  final Offset pos; // normalized within image rect 0..1
  final Color color;
  _HintPoint(this.pos, this.color);
}

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key});

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

enum _ViewMode { original, colorized }

class _WorkbenchPageState extends State<WorkbenchPage>
    with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();
  final List<_HintPoint> _hints = [];

  /// 「全自动」页签的常驻引擎（两页签共享；退到后台即释放模型归还内存）。
  final AutoEngine _engine = AutoEngine();

  DecodedImage? _source;
  Uint8List? _sourcePng;
  Uint8List? _resultPng;
  Color _brush = const Color(0xFF1E88E5);
  _ViewMode _mode = _ViewMode.original;
  bool _busy = false;
  String _status = '从相册选图，或点右上角加载内置样例';
  String? _elapsed;

  static const _palette = <Color>[
    Color(0xFF1E88E5), Color(0xFFE53935), Color(0xFFFDD835),
    Color(0xFF43A047), Color(0xFF8E24AA), Color(0xFFF48FB1),
    Color(0xFF6D4C41), Color(0xFF212121),
  ];

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
    // spec §4 空闲释放的后台侧：退到后台立即 dispose 后端 + 回收工作 isolate。
    if (state == AppLifecycleState.paused) unawaited(_engine.shutdown());
  }

  Future<void> _loadBytes(List<int> bytes, String label) async {
    setState(() { _busy = true; _status = '读取图片…'; _resultPng = null; _hints.clear(); _mode = _ViewMode.original; });
    try {
      final decoded = await Isolate.run(() => MangaImageIO.decodeGrayscale(bytes));
      final png = await Isolate.run(() =>
          MangaImageIO.encodePng(rgb: decoded.rgb, width: decoded.width, height: decoded.height));
      setState(() {
        _source = decoded;
        _sourcePng = png;
        _status = '$label ${decoded.width}×${decoded.height}。点按图片落提示点，然后「上色」。';
      });
    } catch (e) {
      setState(() => _status = '读取失败：$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pickImage() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    await _loadBytes(await File(file.path).readAsBytes(), '已加载');
  }

  Future<void> _loadBundledSample() async {
    final bytes = await rootBundle.load('assets/sample_bw.png');
    await _loadBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), '内置样例已加载');
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
    setState(() { _busy = true; _status = '上色中（色度扩散求解，亮度完整保留）…'; });
    final sw = Stopwatch()..start();
    try {
      final png = await Isolate.run(() {
        final result = colorizeManga(
          grayscaleRgb: src.rgb,
          width: src.width,
          height: src.height,
          hints: hints,
        );
        return (
          bytes: MangaImageIO.encodePng(rgb: result.rgb, width: result.width, height: result.height),
          iterations: result.iterations,
          hintCount: result.hintCount,
        );
      });
      sw.stop();
      setState(() {
        _resultPng = png.bytes;
        _mode = _ViewMode.colorized;
        _elapsed = '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
        _status = png.hintCount == 0
            ? '完成（无提示点，输出为原图）。请落点后重新上色。'
            : '上色完成：${png.hintCount} 个提示点，迭代 ${png.iterations} 次。';
      });
    } catch (e) {
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
      final f = File('${dir.path}/colorized_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png);
      await Share.shareXFiles([XFile(f.path)], text: 'Manga Colorizer 上色结果');
    } catch (e) {
      setState(() => _status = '分享失败：$e');
    }
  }

  Rect _imageRect(Size box, int iw, int ih) {
    final a = iw / ih;
    var w = box.width, h = box.width / a;
    if (h > box.height) { h = box.height; w = h * a; }
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final src = _source;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Manga Colorizer'),
          backgroundColor: Theme.of(context).colorScheme.surface,
          actions: [
            IconButton(onPressed: _busy ? null : _pickImage, icon: const Icon(Icons.photo_library_outlined), tooltip: '从相册选图'),
            IconButton(onPressed: _busy ? null : _loadBundledSample, icon: const Icon(Icons.image_outlined), tooltip: '内置样例'),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: '提示点'),
            Tab(text: '全自动'),
          ]),
        ),
        body: TabBarView(children: [
          // 页签 1：提示点（原有工作台，原样保留）。
          Column(children: [
            Expanded(child: src == null ? _buildEmpty() : _buildCanvas(src)),
            _buildToolbar(),
          ]),
          // 页签 2：全自动（ONNX 端侧推理）。
          AutoPanel(engine: _engine),
        ]),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.palette_outlined, size: 56, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(_status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          OutlinedButton.icon(onPressed: _busy ? null : _loadBundledSample, icon: const Icon(Icons.image_outlined), label: const Text('加载内置样例试试')),
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
        onTapUp: (d) { if (!_busy) placeHint(d.globalPosition); },
        onDoubleTapDown: (d) {
          final ro = context.findRenderObject()! as RenderBox;
          final local = ro.globalToLocal(d.globalPosition);
          if (!rect.contains(local)) return;
          final p = Offset((local.dx - rect.left) / rect.width, (local.dy - rect.top) / rect.height);
          _hints.removeWhere((h) => (h.pos - p).distance < 0.045);
          setState(() {});
        },
        child: Stack(children: [
          Positioned.fromRect(
            rect: rect,
            child: _mode == _ViewMode.colorized && _resultPng != null
                ? Image.memory(_resultPng!, fit: BoxFit.fill, gaplessPlayback: true)
                : Image.memory(_sourcePng!, fit: BoxFit.fill, gaplessPlayback: true),
          ),
          ..._hints.map((h) => Positioned(
                left: rect.left + h.pos.dx * rect.width - 9,
                top: rect.top + h.pos.dy * rect.height - 9,
                child: IgnorePointer(
                  child: Container(
                    width: 18, height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: h.color.withValues(alpha: 0.85),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              )),
          Positioned(
            left: 0, top: 0, right: 0,
            child: IgnorePointer(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                if (_mode == _ViewMode.colorized)
                  Text('上色结果', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
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
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            for (final c in _palette)
              GestureDetector(
                onTap: () => setState(() => _brush = c),
                child: Container(width: 26, height: 26, margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: c,
                    border: Border.all(
                      color: _brush == c ? Theme.of(context).colorScheme.primary : Colors.transparent,
                      width: 2.5))),
              ),
            const Spacer(),
            Text(_elapsed ?? '', style: Theme.of(context).textTheme.labelSmall),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (_source == null || _busy) ? null : _colorize,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.palette_outlined),
                label: Text(_busy ? '处理中…' : '上色'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: (_resultPng == null || _busy) ? null : _shareResult,
              icon: const Icon(Icons.ios_share),
              tooltip: '分享 / 保存',
            ),
            IconButton.filledTonal(
              onPressed: (_resultPng == null || _busy)
                  ? null
                  : () => setState(() => _mode = _mode == _ViewMode.original ? _ViewMode.colorized : _ViewMode.original),
              icon: Icon(_mode == _ViewMode.original ? Icons.auto_fix_high : Icons.image_outlined),
              tooltip: '原图 / 上色切换',
            ),
            Badge(
              isLabelVisible: _hints.isNotEmpty,
              label: Text('${_hints.length}'),
              child: IconButton.filledTonal(
                onPressed: _hints.isEmpty ? null : () => setState(() => _hints.clear()),
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

