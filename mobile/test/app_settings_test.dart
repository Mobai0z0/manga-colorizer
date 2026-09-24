import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/app_theme.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mc-settings'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (_) {
      // Windows 上句柄可能尚未释放，清理失败不影响断言。
    }
  });

  group('AppSettings 持久化', () {
    test('缺失文件 → 默认值（auto / system / dynamic）', () {
      final s = AppSettings.load(dir);
      expect(s.downloadSource, DownloadSource.auto);
      expect(s.themeMode, AppThemeMode.system);
      expect(s.themePreset, ThemePreset.dynamic);
    });

    test('save/load 往返保留三个字段', () {
      const AppSettings(
        downloadSource: DownloadSource.mirror,
        themeMode: AppThemeMode.dark,
        themePreset: ThemePreset.blue,
      ).saveSync(dir);
      final s = AppSettings.load(dir);
      expect(s.downloadSource, DownloadSource.mirror);
      expect(s.themeMode, AppThemeMode.dark);
      expect(s.themePreset, ThemePreset.blue);
    });

    test('未知/损坏内容 → 回退默认，不抛异常', () {
      File('${dir.path}/settings.json')
        ..createSync()
        ..writeAsStringSync('{ not valid json ');
      expect(AppSettings.load(dir).downloadSource, DownloadSource.auto);

      File('${dir.path}/settings.json')
          .writeAsStringSync('{"downloadSource": "nope"}');
      final s = AppSettings.load(dir);
      expect(s.downloadSource, DownloadSource.auto);
      // 缺字段仍回退各字段默认。
      expect(s.themeMode, AppThemeMode.system);
      expect(s.themePreset, ThemePreset.dynamic);
    });

    test('toJson 使用枚举名，可被 fromJson 还原', () {
      final j = const AppSettings(
        downloadSource: DownloadSource.primary,
        themeMode: AppThemeMode.light,
        themePreset: ThemePreset.purple,
      ).toJson();
      expect(j['downloadSource'], 'primary');
      expect(j['themeMode'], 'light');
      expect(j['themePreset'], 'purple');
      final back = AppSettings.fromJson(Map<String, Object?>.from(j));
      expect(back, const AppSettings(
        downloadSource: DownloadSource.primary,
        themeMode: AppThemeMode.light,
        themePreset: ThemePreset.purple,
      ));
    });

    test('值相等：全字段一致才相等（驱动 update 去重）', () {
      expect(const AppSettings(), AppSettings.defaults());
      expect(const AppSettings(themeMode: AppThemeMode.dark),
          isNot(AppSettings.defaults()));
    });
  });

  group('SettingsController', () {
    test('attachBase 后 update 落盘并广播', () async {
      final c = SettingsController(AppSettings.defaults());
      var notified = 0;
      c.addListener(() => notified++);

      // 未注入 base 前只改内存，不落盘。
      c.update(c.settings.copyWith(themeMode: AppThemeMode.dark));
      expect(notified, 1);
      expect(File('${dir.path}/settings.json').existsSync(), isFalse);

      c.attachBase(dir);
      c.update(c.settings.copyWith(themePreset: ThemePreset.cyan));
      expect(notified, 2);
      final s = AppSettings.load(dir);
      expect(s.themeMode, AppThemeMode.dark);
      expect(s.themePreset, ThemePreset.cyan);
    });

    test('update 传入等值设置 → 不广播、不落盘', () {
      final c = SettingsController(AppSettings.defaults(), base: dir);
      var notified = 0;
      c.addListener(() => notified++);
      c.update(AppSettings.defaults());
      expect(notified, 0);
      expect(File('${dir.path}/settings.json').existsSync(), isFalse);
    });
  });
}
