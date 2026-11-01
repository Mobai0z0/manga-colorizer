// 应用级设置的内存模型 + 磁盘持久化 + 变更广播。
//
// 单一真源：下载源与主题都存在同一个 [AppSettings]，经 [SettingsController] 统一
// 读写，避免多处各写各的 settings.json 互相覆盖。落盘在应用私有目录的
// settings.json，读失败一律回退默认值（损坏/缺失不阻塞启动）。
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'app_theme.dart';
import 'onnx/weights.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart'
    show isValidFinishScheme, kDefaultFinishScheme;

/// 背景样式（设置页可选）：莫奈流动背景（默认，三球漫游）或纯色画布
/// （低端机/省电可关，省去三层近全屏渐变逐帧重绘的 GPU 负担）。
enum BackgroundStyle { plain, monet }

/// 全自动模式推理后端（设置页可选）：
/// auto = MNN 权重就绪则用 MNN（mmap 低内存），否则 ONNX Runtime（默认行为）；
/// ort = 固定 ONNX Runtime；mnn = 固定 MNN（需先下载 MNN 权重）。
/// 切换在下一次引擎启动时生效（重新进入全自动页即可）。
enum InferenceBackend { auto, ort, mnn }

class AppSettings {
  const AppSettings({
    this.downloadSource = DownloadSource.auto,
    this.themeMode = AppThemeMode.system,
    this.themePreset = ThemePreset.terracotta,
    this.colorScheme = kDefaultFinishScheme,
    this.refMethod = 'reinhard',
    this.refStrength = 1.0,
    this.customHintColors = const [],
    this.backgroundStyle = BackgroundStyle.monet,
    this.inferenceBackend = InferenceBackend.auto,
  });

  /// 权重下载源，见 [DownloadSource]。默认自动（主站优先、失败回退镜像）。
  final DownloadSource downloadSource;

  /// 明暗模式，默认跟随系统。
  final AppThemeMode themeMode;

  /// 配色预设，默认赤陶（暖纸设计系统）。
  final ThemePreset themePreset;

  /// 全自动色彩收尾方案 id（kFinishSchemes 的 key），默认 standard。
  final String colorScheme;

  /// 参考图模式迁移算法 id：'reinhard'（氛围对齐）/ 'histogram'（分布对齐），
  /// 默认 reinhard（与桌面 ref_method 默认一致）。
  final String refMethod;

  /// 参考图模式迁移强度 [0,1]（0=原样, 1=完全迁移），默认 1.0（与桌面
  /// ref_strength 默认一致）。
  final double refStrength;

  /// 上色页最近的自定义提示点颜色（不透明 ARGB int，最近在前、去重、上限
  /// 8）：工具栏「+」取色后落这里，跨会话复用。空 = 尚未用过自定义色。
  final List<int> customHintColors;

  /// 背景样式：莫奈流动（默认）或纯色画布，见 [BackgroundStyle]。
  final BackgroundStyle backgroundStyle;

  /// 全自动推理后端，见 [InferenceBackend]。默认 auto。
  final InferenceBackend inferenceBackend;

  static const _fileName = 'settings.json';

  static AppSettings defaults() => const AppSettings();

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.downloadSource == downloadSource &&
      other.themeMode == themeMode &&
      other.themePreset == themePreset &&
      other.colorScheme == colorScheme &&
      other.refMethod == refMethod &&
      other.refStrength == refStrength &&
      listEquals(other.customHintColors, customHintColors) &&
      other.backgroundStyle == backgroundStyle &&
      other.inferenceBackend == inferenceBackend;

  @override
  int get hashCode => Object.hash(
      downloadSource,
      themeMode,
      themePreset,
      colorScheme,
      refMethod,
      refStrength,
      backgroundStyle,
      inferenceBackend,
      Object.hashAll(customHintColors));

  AppSettings copyWith({
    DownloadSource? downloadSource,
    AppThemeMode? themeMode,
    ThemePreset? themePreset,
    String? colorScheme,
    String? refMethod,
    double? refStrength,
    List<int>? customHintColors,
    BackgroundStyle? backgroundStyle,
    InferenceBackend? inferenceBackend,
  }) =>
      AppSettings(
        downloadSource: downloadSource ?? this.downloadSource,
        themeMode: themeMode ?? this.themeMode,
        themePreset: themePreset ?? this.themePreset,
        colorScheme: colorScheme ?? this.colorScheme,
        refMethod: refMethod ?? this.refMethod,
        refStrength: refStrength ?? this.refStrength,
        customHintColors: customHintColors ?? this.customHintColors,
        backgroundStyle: backgroundStyle ?? this.backgroundStyle,
        inferenceBackend: inferenceBackend ?? this.inferenceBackend,
      );

  Map<String, Object?> toJson() => {
        'downloadSource': downloadSource.name,
        'themeMode': themeMode.name,
        'themePreset': themePreset.name,
        'colorScheme': colorScheme,
        'refMethod': refMethod,
        'refStrength': refStrength,
        'customHintColors': customHintColors,
        'backgroundStyle': backgroundStyle.name,
        'inferenceBackend': inferenceBackend.name,
      };

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
        downloadSource: _enumFrom(
            json['downloadSource'], DownloadSource.values, DownloadSource.auto),
        themeMode: _enumFrom(
            json['themeMode'], AppThemeMode.values, AppThemeMode.system),
        themePreset: _enumFrom(
            json['themePreset'], ThemePreset.values, ThemePreset.dynamic),
        colorScheme: _schemeFrom(json['colorScheme']),
        refMethod: _refMethodFrom(json['refMethod']),
        refStrength: _refStrengthFrom(json['refStrength']),
        customHintColors: _hintColorsFrom(json['customHintColors']),
        backgroundStyle: _enumFrom(json['backgroundStyle'],
            BackgroundStyle.values, BackgroundStyle.monet),
        inferenceBackend: _enumFrom(json['inferenceBackend'],
            InferenceBackend.values, InferenceBackend.auto),
      );

  /// 方案 id 白名单校验：未知值（旧版本/损坏）回退默认。
  static String _schemeFrom(Object? raw) =>
      raw is String && isValidFinishScheme(raw) ? raw : kDefaultFinishScheme;

  /// 迁移算法 id 白名单校验：未知值回退 reinhard。
  static String _refMethodFrom(Object? raw) =>
      raw is String && (raw == 'reinhard' || raw == 'histogram')
          ? raw
          : 'reinhard';

  /// 迁移强度钳制到 [0,1]：非数值/越界（旧版本/损坏）回退默认 1.0。
  static double _refStrengthFrom(Object? raw) =>
      raw is num ? raw.toDouble().clamp(0.0, 1.0) : 1.0;

  /// 自定义提示点颜色白名单化：仅收 32bit 整数并强制不透明（取色器只产
  /// 不透明色，脏数据带 alpha 会刷成半透明块），去重保持最近在前，上限 8。
  static List<int> _hintColorsFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <int>[];
    for (final v in raw) {
      if (v is! int || v < 0 || v > 0xFFFFFFFF) continue;
      final argb = 0xFF000000 | (v & 0xFFFFFF);
      if (!out.contains(argb)) out.add(argb);
      if (out.length >= 8) break;
    }
    return out;
  }

  static T _enumFrom<T extends Enum>(Object? raw, List<T> values, T fallback) {
    if (raw is String) {
      for (final v in values) {
        if (v.name == raw) return v;
      }
    }
    return fallback;
  }

  static File _file(Directory base) =>
      File('${base.path}${Platform.pathSeparator}$_fileName');

  /// 从 [base] 目录读取设置；文件不存在或解析失败时返回 [defaults]。
  static AppSettings load(Directory base) {
    try {
      final f = _file(base);
      if (!f.existsSync()) return defaults();
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, Object?>) return AppSettings.fromJson(decoded);
      return defaults();
    } on Object {
      return defaults();
    }
  }

  /// 同步写盘：设置体积极小，同步写避免异步在快速切换/测试路径上引入时序不确定。
  /// 写失败静默降级（本次会话内的内存值仍有效）。
  void saveSync(Directory base) {
    try {
      base.createSync(recursive: true);
      _file(base).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(toJson()));
    } on Object {
      // 目录/存储异常不影响本次会话的选择。
    }
  }
}

/// 设置控制器：持有当前 [AppSettings]，变更即广播并（在给定 [base] 时）落盘。
/// App 根与设置面板共享同一实例，作为唯一真源。
class SettingsController extends ChangeNotifier {
  SettingsController(this._settings, {Directory? base}) : _base = base;

  AppSettings _settings;
  Directory? _base;

  AppSettings get settings => _settings;

  /// 启动异步解析到设置目录后注入（此前变更只存内存，不落盘）。
  void attachBase(Directory base) => _base = base;

  void update(AppSettings next) {
    if (next == _settings) return;
    _settings = next;
    final b = _base;
    if (b != null) next.saveSync(b);
    notifyListeners();
  }
}
