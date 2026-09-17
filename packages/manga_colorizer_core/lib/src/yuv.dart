/// BT.601 YUV 色彩空间转换工具。
///
/// 归一化约定: R/G/B/Y ∈ [0,1],U/V ∈ [-0.5,0.5]。
/// 上色算法在 YUV 空间进行: 只求解色度 (U,V),亮度 (Y) 沿用原稿。
library;

import 'dart:math' as math;

/// 8bit 灰度值 → 归一化亮度。
double normalizeLuminance(int gray) => gray / 255.0;

/// 归一化 RGB → (Y, U, V)。
(double, double, double) rgbToYuv(double r, double g, double b) {
  final y = 0.299 * r + 0.587 * g + 0.114 * b;
  final u = (b - y) / 1.772;
  final v = (r - y) / 1.402;
  return (y, u, v);
}

/// (Y, U, V) → 归一化 RGB,分量按 [0,1] 截断。
(double, double, double) yuvToRgb(double y, double u, double v) {
  final r = y + 1.402 * v;
  final g = y - 0.344136 * u - 0.714136 * v;
  final b = y + 1.772 * u;
  return (_clamp01(r), _clamp01(g), _clamp01(b));
}

/// (Y, U, V) → 归一化 RGB,色域超界时等比缩小色度 (保色相)。
///
/// 逐通道截断会单独立的压低某个通道,使色相向偏移 (如高亮红色变橙);
/// 这里在 (u,v) 平面沿原方向找最大可行缩放系数 s ∈ [0,1],
/// 使 RGB 三通道恰好全部落在色域内,色相与明度保持不变。
(double, double, double) yuvToRgbGamut(double y, double u, double v) {
  final rDir = 1.402 * v;
  final gDir = -0.344136 * u - 0.714136 * v;
  final bDir = 1.772 * u;
  var s = 1.0;
  double upper(double dir) =>
      dir > 0 ? (1 - y) / dir : (dir < 0 ? y / (-dir) : double.infinity);
  s = math.min(s, upper(rDir));
  s = math.min(s, upper(gDir));
  s = math.min(s, upper(bDir));
  if (s.isNaN || s < 0) s = 0;
  final r = y + s * rDir;
  final g = y + s * gDir;
  final b = y + s * bDir;
  return (_clamp01(r), _clamp01(g), _clamp01(b));
}

/// 8bit RGB 感知亮度 → [0,1]。
double luminanceOfRgb(int r, int g, int b) =>
    (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;

double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
