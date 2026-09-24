import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';

void main() {
  // 装载应用根：一次覆盖两处行为——应用根在 initState 里把 LogBus 实例置入
  // 静态指针 LogBus.current，以及启动里程碑（tag 为 'startup' 的首条 info）
  // 确实被写入。加载设置目录失败的 error 分支与启动里程碑在同一 try/catch 内，
  // 但宿主测试环境下 path_provider 是否抛出因机器而异，故只断言不依赖环境的
  // 那一半。本用例不锁定「置入静态指针」与「启动异步加载」的先后顺序：应用根
  // 自身的启动写入直接经由实例字段完成，即使静态指针延后置入它们依然可写，
  // 故该顺序在本测试内不可观测。
  testWidgets('应用根创建 LogBus 并写入 startup 里程碑', (tester) async {
    LogBus.current = null;
    await tester.pumpWidget(const MangaColorizerApp());
    await tester.pumpAndSettle();
    final bus = LogBus.current;
    expect(bus, isNotNull, reason: 'root initState 应已置入 LogBus.current');
    expect(bus!.entries.first.tag, 'startup');
    expect(bus.entries.first.message, '应用启动');
    expect(bus.entries.first.level, LogLevel.info);
  });
}
