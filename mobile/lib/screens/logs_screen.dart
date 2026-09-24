// 日志目的地：进程内运行日志的实时控制台。时间正序、新行贴底（用户上翻则
// 暂停跟随），按级别着色、长按可取词。数据来自注入的 LogBus（ChangeNotifier），
// 经 ListenableBuilder 刷新。重启即清空，故空态文案点明"本次启动后"。
import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../logs/log_bus.dart';
import '../logs/log_entry.dart';
import '../shell/screen_chrome.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({
    super.key,
    required this.controller,
    required this.logs,
  });

  final SettingsController controller;
  final LogBus logs;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // 仅当已贴底（或首帧未定位）时自动跟随新行；用户上翻阅读历史时不打断。
  // 阈值 40px 与桌面端 web 控制台滚动跟随策略保持一致。
  bool get _pinnedToBottom =>
      !_scroll.hasClients ||
      _scroll.position.pixels >=
          _scroll.position.maxScrollExtent - 40;

  void _followIfNeeded(bool wasAtBottom) {
    if (!wasAtBottom) return;
    // 首帧的定位就靠这个延迟：builder 跑完时 Scrollable 还没挂上 position，
    // 等到帧后再跳，才有 maxScrollExtent 可跳。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: screenAppBar(context, title: '日志', controller: widget.controller),
      body: ListenableBuilder(
        listenable: widget.logs,
        builder: (context, _) {
          final entries = widget.logs.entries;
          if (entries.isEmpty) return _empty(context);
          final wasAtBottom = _pinnedToBottom;
          _followIfNeeded(wasAtBottom);
          return ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, i) => _row(context, entries[i]),
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.receipt_long_outlined,
              size: 56,
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          const Text('暂无运行日志', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('本次启动后的事件会显示在这里', textAlign: TextAlign.center),
        ]),
      ),
    );
  }

  Color _levelColor(LogLevel l) {
    final s = Theme.of(context).colorScheme;
    return switch (l) {
      LogLevel.info => s.tertiary,
      LogLevel.warning => Colors.orange.shade800,
      LogLevel.error => s.error,
    };
  }

  String _clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _row(BuildContext context, LogEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final color = _levelColor(e.level);
    final label = switch (e.level) {
      LogLevel.info => '信息',
      LogLevel.warning => '警告',
      LogLevel.error => '错误',
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_clock(e.time),
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: scheme.onSurfaceVariant)),
        const SizedBox(width: 8),
        SizedBox(
          width: 32,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText.rich(
            TextSpan(style: const TextStyle(fontSize: 12), children: [
              TextSpan(
                  text: '${e.tag} ',
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600)),
              TextSpan(text: e.message, style: TextStyle(color: color)),
            ]),
          ),
        ),
      ],
    );
  }
}
