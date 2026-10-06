// 「全自动」上色的编排视图 [AutoTab]：权重缺失 → 许可提示 + 引导下载；就绪 →
// 选图 → isolate 推理（进度条 + 取消）→ 预览/分享。推理本身在 AutoEngine（见
// onnx/auto_service.dart），本视图只做编排：权重目录经 path_provider 解析，
// 下载进度按 ~1% 节流重绘。由 screens/auto_screen.dart 承载为「全自动」目的地。
// 不写任何端侧性能承诺（真机耗时未测，属合并后真机验收清单，见 docs 已知限制）。
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
import 'image_cap.dart';
import 'app_settings.dart';
import 'logs/log_bus.dart';

/// 单文件下载的注入接缝：默认走 WeightsStore.download（真实网络），
/// 宿主测试替换成假下载器（测试不得访问真实网络）。
typedef DownloadOne = Future<void> Function(
    WeightFile f, void Function(int done, int total) onProgress);

/// 全自动成功回调：把结果/原图交给外部（图库入库），不在此 import store。
typedef AutoOnCompleted = void Function({
  required Uint8List resultPng,
  required Uint8List sourcePng,
  required int width,
  required int height,
});

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

/// 「全自动」上色的编排视图：门控权重下载、选图、isolate 推理、预览/分享。
/// 由 [AutoScreen]（screens/auto_screen.dart）持有引擎并承载为底栏「全自动」目的地。
class AutoTab extends StatefulWidget {
  const AutoTab({
    super.key,
    required this.engine,
    required this.controller,
    required this.logs,
    this.resolveDir,
    this.downloadOne,
    this.onCompleted,
  });

  final AutoEngine engine;

  /// 全局设置控制器：下载源从此读取、经它落盘（与主题共享同一 settings.json）。
  final SettingsController controller;

  /// 端侧运行日志总线：由 [AutoScreen] 注入，本视图只写入、不释放。
  final LogBus logs;

  /// 权重目录解析：生产默认 getApplicationSupportDirectory()/manga-light-colorizer
  /// （与桌面 weights 布局同名）；测试注入临时目录（path_provider 在宿主测试不可用）。
  final Future<Directory> Function()? resolveDir;
  final DownloadOne? downloadOne;

  /// 全自动成功回调：成功产出结果 PNG 后把结果/原图交给外部（图库入库）。
  final AutoOnCompleted? onCompleted;

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
  DownloadSource _source = DownloadSource.auto;

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
      final source = widget.controller.settings.downloadSource;
      final store = WeightsStore(dir: dir, source: source);
      final ok = await store.ready;
      if (!mounted) return;
      setState(() {
        _checking = false;
        _dir = dir;
        _source = source;
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

  /// 切换下载源：本地立即以新 [source] 重建 store 并重绘（选择即时生效），
  /// 并经全局控制器落盘（与主题共享同一 settings.json，写失败由控制器降级）。
  void _applySource(DownloadSource source) {
    final dir = _dir;
    if (dir == null || !mounted) return;
    setState(() {
      _source = source;
      _store = WeightsStore(dir: dir, source: source);
    });
    widget.controller.update(
        widget.controller.settings.copyWith(downloadSource: source));
  }

  Future<void> _pickSource() async {
    final chosen = await showDialog<DownloadSource>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('模型下载源'),
        children: [
          RadioGroup<DownloadSource>(
            groupValue: _source,
            onChanged: (v) => Navigator.of(ctx).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in DownloadSource.values)
                  RadioListTile<DownloadSource>(
                    value: s,
                    title: Text(_sourceLabel(s)),
                    subtitle: Text(_sourceHint(s)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (chosen != null && chosen != _source) _applySource(chosen);
  }

  static String _sourceLabel(DownloadSource s) => switch (s) {
        DownloadSource.auto => '自动（推荐）',
        DownloadSource.primary => '仅主站 (huggingface.co)',
        DownloadSource.mirror => '仅镜像 (hf-mirror.com)',
      };

  static String _sourceHint(DownloadSource s) => switch (s) {
        DownloadSource.auto => '主站优先，失败自动改走镜像续传',
        DownloadSource.primary => '国内网络通常无法直连，可能失败',
        DownloadSource.mirror => '直连镜像站，不经主站',
      };

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
          await store.download(f,
              onProgress: onProgress,
              onFallback: (file, from, next, why) => widget.logs.warn(
                  'weights',
                  '权重 ${file.name} 主站失败，回退镜像：'
                  '${Uri.parse(from).host}→${Uri.parse(next).host}：$why'));
        }
        widget.logs.info('weights', '权重 ${f.name} 下载完成（${f.size} 字节）');
      }
      if (mounted) {
        setState(() {
          _weightsMissing = false;
          _status = '权重就绪。';
        });
        widget.logs.info('weights', '权重全部就绪');
      }
    } on WeightsException catch (e) {
      // 契约：下载器的传输失败只会以 WeightsException 出现。
      if (mounted) setState(() => _status = '下载失败：${e.message}');
      widget.logs.error('weights', '下载失败：${e.message}');
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

  // isolate 计算入口**必须 static**：闭包若在实例方法作用域创建，会被同方法内
  // 捕获 this 的 setState 闭包经共享 context 污染——SendPort 序列化闭包时沿
  // context 父链连 _AutoTabState（整棵 widget 树）一起走，抛 "object is
  // unsendable"，选图/编码必失败（v0.5.1 真机必现）。static 作用域无 this 可捕。

  /// 解码选图为灰度单通道 + 原稿 RGB PNG（在工作 isolate 执行）。
  /// 长边超过 kMaxPickSide 先缩到上限（端侧内存分级，见 image_cap.dart）。
  static Future<
      ({
        Uint8List gray,
        int width,
        int height,
        Uint8List png,
        int? origWidth,
        int? origHeight,
      })> _decodePick(Uint8List bytes) {
    return Isolate.run(() {
      final capped = capDecodeGrayscale(bytes);
      final d = capped.image;
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
        origWidth: capped.origWidth,
        origHeight: capped.origHeight,
      );
    });
  }

  /// RGB 像素编码为 PNG（在工作 isolate 执行）。
  static Future<Uint8List> _encodePng(Uint8List rgb, int width, int height) {
    return Isolate.run(
        () => MangaImageIO.encodePng(rgb: rgb, width: width, height: height));
  }

  Future<void> _pick() async {
    if (_busy) return;
    // maxWidth/maxHeight：让相册在原生侧就缩到长边上限（不落全分辨率位图，
    // 见 image_cap.dart）；未生效时 _decodePick 的兜底缩放会再拦一次。
    final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: kMaxPickSide.toDouble(),
        maxHeight: kMaxPickSide.toDouble());
    if (file == null) return;
    // 相册选择是异步挂起：期间本页可能被销毁，setState 前须验 mounted
    // （与本文件其余 post-await setState 的守卫一致）。
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = '读取图片…';
    });
    try {
      // readAsBytes 而非 File(path)：相册 content:// URI 在部分设备上
      // XFile.path 不是真实文件路径，须经平台通道解析。
      final bytes = await file.readAsBytes();
      final decoded = await _decodePick(bytes);
      if (!mounted) return;
      final origW = decoded.origWidth;
      if (origW != null) {
        widget.logs.info('auto',
            '原图 $origW×${decoded.origHeight} 超过端侧长边上限 '
            '$kMaxPickSide，已缩放至 ${decoded.width}×${decoded.height}');      }
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
    widget.logs.info('auto', '全自动任务开始 $_w×$_h');
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
        widget.logs.info('auto', '全自动任务已取消');
        return;
      }
      if (mounted) setState(() => _status = '编码 PNG…');
      final w = _w, h = _h;
      final png = await _encodePng(out, w, h);
      if (!mounted) return;
      setState(() {
        _resultPng = png;
        _status = '完成。可预览或分享。';
      });
      final src = _sourcePng;
      if (src != null) {
        widget.onCompleted?.call(
            resultPng: png, sourcePng: src, width: w, height: h);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _status = '全自动失败：$e');
      widget.logs.error('auto', '全自动失败：$e');
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
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : _pickSource,
            icon: const Icon(Icons.tune),
            label: Text('下载源：${_sourceLabel(_source)}'),
          ),
        ),
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
