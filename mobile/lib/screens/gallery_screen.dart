// 画廊目的地（E-壳阶段）：静态空态。E-Gallery spec 将引入持久化并替换本屏。
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../shell/screen_chrome.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key, required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: screenAppBar(context, title: '图库', controller: controller),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text('还没有已保存的作品',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('在上色 / 全自动完成后保存即可加入画廊（即将推出）',
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
