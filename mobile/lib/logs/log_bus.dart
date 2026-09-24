// 端侧运行日志唯一真源：容量 600 的内存环形缓冲（对齐桌面 LOG_RING），
// 只增不删、超容量丢最旧、重启即清空。继承 ChangeNotifier 供 LogsScreen
// 经 ListenableBuilder 实时刷新。绝不落盘、绝不发网络。
//
// 投递：构造注入为主（app 根 → AppShell → 各屏/AutoEngine）；对无法穿参的
// 底层静默 catch（gallery_store、启动期）用静态 [LogBus.current] 兜底。
// 本文件不 import 任何应用内文件，只依赖 flutter/foundation 与 log_entry。
//
// level 与 tag 语义分离：level 只表达严重度（info/warning/error），供过滤与
// 着色；tag 表达来源子系统，二者互不越界。tag 取值 startup/weights/auto/
// hints/gallery 是调用方侧的约定，本类不校验也不丢弃集合外的 tag——日志写入
// 永不改变既有控制流，写错 tag 应与写入失败一样无害。
import 'package:flutter/foundation.dart';

import 'log_entry.dart';

/// 环形缓冲容量，对齐桌面 tool/colorizer_service/service.py 的 deque(maxlen=600)。
const int kLogCapacity = 600;

class LogBus extends ChangeNotifier {
  /// 供无法接受注入的底层静默 catch 使用的进程级指针；由 app 根在创建后置入。
  /// 为 null 时所有写入静默跳过——日志器缺失不应影响宿主。
  static LogBus? current;

  final List<LogEntry> _ring = []; // 旧 → 新
  int _seq = 0;
  bool _disposed = false;

  /// 时间正序（旧 → 新）只读快照，控制台自上而下阅读。
  List<LogEntry> get entries => List.unmodifiable(_ring);

  void info(String tag, String message) => _append(LogLevel.info, tag, message);
  void warn(String tag, String message) => _append(LogLevel.warning, tag, message);
  void error(String tag, String message) => _append(LogLevel.error, tag, message);

  /// 清空可见记录，但 seq 计数不复位以保持跨清空的单调性。
  void clear() {
    if (_ring.isEmpty) return;
    _ring.clear();
    _notify();
  }

  void _append(LogLevel level, String tag, String message) {
    // 日志器绝不因自身而抛出：任何异常在此吞掉（对齐桌面 _RingHandler.emit 的 except pass）。
    try {
      _ring.add(LogEntry(
        seq: ++_seq,
        time: DateTime.now(),
        level: level,
        tag: tag,
        message: message,
      ));
      if (_ring.length > kLogCapacity) {
        _ring.removeRange(0, _ring.length - kLogCapacity);
      }
      _notify();
    } on Object {
      // 记录失败不影响调用方。
    }
  }

  void _notify() {
    if (_disposed) return; // dispose 后到帧回调仍可能写入，避免断言失败。
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    current = null;
    super.dispose();
  }
}
