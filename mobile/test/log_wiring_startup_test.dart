import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';

void main() {
  // 装载应用根：一次覆盖 §4.4 的静态指针赋值时机与埋点 1 的写入。
  // 埋点 2（启动期加载失败）在同一 try/catch 内，但宿主测试环境下
  // path_provider 是否抛出因机器而异，故只钉住不依赖环境的那一半。
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
