/// manga_colorizer_core — 纯 Dart 黑白漫画上色引擎。
///
/// 提供两类上色能力:
/// 1. 提示点色度扩散上色 ([colorizeManga],Levin 2004 优化法);
/// 2. 亮度-调色板渐变映射上色 ([applyTint])。
///
/// 图像编解码见 [MangaImageIO]。
library;

export 'src/colorize.dart';
export 'src/autolevel.dart';
export 'src/cel.dart';
export 'src/checker.dart';
export 'src/filters.dart';
export 'src/geometry.dart' show ChromaSolver, ChromaSolution;
export 'src/image_io.dart';
export 'src/lab.dart';
export 'src/palette.dart';
export 'src/skin.dart';
export 'src/tiling.dart';
export 'src/tint.dart';
export 'src/yuv.dart';
