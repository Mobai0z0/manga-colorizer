import 'dart:math' as math;
import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 日漫特征合成页 v2: 在基础页上叠加网点(descreen 靶点)、灰阶渐变背景、
/// 细线高光纹理, 验证精细上色管线。
///
/// [screentone] 开启时在制服区域叠加规则网点 (亮度中值不变, 高频振荡),
/// [gradientBg] 开启时背景为垂直灰阶渐变 (模拟氛围网点)。
DecodedImage makeMangaPageV2(
    {int width = 900,
    int height = 1300,
    int seed = 31,
    double brightness = 1.0,
    bool screentone = true,
    bool gradientBg = true}) {
  final rng = math.Random(seed);
  final canvas = Uint8List(width * height * 3);

  void put(int x, int y, int v) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    final i = (y * width + x) * 3;
    canvas[i] = v;
    canvas[i + 1] = v;
    canvas[i + 2] = v;
  }

  void fillRect(int x0, int y0, int x1, int y1, int v) {
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        put(x, y, v);
      }
    }
  }

  void strokeRect(int x0, int y0, int x1, int y1, int v, int t) {
    for (var k = 0; k < t; k++) {
      for (var x = x0 - k; x <= x1 + k; x++) {
        put(x, y0 - k, v);
        put(x, y1 + k, v);
      }
      for (var y = y0 - k; y <= y1 + k; y++) {
        put(x0 - k, y, v);
        put(x1 + k, y, v);
      }
    }
  }

  void fillEllipse(double cx, double cy, double rx, double ry, int v,
      {double? irx, double? iry}) {
    for (var y = (cy - ry).floor(); y <= (cy + ry).ceil(); y++) {
      for (var x = (cx - rx).floor(); x <= (cx + rx).ceil(); x++) {
        final nx = (x - cx) / rx;
        final ny = (y - cy) / ry;
        if (nx * nx + ny * ny <= 1) {
          if (irx != null && iry != null) {
            if (nx * nx / (irx * irx) + ny * ny / (iry * iry) <= 1) continue;
          }
          put(x, y, v);
        }
      }
    }
  }

  void line(double x0, double y0, double x1, double y1, int v, double th) {
    final steps = (math.max((x1 - x0).abs(), (y1 - y0).abs()) * 2).ceil() + 1;
    for (var s = 0; s <= steps; s++) {
      final t = s / steps;
      final x = x0 + (x1 - x0) * t;
      final y = y0 + (y1 - y0) * t;
      final r = math.max(1, th / 2);
      for (var dy = -r.ceil(); dy <= r.ceil(); dy++) {
        for (var dx = -r.ceil(); dx <= r.ceil(); dx++) {
          if (dx * dx + dy * dy <= r * r) put(x.round() + dx, y.round() + dy, v);
        }
      }
    }
  }

  // --- 背景灰阶渐变 (垂直, 250 → 235) ---
  for (var y = 0; y < height; y++) {
    final v = gradientBg
        ? (250 - 15 * y / height).round()
        : 248;
    for (var x = 0; x < width; x++) {
      put(x, y, v);
    }
  }

  // --- 页框 ---
  strokeRect(12, 12, width - 13, height - 13, 20, 3);

  // --- 速度线 ---
  final fx = width * 0.36;
  final fy = height * 0.40;
  for (var k = 0; k < 60; k++) {
    final a = rng.nextDouble() * math.pi * 2;
    final r0 = width * (0.30 + rng.nextDouble() * 0.06);
    final r1 = r0 + width * (0.14 + rng.nextDouble() * 0.22);
    line(fx + math.cos(a) * r0, fy + math.sin(a) * r0,
        fx + math.cos(a) * r1, fy + math.sin(a) * r1, 95, 1.2);
  }

  // --- 人物 (更大更精细, 占高 0.62) ---
  final cx = width * 0.36;
  final headRx = width * 0.14;
  final headRy = height * 0.062;
  final headCy = height * 0.33;
  // 头发 (双层弧 + 高光细线)。
  fillEllipse(cx, headCy, headRx, headRy, 41);
  fillEllipse(cx, headCy + headRy * 0.08, headRx * 1.12, headRy * 0.96, 41);
  // 发丝高光: 三条细亮弧线 (细线高光纹理靶点)。
  for (var k = 0; k < 3; k++) {
    line(cx - headRx * (0.5 - k * 0.28), headCy - headRy * (0.55 + k * 0.06),
        cx + headRx * (0.4 - k * 0.2), headCy - headRy * (0.62 + k * 0.05), 150,
        1.1);
  }
  // 脸。
  fillEllipse(cx, headCy + headRy * 0.62, headRx * 0.76, headRy * 0.72, 236);
  fillEllipse(cx, headCy, headRx, headRy, 20,
      irx: headRx * 0.97, iry: headRy * 0.97);
  // 眼睛/嘴。
  fillEllipse(cx - headRx * 0.26, headCy + headRy * 0.52, 4.5, 6, 15);
  fillEllipse(cx + headRx * 0.26, headCy + headRy * 0.52, 4.5, 6, 15);
  line(cx - 7, headCy + headRy * 1.0, cx + 7, headCy + headRy * 1.0, 60, 1.0);
  // 脖子。
  final neckY = headCy + headRy * 1.35;
  fillRect((cx - 9).round(), neckY.round(), (cx + 9).round(),
      (neckY + height * 0.03).round(), 236);
  // 制服。
  final shY = neckY + height * 0.035;
  final uBottom = shY + height * 0.20;
  for (var y = shY.round(); y <= uBottom.round(); y++) {
    final half = (width * 0.17 * (y - shY) / (uBottom - shY)).round();
    fillRect((cx - half).round(), y, (cx + half).round(), y, 55);
  }
  // 网点叠加 (制服区): 规则 50% 网点, 中值≈55 保持, 高频振荡供 descreen 靶点。
  if (screentone) {
    for (var y = shY.round(); y <= uBottom.round(); y++) {
      for (var x = (cx - width * 0.2).round(); x <= (cx + width * 0.2).round(); x++) {
        if ((x + y) % 4 < 2) put(x, y, 75); // 亮网点
      }
    }
  }
  // 领巾。
  fillRect((cx - 7).round(), (shY + 5).round(), (cx + 7).round(),
      (shY + height * 0.065).round(), 120);

  // --- 气泡 ---
  final bx = width * 0.70;
  final by = height * 0.22;
  fillEllipse(bx, by, width * 0.17, height * 0.06, 252);
  fillEllipse(bx, by, width * 0.17, height * 0.06, 20,
      irx: width * 0.165, iry: height * 0.057);
  for (var k = 0; k < 3; k++) {
    final ly = by + (k - 1) * 11.0;
    line(bx - 30, ly, bx + 30 - k * 9, ly, 70, 2.2);
  }

  // --- 地面线 ---
  line(width * 0.10, height * 0.68, width * 0.64, height * 0.68, 100, 1.1);
  line(width * 0.18, height * 0.71, width * 0.58, height * 0.71, 140, 0.9);

  if (brightness != 1.0) {
    for (var i = 0; i < canvas.length; i++) {
      canvas[i] = (canvas[i] * brightness).round().clamp(0, 255);
    }
  }
  return DecodedImage(width, height, canvas);
}

/// v2 页推荐槽位 (按上述布局几何)。
List<HintSlot> mangaPageV2Slots(int width, int height) => [
      HintSlot(role: 'hair', x: (width * 0.36).round(), y: (height * 0.302).round()),
      HintSlot(role: 'uniform', x: (width * 0.42).round(), y: (height * 0.565).round()),
      HintSlot(role: 'scarf', x: (width * 0.36).round(), y: (height * 0.508).round()),
      HintSlot(role: 'skin', x: (width * 0.36).round(), y: (height * 0.368).round()),
    ];
