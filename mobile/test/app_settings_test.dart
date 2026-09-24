import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/app_settings.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mc-settings'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('缺失文件 → 默认值（auto）', () {
    expect(AppSettings.load(dir).downloadSource, DownloadSource.auto);
  });

  test('save/load 往返保留所选下载源', () async {
    await const AppSettings(downloadSource: DownloadSource.mirror).save(dir);
    expect(AppSettings.load(dir).downloadSource, DownloadSource.mirror);
  });

  test('未知/损坏内容 → 回退默认，不抛异常', () {
    File('${dir.path}/settings.json')
      ..createSync()
      ..writeAsStringSync('{ not valid json ');
    expect(AppSettings.load(dir).downloadSource, DownloadSource.auto);

    File('${dir.path}/settings.json')
        .writeAsStringSync('{"downloadSource": "nope"}');
    expect(AppSettings.load(dir).downloadSource, DownloadSource.auto);
  });

  test('toJson 使用枚举名，可被 fromJson 还原', () {
    final j = const AppSettings(downloadSource: DownloadSource.primary)
        .toJson();
    expect(j['downloadSource'], 'primary');
    expect(
        AppSettings.fromJson(Map<String, Object?>.from(j)).downloadSource,
        DownloadSource.primary);
  });
}
