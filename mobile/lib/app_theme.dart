// 主题层：配色预设 + 明暗模式。App 根据此构建 MaterialApp 的 theme/darkTheme，
// MaterialApp 会按 themeMode/平台亮度自行选用明或暗。
//
// [ThemePreset.dynamic]（跟随设备取色 / Material You）由 dynamic_color 包的
// DynamicColorBuilder 提供设备调色板；不支持或未授权时回退 [kDynamicFallbackSeed]。
import 'package:flutter/material.dart';

/// 明暗模式。
enum AppThemeMode { system, light, dark }

/// 配色预设。[dynamic] ＝跟随设备取色；其余为固定种子色。
enum ThemePreset { dynamic, green, blue, purple, orange, pink, cyan }

extension AppThemeModeX on AppThemeMode {
  ThemeMode get themeMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };
}

/// 各预设的种子色；[ThemePreset.dynamic] 用 [kDynamicFallbackSeed] 作不可用回退。
const Color kDynamicFallbackSeed = Color(0xFF2F6D5E);

const Map<ThemePreset, Color> kPresetSeeds = {
  ThemePreset.dynamic: kDynamicFallbackSeed,
  ThemePreset.green: Color(0xFF2F6D5E),
  ThemePreset.blue: Color(0xFF1E88E5),
  ThemePreset.purple: Color(0xFF8E24AA),
  ThemePreset.orange: Color(0xFFEF6C00),
  ThemePreset.pink: Color(0xFFD81B60),
  ThemePreset.cyan: Color(0xFF00838F),
};

String themePresetLabel(ThemePreset p) => switch (p) {
      ThemePreset.dynamic => '跟随系统',
      ThemePreset.green => '墨绿',
      ThemePreset.blue => '蓝',
      ThemePreset.purple => '紫',
      ThemePreset.orange => '橙',
      ThemePreset.pink => '粉',
      ThemePreset.cyan => '青',
    };

/// 由固定预设 + 明暗构建主题（[preset] 为 dynamic 时即取回退墨绿）。
ThemeData buildAppTheme(ThemePreset preset, Brightness brightness) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: kPresetSeeds[preset] ?? kDynamicFallbackSeed,
        brightness: brightness,
      ),
    );
