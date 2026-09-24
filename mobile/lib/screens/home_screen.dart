// 首页：hero + 四张直达功能卡 + 关于/许可。E-壳的对齐入口（spec §6）。
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../shell/destinations.dart';
import '../shell/screen_chrome.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen(
      {super.key, required this.controller, required this.onNavigate});
  final SettingsController controller;
  final ValueChanged<AppDestination> onNavigate;

  static const _license =
      '模型权重 CC BY-NC-SA 4.0，需自行下载，仅限非商业使用；详见仓库 docs/licensing。';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: screenAppBar(context, title: '首页', controller: controller),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Manga Colorizer',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700, color: scheme.primary)),
          const SizedBox(height: 4),
          const Text('漫画上色 · 端侧提示点 & 全自动'),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _card(context, AppDestination.colorize, '上色（提示点）', '点几下即可上色'),
              _card(context, AppDestination.auto, '全自动', '端侧 ONNX 一键上色'),
              _card(context, AppDestination.gallery, '图库', '查看已保存作品'),
              _card(context, AppDestination.logs, '日志', '查看运行记录'),
            ],
          ),
          const SizedBox(height: 24),
          Text('关于', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(_license, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, AppDestination dest, String title, String sub) {
    return SizedBox(
      width: 150,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onNavigate(dest),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(dest.icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 10),
                Text(title,
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(sub, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
