import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:manga_colorizer_cli/src/cli_io.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 语义分区渲染 v9: 色相内容识别 + 部位独立配方 + 肤色去黄。
///
/// 与 v8 的本质区别（v8 的块状感来自纯几何归属）:
///   v8 = 最近锚点几何归属 → 本质是 Voronoi 分块, 块状感不可避免;
///   v9 = 每个像素按【自身色相内容】分类到材质的期望色相扇区
///        (肤色扇区 12-32° / 天空扇区 190-230° / 发色=本页发锚色相圆周均值 ±35° /
///         白衣扇区=任意色相但 s<0.10 且 v>0.88),
///        几何距离只做【同扇区内】多候选的决胜 — 分类边界自动跟随墨线与
///        亮度结构(扩散色度场沿墨线扩散), 不再是块。
///
/// 肤色去黄: hue 22°→18°, sat 0.32→0.24, 亮部偏移去掉向黄分量 —
/// 面部落在自然肤色带(r>g>b, hue 15-25°, sat 0.18-0.30)。
///
/// 消融开关: --no-semantic 关闭内容识别, 退化为 v8 几何归属 — 用于消融对照。
/// 全部参数与图片内容零硬编码: 配方表是常数, 分类是逐像素内容判定。
///
/// 用法:
///   dart run bin/semantic_colorize.dart -i in.png -o out.png \
///     --hints hints.json [--seed 7] [--no-semantic]
Future<void> main(List<String> args) async {
  String? input;
  String? output;
  String? hintsPath;
  var seed = 7;
  var hueJitter = 6.0;
  var satJitter = 0.045;
  var lumJitter = 0.030;
  var banded = true;
  var semantic = true;
  var ramp = true;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-i':
        input = args[++i];
      case '-o':
        output = args[++i];
      case '--hints':
        hintsPath = args[++i];
      case '--seed':
        seed = int.parse(args[++i]);
      case '--hue-jitter':
        hueJitter = double.parse(args[++i]);
      case '--no-banded':
        banded = false;
      case '--no-semantic':
        semantic = false;
      case '--no-ramp':
        ramp = false;
      default:
        stderr.writeln('未知参数: ${args[i]}');
        exitCode = 64;
        return;
    }
  }
  if (input == null || output == null || hintsPath == null) {
    stderr.writeln('用法: dart run bin/semantic_colorize.dart -i <输入> -o <输出> '
        '--hints <json> [--seed 7] [--no-semantic]');
    exitCode = 64;
    return;
  }

  final source = CliIo.readGrayscale(input);
  final hintsRaw = jsonDecode(File(hintsPath).readAsStringSync()) as List;
  final hints = <ColorHint>[];
  final materials = <String>[];
  for (var idx = 0; idx < hintsRaw.length; idx++) {
    final m = hintsRaw[idx] as Map<String, Object?>;
    final hx = (m['x'] as num).toInt();
    final hy = (m['y'] as num).toInt();
    if (hx < 0 || hy < 0 || hx >= source.width || hy >= source.height) {
      stderr.writeln(
          '错误: 提示点 #$idx ($hx,$hy) 超出图像 ${source.width}x${source.height} — '
          '提示点坐标必须逐页匹配图片尺寸(请为该页单独写 hints JSON)');
      exitCode = 64;
      return;
    }
    hints.add(ColorHint.fromJson(m));
    materials.add((m['material'] ?? m['role'] ?? 'backdrop') as String);
  }
  final options = const ColorizeOptions(
    maxIterations: 1500,
    descreen: true,
    lockPureMonochrome: false,
    monochromeLowThreshold: 0.05,
    monochromeHighThreshold: 0.99,
  );

  final watch = Stopwatch()..start();
  final result = colorizeManga(
    grayscaleRgb: source.rgb,
    width: source.width,
    height: source.height,
    hints: hints,
    options: options,
  );
  final diffuseMs = watch.elapsedMilliseconds;

  final out = semanticPass(
    result.rgb,
    source.rgb,
    source.width,
    source.height,
    hints,
    materials,
    seed: seed,
    hueJitter: hueJitter,
    satJitter: satJitter,
    lumJitter: lumJitter,
    banded: banded,
    semantic: semantic,
    ramp: ramp,
  );
  CliIo.writePng(output, out, source.width, source.height);
  stdout.writeln('semantic_colorize 完成: 扩散 ${result.iterations} 次/'
      '$diffuseMs ms, seed=$seed semantic=$semantic');
}

double _smooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

class ValueNoise {
  ValueNoise(this.seed);
  final int seed;
  static int _hash(int x, int y, int s) {
    var h = x * 374761393 + y * 668265263 + s * 2246822519;
    h = (h ^ (h >> 13)) * 1274126177;
    return h ^ (h >> 16);
  }

  static double _rand(int x, int y, int s) =>
      (_hash(x, y, s) & 0x7fffffff) / 0x7fffffff;

  double at(double x, double y) {
    final gx = x / 24;
    final gy = y / 24;
    final x0 = gx.floor();
    final y0 = gy.floor();
    final tx = _smooth(gx - x0);
    final ty = _smooth(gy - y0);
    final a = _rand(x0, y0, seed);
    final b = _rand(x0 + 1, y0, seed);
    final c = _rand(x0, y0 + 1, seed);
    final d = _rand(x0 + 1, y0 + 1, seed);
    return a + (b - a) * tx + (c - a) * ty + (a - b - c + d) * tx * ty;
  }
}

(double, double, double) _rgbToHsv(double r, double g, double b) {
  final mx = math.max(r, math.max(g, b));
  final mn = math.min(r, math.min(g, b));
  final d = mx - mn;
  final v = mx;
  final s = mx <= 0 ? 0.0 : d / mx;
  double h;
  if (d <= 0) {
    h = 0;
  } else if (mx == r) {
    h = 60 * ((g - b) / d % 6);
  } else if (mx == g) {
    h = 60 * ((b - r) / d + 2);
  } else {
    h = 60 * ((r - g) / d + 4);
  }
  if (h < 0) h += 360;
  return (h, s, v);
}

(int, int, int) _hsvToRgb(double h, double s, double v) {
  final c = v * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = v - c;
  double rr, gg, bb;
  if (h < 60) {
    rr = c;
    gg = x;
    bb = 0;
  } else if (h < 120) {
    rr = x;
    gg = c;
    bb = 0;
  } else if (h < 180) {
    rr = 0;
    gg = c;
    bb = x;
  } else if (h < 240) {
    rr = 0;
    gg = x;
    bb = c;
  } else if (h < 300) {
    rr = x;
    gg = 0;
    bb = c;
  } else {
    rr = c;
    gg = 0;
    bb = x;
  }
  return (
    ((rr + m) * 255).round().clamp(0, 255),
    ((gg + m) * 255).round().clamp(0, 255),
    ((bb + m) * 255).round().clamp(0, 255)
  );
}

double _hueDist(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

double _shiftHue(double h, double delta) {
  var x = h + delta;
  if (x < 0) x += 360;
  if (x >= 360) x -= 360;
  return x;
}

/// 部位配方(常数表, 无图片特判)。
/// skin 去黄: hue 18, sat 0.24; 暗部偏红(非黄), 亮部偏粉不偏黄。
class _MatSpec {
  const _MatSpec(this.hue, this.sat, this.darkHueShift, this.darkSatGain,
      this.lightHueShift, this.lightSatDrop);
  final double hue;
  final double sat;
  final double darkHueShift;
  final double darkSatGain;
  final double lightHueShift;
  final double lightSatDrop;
}

const _skinSpec = _MatSpec(18, 0.28, -10, 1.30, 6, 0.10); // 亮部向粉 6°, 衰减减弱防苍白
const _blushSpec = _MatSpec(6, 0.38, -4, 1.15, 5, 0.15);
const _skySpec = _MatSpec(205, 0.34, -6, 1.15, 8, 0.18);
const _whiteSpec = _MatSpec(210, 0.05, -8, 2.0, 0, 0.5);

_MatSpec _specFor(String material, double hintHue, double hintSat) {
  switch (material) {
    case 'skin':
      return _skinSpec;
    case 'blush':
      return _blushSpec;
    case 'sky':
      return _skySpec;
    case 'white':
      return _whiteSpec;
    case 'hair':
      return _MatSpec(hintHue, math.max(hintSat, 0.28), -14, 1.30, 12, 0.30);
    case 'eye':
      return _MatSpec(hintHue, math.max(hintSat, 0.38), -10, 1.25, 10, 0.25);
    case 'garment':
      return _MatSpec(hintHue, math.max(hintSat, 0.26), -12, 1.28, 14, 0.28);
    case 'garment2':
      return _MatSpec(hintHue, math.max(hintSat, 0.22), -12, 1.28, 14, 0.28);
    default:
      return _MatSpec(hintHue, math.max(hintSat * 0.8, 0.10), -8, 1.20, 10, 0.30);
  }
}

/// 材质期望色相: 固定配方用常数值, 自由色材质用锚点色相。
double _expectedHue(String material, double hintHue) {
  switch (material) {
    case 'skin':
      return 18;
    case 'blush':
      return 6;
    case 'sky':
      return 205;
    case 'white':
      return 210;
    default:
      return hintHue;
  }
}

/// 材质明度→颜色色阶 (ramp): 按「灰度直接查表取色」的思路实现, 取代逐像素“染色” —
/// 亮度直接映射到颜色, 不再叠加色相。每条 ramp 是 5 个色标
/// (阴影→中间调→亮部), 按展平亮度插值。颜色值为常数表, 不做图片特判。
class _RampStop {
  const _RampStop(this.t, this.r, this.g, this.b);
  final double t; // 0=最暗, 1=最亮
  final int r;
  final int g;
  final int b;
}

const _skinRamp = [
  _RampStop(0.00, 156, 96, 74), // 深阴影 红棕
  _RampStop(0.30, 210, 150, 118), // 阴影 杏棕
  _RampStop(0.55, 240, 195, 160), // 中间调 杏色
  _RampStop(0.80, 249, 219, 190), // 亮部 浅肤
  _RampStop(1.00, 253, 236, 214), // 高光 山茶白
];

const _hairRamp = [
  _RampStop(0.00, 28, 24, 26), // 深黑
  _RampStop(0.35, 54, 44, 42), // 暗棕
  _RampStop(0.60, 88, 70, 58), // 中棕
  _RampStop(0.85, 130, 104, 82), // 亮棕
  _RampStop(1.00, 168, 138, 108), // 高光 金棕
];

const _garmentRamp = [
  _RampStop(0.00, 34, 38, 54), // 深藏青
  _RampStop(0.35, 56, 62, 86),
  _RampStop(0.60, 88, 96, 126),
  _RampStop(0.85, 138, 148, 180),
  _RampStop(1.00, 190, 200, 224),
];

const _whiteRamp = [
  _RampStop(0.00, 168, 176, 188), // 阴影 淡青灰
  _RampStop(0.50, 216, 222, 230),
  _RampStop(1.00, 252, 251, 248), // 纸白
];

const _skyRamp = [
  _RampStop(0.00, 120, 160, 200), // 深天蓝
  _RampStop(0.50, 168, 204, 232),
  _RampStop(1.00, 224, 238, 248), // 近地平线
];

const _blushRamp = [
  _RampStop(0.00, 214, 130, 118),
  _RampStop(0.50, 238, 168, 152),
  _RampStop(1.00, 248, 196, 182),
];

const _eyeRamp = [
  _RampStop(0.00, 24, 22, 24),
  _RampStop(0.50, 62, 48, 44),
  _RampStop(1.00, 110, 88, 76),
];

const _backdropRamp = [
  _RampStop(0.00, 150, 146, 138),
  _RampStop(0.50, 204, 200, 192),
  _RampStop(1.00, 242, 240, 234),
];

(int, int, int) _rampLookup(List<_RampStop> stops, double t) {
  final tt = t.clamp(0.0, 1.0);
  for (var i = 0; i < stops.length - 1; i++) {
    final a = stops[i];
    final b = stops[i + 1];
    if (tt >= a.t && tt <= b.t) {
      final f = (tt - a.t) / (b.t - a.t);
      return (
        (a.r + (b.r - a.r) * f).round(),
        (a.g + (b.g - a.g) * f).round(),
        (a.b + (b.b - a.b) * f).round()
      );
    }
  }
  final last = stops.last;
  return (last.r, last.g, last.b);
}

List<_RampStop> _rampFor(String material) {
  switch (material) {
    case 'skin':
      return _skinRamp;
    case 'blush':
      return _blushRamp;
    case 'hair':
      return _hairRamp;
    case 'eye':
      return _eyeRamp;
    case 'garment':
      return _garmentRamp;
    case 'garment2':
      return _garmentRamp;
    case 'sky':
      return _skyRamp;
    case 'white':
      return _whiteRamp;
    default:
      return _backdropRamp;
  }
}

Uint8List semanticPass(
  Uint8List rgb,
  Uint8List grayRgb,
  int width,
  int height,
  List<ColorHint> hints,
  List<String> materials, {
  required int seed,
  required double hueJitter,
  required double satJitter,
  required double lumJitter,
  required bool banded,
  required bool semantic,
  required bool ramp,
}) {
  final n = rgb.length ~/ 3;
  final out = Uint8List(rgb.length);
  final noise = ValueNoise(seed);
  final noise2 = ValueNoise(seed + 101);

  final lum = Float32List(n);
  for (var i = 0; i < n; i++) {
    lum[i] = luminanceOfRgb(
        grayRgb[i * 3], grayRgb[i * 3 + 1], grayRgb[i * 3 + 2]);
  }
  final vField = Float32List(n);
  for (var i = 0; i < n; i++) {
    vField[i] = math.max(
            grayRgb[i * 3], math.max(grayRgb[i * 3 + 1], grayRgb[i * 3 + 2])) /
        255.0;
  }
  final blurV = boxBlur(boxBlur(vField, width, height, 2), width, height, 2);

  // 锚点期望色相 + 发色圆周均值 + 各材质候选列表。
  final expHues = List<double>.generate(hints.length, (k) {
    final (h, s, _) = _rgbToHsv(
        hints[k].r / 255, hints[k].g / 255, hints[k].b / 255);
    return _expectedHue(materials[k], s <= 0 ? 0 : h);
  });
  double sinSum = 0, cosSum = 0;
  for (var k = 0; k < hints.length; k++) {
    if (materials[k] != 'hair') continue;
    final (h, s, _) = _rgbToHsv(
        hints[k].r / 255, hints[k].g / 255, hints[k].b / 255);
    if (s <= 0) continue;
    sinSum += math.sin(h * math.pi / 180);
    cosSum += math.cos(h * math.pi / 180);
  }
  var hairHue = 0.0;
  if (sinSum != 0 || cosSum != 0) {
    hairHue = (math.atan2(sinSum, cosSum) * 180 / math.pi + 360) % 360;
    for (var k = 0; k < hints.length; k++) {
      if (materials[k] == 'hair') expHues[k] = hairHue;
    }
  }

  // 语义扇区常数(全图通用, 无单图特判)。
  const skinLo = 10.0, skinHi = 32.0; // 自然肤色色相扇区
  const skyLo = 188.0, skyHi = 232.0; // 天空蓝扇区
  const hairTol = 38.0; // 发色色相容差

  // 预分类锚点: 每个材质一组锚点索引。
  final byMat = <String, List<int>>{};
  for (var k = 0; k < hints.length; k++) {
    byMat.putIfAbsent(materials[k], () => []).add(k);
  }
  List<int> matAnchors(String m) => byMat[m] ?? const [];

  var inkCount = 0, semanticCount = 0, geoCount = 0, synthCount = 0;
  var bandedCount = 0, skinFix = 0;

  for (var i = 0; i < n; i++) {
    final px = (i % width).toDouble();
    final py = (i ~/ width).toDouble();
    final r = rgb[i * 3] / 255.0;
    final g = rgb[i * 3 + 1] / 255.0;
    final b = rgb[i * 3 + 2] / 255.0;
    final (h0, s0, v0) = _rgbToHsv(r, g, b);

    // 墨线保留。
    if (v0 < 0.15) {
      out[i * 3] = rgb[i * 3];
      out[i * 3 + 1] = rgb[i * 3 + 1];
      out[i * 3 + 2] = rgb[i * 3 + 2];
      inkCount++;
      continue;
    }

    // ---- 材质判定 ----
    String mat = '';
    var contentMatched = false;
    if (semantic) {
      // 内容优先: 按像素自身色相落进哪个材质扇区。
      if (h0 >= skinLo && h0 <= skinHi && s0 >= 0.05 && v0 > 0.45) {
        mat = 'skin';
        contentMatched = true;
      } else if (h0 >= skyLo && h0 <= skyHi && s0 >= 0.06) {
        mat = 'sky';
        contentMatched = true;
      } else if (matAnchors('hair').isNotEmpty &&
          hairHue > 0 &&
          _hueDist(h0, hairHue) <= hairTol &&
          s0 >= 0.10) {
        mat = 'hair';
        contentMatched = true;
      } else if (s0 < 0.10 && v0 > 0.88 && matAnchors('white').isNotEmpty) {
        mat = 'white';
        contentMatched = true;
      }
    }
    if (!contentMatched) {
      // 几何决胜: 最近锚点(弱色/未知色相/消融模式)。
      // v9.1 修复: 中性亮像素禁止落入 white/backdrop 锚点 — 面部纸白区离白锚
      // 几何更近却被错误留白; 只允许 skin/hair/eye/blush/garment/garment2/sky 候选,
      // white 归属仅在内容识别命中白扇区时成立(那才是真白纸)。
      var bestK = -1;
      var bestScore = double.infinity;
      for (var k = 0; k < hints.length; k++) {
        final mk = materials[k];
        if (s0 < 0.08 && (mk == 'white' || mk == 'backdrop')) continue;
        final dx = px - hints[k].x;
        final dy = py - hints[k].y;
        final geo = math.sqrt(dx * dx + dy * dy);
        final w = semantic && s0 >= 0.08 ? _hueDist(h0, expHues[k]) * 30 : 0.0;
        final score = w + geo;
        if (score < bestScore) {
          bestScore = score;
          bestK = k;
        }
      }
      if (bestK < 0) {
        // 页面只有 white/backdrop 锚(纯风景页): 保留几何最近。
        for (var k = 0; k < hints.length; k++) {
          final dx = px - hints[k].x;
          final dy = py - hints[k].y;
          final geo = math.sqrt(dx * dx + dy * dy);
          if (geo < bestScore) {
            bestScore = geo;
            bestK = k;
          }
        }
      }
      mat = materials[bestK];
      geoCount++;
    } else {
      semanticCount++;
    }

    // white 中性亮像素保护(文字框/纸白)。
    if (mat == 'white' && s0 < 0.03 && v0 >= 0.90) {
      out[i * 3] = rgb[i * 3];
      out[i * 3 + 1] = rgb[i * 3 + 1];
      out[i * 3 + 2] = rgb[i * 3 + 2];
      inkCount++;
      continue;
    }

    // ---- 该材质的锚点色相(自由色材质用同扇区最近锚的色相) ----
    double matHue;
    if (mat == 'hair') {
      matHue = hairHue > 0 ? hairHue : expHues[hints.length > 0 ? 0 : 0];
    } else if (mat == 'skin') {
      matHue = 18;
    } else if (mat == 'blush') {
      matHue = 6;
    } else if (mat == 'sky') {
      matHue = 205;
    } else if (mat == 'white') {
      matHue = 210;
    } else {
      // garment/garment2/backdrop: 同材质锚点里找几何最近者。
      final anchors = matAnchors(mat);
      var bestD = double.infinity;
      var bestH = expHues.isNotEmpty ? expHues.first : 200.0;
      for (final k in anchors) {
        final dx = px - hints[k].x;
        final dy = py - hints[k].y;
        final d = dx * dx + dy * dy;
        if (d < bestD) {
          bestD = d;
          bestH = expHues[k];
        }
      }
      matHue = bestH;
    }
    final spec = _specFor(mat, matHue, 0.25);
    if (mat == 'skin' && h0 > 28 && s0 >= 0.08) skinFix++;

    // ---- 抖动 ----
    final jh = (noise.at(px, py) - 0.5) * 2 * hueJitter;
    final js = (noise2.at(px, py) - 0.5) * 2 * satJitter;
    final jl = (noise.at(px + 91.7, py + 37.3) - 0.5) * 2 * lumJitter;

    // ---- 着色 ----
    int or2, og, ob;
    if (ramp && mat != 'backdrop') {
      // v10 色阶配对: 灰度直接查材质色阶表得颜色 — 不是染色, 是查表。
      // 输入灰度用展平场(网点→平涂), 与彩漫灰阶一一对应。
      var t = blurV[i];
      // 分带: 暗部沿 ramp 下拉, 亮部上抬(色阶内部的自然层次)。
      if (banded) {
        final y0 = lum[i];
        t += (y0 - blurV[i]) * 0.55; // 恢复部分原稿网点对比度
      }
      var (rr, gg, bb) = _rampLookup(_rampFor(mat), t + jl * 0.6);
      // 确定性色相微偏移(单色 ramp 上的自然抖动): 转 HSV 抖色相后回 RGB。
      final (rh, rs, rv) = _rgbToHsv(rr / 255, gg / 255, bb / 255);
      final (rh2, rs2, rv2) = (
        _shiftHue(rh, jh),
        (rs + js).clamp(0.0, 0.9),
        (rv + jl * 0.5).clamp(0.0, 1.0)
      );
      final (fr, fg, fb) = _hsvToRgb(rh2, rs2, rv2);
      or2 = fr;
      og = fg;
      ob = fb;
    } else {
      // 旧路径(色度染色, --no-ramp 或 backdrop): 保留 v9.1 逻辑。
      var hue = matHue;
      var sat = spec.sat;
      double val;
      if (s0 < 0.03) {
        sat = mat == 'white' ? 0.035 : spec.sat * 0.55;
        val = blurV[i];
      } else {
        sat = spec.sat * (0.8 + 0.4 * math.min(s0 / 0.30, 1.0));
        final pull = _hueDist(h0, hue) < 45 ? (h0 - hue) * 0.30 : 0.0;
        hue = _shiftHue(hue, pull);
        val = v0;
      }
      if (banded) {
        final y = lum[i];
        final darkT = _smooth((0.62 - y) / 0.30);
        final lightT = _smooth((y - 0.86) / 0.12);
        if (darkT > 0) {
          hue = _shiftHue(hue, spec.darkHueShift * darkT);
          sat = (sat * (1 + (spec.darkSatGain - 1) * darkT)).clamp(0.0, 0.80);
        }
        if (lightT > 0) {
          hue = _shiftHue(hue, spec.lightHueShift * lightT);
          sat = (sat * (1 - spec.lightSatDrop * lightT)).clamp(0.0, 0.80);
        }
      }
      hue = _shiftHue(hue, jh);
      sat = (sat + js).clamp(0.0, 0.85);
      val = (val + jl).clamp(0.0, 1.0);
      final (rr, gg, bb) = _hsvToRgb(hue, sat, val);
      or2 = rr;
      og = gg;
      ob = bb;
    }
    out[i * 3] = or2;
    out[i * 3 + 1] = og;
    out[i * 3 + 2] = ob;
  }
  stdout.writeln('semanticPass v9: 墨线 $inkCount, 语义命中 $semanticCount, '
      '几何决胜 $geoCount, 中性合成 $synthCount, 分带 $bandedCount, '
      '肤色去黄修正 $skinFix');
  return out;
}
