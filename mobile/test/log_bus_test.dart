import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';

void main() {
  test('追加正序、seq 单调从 1 起', () {
    final b = LogBus();
    b.info('startup', 'a');
    b.warn('weights', 'b');
    b.error('auto', 'c');
    final e = b.entries;
    expect(e.map((x) => x.seq), [1, 2, 3]);
    expect(e.map((x) => x.level),
        [LogLevel.info, LogLevel.warning, LogLevel.error]);
    expect(e.map((x) => x.message), ['a', 'b', 'c']);
    b.dispose();
  });

  test('超容量丢最旧，长度封顶 kLogCapacity', () {
    final b = LogBus();
    for (var i = 0; i < kLogCapacity + 50; i++) {
      b.info('auto', 'm$i');
    }
    expect(b.entries.length, kLogCapacity);
    // 被丢的是最初 50 条；剩余首条应为 m50。
    expect(b.entries.first.message, 'm50');
    expect(b.entries.last.message, 'm${kLogCapacity + 49}');
    b.dispose();
  });

  test('每次追加广播一次', () {
    final b = LogBus();
    var n = 0;
    b.addListener(() => n++);
    b.info('startup', 'x');
    b.info('startup', 'y');
    expect(n, 2);
    b.dispose();
  });

  test('clear 清空但 seq 不复位（保持单调）', () {
    final b = LogBus();
    b.info('auto', 'p');
    b.clear();
    expect(b.entries, isEmpty);
    b.info('auto', 'q');
    expect(b.entries.single.seq, 2); // 计数不因 clear 回卷
    b.dispose();
  });

  test('边界值不抛：空 tag / 空消息 / 超长消息', () {
    final b = LogBus();
    b.info('', '');
    b.warn('auto', 'x' * 5000);
    expect(b.entries.length, 2);
    expect(b.entries.first.message, isEmpty);
    b.dispose();
  });

  test('entries 是只读快照：调用方改不动内部环', () {
    final b = LogBus();
    b.info('auto', 'x');
    final snap = b.entries;
    expect(() => snap.add(LogEntry(
        seq: 99, time: DateTime.now(), level: LogLevel.info, tag: 't', message: 'm')),
        throwsUnsupportedError);
    expect(() => snap[0] = LogEntry(
        seq: 98, time: DateTime.now(), level: LogLevel.info, tag: 't', message: 'm'),
        throwsUnsupportedError);
    expect(b.entries.single.message, 'x'); // 内部环未受影响
    b.dispose();
  });

  test('dispose 后追加不抛（重入保护）', () {
    final b = LogBus();
    b.dispose();
    expect(() => b.info('startup', 'after'), returnsNormally);
  });
}
