// 「全自动」页签：权重缺失 → 许可提示 + 引导下载；就绪 → 选图 → isolate 推理
// （进度条 + 取消）→ 预览/分享。推理本身在 AutoEngine（见 onnx/auto_service.dart），
// 本页签只做编排：权重目录经 path_provider 解析，下载进度按 ~1% 节流重绘。
// 不写任何端侧性能承诺（真机耗时未测，Task 7 文档侧说明）。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'onnx/auto_service.dart';
import 'onnx/weights.dart';

/// 单文件下载的注入接缝：默认走 WeightsStore.download（真实网络），
/// 宿主测试替换成假下载器（测试不得访问真实网络）。
typedef DownloadOne = Future<void> Function(
    WeightFile f, void Function(int done, int total) onProgress);

/// 下载进度节流：`WeightsStore.download` 按**网络分块**触发 onProgress，逐条
/// setState 会拖垮 UI。只在整百分比前进时返回新值；total<=0 或百分比未前进
/// 返回 null（不重绘）。
@visibleForTesting
int? nextDownloadPercent(int done, int total, int? lastPercent) {
  if (total <= 0) return lastPercent;
  final pct = (done * 100 / total).floor().clamp(0, 100);
  if (lastPercent != null && pct <= lastPercent) return null;
  return pct;
}

/// 「全自动」页签入口（挂在 WorkbenchPage 的第二个 Tab 上）。
class AutoPanel extends StatelessWidget {
  const AutoPanel({super.key, required this.engine});
  final AutoEngine engine;

  @override
  Widget build(BuildContext context) => AutoTab(engine: engine);
}

class AutoTab extends StatefulWidget {
  const AutoTab({
    super.key,
    required this.engine,
    this.resolveDir,
    this.downloadOne,
  });

  final AutoEngine engine;

  /// 权重目录解析：生产默认 getApplicationSupportDirectory()/manga-light-colorizer
  /// （与桌面 weights 布局同名）；测试注入临时目录（path_provider 在宿主测试不可用）。
  final Future<Directory> Function()? resolveDir;
  final DownloadOne? downloadOne;

  @override
  State<AutoTab> createState() => _AutoTabState();
}

class _AutoTabState extends State<AutoTab> {
  final ImagePicker _picker = ImagePicker();

  bool _checking = true; // 首帧探测权重目录中（纯文本，不放转圈以免 pumpAndSettle 不收敛）
  bool _initError = false;
  bool _weightsMissing = true;
  Directory? _dir;
  WeightsStore? _store;

  bool _busy = false;
  bool _downloading = false;
  int? _dlPct;
  bool _inferring = false;
  double _inferPct = 0;

  Uint8List? _gray;
  int _w = 0, _h = 0;
  Uint8List? _sourcePng;
  Uint8List? _resultPng;
  String _status = '检查权重…';

  static const _license =
      '模型权重 CC BY-NC-SA 4.0，需自行下载，仅限非商业使用；详见仓库 docs/licensing。';

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<Directory> _appWeightsDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/manga-light-colorizer');
  }

  Future<void> _init() async {
    try {
      final dir = await (widget.resolveDir ?? _appWeightsDir)();
      final store = WeightsStore(dir: dir, mirrorPreferred: (u) => false);
      final ok = await store.ready;
      if (!mounted) return;
      setState(() {
        _checking = false;
        _dir = dir;
        _store = store;
        _weightsMissing = !ok;
        _status = ok ? '权重就绪。' : '权重未下载，请先看下方说明。';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _initError = true;
        _weightsMissing = true;
        _status = '初始化失败：$e';
      });
    }
  }

  Future<void> _download() async {
    final store = _store;
    if (store == null || _busy) return;
    setState(() {
      _busy = true;
      _downloading = true;
      _dlPct = null;
      _status = '准备下载…';
    });
    try {
      store.dir.createSync(recursive: true);
      for (final f in kWeightFiles) {
        if (store.readyFor(f)) continue; // 完整文件跳过；半截 .part 由下载器续传
        if (mounted) {
          setState(() {
            _status = '正在下载 ${f.name}…';
            _dlPct = null;
          });
        }
        // download 的 onProgress 按网络分块高频触发，逐条 setState 会卡 UI：
        // 用 nextDownloadPercent 节流到"每前进 1% 至多重绘一次"。
        int? lastPct;
        void onProgress(int done, int total) {
          final next = nextDownloadPercent(done, total, lastPct);
          if (next == null) return;
          lastPct = next;
          if (mounted) setState(() => _dlPct = next);
        }

        final injected = widget.downloadOne;
        if (injected != null) {
          await injected(f, onProgress);
        } else {
          await store.download(f, onProgress: onProgress);
        }
      }
      if (mounted) {
        setState(() {
          _weightsMissing = false;
          _status = '权重就绪。';
        });
      }
    } on WeightsException catch (e) {
      // 契约：下载器的传输失败只会以 WeightsException 出现。
      if (mounted) setState(() => _status = '下载失败：${e.message}');
    } on Object catch (e) {
      if (mounted) setState(() => _status = '下载失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloading = false;
          _dlPct = null;
        });
      }
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    setState(() {
      _busy = true;
      _status = '读取图片…';
    });
    try {
      final bytes = await File(file.path).readAsBytes();
      final decoded = await Isolate.run(() {
        final d = MangaImageIO.decodeGrayscale(bytes);
        final n = d.width * d.height;
        final gray = Uint8List(n);
        for (var i = 0; i < n; i++) {
          gray[i] = d.rgb[i * 3]; // decodeGrayscale 已把亮度写到三通道
        }
        return (
          gray: gray,
          width: d.width,
          height: d.height,
          png: MangaImageIO.encodePng(
              rgb: d.rgb, width: d.width, height: d.height),
        );
      });
      if (!mounted) return;
      setState(() {
        _gray = decoded.gray;
        _w = decoded.width;
        _h = decoded.height;
        _sourcePng = decoded.png;
        _resultPng = null;
        _status = '已加载 ${decoded.width}×${decoded.height}。';
      });
    } on Object catch (e) {
      if (mounted) setState(() => _status = '读取失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run() async {
    final gray = _gray;
    final dir = _dir;
    if (gray == null || dir == null || _busy) return;
    setState(() {
      _busy = true;
      _inferring = true;
      _inferPct = 0;
      _resultPng = null;
      _status = '加载模型并分块上色中…';
    });
    try {
      await widget.engine.ensureStarted(dir.path);
      final out = await widget.engine.colorize(gray, _w, _h, onProgress: (p) {
        if (!mounted) return;
        setState(() {
          _inferPct = p;
          _status = '上色中 ${(p * 100).round()}%';
        });
      });
      if (out == null) {
        if (mounted) setState(() => _status = '已取消。');
        return;
      }
      if (mounted) setState(() => _status = '编码 PNG…');
      final w = _w, h = _h;
      final png = await Isolate.run(
          () => MangaImageIO.encodePng(rgb: out, width: w, height: h));
      if (!mounted) return;
      setState(() {
        _resultPng = png;
        _status = '完成。可预览或分享。';
      });
    } on Object catch (e) {
      if (mounted) setState(() => _status = '全自动失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _inferring = false;
          _inferPct = 0;
        });
      }
    }
  }

  Future<void> _cancelRun() => widget.engine.shutdown();

  Future<void> _share() async {
    final png = _resultPng;
    if (png == null) return;
    try {
      final temp = await getTemporaryDirectory();
      final f = File(
          '${temp.path}/auto_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png);
      await Share.shareXFiles([XFile(f.path)], text: 'Manga Colorizer 全自动上色结果');
    } on Object catch (e) {
      if (mounted) setState(() => _status = '分享失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalMb =
        (kWeightFiles.fold<int>(0, (s, f) => s + f.size) / 1000000).round();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_status, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (!_checking && _weightsMissing) ..._guide(context, totalMb),
        if (!_weightsMissing && !_checking) ..._ready(context),
      ],
    );
  }

  List<Widget> _guide(BuildContext context, int totalMb) {
    return [
      Text('尚未检测到模型权重（${kWeightFiles.length} 个文件，约 $totalMb MB）。'),
      const SizedBox(height: 8),
      Text(_license, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: (_store == null || _busy) ? null : _download,
        icon: const Icon(Icons.file_download_outlined),
        label: const Text('下载权重(~300MB)'),
      ),
      if (_initError)
        TextButton(onPressed: _busy ? null : _init, child: const Text('重试')),
      if (_downloading) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(value: (_dlPct ?? 0) / 100.0),
      ],
    ];
  }

  List<Widget> _ready(BuildContext context) {
    return [
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('选图'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: (_busy || _gray == null) ? null : _run,
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('开始全自动'),
            ),
          ),
          if (_inferring)
            IconButton(
              onPressed: _cancelRun,
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '取消',
            ),
        ],
      ),
      if (_inferring) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(value: _inferPct),
      ],
      const SizedBox(height: 12),
      if (_sourcePng != null) ...[
        Text('原稿（灰度）', style: Theme.of(context).textTheme.labelSmall),
        Image.memory(_sourcePng!, fit: BoxFit.contain, gaplessPlayback: true),
        const SizedBox(height: 12),
      ],
      if (_resultPng != null) ...[
        Row(
          children: [
            Expanded(
              child:
                  Text('上色结果', style: Theme.of(context).textTheme.labelSmall),
            ),
            IconButton(
              onPressed: _share,
              icon: const Icon(Icons.ios_share),
              tooltip: '分享 / 保存',
            ),
          ],
        ),
        Image.memory(_resultPng!, fit: BoxFit.contain, gaplessPlayback: true),
      ],
    ];
  }
}
