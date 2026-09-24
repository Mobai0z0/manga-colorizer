import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app.dart';
import 'package:manga_colorizer_mobile/logs/log_bus.dart';
import 'package:manga_colorizer_mobile/logs/log_entry.dart';
import 'package:manga_colorizer_mobile/screens/gallery_screen.dart';

void main() {
  // 装载应用根：一次覆盖两处行为——应用根在 initState 里把 LogBus 实例置入
  // 静态指针 LogBus.current，以及启动里程碑（tag 为 'startup' 的首条 info）
  // 确实被写入。加载设置目录失败的 error 分支与启动里程碑在同一 try/catch 内，
  // 但宿主测试环境下 path_provider 是否抛出因机器而异，故只断言不依赖环境的
  // 那一半。应用根自身的启动写入直接经由实例字段完成；「先置入静态指针、后
  // 启动异步加载」的时序由下方用例锁定：图库的降级写入拿不到注入参数、只能
  // 经 LogBus.current 投递，它落进根总线即证明加载调用图运行时指针已就绪。
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

  // 图库入库在无法穿参的回调深处经 LogBus.current 投递降级日志：本用例只在
  // pumpWidget（一帧）之后取指针并断言降级写入落进应用根的总线，锁定的是
  // 「指针在首帧结束前已置入、且指向应用根持有的那个总线」。若 initState
  // 不再置入指针或置入其他实例，下方取到 null 或写入落不进根总线，即红。
  testWidgets('gallery 降级写入经静态指针落进应用根的总线', (tester) async {
    LogBus.current = null;
    await tester.pumpWidget(const MangaColorizerApp());
    // 只 pump 了一帧：启动的异步加载尚未跑完，此刻指针应已就绪。
    final root = LogBus.current;
    expect(root, isNotNull,
        reason: 'initState 须在异步加载启动前置入 LogBus.current');
    // 应用根持有的 GalleryStore 经壳层透传给图库屏，从部件树取回它
    // （图库屏此时未选中、处于 offstage，取树需要显式不跳过）。
    final store = tester
        .widget<GalleryScreen>(find.byType(GalleryScreen, skipOffstage: false))
        .gallery;
    final dir = Directory.systemTemp.createTempSync('gallery_wiring');
    addTearDown(() => dir.deleteSync(recursive: true));
    store.attachDir(dir);
    final junk = Uint8List.fromList([1, 2, 3, 4, 5]); // 非 PNG：缩略图编码必失败
    // 入库走真实文件 IO，须留在 fake-async 之外用真实事件循环等待完成。
    await tester.runAsync(() => store.add(
        resultPng: junk, sourcePng: junk, width: 4, height: 4, mode: 'auto'));
    await tester.pumpAndSettle();
    final galleryWrites =
        root!.entries.where((e) => e.tag == 'gallery').toList();
    expect(galleryWrites, hasLength(1));
    expect(galleryWrites.single.level, LogLevel.warning);
    expect(galleryWrites.single.message, contains('缩略图'));
  });
}
