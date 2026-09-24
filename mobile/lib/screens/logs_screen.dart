// 日志目的地（E-壳阶段）：静态空态。E-Logs spec 将引入端侧记录并替换本屏。
import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../shell/screen_chrome.dart';

class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key, required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: screenAppBar(context, title: '日志', controller: controller),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text('暂无运行日志',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('端侧日志记录（即将推出）', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
