import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';

void main() {
  test('LogEntry 直读字段构造，无序列化面', () {
    final t = DateTime(2026, 9, 24, 5, 7, 9);
    final e = LogEntry(
        seq: 12, time: t, level: LogLevel.warning, tag: 'weights', message: '回退镜像');
    expect(e.seq, 12);
    expect(e.time, t);
    expect(e.level, LogLevel.warning);
    expect(e.tag, 'weights');
    expect(e.message, '回退镜像');
  });

  test('LogLevel 三值齐备且顺序固定', () {
    expect(LogLevel.values,
        [LogLevel.info, LogLevel.warning, LogLevel.error]);
  });
}
