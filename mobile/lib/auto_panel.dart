// 「全自动」上色的编排视图 [AutoTab]：权重缺失 → 许可提示 + 引导下载；就绪 →
// 选图 → isolate 推理（进度条 + 取消）→ 预览/分享。推理本身在 AutoEngine（见
// onnx/auto_service.dart），本视图只做编排：权重目录经 path_provider 解析，
// 下载进度按 ~1% 节流重绘。由 screens/auto_screen.dart 承载为「全自动」目的地。
// 不写任何端侧性能承诺（真机耗时未测，属合并后真机验收清单，见 docs 已知限制）。
//
// v0.6.1 起参考图模式同步桌面（tool/colorizer_service/service.py
// `_process_reference`）：原稿 + 人设彩图 → 模型语义色 ⊕ 参考图迁移色
// 在 Lab a/b 上 5:5 融合（L 恒取原稿），迁移算法/强度随设置持久化，
// 端到口在 reference_flow.dart 的 referenceColorizeInIsolate。
// 结果以 mode='reference' 入图库。v0.6.0 的「免模型纯迁移」与「对全自动
// 结果叠加参考图色调」两条旧路径已随全量替换移除（桌面无对应行为）。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart'
    show kDefaultFinishScheme, kFinishSchemes, ReferenceMethod;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'onnx/auto_service.dart';
import 'onnx/weights.dart';
import 'image_cap.dart';
import 'mem_info.dart';
import 'png_encode.dart';
import 'reference_flow.dart';
import 'theme/glass.dart';
import 'resource_tier.dart';
import 'app_settings.dart';
import 'logs/log_bus.dart';

/// 单文件下载的注入接缝：默认走 WeightsStore.download（真实网络），
/// 宿主测试替换成假下载器（测试不得访问真实网络）。
typedef DownloadOne = Future<void> Function(
    WeightFile f, void Function(int done, int total) onProgress);

/// 全自动成功回调：把结果/原图交给外部（图库入库），不在此 import store。
/// [mode] 为入库模式（'auto' 或参考图叠加后的 'reference'）。
typedef AutoOnCompleted = void Function({
  required Uint8List resultPng,
  required Uint8List sourcePng,
  required int width,
  required int height,
  required String mode,
});

/// 色彩方案的界面文案（id 与 kFinishSchemes/桌面 FINISH_SCHEMES 同源）。
const Map<String, String> kSchemeLabels = {
  'standard': '标准',
  'vivid-cel': '鲜明赛璐璐',
  'soft-pastel': '柔和淡彩',
  'impasto': '厚涂浓郁',
  'retro-showa': '昭和复古',
};

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
  // 下载源单一真源＝controller.settings.downloadSource；本类不再缓存独立副本，
  // 避免与「设置页」的模型下载源选择互相漂移（IndexedStack 下各屏常驻、不重走
  // initState，旧本地副本不会自动跟随 settings 同步）。
  DownloadSource get _source => widget.controller.settings.downloadSource;
  DownloadSource _appliedSource = DownloadSource.auto;

  bool _busy = false;
  bool _downloading = false;
  int? _dlPct;
  bool _inferring = false;
  double _inferPct = 0;

  Uint8List? _gray;
  int _w = 0, _h = 0;
  Uint8List? _sourcePng;
  Uint8List? _resultPng;
  String _scheme = kDefaultFinishScheme;
  String _status = '检查权重…';

  // ---- 参考图上色（桌面同款，需模型）状态 ----
  Uint8List? _refSrcRgb; // 原稿 RGB（迁移源）
  Uint8List? _refSrcGray; // 原稿灰度（模型输入 + L 来源）
  int _refSrcW = 0, _refSrcH = 0;
  Uint8List? _refSrcPng; // 原稿预览/入库用 PNG
  Uint8List? _refRgb; // 参考图 RGB
  Uint8List? _refThumbPng; // 参考图小预览
  Uint8List? _refOutPng; // 融合结果 PNG
  bool _refBusy = false;
  ReferenceMethod _refMethod = ReferenceMethod.reinhard;
  double _refStrength = 1.0;

  static const _license =
      '模型权重 CC BY-NC-SA 4.0，需自行下载，仅限非商业使用；详见仓库 docs/licensing。';

  @override
  void initState() {
    super.initState();
    _scheme = widget.controller.settings.colorScheme;
    _refMethod = _refMethodFromId(widget.controller.settings.refMethod);
    _refStrength = widget.controller.settings.refStrength;
    // 监听全局设置：设置页改下载源时同步本页 store（见 _onSettingsSourceChanged）。
    widget.controller.addListener(_onSettingsSourceChanged);
    unawaited(_init());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSettingsSourceChanged);
    super.dispose();
  }

  /// 设置里的迁移算法 id → 枚举（白名单外回退 reinhard）。
  static ReferenceMethod _refMethodFromId(String id) =>
      id == 'histogram' ? ReferenceMethod.histogram : ReferenceMethod.reinhard;

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
        _appliedSource = source;
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

  /// 切换下载源：单一真源＝controller.settings.downloadSource。先标记本地
  /// [_appliedSource]（防 _onSettingsSourceChanged 重复建 store），再重建 store
  /// 并落盘。设置页改动同一字段时由监听器同步本页 store，两端永不漂移。
  void _applySource(DownloadSource source) {
    final dir = _dir;
    if (dir == null || !mounted) return;
    _appliedSource = source;
    setState(() {
      _store = WeightsStore(dir: dir, source: source);
    });
    widget.controller
        .update(widget.controller.settings.copyWith(downloadSource: source));
  }

  /// 监听全局设置：任何来源（含设置页）改了下载源，都重建本页 store 与之对齐。
  void _onSettingsSourceChanged() {
    final dir = _dir;
    if (dir == null || !mounted) return;
    final s = widget.controller.settings.downloadSource;
    if (s == _appliedSource) return;
    _appliedSource = s;
    setState(() {
      _store = WeightsStore(dir: dir, source: s);
    });
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

  /// 灰度单通道化（在工作 isolate 执行）：RGBA 由主 isolate 的 capDecodeRgba
  /// 按目标尺寸产出（见 image_cap.dart），isolate 内不再出现全分辨率位图——
  /// 旧路径对 50MP 原图的兜底解码瞬时可达 ~300MB。
  /// 源稿 PNG 不在这里编码：改走引擎线程原生编码（png_encode.dart），纯 Dart
  /// zlib 在 2048² 上可达秒级。
  static Future<Uint8List> _decodeGray(Uint8List rgba) {
    return Isolate.run(() => rgbaToGray(rgba));
  }

  /// 结果 RGB → PNG（引擎线程原生编码，主 isolate await）。
  static Future<Uint8List> _encodePng(Uint8List rgb, int width, int height) {
    return encodePngFromRgb(rgb, width, height);
  }

  Future<void> _pick() async {
    if (_busy) return;
    // 设备分级档位：picker 原生缩放与解码兜底共用同一上限（detect 有缓存，
    // 探测失败回退 v0.5.4 默认档）。
    final tier = await ResourceTier.detect();
    // maxWidth/maxHeight：让相册在原生侧就缩到长边上限（不落全分辨率位图，
    // 见 image_cap.dart）；未生效（部分 OEM 相册不认）时 capDecodeRgba 的
    // 按目标尺寸解码会在主 isolate 拦下，绝不物化全分辨率位图。
    final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: tier.maxPickSide.toDouble(),
        maxHeight: tier.maxPickSide.toDouble());
    if (file == null) return;
    // 相册选择是异步挂起：期间本页可能被销毁，setState 前须验 mounted
    // （与本文件其余 post-await setState 的守卫一致）。
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = '读取图片…';
      // 先丢上一张的整页缓冲：解码期间新旧两份不该同时在场。
      _gray = null;
      _sourcePng = null;
      _resultPng = null;
    });
    try {
      // readAsBytes 而非 File(path)：相册 content:// URI 在部分设备上
      // XFile.path 不是真实文件路径，须经平台通道解析。
      final bytes = await file.readAsBytes();
      final cap = await capDecodeRgba(bytes, maxSide: tier.maxPickSide);
      // 灰度（工作 isolate，RGBA+复制 ≈2 份）与源稿 PNG（引擎线程，
      // ImmutableBuffer 复制 ≈2 份）**串行**产出：并行时三份 RGBA 同场
      // ~50MB，串行各自 ~34MB——选图阶段多花百余毫秒，换低内存设备的
      // 峰值余量（picker 兜底路径最危险的一段）。
      final gray = await _decodeGray(cap.rgba);
      final png = await encodePngFromRgba(cap.rgba, cap.width, cap.height);
      if (!mounted) return;
      final origW = cap.origWidth;
      if (origW != null) {
        widget.logs.info(
            'auto',
            '原图 $origW×${cap.origHeight} 超过端侧长边上限 '
                '${tier.maxPickSide}，已缩放至 ${cap.width}×${cap.height}');
      }
      setState(() {
        _gray = gray;
        _w = cap.width;
        _h = cap.height;
        _sourcePng = png;
        _resultPng = null;
        _status = '已加载 ${cap.width}×${cap.height}。';
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
    widget.logs.info('auto', '全自动任务开始 $_w×$_h${rssSuffix()}');
    try {
      // 线程数/arena 策略/空闲保留时长随设备分级下发（低内存档 2 线程 +
      // arena 关闭 + 60s 空闲；高档 5min 空闲换连续多图不重加载），
      // 经 ['dir'] 消息进 worker、引擎侧持有空闲计时。
      final tier = await ResourceTier.detect();
      await widget.engine.ensureStarted(dir.path,
          intraThreads: tier.intraThreads,
          useArena: tier.useArena,
          idleRelease: tier.idleRelease);
      widget.logs.info('auto', '色彩方案：$_scheme');
      final out = await widget.engine.colorize(gray, _w, _h, scheme: _scheme,
          onProgress: (p) {
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
      widget.logs.info('auto', 'PNG 编码完成 $w×$h${rssSuffix()}');
      if (!mounted) return;
      setState(() {
        _resultPng = png;
        _status = '完成。可预览或分享。';
      });
      final src = _sourcePng;
      if (src != null) {
        widget.onCompleted?.call(
            resultPng: png, sourcePng: src, width: w, height: h, mode: 'auto');
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

  /// 切换色彩方案：本页即时生效并经全局控制器落盘（同 settings.json 单一真源）。
  void _applyScheme(String id) {
    if (!kFinishSchemes.containsKey(id)) return;
    setState(() => _scheme = id);
    widget.controller
        .update(widget.controller.settings.copyWith(colorScheme: id));
    widget.logs.info('auto', '色彩方案切换为 ${kSchemeLabels[id] ?? id}');
  }

  /// 通用选图（参考图模式路径）：相册原生缩放 + capDecodeRgba 兜底，
  /// 返回 RGBA 与尺寸（与 _pick 的缓冲纪律一致）。
  Future<({Uint8List rgba, int width, int height})?> _pickRgba() async {
    final tier = await ResourceTier.detect();
    final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: tier.maxPickSide.toDouble(),
        maxHeight: tier.maxPickSide.toDouble());
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final cap = await capDecodeRgba(bytes, maxSide: tier.maxPickSide);
    return (rgba: cap.rgba, width: cap.width, height: cap.height);
  }

  /// 参考图模式选原稿：RGBA → RGB（迁移源）+ 灰度（模型输入 + L 来源）
  /// + PNG（预览/入库），串行产出（与 _pick 同款缓冲纪律）。
  Future<void> _pickRefSource() async {
    if (_refBusy) return;
    final picked = await _pickRgba();
    if (!mounted) return;
    if (picked == null) return;
    setState(() {
      _refBusy = true;
      _status = '读取原稿…';
      _refSrcRgb = null;
      _refSrcGray = null;
      _refSrcPng = null;
      _refOutPng = null;
    });
    try {
      final rgb = await Isolate.run(() => rgbaToRgbBytes(picked.rgba));
      final gray = await Isolate.run(() => rgbaToGray(picked.rgba));
      final png =
          await encodePngFromRgba(picked.rgba, picked.width, picked.height);
      if (!mounted) return;
      setState(() {
        _refSrcRgb = rgb;
        _refSrcGray = gray;
        _refSrcW = picked.width;
        _refSrcH = picked.height;
        _refSrcPng = png;
        _status = '原稿 ${picked.width}×${picked.height} 已就绪。';
      });
    } on Object catch (e) {
      if (mounted) setState(() => _status = '读取失败：$e');
    } finally {
      if (mounted) setState(() => _refBusy = false);
    }
  }

  Future<void> _pickReference() async {
    if (_refBusy) return;
    final picked = await _pickRgba();
    if (!mounted) return;
    if (picked == null) return;
    setState(() {
      _refBusy = true;
      _status = '读取参考图…';
      _refRgb = null;
      _refThumbPng = null;
      _refOutPng = null;
    });
    try {
      final rgb = await Isolate.run(() => rgbaToRgbBytes(picked.rgba));
      final png =
          await encodePngFromRgba(picked.rgba, picked.width, picked.height);
      if (!mounted) return;
      setState(() {
        _refRgb = rgb;
        _refThumbPng = png;
        _status = '参考图已就绪。';
      });
    } on Object catch (e) {
      if (mounted) setState(() => _status = '读取失败：$e');
    } finally {
      if (mounted) setState(() => _refBusy = false);
    }
  }

  /// 参考图模式（桌面同款，service.py `_process_reference` 的 Dart 镜像）：
  /// 原稿 + 人设彩图 → 模型语义色 ⊕ 参考图迁移色 Lab a/b 5:5 融合，L 恒取
  /// 原稿灰度。模型部分固定 standard 方案（桌面参考图路径同样写死
  /// DEFAULT_SCHEME，不吃 auto 页的方案选择）。结果以 mode='reference' 入库。
  Future<void> _runReference() async {
    final srcRgb = _refSrcRgb;
    final srcGray = _refSrcGray;
    final ref = _refRgb;
    final dir = _dir;
    if (srcRgb == null || srcGray == null || ref == null || dir == null) return;
    if (_refBusy || _busy) return;
    setState(() {
      _refBusy = true;
      _status = '参考图上色中…';
      _refOutPng = null;
    });
    widget.logs.info(
        'reference',
        '参考图任务开始 $_refSrcW×$_refSrcH method=${_refMethod.name} '
            'strength=$_refStrength${rssSuffix()}');
    try {
      // 线程数/arena 策略随设备分级下发（与全自动同源；引擎常驻复用）。
      final tier = await ResourceTier.detect();
      await widget.engine.ensureStarted(dir.path,
          intraThreads: tier.intraThreads,
          useArena: tier.useArena,
          idleRelease: tier.idleRelease);
      final autoRgb = await widget.engine.colorize(srcGray, _refSrcW, _refSrcH,
          scheme: kDefaultFinishScheme, onProgress: (p) {
        if (!mounted) return;
        setState(() => _status = '模型上色中 ${(p * 100).round()}%');
      });
      if (autoRgb == null) {
        if (mounted) setState(() => _status = '已取消。');
        widget.logs.info('reference', '参考图任务已取消');
        return;
      }
      if (!mounted) return;
      setState(() => _status = '融合参考图色调…');
      final outRgb = await referenceColorizeInIsolate(
          srcRgb: srcRgb,
          refRgb: ref,
          autoRgb: autoRgb,
          srcGray: srcGray,
          method: _refMethod,
          strength: _refStrength);
      if (!mounted) return;
      setState(() => _status = '编码 PNG…');
      final png = await _encodePng(outRgb, _refSrcW, _refSrcH);
      widget.logs
          .info('reference', '参考图上色完成 $_refSrcW×$_refSrcH${rssSuffix()}');
      if (!mounted) return;
      setState(() {
        _refOutPng = png;
        _status = '完成。可预览或分享。';
      });
      final srcPng = _refSrcPng;
      if (srcPng != null) {
        widget.onCompleted?.call(
            resultPng: png,
            sourcePng: srcPng,
            width: _refSrcW,
            height: _refSrcH,
            mode: 'reference');
      }
    } on Object catch (e) {
      if (mounted) setState(() => _status = '参考图上色失败：$e');
      widget.logs.error('reference', '参考图上色失败：$e');
    } finally {
      if (mounted) setState(() => _refBusy = false);
    }
  }

  /// 切换迁移算法：本页即时生效并经全局控制器落盘（同 settings.json 单一真源）。
  void _applyRefMethod(ReferenceMethod m) {
    if (m == _refMethod) return;
    setState(() => _refMethod = m);
    widget.controller
        .update(widget.controller.settings.copyWith(refMethod: m.name));
    widget.logs.info('reference',
        '迁移算法切换为 ${m == ReferenceMethod.histogram ? '分布对齐' : '氛围对齐'}');
  }

  /// 调整迁移强度：本页即时生效并经全局控制器落盘。
  void _applyRefStrength(double v) {
    final clamped = v.clamp(0.0, 1.0);
    setState(() => _refStrength = clamped);
    widget.controller
        .update(widget.controller.settings.copyWith(refStrength: clamped));
  }

  Future<void> _shareRef() async {
    final png = _refOutPng;
    if (png == null) return;
    try {
      final temp = await getTemporaryDirectory();
      final f =
          File('${temp.path}/ref_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png);
      await Share.shareXFiles([XFile(f.path)], text: 'Manga Colorizer 参考图上色结果');
    } on Object catch (e) {
      if (mounted) setState(() => _status = '分享失败：$e');
    }
  }

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
        // 参考图卡片常驻展示（含权重缺失时的下载引导提示）：
        // 与桌面参考图模式同语义，需要模型权重才能运行。
        if (!_checking) ...[
          const SizedBox(height: 16),
          ..._referenceCard(context),
        ],
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
      const SizedBox(height: 8),
      // 色彩方案：随 job 下发推理端收尾（与桌面 FINISH_SCHEMES 同表）。
      DropdownButtonFormField<String>(
        initialValue: _scheme,
        decoration: InputDecoration(
          labelText: '色彩方案',
          hintText: '标准＝修复偏黄偏灰的默认收尾',
          // 圆角填充、无描边无阴影：扁平卡片观感。
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: Theme.of(context).colorScheme.primary, width: 1.5),
          ),
          suffixIcon: _scheme == kDefaultFinishScheme
              ? null
              : IconButton(
                  onPressed:
                      _busy ? null : () => _applyScheme(kDefaultFinishScheme),
                  icon: const Icon(Icons.restart_alt),
                  tooltip: '恢复默认',
                ),
        ),
        items: [
          for (final id in kFinishSchemes.keys)
            DropdownMenuItem(value: id, child: Text(kSchemeLabels[id] ?? id)),
        ],
        onChanged: _busy ? null : (v) => v == null ? null : _applyScheme(v),
      ),
      if (_inferring) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(value: _inferPct),
      ],
      const SizedBox(height: 12),
      if (_sourcePng != null) ...[
        Text('原稿（灰度）', style: Theme.of(context).textTheme.labelSmall),
        // cacheWidth 限纹理：2048² 的 PNG 全尺寸解码一张 16.8MB，预览用
        // 1024 宽足够，两张（原稿+结果）同屏省 ~25MB。
        Image.memory(_sourcePng!,
            fit: BoxFit.contain, cacheWidth: 1024, gaplessPlayback: true),
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
        Image.memory(_resultPng!,
            fit: BoxFit.contain, cacheWidth: 1024, gaplessPlayback: true),
      ],
    ];
  }

  /// 参考图模式卡片（桌面同款，service.py `_process_reference`）：
  /// 原稿（黑白线稿）+ 人设彩图 → 模型语义色 ⊕ 参考图迁移色 Lab 5:5 融合。
  /// 需模型权重；迁移算法与强度随设置持久化（与桌面选项同语义）。
  List<Widget> _referenceCard(BuildContext context) {
    return [
      GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.wallpaper, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('参考图上色',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                  '根据人设彩图对齐上色：模型语义色 + 参考图色调迁移融合'
                  '（Lab 5:5），亮度保真、纸白不染色。',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _refBusy ? null : _pickRefSource,
                    icon: const Icon(Icons.image_outlined),
                    label: Text(_refSrcRgb == null ? '选原稿' : '换原稿'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _refBusy ? null : _pickReference,
                    icon: const Icon(Icons.palette_outlined),
                    label: Text(_refRgb == null ? '选参考图' : '换参考图'),
                  ),
                  FilledButton.icon(
                    onPressed: (_refBusy ||
                            _busy ||
                            _weightsMissing ||
                            _refSrcRgb == null ||
                            _refRgb == null)
                        ? null
                        : _runReference,
                    icon: const Icon(Icons.colorize),
                    label: const Text('开始上色'),
                  ),
                  if (_refThumbPng != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(_refThumbPng!,
                          width: 44, height: 44, fit: BoxFit.cover),
                    ),
                ],
              ),
              if (_weightsMissing) ...[
                const SizedBox(height: 8),
                Text('需要先下载模型权重（见上方引导）——参考图上色由模型提供语义色。',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 4),
              // 迁移算法（与桌面 ref-method 同选项，随设置持久化）
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('氛围对齐'),
                    selected: _refMethod == ReferenceMethod.reinhard,
                    onSelected: (_) =>
                        _applyRefMethod(ReferenceMethod.reinhard),
                  ),
                  ChoiceChip(
                    label: const Text('分布对齐'),
                    selected: _refMethod == ReferenceMethod.histogram,
                    onSelected: (_) =>
                        _applyRefMethod(ReferenceMethod.histogram),
                  ),
                ],
              ),
              // 迁移强度（与桌面 ref-strength 同语义，5% 步进）
              Row(
                children: [
                  Text('迁移强度', style: Theme.of(context).textTheme.bodySmall),
                  Expanded(
                    child: Slider(
                      value: _refStrength,
                      min: 0,
                      max: 1,
                      divisions: 20,
                      label: '${(_refStrength * 100).round()}%',
                      onChanged: _refBusy ? null : _applyRefStrength,
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text('${(_refStrength * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
              if (_refBusy) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (_refOutPng != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text('上色结果',
                          style: Theme.of(context).textTheme.labelSmall),
                    ),
                    IconButton(
                      onPressed: _shareRef,
                      icon: const Icon(Icons.ios_share),
                      tooltip: '分享 / 保存',
                    ),
                  ],
                ),
                Image.memory(_refOutPng!,
                    fit: BoxFit.contain,
                    cacheWidth: 1024,
                    gaplessPlayback: true),
              ],
            ],
          ),
      ),
    ];
  }
}
