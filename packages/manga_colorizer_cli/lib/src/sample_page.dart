import 'dart:math' as math;
import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 极简灰度画布 (供漫画样例绘制)。
class _Canvas {
  final Uint8List data;
  final int width;
  final int height;

  _Canvas(this.width, this.height) : data = Uint8List(width * height * 3);

  void put(int x, int y, int v) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    final i = (y * width + x) * 3;
    data[i] = v;
    data[i + 1] = v;
    data[i + 2] = v;
  }

  void fillRect(int x0, int y0, int x1, int y1, int v) {
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        put(x, y, v);
      }
    }
  }

  void strokeRect(int x0, int y0, int x1, int y1, int v, int thickness) {
    for (var t = 0; t < thickness; t++) {
      for (var x = x0 - t; x <= x1 + t; x++) {
        put(x, y0 - t, v);
        put(x, y1 + t, v);
      }
      for (var y = y0 - t; y <= y1 + t; y++) {
        put(x0 - t, y, v);
        put(x1 + t, y, v);
      }
    }
  }

  void fillEllipse(double cx, double cy, double rx, double ry, int v,
      {double? innerRx, double? innerRy}) {
    for (var y = (cy - ry).floor(); y <= (cy + ry).ceil(); y++) {
      for (var x = (cx - rx).floor(); x <= (cx + rx).ceil(); x++) {
        final nx = (x - cx) / rx;
        final ny = (y - cy) / ry;
        final d = nx * nx + ny * ny;
        if (d <= 1) {
          if (innerRx != null && innerRy != null) {
            final din =
                nx * nx / (innerRx * innerRx) + ny * ny / (innerRy * innerRy);
            if (din <= 1) continue;
          }
          put(x, y, v);
        }
      }
    }
  }

  void line(double x0, double y0, double x1, double y1, int v, double thickness) {
    final steps = (math.max((x1 - x0).abs(), (y1 - y0).abs()) * 2).ceil() + 1;
    for (var s = 0; s <= steps; s++) {
      final t = s / steps;
      final x = x0 + (x1 - x0) * t;
      final y = y0 + (y1 - y0) * t;
      final r = math.max(1, thickness / 2);
      for (var dy = -r.ceil(); dy <= r.ceil(); dy++) {
        for (var dx = -r.ceil(); dx <= r.ceil(); dx++) {
          if (dx * dx + dy * dy <= r * r) put(x.round() + dx, y.round() + dy, v);
        }
      }
    }
  }

  /// 全图乘以 brightness (模拟环境光/昼夜)。
  void applyBrightness(double brightness) {
    for (var i = 0; i < data.length; i++) {
      data[i] = (data[i] * brightness).round().clamp(0, 255);
    }
  }
}

/// 绘制一个漫画人物 (半身像,占位简笔)。
///
/// [scale] = 人物高度相对画布高度的比例基准;灰度值可通过参数区分角色。
void _drawFigure(
    _Canvas c, double cx, double baseY, double scale,
    {required int hairV,
    required int uniformV,
    required int scarfV,
    required int faceV}) {
  final headRx = c.width * 0.13 * scale;
  final headRy = c.height * 0.075 * scale;
  final headCy = baseY - c.height * 0.13 * scale;
  final faceCy = headCy + headRy * 0.55;
  // 头发。
  c.fillEllipse(cx, headCy, headRx, headRy, hairV);
  c.fillEllipse(cx, headCy + headRy * 0.1, headRx * 1.1, headRy * 0.95, hairV);
  // 脸 (浅灰,不撞纸白锁定阈值)。
  c.fillEllipse(cx, faceCy, headRx * 0.78, headRy * 0.78, faceV);
  // 轮廓线。
  c.fillEllipse(cx, headCy, headRx, headRy, 20,
      innerRx: headRx * 0.97, innerRy: headRy * 0.97);
  // 眼睛。
  c.fillEllipse(cx - headRx * 0.27, faceCy - headRy * 0.1, 3.2, 4.5, 15);
  c.fillEllipse(cx + headRx * 0.27, faceCy - headRy * 0.1, 3.2, 4.5, 15);
  // 嘴。
  c.line(cx - 5, faceCy + headRy * 0.45, cx + 5, faceCy + headRy * 0.45, 60, 1.0);
  // 脖子。
  final neckTop = faceCy + headRy * 0.75;
  final shoulderY = neckTop + c.height * 0.035 * scale;
  c.fillRect((cx - 8).round(), neckTop.round(), (cx + 8).round(),
      shoulderY.round(), faceV);
  // 制服 (梯形)。
  final uniformBottom = shoulderY + c.height * 0.19 * scale;
  for (var y = shoulderY.round(); y <= uniformBottom.round(); y++) {
    final half =
        (c.width * 0.16 * scale * (y - shoulderY) / (uniformBottom - shoulderY))
            .round();
    c.fillRect((cx - half).round(), y, (cx + half).round(), y, uniformV);
  }
  // 领巾。
  c.fillRect((cx - 6).round(), (shoulderY + 4).round(), (cx + 6).round(),
      (shoulderY + c.height * 0.07 * scale).round(), scarfV);
}

/// 生成单人死亡漫画样例页 (纸面 + 速度线 + 单人 + 气泡)。
///
/// [brightness] < 1 模拟夜间/暗光环境 (整体亮度压缩,色相信息由色板提供)。
DecodedImage makeSampleManga(
    {int width = 512, int height = 640, int seed = 7, double brightness = 1.0}) {
  final rng = math.Random(seed);
  final canvas = _Canvas(width, height);
  // 纸面。
  canvas.fillRect(0, 0, width - 1, height - 1, 248);
  for (var i = 0; i < width * height * 0.02; i++) {
    canvas.put(rng.nextInt(width), rng.nextInt(height), 244);
  }
  canvas.strokeRect(10, 10, width - 11, height - 11, 20, 2);
  // 速度线背景。
  final focusX = width * 0.38;
  final focusY = height * 0.42;
  for (var k = 0; k < 46; k++) {
    final angle = rng.nextDouble() * math.pi * 2;
    final r0 = width * (0.28 + rng.nextDouble() * 0.08);
    final r1 = r0 + width * (0.12 + rng.nextDouble() * 0.2);
    canvas.line(focusX + math.cos(angle) * r0, focusY + math.sin(angle) * r0,
        focusX + math.cos(angle) * r1, focusY + math.sin(angle) * r1, 90, 1.4);
  }
  // 人物 (脸部 235 / 领巾 120,避开纸白锁定阈值)。
  _drawFigure(
    canvas,
    width * 0.38,
    height * 0.62,
    1.0,
    hairV: 41,
    uniformV: 55,
    scarfV: 120,
    faceV: 235,
  );
  // 对话气泡。
  final bx = width * 0.72;
  final by = height * 0.20;
  canvas.fillEllipse(bx, by, width * 0.16, height * 0.065, 250);
  canvas.fillEllipse(bx, by, width * 0.16, height * 0.065, 20,
      innerRx: width * 0.155, innerRy: height * 0.062);
  canvas.line(bx - width * 0.08, by + height * 0.03, width * 0.38 + width * 0.05,
      height * 0.30, 20, 2.0);
  for (var k = 0; k < 3; k++) {
    final ly = by + (k - 1) * 10.0;
    canvas.line(bx - 26, ly, bx + 26 - k * 8, ly, 70, 2.4);
  }
  // 地面阴影线。
  canvas.line(width * 0.12, height * 0.66, width * 0.62, height * 0.66, 100, 1.2);
  canvas.line(width * 0.2, height * 0.69, width * 0.55, height * 0.69, 140, 1.0);
  if (brightness != 1.0) canvas.applyBrightness(brightness);
  return DecodedImage(width, height, canvas.data);
}

/// 生成双人同框场景 (两位角色并排,制服/头发灰度有意拉开亮度差,
/// 用于验证多人同框时的颜色归属隔离规则)。
DecodedImage makeSceneTwoCharacters(
    {int width = 800, int height = 640, int seed = 11}) {
  final rng = math.Random(seed);
  final canvas = _Canvas(width, height);
  canvas.fillRect(0, 0, width - 1, height - 1, 248);
  for (var i = 0; i < width * height * 0.02; i++) {
    canvas.put(rng.nextInt(width), rng.nextInt(height), 244);
  }
  canvas.strokeRect(10, 10, width - 11, height - 11, 20, 2);
  // 角色 A (左): 深紫发 41 / 藏青制服 55 / 领巾 120。
  _drawFigure(
    canvas,
    width * 0.30,
    height * 0.66,
    1.0,
    hairV: 41,
    uniformV: 55,
    scarfV: 120,
    faceV: 235,
  );
  // 角色 B (右): 深棕发 30 / 军绿制服亮度 75 (与 A 拉开亮度差) / 围巾 140。
  _drawFigure(
    canvas,
    width * 0.70,
    height * 0.62,
    0.9,
    hairV: 30,
    uniformV: 75,
    scarfV: 140,
    faceV: 230,
  );
  if (brightnessOverride != null) canvas.applyBrightness(brightnessOverride!);
  return DecodedImage(width, height, canvas.data);
}

/// 双人场景的全局亮度覆盖 (测试用,常规为 null)。
double? brightnessOverride;

/// 单人样例推荐提示点槽位 (role 对应色板部位;坐标按当前布局几何计算)。
List<HintSlot> recommendedSampleSlots(int width, int height) => [
      // 头发: 头部椭圆上半 (face 顶部之上)。
      HintSlot(
          role: 'hair',
          x: (width * 0.38).round(),
          y: (height * 0.448).round()),
      // 制服: 躯干中部梯形内。
      HintSlot(
          role: 'uniform',
          x: (width * 0.42).round(),
          y: (height * 0.719).round()),
      // 领巾: 领巾矩形中部。
      HintSlot(
          role: 'scarf',
          x: (width * 0.38).round(),
          y: (height * 0.664).round()),
      // 脸部: 面部椭圆中心 (灰度 235,不撞纸白锁定)。
      HintSlot(
          role: 'skin',
          x: (width * 0.38).round(),
          y: (height * 0.531).round()),
    ];

/// 双人场景角色 A 槽位 (cx=0.30w, scale=1.0)。
List<HintSlot> sceneTwoSlotsA(int width, int height) => [
      HintSlot(role: 'hair', x: (width * 0.30).round(), y: (height * 0.489).round()),
      HintSlot(role: 'uniform', x: (width * 0.325).round(), y: (height * 0.758).round()),
      HintSlot(role: 'scarf', x: (width * 0.30).round(), y: (height * 0.711).round()),
      HintSlot(role: 'skin', x: (width * 0.30).round(), y: (height * 0.571).round()),
    ];

/// 双人场景角色 B 槽位 (cx=0.70w, scale=0.9)。
List<HintSlot> sceneTwoSlotsB(int width, int height) => [
      HintSlot(role: 'hair', x: (width * 0.70).round(), y: (height * 0.469).round()),
      HintSlot(role: 'uniform', x: (width * 0.725).round(), y: (height * 0.711).round()),
      HintSlot(role: 'scarf', x: (width * 0.70).round(), y: (height * 0.656).round()),
      HintSlot(role: 'skin', x: (width * 0.70).round(), y: (height * 0.541).round()),
    ];
