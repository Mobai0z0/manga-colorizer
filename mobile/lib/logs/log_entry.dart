// 端侧运行日志的单条记录：进程内内存环的元素，不落盘，故无序列化。
// seq 由 LogBus 单调分配（对齐桌面 LOG_RING）；time 存对象，格式化留给 view 层。

/// 事件严重度。tag 表子系统，二者语义分离（见 log_bus.dart 顶注）。
enum LogLevel { info, warning, error }

class LogEntry {
  const LogEntry({
    required this.seq,
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  final int seq;
  final DateTime time;
  final LogLevel level;

  /// 来源子系统名，取值固定为 startup/weights/auto/hints/gallery。
  final String tag;
  final String message;
}
