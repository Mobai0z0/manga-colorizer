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

/// 灰度（R=G=B 的退化 RGB）→ [rgbToLab] 的 **L 字节**。三通道相等时
/// x=y=z，a/b 恒为偏置 128，无需存储。y 的系数求和顺序与 [rgbToLab] 的
/// r=g=b 路径完全一致，同一输入下逐值相等（全 256 值对拍见 lab_test）；
/// 「L 恒取原稿」的管线用它免建 3n 的三通道展开缓冲。
Uint8List grayToLabL(Uint8List gray) {
  final out = Uint8List(gray.length);
  for (var i = 0; i < gray.length; i++) {
    final v = _srgb(gray[i] / 255.0);
    final y = _fwd(0.212671 * v + 0.715160 * v + 0.072169 * v);
    out[i] = ((116 * y - 16) * 255 / 100).clamp(0, 255).round();
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

/// 单通道约束下的色度收缩系数 t 上界：c>y → (1−y)/(c−y)；c<y → y/(y−c)；
/// c==y → 无约束。解析解（Lab→RGB 对 a/b 非线性，逐像素二分会贵一个量级），
/// 对齐桌面 service.py `_gamut_cap`。
double _gamutCap(double c, double y, double t) {
  final d = c - y;
  if (d > 1e-12) {
    final lim = (1.0 - y) / d;
    return lim < t ? lim : t;
  }
  if (d < -1e-12) {
    final lim = y / -d;
    return lim < t ? lim : t;
  }
  return t;
}

/// [labToRgb] 的色域映射版：先对 a/b 施加色度增益 [chromaGain]（1=不变，
/// 128+(v−128)·G 语义），大幅超出 sRGB 色域的像素不再逐通道截断，而是在
/// 线性 RGB 空间按「亮度不变、色度等比收缩」求最大可行 t（rgb' = Y +
/// (rgb−Y)·t，Y 用 XYZ 矩阵 Y 行系数，收缩前后亮度严格不变、色品朝 D65
/// 白点方向即色相不变）——截断把通道拉向 0/1、色相被拉向三原色，是全自动
/// 输出发灰发闷的主因之一。t≥0.95 的微量出域是 8bit Lab 往返的量化噪声
/// （色域边界贴边色），维持逐通道截断恰好还原原色，两种行为在切换点相差
/// ≤5% 色度；色域内像素与 [labToRgb] 逐位一致。
///
/// 与桌面 service.py `_finish_bgr` 同一套数学（桌面 numpy 向量化+64 行分块，
/// 此处逐像素标量、零额外缓冲，语义对拍金样见 `test/gamut_golden.json`）。
/// 亮度增益场景由调用方在 8bit 量化前施加（mobile/lib/onnx/pipeline.dart）。
Uint8List labToRgbGamut(Uint8List lab, int n, {double chromaGain = 1.0}) {
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final l = lab[i * 3] / 255.0 * 100.0,
        a = (lab[i * 3 + 1] - 128.0) * chromaGain,
        b = (lab[i * 3 + 2] - 128.0) * chromaGain;
    final fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
    final x = _inv(fx) * 0.950456,
        y = l > 8 ? fy * fy * fy : l / 903.3,
        z = _inv(fz) * 1.088754;
    var r = 3.240481 * x - 1.537152 * y - 0.498536 * z;
    var g = -0.969254 * x + 1.875990 * y + 0.041556 * z;
    var bl = 0.055643 * x - 0.203997 * y + 1.057311 * z;
    // 亮度系数 = XYZ 矩阵 Y 行，收缩前后亮度严格不变
    final yy = 0.212671 * r + 0.715160 * g + 0.072169 * bl;
    var t = _gamutCap(r, yy, _gamutCap(g, yy, _gamutCap(bl, yy, 1.0)));
    if (t < 0.95) {
      r = yy + (r - yy) * t;
      g = yy + (g - yy) * t;
      bl = yy + (bl - yy) * t;
    } else {
      // 色域内或量化噪声级微量出域：逐通道截断（labToRgb 语义）
      r = r.clamp(0.0, 1.0);
      g = g.clamp(0.0, 1.0);
      bl = bl.clamp(0.0, 1.0);
    }
    out[i * 3] = _gamma(r);
    out[i * 3 + 1] = _gamma(g);
    out[i * 3 + 2] = _gamma(bl);
  }
  return out;
}
