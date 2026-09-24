import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/shell/destinations.dart';

void main() {
  test('五个目的地 + 中文标签', () {
    expect(AppDestination.values, hasLength(5));
    expect(AppDestination.home.label, '首页');
    expect(AppDestination.colorize.label, '上色');
    expect(AppDestination.auto.label, '全自动');
    expect(AppDestination.gallery.label, '图库');
    expect(AppDestination.logs.label, '日志');
  });

  test('每个目的地有非空图标', () {
    for (final d in AppDestination.values) {
      expect(d.icon, isA<IconData>());
    }
  });
}
