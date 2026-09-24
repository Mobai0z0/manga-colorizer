// RGB↔Lab(D65, 8bit, a/b 偏置 +128)，数值语义对齐 OpenCV cvtColor（金样对拍见测试）。
import 'dart:math' as math;
import 'dart:typed_data';

const _d = 6 / 29; // δ
double _fwd(double t) => t > _d * _d * _d
    ? math.pow(t, 1 / 3).toDouble()
    : t / (3 * _d * _d) + 4 / 29;
double _inv(double t) => t > _d ? t * t * t : 3 * _d * _d * (t - 4 / 29);
double _srgb(double c) =>
    c > 0.04045 ? math.pow((c + 0.055) / 1.055, 2.4).toDouble() : c / 12.92;
int _gamma(double c) {
  final v = c > 0.0031308 ? 1.055 * math.pow(c, 1 / 2.4) - 0.055 : 12.92 * c;
  return (v.clamp(0.0, 1.0) * 255).round();
}

/// sRGB(8bit) → Lab(D65)，逐值对齐 cv2.COLOR_RGB2LAB 的 8bit 打包语义：
/// L 按 **0..100 缩放存成 0..255**，a/b 为真实值 **+128 偏置** 后四舍五入并
/// 截断到 0..255；[rgb]/返回值为行优先 n*3 字节，[n] 是**像素数**（非字节数）。
///
/// 注意：8bit Lab 是对饱和色的有损编码（色度出域会被截断），与 [labToRgb]
/// 的完整往返存在量化地板误差（cv2 自家往返实测同量级）——对拍结论与容差
/// 依据见本包 `test/goldens/` 金样与 `test/lab_test.dart`。
Uint8List rgbToLab(Uint8List rgb, int n) {
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final r = _srgb(rgb[i * 3] / 255.0),
        g = _srgb(rgb[i * 3 + 1] / 255.0),
        b = _srgb(rgb[i * 3 + 2] / 255.0);
    final x = _fwd((0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.950456);
    final y = _fwd(0.212671 * r + 0.715160 * g + 0.072169 * b);
    final z = _fwd((0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.088754);
    // cv2 8bit Lab: L 按 0..100 → 0..255 缩放存储, a/b 直接 +128 偏置。
    out[i * 3] = ((116 * y - 16) * 255 / 100).clamp(0, 255).round();
    out[i * 3 + 1] = (500 * (x - y) + 128).clamp(0, 255).round();
    out[i * 3 + 2] = (200 * (y - z) + 128).clamp(0, 255).round();
  }
  return out;
}

/// [rgbToLab] 的逆变换，对齐 cv2.COLOR_LAB2RGB 的 8bit 语义：L 按 /255*100
/// 还原，a/b 减 128 偏置；[lab] 为行优先 n*3 字节，[n] 是像素数。
/// 与正向同为逐值对拍金样（单步差 ≤2 判对齐，见 `test/lab_test.dart`）；
/// 经 8bit Lab 的完整往返有损，勿按逐比特一致对待。
Uint8List labToRgb(Uint8List lab, int n) {
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final l = lab[i * 3] / 255.0 * 100.0,
        a = lab[i * 3 + 1] - 128.0,
        b = lab[i * 3 + 2] - 128.0;
    final fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
    final x = _inv(fx) * 0.950456,
        y = l > 8 ? fy * fy * fy : l / 903.3,
        z = _inv(fz) * 1.088754;
    out[i * 3] = _gamma(3.240481 * x - 1.537152 * y - 0.498536 * z);
    out[i * 3 + 1] = _gamma(-0.969254 * x + 1.875990 * y + 0.041556 * z);
    out[i * 3 + 2] = _gamma(0.055643 * x - 0.203997 * y + 1.057311 * z);
  }
  return out;
}
