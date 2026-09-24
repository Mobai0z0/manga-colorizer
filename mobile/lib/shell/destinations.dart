// 底部导航目的地：单一真源，壳与各屏据此渲染 label/icon 并映射索引。
import 'package:flutter/material.dart';

enum AppDestination { home, colorize, auto, gallery, logs }

extension AppDestinationX on AppDestination {
  String get label => switch (this) {
        AppDestination.home => '首页',
        AppDestination.colorize => '上色',
        AppDestination.auto => '全自动',
        AppDestination.gallery => '图库',
        AppDestination.logs => '日志',
      };

  IconData get icon => switch (this) {
        AppDestination.home => Icons.home_outlined,
        AppDestination.colorize => Icons.brush_outlined,
        AppDestination.auto => Icons.auto_fix_high,
        AppDestination.gallery => Icons.photo_library_outlined,
        AppDestination.logs => Icons.receipt_long_outlined,
      };
}
