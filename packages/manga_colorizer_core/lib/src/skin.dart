library;

import 'dart:math' as math;

/// 自然肤色常识约束。
///
/// 依据:
/// 1. 公开肤色调色板五档 (color-hex "Skin Tones": #8d5524 #c68642 #e0ac69
///    #f1c27d #ffdbac,实际检索于 2026-09-15);
/// 2. 肤色检测文献中 YCbCr/RGB 肤色聚类的共同结论: 肤色色相落在
///    "暖色象限、R 通道明显高于 B" 的连续窄带内 (Kolkur et al. 2017,
///    Human Skin Detection Using RGB, HSV and YCbCr Color Models)。
///
/// 本引擎在 YUV 平面定义肤色扇区: phi = atan2(v, -u) ∈ [phiMin, phiMax]
/// (u<0、v>0 的暖色象限),色度幅值 ∈ [minChroma, maxChroma]。
/// role=skin 的提示点与成图区域色度会被约束进扇区,
/// 从机制上杜绝 "发绿 / 发灰 / 蜡像感" 的肤色。

/// 肤色种子色 (公开调色板五档,由浅到深)。
const List<List<int>> kSkinSeedRgb = [
  [141, 85, 36],
  [198, 134, 66],
  [224, 172, 105],
  [241, 194, 125],
  [255, 219, 172],
];

/// YUV 肤色扇区描述 (角度制)。
class SkinSector {
  final double phiMinDeg;
  final double phiMaxDeg;
  final double minChroma;
  final double maxChroma;

  const SkinSector(
      this.phiMinDeg, this.phiMaxDeg, this.minChroma, this.maxChroma);

  bool containsPhi(double phiDeg) =>
      phiDeg >= phiMinDeg && phiDeg <= phiMaxDeg;
}

double _seedChroma(List<int> rgb) {
  final y = (0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]) / 255;
  final u = (rgb[2] / 255 - y) / 1.772;
  final v = (rgb[0] / 255 - y) / 1.402;
  return math.sqrt(u * u + v * v);
}

double _seedPhi(List<int> rgb) {
  final y = (0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]) / 255;
  final u = (rgb[2] / 255 - y) / 1.772;
  final v = (rgb[0] / 255 - y) / 1.402;
  return _phiDeg(u, v);
}

double _phiDeg(double u, double v) {
  final deg = math.atan2(v, -u) * 180 / math.pi;
  return deg < 0 ? deg + 360 : deg;
}

/// 由种子色推导的自然肤色扇区 (色相前后各留 4° 余量)。
SkinSector naturalSkinSector() {
  var lo = 360.0;
  var hi = 0.0;
  var maxMag = 0.0;
  for (final seed in kSkinSeedRgb) {
    final phi = _seedPhi(seed);
    if (phi < lo) lo = phi;
    if (phi > hi) hi = phi;
    final mag = _seedChroma(seed);
    if (mag > maxMag) maxMag = mag;
  }
  return SkinSector(lo - 4, hi + 4, 0.05, (maxMag * 2.2).clamp(0.30, 0.50));
}

/// 把 (u, v) 色度约束进自然肤色扇区,返回修正后的色度。
///
/// 色相在扇区外 → 旋转到最近扇区边界;幅值超带 → 等比缩放到边界。
/// 亮度不受影响 (由调用方保留原稿亮度)。
(double, double) enforceNaturalSkin(double u, double v) {
  final sector = naturalSkinSector();
  var mag = math.sqrt(u * u + v * v);
  if (mag < 1e-6) return (u, v);
  var phi = _phiDeg(u, v);
  if (!sector.containsPhi(phi)) {
    // 圆周上取到 [phiMin, phiMax] 的最近边界。
    final dLo = _angularDistance(phi, sector.phiMinDeg);
    final dHi = _angularDistance(phi, sector.phiMaxDeg);
    phi = dLo <= dHi ? sector.phiMinDeg : sector.phiMaxDeg;
  }
  if (mag < sector.minChroma) mag = sector.minChroma;
  if (mag > sector.maxChroma) mag = sector.maxChroma;
  final rad = phi * math.pi / 180;
  return (-mag * math.cos(rad), mag * math.sin(rad));
}

/// 校验一个 RGB 是否落在自然肤色扇区内 (供验收与色板自检使用)。
bool isNaturalSkinRgb(int r, int g, int b) {
  final y = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  if (y <= 0 || y >= 1) return false;
  final u = (b / 255 - y) / 1.772;
  final v = (r / 255 - y) / 1.402;
  final mag = math.sqrt(u * u + v * v);
  final sector = naturalSkinSector();
  if (mag < sector.minChroma * 0.8 || mag > sector.maxChroma) return false;
  return sector.containsPhi(_phiDeg(u, v));
}

double _angularDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}
