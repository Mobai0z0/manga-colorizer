import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../app_theme.dart';
import '../onnx/weights.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});
  final SettingsController controller;

  static const _license =
      '模型权重 CC BY-NC-SA 4.0，需自行下载，仅限非商业使用；详见仓库 docs/licensing。';

  static const _sourceHint = {
    DownloadSource.auto: '主站优先，失败自动改走镜像续传',
    DownloadSource.primary: '国内网络通常无法直连，可能失败',
    DownloadSource.mirror: '直连镜像站，不经主站',
  };
  static const _sourceLabel = {
    DownloadSource.auto: '自动（推荐）',
    DownloadSource.primary: '仅主站',
    DownloadSource.mirror: '仅镜像',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = controller.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Text('主题模式', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<AppThemeMode>(
                segments: const [
                  ButtonSegment(value: AppThemeMode.system,
                      icon: Icon(Icons.brightness_auto_outlined), label: Text('跟随系统')),
                  ButtonSegment(value: AppThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined), label: Text('浅色')),
                  ButtonSegment(value: AppThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined), label: Text('深色')),
                ],
                selected: {s.themeMode},
                onSelectionChanged: (sel) =>
                    controller.update(s.copyWith(themeMode: sel.first)),
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
                      onTap: () => controller.update(s.copyWith(themePreset: p)),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text('模型下载源', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              RadioGroup<DownloadSource>(
                groupValue: s.downloadSource,
                onChanged: (v) {
                  if (v != null) {
                    controller.update(s.copyWith(downloadSource: v));
                  }
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final src in DownloadSource.values)
                      RadioListTile<DownloadSource>(
                        value: src,
                        title: Text(_sourceLabel[src]!),
                        subtitle: Text(_sourceHint[src]!),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('关于', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(_license, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
      },
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
            color: isDynamic ? scheme.surfaceContainerHighest : seed,
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 3,
            ),
          ),
          child: isDynamic
              ? Icon(Icons.auto_awesome, color: scheme.primary, size: 22)
              : (selected ? const Icon(Icons.check, color: Colors.white, size: 22) : null),
        ),
      ),
    );
  }
}
