import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';
import 'package:manga_colorizer_mobile/onnx/auto_service.dart';

import 'fake_backend.dart';

void main() {
  late AutoBackendFactory orig;
  setUp(() => orig = autoBackendFactory);
  tearDown(() => autoBackendFactory = orig);

  // 复用 auto_service_test 的接缝：in-process worker + FakeBackend，
  // 不触碰真实 ORT/网络/path_provider。
  test('引擎启动记 info，worker 意外终止记 error', () async {
    autoBackendFactory = (_) => FakeBackend();
    final bus = LogBus();
    late void Function(Object why) notifyDied;
    final engine = AutoEngine(
        logBus: bus,
        spawn: (toMain, {onDied}) {
          // in-process 循环没有 isolate 退出事件，测试直调同一回调。
          notifyDied = (why) => onDied!(why);
          return startInProcessAutoWorker(toMain, onDied: onDied);
        },
        idleRelease: const Duration(minutes: 5));
    await engine.ensureStarted(Directory.systemTemp.path);
    expect(
        bus.entries
            .map((e) => '${e.level.name}:${e.tag}:${e.message}')
            .toList(),
        ['info:auto:引擎已启动（worker 握手完成）']);
    notifyDied('worker isolate 已退出');
    await pumpEventQueue();
    expect(bus.entries.last.level, LogLevel.error);
    expect(bus.entries.last.message, contains('worker isolate 已退出'));
    await engine.shutdown();
    bus.dispose();
  });
}
