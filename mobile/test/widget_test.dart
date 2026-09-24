import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manga_colorizer_mobile/auto_panel.dart';
import 'package:manga_colorizer_mobile/main.dart';
import 'package:manga_colorizer_mobile/onnx/auto_service.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';

void main() {
  testWidgets('工作台首屏渲染标题与空态引导', (tester) async {
    await tester.pumpWidget(const MangaColorizerApp());
    await tester.pumpAndSettle();

    expect(find.text('Manga Colorizer'), findsOneWidget);
    expect(find.textContaining('从相册选图'), findsAtLeastNWidgets(1));
  });

  testWidgets('workbench shows hint and auto tabs', (tester) async {
    await tester.pumpWidget(const MangaColorizerApp());
    await tester.pumpAndSettle();

    expect(find.text('提示点'), findsOneWidget);
    expect(find.text('全自动'), findsOneWidget);
  });

  testWidgets('提示点页签动作仅在页签 0 出现（全自动在前时隐藏）', (tester) async {
    await tester.pumpWidget(const MangaColorizerApp());
    await tester.pumpAndSettle();

    // 页签 0：相册选图 / 内置样例照常出现。
    expect(find.byTooltip('从相册选图'), findsOneWidget);
    expect(find.byTooltip('内置样例'), findsOneWidget);

    // 切到全自动：这两个动作改的是隐藏页签的画布，必须消失。
    await tester.tap(find.text('全自动'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('从相册选图'), findsNothing);
    expect(find.byTooltip('内置样例'), findsNothing);

    // 切回来恢复原样。
    await tester.tap(find.text('提示点'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('从相册选图'), findsOneWidget);
    expect(find.byTooltip('内置样例'), findsOneWidget);
  });

  group('全自动页签', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('mc-weights'));
    tearDown(() => dir.deleteSync(recursive: true));

    Widget tab({DownloadOne? downloadOne}) => MaterialApp(
          home: Scaffold(
            body: AutoTab(
              engine: AutoEngine(),
              resolveDir: () async => dir,
              downloadOne: downloadOne,
            ),
          ),
        );

    testWidgets('权重缺失 → 显示大小/许可提示 + 下载按钮', (tester) async {
      await tester.pumpWidget(tab());
      await tester.pumpAndSettle();

      expect(find.text('下载权重(~300MB)'), findsOneWidget);
      expect(find.textContaining('CC BY-NC-SA'), findsOneWidget);
      expect(find.textContaining('docs/licensing'), findsOneWidget);
    });

    testWidgets('下载失败 → WeightsException 文案入状态且可重试', (tester) async {
      await tester.pumpWidget(tab(
        downloadOne: (f, _) async =>
            throw WeightsException('${f.name}: 传输中断: mock'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('下载权重(~300MB)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('下载失败'), findsOneWidget);
      expect(find.textContaining('传输中断'), findsOneWidget);
      expect(find.text('下载权重(~300MB)'), findsOneWidget); // 仍可重试
    });

    testWidgets('下载成功 → 就绪态显示选图引导，按钮消失', (tester) async {
      final downloaded = <String>[];
      await tester.pumpWidget(tab(
        downloadOne: (f, onProgress) async {
          downloaded.add(f.name);
          for (var i = 1; i <= 10; i++) {
            onProgress(f.size * i ~/ 10, f.size); // 模拟密集回调
          }
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('下载权重(~300MB)'));
      await tester.pumpAndSettle();

      expect(downloaded, kWeightFiles.map((f) => f.name).toList());
      expect(find.text('下载权重(~300MB)'), findsNothing);
      expect(find.textContaining('权重就绪'), findsOneWidget);
    });
  });

  test('nextDownloadPercent 节流：每 1% 至多刷新一次', () {
    expect(nextDownloadPercent(1, 1000, null), 0); // 首次也要落一个起点
    expect(nextDownloadPercent(2, 1000, 0), null); // 同百分比不刷新
    expect(nextDownloadPercent(500, 1000, 0), 50); // 跨了 50 个点 → 一次
    expect(nextDownloadPercent(500, 1000, 50), null);
    expect(nextDownloadPercent(1000, 1000, 99), 100); // 终值必须到达
    expect(nextDownloadPercent(1000, 1000, 100), null);
    expect(nextDownloadPercent(0, 0, 5), 5); // total<=0 → 不闪
  });
}
