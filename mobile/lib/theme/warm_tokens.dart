// 暖纸设计令牌：与桌面端 web/dist 设计系统（app.css）同值同构。
// 色彩全域暖调中性——羊皮纸画布 / 象牙白浮层 / 赤陶红主色 / 琥珀口诀 /
// 暖红避坑，严格杜绝冷调科技蓝灰；深色为 Anthropic 暖黑
// （#141413 画布 / #252523 浮层 / #30302e 边框）。
//
// 本文件只放「值」与 ThemeExtension 载体，不放组件；组件见 glass.dart 与
// monet_background.dart，装配见 app_theme.dart。
import 'package:flutter/material.dart';

/// 浅色暖纸令牌。
const Color kParchment = Color(0xFFF4F2EC); // 画布（羊皮纸，近白暖调杜绝黄感）
const Color kIvory = Color(0xFFFAF9F5); // 浮层（象牙白）
const Color kInk = Color(0xFF2B2822); // 主文字
const Color kInkSoft = Color(0xFF6D685B); // 次文字
const Color kCreamLine = Color(0xFFE2DED0); // 极细暖奶油边框
const Color kTerracotta = Color(0xFFD97757); // 品牌主色（赤陶红）
const Color kTerracottaStrong = Color(0xFFB0573A); // 小字号文本强调
const Color kAmber = Color(0xFFD97706); // 速记口诀（琥珀黄）
const Color kBrick = Color(0xFFB53333); // 避坑 / 错误（暖红）

/// 深色暖纸令牌。
const Color kCanvasDark = Color(0xFF141413);
const Color kSurfaceDark = Color(0xFF252523);
const Color kLineDark = Color(0xFF30302E);
const Color kInkDark = Color(0xFFF0EEE6);
const Color kInkSoftDark = Color(0xFFA8A397);
const Color kTerracottaStrongDark = Color(0xFFE89A7E);

/// 莫奈流动背景三色球（低饱和，与 web 同值）：赤陶 / 鼠尾草 / 暖砂金。
/// 三色统一改浅去饱和——浅色画布已近白，色球只需极淡的呼吸晕染，
/// 浓度过高会叠加出“屎黄”（用户 2026-10-16 两轮反馈后的定值）。
const Color kMonetTerracotta = Color(0xFFD2A493);
const Color kMonetSage = Color(0xFFA3B099);
const Color kMonetSand = Color(0xFFD2C5A8);

/// 衬线 / 等宽字体族：Android 走系统别名（serif→Noto Serif，含 CJK 宋族；
/// monospace→Droid Sans Mono），Apple 平台分别映射到 Times 宋族 / Menlo。
/// 回退链覆盖桌面浏览器宿主（Tauri WebView 不在本文件职责内）。
const String kSerifFamily = 'serif';
const String kMonoFamily = 'monospace';
const List<String> kSerifFallback = ['Georgia', 'Songti SC', 'SimSun'];

/// 配色预设的强调色族：primary 一家四件 × 明暗两套。
/// 中性色（画布/浮层/边框/文字）不随预设变化——换预设只换「口红」，
/// 不换「纸张」，保证暖纸底子恒定。
class WarmAccent {
  const WarmAccent({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.primaryDark,
    required this.onPrimaryDark,
    required this.primaryContainerDark,
    required this.onPrimaryContainerDark,
  });

  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color primaryDark;
  final Color onPrimaryDark;
  final Color primaryContainerDark;
  final Color onPrimaryContainerDark;
}

/// 六个暖色族预设（与桌面端色板同审美）。
const WarmAccent kTerracottaAccent = WarmAccent(
  primary: Color(0xFFD97757),
  onPrimary: Color(0xFF221D17),
  primaryContainer: Color(0xFFF7E7DD),
  onPrimaryContainer: Color(0xFF7E3A24),
  primaryDark: Color(0xFFD97757),
  onPrimaryDark: Color(0xFF1D1A16),
  primaryContainerDark: Color(0xFF4A2B1E),
  onPrimaryContainerDark: Color(0xFFF4C3AC),
);
const WarmAccent kSageAccent = WarmAccent(
  primary: Color(0xFF7C8F6A),
  onPrimary: Color(0xFF1F2418),
  primaryContainer: Color(0xFFE9EDDF),
  onPrimaryContainer: Color(0xFF3F4A33),
  primaryDark: Color(0xFFA3B591),
  onPrimaryDark: Color(0xFF22281C),
  primaryContainerDark: Color(0xFF37422E),
  onPrimaryContainerDark: Color(0xFFDCE5CF),
);
const WarmAccent kSandAccent = WarmAccent(
  primary: Color(0xFFB08F4F),
  onPrimary: Color(0xFF241D0E),
  primaryContainer: Color(0xFFF3EAD3),
  onPrimaryContainer: Color(0xFF57451E),
  primaryDark: Color(0xFFC9AC72),
  onPrimaryDark: Color(0xFF26200F),
  primaryContainerDark: Color(0xFF453A22),
  onPrimaryContainerDark: Color(0xFFEBD9B4),
);
const WarmAccent kClayAccent = WarmAccent(
  primary: Color(0xFFB05A44),
  onPrimary: Color(0xFF26140D),
  primaryContainer: Color(0xFFF6E3DC),
  onPrimaryContainer: Color(0xFF5E2A1B),
  primaryDark: Color(0xFFD08A72),
  onPrimaryDark: Color(0xFF27150C),
  primaryContainerDark: Color(0xFF4E2E22),
  onPrimaryContainerDark: Color(0xFFF2C9B8),
);
const WarmAccent kRoseAccent = WarmAccent(
  primary: Color(0xFFBC5F76),
  onPrimary: Color(0xFF2A1220),
  primaryContainer: Color(0xFFF7E4E9),
  onPrimaryContainer: Color(0xFF5C2B3B),
  primaryDark: Color(0xFFD98BA0),
  onPrimaryDark: Color(0xFF2C1420),
  primaryContainerDark: Color(0xFF4E2C38),
  onPrimaryContainerDark: Color(0xFFF5CBD8),
);
const WarmAccent kAmberAccent = WarmAccent(
  primary: Color(0xFFA8620A),
  onPrimary: Color(0xFF221D17),
  primaryContainer: Color(0xFFF7EAD2),
  onPrimaryContainer: Color(0xFF6B3D04),
  primaryDark: Color(0xFFE0912F),
  onPrimaryDark: Color(0xFF1D1A16),
  primaryContainerDark: Color(0xFF43310F),
  onPrimaryContainerDark: Color(0xFFF3CD93),
);

/// 主题扩展：ColorScheme 装不下的设计令牌（玻璃质感、莫奈色球、
/// 文本强调色）。经 Theme.of(context).extension<WarmPalette>() 取用。
@immutable
class WarmPalette extends ThemeExtension<WarmPalette> {
  const WarmPalette({
    required this.brightness,
    required this.primaryStrong,
    required this.glassTint,
    required this.glassBorder,
    required this.glassBevel,
    required this.monetTerracotta,
    required this.monetSage,
    required this.monetSand,
    required this.monetOpacity,
  });

  /// 浅色玻璃（半透明白内衬 72% + 高光边框 50% + 顶部内发光 65%）。
  const WarmPalette.light()
      : this(
          brightness: Brightness.light,
          primaryStrong: kTerracottaStrong,
          glassTint: Color(0xB8FFFFFF),
          glassBorder: Color(0x80FFFFFF),
          glassBevel: Color(0xA6FFFFFF),
          monetTerracotta: kMonetTerracotta,
          monetSage: kMonetSage,
          monetSand: kMonetSand,
          monetOpacity: 0.24,
        );

  /// 深色玻璃（暖黑内衬 72% + 高光边框 9% + 顶部内发光 8%）。
  const WarmPalette.dark()
      : this(
          brightness: Brightness.dark,
          primaryStrong: kTerracottaStrongDark,
          glassTint: Color(0xB8252525),
          glassBorder: Color(0x17FFFFFF),
          glassBevel: Color(0x14FFFFFF),
          monetTerracotta: kMonetTerracotta,
          monetSage: kMonetSage,
          monetSand: kMonetSand,
          monetOpacity: 0.34,
        );

  final Brightness brightness;

  /// 小字号文本强调色（链接 / 日志 INFO / 空态提示）：赤陶加深一档，
  /// 保证羊皮纸上的对比度。
  final Color primaryStrong;

  /// 液态玻璃三件套：半透明内衬 / 高光边框 / 内发光倒角。
  final Color glassTint;
  final Color glassBorder;
  final Color glassBevel;

  /// 莫奈三色球与浓度。
  final Color monetTerracotta;
  final Color monetSage;
  final Color monetSand;
  final double monetOpacity;

  static WarmPalette of(BuildContext context) {
    final p = Theme.of(context).extension<WarmPalette>();
    assert(p != null, 'WarmPalette 未注册：检查 MaterialApp theme 的 extensions');
    return p ??
        (Theme.of(context).brightness == Brightness.dark
            ? const WarmPalette.dark()
            : const WarmPalette.light());
  }

  @override
  WarmPalette copyWith({
    Brightness? brightness,
    Color? primaryStrong,
    Color? glassTint,
    Color? glassBorder,
    Color? glassBevel,
    Color? monetTerracotta,
    Color? monetSage,
    Color? monetSand,
    double? monetOpacity,
  }) =>
      WarmPalette(
        brightness: brightness ?? this.brightness,
        primaryStrong: primaryStrong ?? this.primaryStrong,
        glassTint: glassTint ?? this.glassTint,
        glassBorder: glassBorder ?? this.glassBorder,
        glassBevel: glassBevel ?? this.glassBevel,
        monetTerracotta: monetTerracotta ?? this.monetTerracotta,
        monetSage: monetSage ?? this.monetSage,
        monetSand: monetSand ?? this.monetSand,
        monetOpacity: monetOpacity ?? this.monetOpacity,
      );

  @override
  WarmPalette lerp(ThemeExtension<WarmPalette>? other, double t) {
    if (other is! WarmPalette) return this;
    return WarmPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      primaryStrong: Color.lerp(primaryStrong, other.primaryStrong, t)!,
      glassTint: Color.lerp(glassTint, other.glassTint, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassBevel: Color.lerp(glassBevel, other.glassBevel, t)!,
      monetTerracotta: Color.lerp(monetTerracotta, other.monetTerracotta, t)!,
      monetSage: Color.lerp(monetSage, other.monetSage, t)!,
      monetSand: Color.lerp(monetSand, other.monetSand, t)!,
      monetOpacity: monetOpacity + (other.monetOpacity - monetOpacity) * t,
    );
  }
}
