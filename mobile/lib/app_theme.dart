// 主题层：暖纸设计系统（Anthropic 暖纸美学 × 苹果液态玻璃 × 莫奈流动背景）
// 的装配入口。与桌面端 web/dist 设计系统同值同构：
//   - 固定暖调中性色（画布/浮层/边框/文字），预设只换强调色族；
//   - 衬线标题 / 无衬线正文（行高 1.6）/ 等宽数据三栈字体；
//   - 玻璃令牌与莫奈色球经 ThemeExtension（WarmPalette）下发。
//
// [ThemePreset.dynamic]（跟随设备取色 / Material You）由 dynamic_color 包的
// DynamicColorBuilder 提供设备调色板，经 [buildDynamicTheme] 套回暖纸中性底；
// 不支持或未授权时回退赤陶暖纸（kDynamicFallbackAccent）。
import 'package:flutter/material.dart';

import 'theme/warm_tokens.dart';

/// 明暗模式。
enum AppThemeMode { system, light, dark }

extension AppThemeModeX on AppThemeMode {
  ThemeMode get themeMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };
}

/// 配色预设：六个暖色族 + dynamic（跟随设备取色）。
/// 旧预设（墨绿/蓝/紫/橙/粉/青）随设计系统切换整体移除——
/// 新体系全域暖调，杜绝冷调科技蓝灰；settings.json 里的旧值会经
/// AppSettings._enumFrom 白名单回退到默认（赤陶），不影响加载。
enum ThemePreset { terracotta, sage, sand, clay, rose, amber, dynamic }

/// dynamic 不可用时的回退强调色：赤陶（默认预设）。
const WarmAccent kDynamicFallbackAccent = kTerracottaAccent;

const Map<ThemePreset, WarmAccent> kPresetAccents = {
  ThemePreset.terracotta: kTerracottaAccent,
  ThemePreset.sage: kSageAccent,
  ThemePreset.sand: kSandAccent,
  ThemePreset.clay: kClayAccent,
  ThemePreset.rose: kRoseAccent,
  ThemePreset.amber: kAmberAccent,
};

String themePresetLabel(ThemePreset p) => switch (p) {
      ThemePreset.terracotta => '赤陶',
      ThemePreset.sage => '鼠尾草',
      ThemePreset.sand => '砂金',
      ThemePreset.clay => '陶土',
      ThemePreset.rose => '玫瑰',
      ThemePreset.amber => '琥珀',
      ThemePreset.dynamic => '跟随系统',
    };

/// 设置页预设圆点的预览色（dynamic 无固定色，由调用方用图标表示）。
const Map<ThemePreset, Color> kPresetPreview = {
  ThemePreset.terracotta: kTerracotta,
  ThemePreset.sage: Color(0xFF7C8F6A),
  ThemePreset.sand: Color(0xFFB08F4F),
  ThemePreset.clay: Color(0xFFB05A44),
  ThemePreset.rose: Color(0xFFBC5F76),
  ThemePreset.amber: Color(0xFFA8620A),
};

// ---------- 中性色（明暗两套，不随预设变化） ----------

const Color _lightSecondary = Color(0xFF6D685B);
const Color _lightOnSecondary = Color(0xFFFAF9F5);
const Color _lightSecondaryContainer = Color(0xFFEAE6D9);
const Color _lightOnSecondaryContainer = Color(0xFF3A372D);
const Color _lightTertiary = Color(0xFFA8620A); // 琥珀加深档（小字号可读）
const Color _lightTertiaryContainer = Color(0xFFF7EAD2);
const Color _lightOnTertiaryContainer = Color(0xFF6B3D04);
const Color _lightOnError = Color(0xFFFFFFFF);
const Color _lightErrorContainer = Color(0xFFF6E2DE);
const Color _lightOnErrorContainer = Color(0xFF571313);
const Color _lightOutline = Color(0xFFA39D8B);

const Color _darkSecondary = Color(0xFFA8A397);
const Color _darkOnSecondary = Color(0xFF2B2822);
const Color _darkSecondaryContainer = Color(0xFF34322A);
const Color _darkOnSecondaryContainer = Color(0xFFE5E1D2);
const Color _darkTertiary = Color(0xFFE0912F);
const Color _darkTertiaryContainer = Color(0xFF43310F);
const Color _darkOnTertiaryContainer = Color(0xFFF3CD93);
const Color _darkOnError = Color(0xFF3A1410);
const Color _darkErrorContainer = Color(0xFF47201A);
const Color _darkOnErrorContainer = Color(0xFFF3B8A9);
const Color _darkOutline = Color(0xFF7C7A6E);

/// 由预设 + 明暗构建主题（[preset] 为 dynamic 时即取回退赤陶）。
ThemeData buildAppTheme(ThemePreset preset, Brightness brightness) {
  final accent = preset == ThemePreset.dynamic
      ? kDynamicFallbackAccent
      : kPresetAccents[preset] ?? kDynamicFallbackAccent;
  return _finalize(_warmScheme(accent, brightness), brightness);
}

/// Material You 分支：保留设备主色族，套回暖纸中性底、字体与组件主题，
/// 保证「跟随系统」也只在家具上跟随，墙纸（画布/浮层）恒为暖纸。
ThemeData buildDynamicTheme(ColorScheme deviceScheme, Brightness brightness) =>
    _finalize(applyWarmNeutrals(deviceScheme, brightness), brightness);

/// 把设备调色板的中性角色统一替换为暖纸值（保留其 primary 一家）。
ColorScheme applyWarmNeutrals(ColorScheme scheme, Brightness b) =>
    scheme.copyWith(
      secondary: b == Brightness.light ? _lightSecondary : _darkSecondary,
      onSecondary: b == Brightness.light ? _lightOnSecondary : _darkOnSecondary,
      secondaryContainer: b == Brightness.light
          ? _lightSecondaryContainer
          : _darkSecondaryContainer,
      onSecondaryContainer: b == Brightness.light
          ? _lightOnSecondaryContainer
          : _darkOnSecondaryContainer,
      tertiary: b == Brightness.light ? _lightTertiary : _darkTertiary,
      tertiaryContainer: b == Brightness.light
          ? _lightTertiaryContainer
          : _darkTertiaryContainer,
      onTertiaryContainer: b == Brightness.light
          ? _lightOnTertiaryContainer
          : _darkOnTertiaryContainer,
      error: b == Brightness.light ? kBrick : kBrickDark,
      errorContainer:
          b == Brightness.light ? _lightErrorContainer : _darkErrorContainer,
      onErrorContainer: b == Brightness.light
          ? _lightOnErrorContainer
          : _darkOnErrorContainer,
      surface: b == Brightness.light ? kParchment : kCanvasDark,
      surfaceDim: b == Brightness.light
          ? const Color(0xFFE6E2D3)
          : const Color(0xFF100F0E),
      surfaceBright: b == Brightness.light ? kIvory : const Color(0xFF2A2A28),
      surfaceContainerLowest: b == Brightness.light
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF0C0C0B),
      surfaceContainerLow: b == Brightness.light
          ? const Color(0xFFF7F4EB)
          : const Color(0xFF1B1B19),
      surfaceContainer: b == Brightness.light ? kIvory : kSurfaceDark,
      surfaceContainerHigh: b == Brightness.light
          ? const Color(0xFFF4F1E8)
          : const Color(0xFF2E2E2B),
      surfaceContainerHighest: b == Brightness.light
          ? const Color(0xFFEEE9DC)
          : const Color(0xFF383834),
      onSurface: b == Brightness.light ? kInk : kInkDark,
      onSurfaceVariant: b == Brightness.light ? kInkSoft : kInkSoftDark,
      outline: b == Brightness.light ? _lightOutline : _darkOutline,
      outlineVariant: b == Brightness.light ? kCreamLine : kLineDark,
      shadow: b == Brightness.light
          ? const Color(0xFF54422C)
          : const Color(0xFF000000),
      scrim: b == Brightness.light
          ? const Color(0xFF1C1812)
          : const Color(0xFF000000),
      inverseSurface: b == Brightness.light ? kInk : kInkDark,
      inverseOnSurface: b == Brightness.light
          ? const Color(0xFFF5F2E8)
          : const Color(0xFF232220),
    );

/// 预设强调色族 + 暖纸中性色 → 完整 ColorScheme。
ColorScheme _warmScheme(WarmAccent accent, Brightness b) {
  final base = ColorScheme.fromSeed(
    seedColor: b == Brightness.light ? accent.primary : accent.primaryDark,
    brightness: b,
  );
  return applyWarmNeutrals(base, b).copyWith(
    primary: b == Brightness.light ? accent.primary : accent.primaryDark,
    onPrimary: b == Brightness.light ? accent.onPrimary : accent.onPrimaryDark,
    primaryContainer: b == Brightness.light
        ? accent.primaryContainer
        : accent.primaryContainerDark,
    onPrimaryContainer: b == Brightness.light
        ? accent.onPrimaryContainer
        : accent.onPrimaryContainerDark,
    error: b == Brightness.light ? kBrick : kBrickDark,
    onError: b == Brightness.light ? _lightOnError : _darkOnError,
  );
}

/// 统一装配：令牌 + 字体 + 组件主题。两条构建路径（固定预设 / Material You）
/// 都必须经这里，保证外观完全一致。
ThemeData _finalize(ColorScheme scheme, Brightness b) {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: b,
  );
  return base.copyWith(
    // 画布透明：露出 MaterialApp.builder 里垫底的莫奈流动背景。
    scaffoldBackgroundColor: Colors.transparent,
    extensions: [
      b == Brightness.light
          ? const WarmPalette.light()
          : const WarmPalette.dark(),
    ],
    textTheme: _warmTextTheme(base.textTheme),
    // AppBar / 导航栏由玻璃组件（GlassAppBar / GlassBottomBar）接管外观，
    // 这里只关掉 Material 自带的底色与 elevation 色渍，避免双重底色。
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.secondaryContainer,
    ),
    cardTheme: CardTheme(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.inverseOnSurface,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
    ),
  );
}

/// 三栈字体：标题（大标题与卡片标题）衬线 500 书扉页感；正文无衬线行高 1.6；
/// 标签与正文保持无衬线。等宽字体由各数据位（日志时间等）显式指定。
TextTheme _warmTextTheme(TextTheme base) => base.copyWith(
      displayLarge: _serif(base.displayLarge),
      displayMedium: _serif(base.displayMedium),
      displaySmall: _serif(base.displaySmall),
      headlineLarge: _serif(base.headlineLarge),
      headlineMedium: _serif(base.headlineMedium),
      headlineSmall: _serif(base.headlineSmall),
      titleLarge: _serif(base.titleLarge),
      titleMedium: _serif(base.titleMedium),
      titleSmall: _serif(base.titleSmall),
      bodyLarge: _body(base.bodyLarge),
      bodyMedium: _body(base.bodyMedium),
      bodySmall: _body(base.bodySmall),
    );

TextStyle? _serif(TextStyle? s) => s?.copyWith(
      fontFamily: kSerifFamily,
      fontFamilyFallback: kSerifFallback,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      height: 1.3,
    );

TextStyle? _body(TextStyle? s) => s?.copyWith(height: 1.6);
