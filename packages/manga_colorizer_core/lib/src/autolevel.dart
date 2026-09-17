library;

import 'dart:typed_data';

/// 自动色阶预处理 (对标 Manga-Colorization-v2 系的扫描件预处理思路)。
///
/// 漫画扫描件常见问题: 纸面发灰(白点不到 250)、网点淡化黑位(黑点不到 20)。
/// 亮亮度保留策略依赖"纸白≥0.95 才锁定",低对比页会导致整页纸面被误着色。
/// 自动色阶按直方图分位数拉伸黑白场,把纸面/墨线推回锁定阈值内,
/// 再交给上色管线 —— 亮通道仍是"原稿亮度",只是去除了扫描偏置。

/// 自动色阶参数。
class AutoLevelOptions {
  /// 白场分位数 (累计直方图从亮端找到该比例处为白场),默认 0.5%。
  final double whitePercentile;

  /// 黑场分位数,默认 0.5%。
  final double blackPercentile;

  /// 自动检测后是否仍强制把白场拉到 255、黑场拉到 0。
  final bool fullStretch;

  const AutoLevelOptions({
    this.whitePercentile = 0.005,
    this.blackPercentile = 0.005,
    this.fullStretch = true,
  });

  factory AutoLevelOptions.fromJson(Object? json) {
    if (json == null) return const AutoLevelOptions();
    if (json is! Map) throw const FormatException('autoLevel 必须是对象');
    return AutoLevelOptions(
      whitePercentile: _readP(json, 'whitePercentile', 0.005),
      blackPercentile: _readP(json, 'blackPercentile', 0.005),
      fullStretch: (json['fullStretch'] as bool?) ?? true,
    );
  }

  static double _readP(Map json, String key, double fallback) {
    final v = json[key];
    if (v == null) return fallback;
    if (v is! num || v < 0 || v > 0.2) {
      throw FormatException('autoLevel.$key 必须在 [0, 0.2]');
    }
    return v.toDouble();
  }
}

/// 对灰度 RGB (r=g=b) 图做自动色阶,返回新像素数组与检测到的黑白场。
///
/// 返回 (新像素, blackPoint 0-255, whitePoint 0-255)。
(Uint8List, int, int) autoLevels(
    Uint8List grayscaleRgb, AutoLevelOptions options) {
  final n = grayscaleRgb.length ~/ 3;
  if (n == 0) return (grayscaleRgb, 0, 255);
  // 灰度直方图 (取 g 通道即可,输入约定 r=g=b)。
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < n; i++) {
    hist[grayscaleRgb[i * 3 + 1]]++;
  }
  // 黑场: 从暗端累计到 blackPercentile。
  var blackPoint = 0;
  var acc = 0;
  final blackCut = (n * options.blackPercentile).round();
  for (var v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= blackCut) {
      blackPoint = v;
      break;
    }
  }
  // 白场: 从亮端累计到 whitePercentile。
  var whitePoint = 255;
  acc = 0;
  final whiteCut = (n * options.whitePercentile).round();
  for (var v = 255; v >= 0; v--) {
    acc += hist[v];
    if (acc >= whiteCut) {
      whitePoint = v;
      break;
    }
  }
  if (whitePoint - blackPoint < 8) {
    // 近乎单色图,不拉伸 (避免放大噪声)。
    return (grayscaleRgb, blackPoint, whitePoint);
  }
  final lut = Uint8List(256);
  final scale = options.fullStretch ? 255.0 : 255.0;
  final lo = blackPoint.toDouble();
  final span = (whitePoint - blackPoint).toDouble();
  for (var v = 0; v < 256; v++) {
    final stretched = ((v - lo) * scale / span).round().clamp(0, 255);
    lut[v] = stretched;
  }
  final out = Uint8List(grayscaleRgb.length);
  for (var i = 0; i < grayscaleRgb.length; i++) {
    out[i] = lut[grayscaleRgb[i]];
  }
  return (out, blackPoint, whitePoint);
}

/// 判断是否建议执行自动色阶。
///
/// 触发信号只用"纸面发灰" (纸面主峰 < 245, 纸白锁定会失效)。
/// 墨线淡化在扫描件中通常与纸面偏置同源 (整体曝光偏移), 拉白场即可一并修正;
/// 单独的"黑位偏高"多是大片深色 artwork (头发/制服/夜空), 不应拉伸。
/// 返回 (是否触发, 纸面主峰, 1% 分位黑场)。
(bool, int, int) shouldAutoLevel(Uint8List grayscaleRgb) {
  final n = grayscaleRgb.length ~/ 3;
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < n; i++) {
    hist[grayscaleRgb[i * 3 + 1]]++;
  }
  // 纸面主峰: 200..255 内最高频。
  var paperPeak = 0;
  var paperCount = 0;
  for (var v = 200; v < 256; v++) {
    if (hist[v] > paperCount) {
      paperCount = hist[v];
      paperPeak = v;
    }
  }
  // 1% 分位黑场 (仅用于报告诊断, 不参与触发)。
  var blackP1 = 0;
  var acc = 0;
  final cut = (n * 0.01).round();
  for (var v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= cut) {
      blackP1 = v;
      break;
    }
  }
  return (paperPeak < 245, paperPeak, blackP1);
}
