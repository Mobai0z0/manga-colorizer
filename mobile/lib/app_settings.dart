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

class AppSettings {
  const AppSettings({
    this.downloadSource = DownloadSource.auto,
    this.themeMode = AppThemeMode.system,
    this.themePreset = ThemePreset.dynamic,
    this.colorScheme = kDefaultFinishScheme,
    this.refMethod = 'reinhard',
    this.refStrength = 1.0,
  });

  /// 权重下载源，见 [DownloadSource]。默认自动（主站优先、失败回退镜像）。
  final DownloadSource downloadSource;

  /// 明暗模式，默认跟随系统。
  final AppThemeMode themeMode;

  /// 配色预设，默认墨绿。
  final ThemePreset themePreset;

  /// 全自动色彩收尾方案 id（kFinishSchemes 的 key），默认 standard。
  final String colorScheme;

  /// 参考图模式迁移算法 id：'reinhard'（氛围对齐）/ 'histogram'（分布对齐），
  /// 默认 reinhard（与桌面 ref_method 默认一致）。
  final String refMethod;

  /// 参考图模式迁移强度 [0,1]（0=原样, 1=完全迁移），默认 1.0（与桌面
  /// ref_strength 默认一致）。
  final double refStrength;

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
      other.refStrength == refStrength;

  @override
  int get hashCode => Object.hash(downloadSource, themeMode, themePreset,
      colorScheme, refMethod, refStrength);

  AppSettings copyWith({
    DownloadSource? downloadSource,
    AppThemeMode? themeMode,
    ThemePreset? themePreset,
    String? colorScheme,
    String? refMethod,
    double? refStrength,
  }) =>
      AppSettings(
        downloadSource: downloadSource ?? this.downloadSource,
        themeMode: themeMode ?? this.themeMode,
        themePreset: themePreset ?? this.themePreset,
        colorScheme: colorScheme ?? this.colorScheme,
        refMethod: refMethod ?? this.refMethod,
        refStrength: refStrength ?? this.refStrength,
      );

  Map<String, Object?> toJson() => {
        'downloadSource': downloadSource.name,
        'themeMode': themeMode.name,
        'themePreset': themePreset.name,
        'colorScheme': colorScheme,
        'refMethod': refMethod,
        'refStrength': refStrength,
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
