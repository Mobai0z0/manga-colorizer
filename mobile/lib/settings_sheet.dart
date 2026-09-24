// 设置面板（模态底部弹层）：明暗模式 + 配色预设。直接读写 [SettingsController]，
// 选择即时生效并落盘。后续 E 的完整设置页会收编本面板。
import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'app_theme.dart';

Future<void> showAppSettings(BuildContext context, SettingsController controller) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListenableBuilder(
        listenable: controller,
        builder: (ctx, _) => _SettingsBody(controller: controller),
      ),
    );

class _SettingsBody extends StatelessWidget {
  const _SettingsBody({required this.controller});
  final SettingsController controller;

  void _set(AppSettings next) => controller.update(next);

  @override
  Widget build(BuildContext context) {
    final s = controller.settings;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('设置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('主题模式', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<AppThemeMode>(
              segments: const [
                ButtonSegment(
                    value: AppThemeMode.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('跟随系统')),
                ButtonSegment(
                    value: AppThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('浅色')),
                ButtonSegment(
                    value: AppThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('深色')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (sel) =>
                  _set(s.copyWith(themeMode: sel.first)),
            ),
            const SizedBox(height: 20),
            Text('配色主题', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final p in ThemePreset.values)
                  _PresetChip(
                    preset: p,
                    selected: s.themePreset == p,
                    onTap: () => _set(s.copyWith(themePreset: p)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip(
      {required this.preset, required this.selected, required this.onTap});
  final ThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDynamic = preset == ThemePreset.dynamic;
    final seed = kPresetSeeds[preset]!;
    return Tooltip(
      message: themePresetLabel(preset),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDynamic
                ? scheme.surfaceContainerHighest
                : seed,
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 3,
            ),
          ),
          child: isDynamic
              ? Icon(Icons.auto_awesome,
                  color: scheme.primary, size: 22)
              : (selected
                  ? Icon(Icons.check, color: Colors.white, size: 22)
                  : null),
        ),
      ),
    );
  }
}
