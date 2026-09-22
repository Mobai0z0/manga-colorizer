import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:manga_colorizer_cli/src/cli_io.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 原生彩漫质感上色 v8 (material): 全图覆盖 + 色相感知精确归属。
///
/// 设计要点:
///   1) 全图覆盖: 中性像素(灰阶/网点/未锚定区域, v≥0.15)不再保留灰色,
///      按最近锚点材质合成颜色(饱和 ×0.55 收敛), 亮度用展平场(网点→平涂);
///      纯墨线(v<0.15)仍然原样保留 — 线稿纯净。
///   2) 精确归属: 彩色像素(s≥0.08)按「扩散色相 vs 材质期望色相」×30 + 几何距离
///      综合评分选材质 — 皮肤渗到头发区的像素会被拉回正确配方;
///      弱色像素(0.03≤s<0.08)以几何为主(色相权重 ×5)防误判。
///   3) 发色统一: 同页 hair 锚点色相取圆周均值, 消除多锚点色相差造成的斑块。
///   4) 结构耦合: 彩色像素饱和度随扩散置信度浮动(0.8–1.2×), 色相向扩散色相
///      偏移 35% — 色块内部随结构自然变化。
///
/// 用法:
///   dart run bin/material_colorize.dart -i in.png -o out.png \
///     --hints hints.json [--seed 7] [--hue-jitter 6] [--no-banded]
Future<void> main(List<String> args) async {
  String? input;
  String? output;
  String? hintsPath;
  var seed = 7;
  var hueJitter = 6.0;
  var satJitter = 0.045;
  var lumJitter = 0.030;
  var banded = true;
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
      case '--sat-jitter':
        satJitter = double.parse(args[++i]);
      case '--lum-jitter':
        lumJitter = double.parse(args[++i]);
      case '--no-banded':
        banded = false;
      default:
        stderr.writeln('未知参数: ${args[i]}');
        exitCode = 64;
        return;
    }
  }
  if (input == null || output == null || hintsPath == null) {
    stderr.writeln(
        '用法: dart run bin/material_colorize.dart -i <输入> -o <输出> --hints <json> '
        '[--seed 7] [--hue-jitter 6] [--no-banded]');
    exitCode = 64;
    return;
  }

  final source = CliIo.readGrayscale(input);
  final hintsRaw = jsonDecode(File(hintsPath).readAsStringSync()) as List;
  final hints = <ColorHint>[];
  final materials = <String>[];
  for (final e in hintsRaw) {
    final m = e as Map<String, Object?>;
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

  final out = materialPass(
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
  );
  CliIo.writePng(output, out, source.width, source.height);
  stdout.writeln('material_colorize 完成: 扩散 ${result.iterations} 次/'
      '$diffuseMs ms, seed=$seed hueJitter=$hueJitter banded=$banded');
}

double _smooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

/// 确定性 2D 值噪声 (种子锁定, 平滑插值)。
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

  /// [x,y] 处的平滑噪声, 值域 [0,1]。格子约 24px。
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

/// 材质槽位的上色配方: 目标色相/饱和度, 暗部偏移, 亮部偏移。
class _MatSpec {
  _MatSpec(this.hue, this.sat, this.darkHueShift, this.darkSatGain,
      this.lightHueShift, this.lightSatDrop);
  final double hue;
  final double sat;
  final double darkHueShift; // 暗部色相偏移(度, 负=向暖/红)
  final double darkSatGain;
  final double lightHueShift; // 亮部色相偏移(度, 正=向冷/青)
  final double lightSatDrop;
}

_MatSpec _specFor(String material, double hintHue, double hintSat) {
  switch (material) {
    case 'skin':
      return _MatSpec(22, 0.32, -8, 1.35, 10, 0.25);
    case 'blush':
      return _MatSpec(8, 0.45, -5, 1.2, 8, 0.2);
    case 'hair':
      return _MatSpec(hintHue, math.max(hintSat, 0.30), -14, 1.30, 12, 0.30);
    case 'eye':
      return _MatSpec(hintHue, math.max(hintSat, 0.40), -10, 1.25, 10, 0.25);
    case 'garment':
      return _MatSpec(hintHue, math.max(hintSat, 0.28), -12, 1.28, 14, 0.28);
    case 'garment2':
      return _MatSpec(hintHue, math.max(hintSat, 0.24), -12, 1.28, 14, 0.28);
    case 'sky':
      return _MatSpec(hintHue <= 0 ? 205 : hintHue, 0.38, -6, 1.15, 8, 0.18);
    case 'backdrop':
      return _MatSpec(hintHue, math.max(hintSat * 1.1, 0.12), -8, 1.20, 10, 0.30);
    case 'white':
      return _MatSpec(hintHue <= 0 ? 210 : hintHue, 0.06, -10, 2.2, 0, 0.5);
    default:
      return _MatSpec(hintHue, math.max(hintSat * 0.8, 0.10), -8, 1.20, 10, 0.30);
  }
}

/// 材质期望色相(用于精确归属): 固定配方材质用默认值, 自由色材质用锚点自身色相。
double _expectedHue(String material, double hintHue) {
  switch (material) {
    case 'skin':
      return 22;
    case 'blush':
      return 8;
    case 'sky':
      return 205;
    case 'white':
      return 210;
    default:
      return hintHue;
  }
}

Uint8List materialPass(
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
}) {
  final n = rgb.length ~/ 3;
  final out = Uint8List(rgb.length);
  final noise = ValueNoise(seed);
  final noise2 = ValueNoise(seed + 101);

  // 原稿亮度场(明暗分带)。
  final lum = Float32List(n);
  for (var i = 0; i < n; i++) {
    lum[i] = luminanceOfRgb(
        grayRgb[i * 3], grayRgb[i * 3 + 1], grayRgb[i * 3 + 2]);
  }

  // 展平亮度场(网点→平涂): 盒模糊 ×2。
  final vField = Float32List(n);
  for (var i = 0; i < n; i++) {
    vField[i] = math.max(
            grayRgb[i * 3], math.max(grayRgb[i * 3 + 1], grayRgb[i * 3 + 2])) /
        255.0;
  }
  final blurV = boxBlur(boxBlur(vField, width, height, 2), width, height, 2);

  // 每锚点: 期望色相。hair 材质取圆周均值(消除多锚点色相差斑块)。
  final expHues = List<double>.generate(hints.length, (k) {
    final (h, s, _) = _rgbToHsv(hints[k].r / 255, hints[k].g / 255,
        hints[k].b / 255);
    return _expectedHue(materials[k], s <= 0 ? 0 : h);
  });
  double sinSum = 0, cosSum = 0;
  for (var k = 0; k < hints.length; k++) {
    if (materials[k] != 'hair') continue;
    final (h, s, _) = _rgbToHsv(hints[k].r / 255, hints[k].g / 255,
        hints[k].b / 255);
    if (s <= 0) continue;
    sinSum += math.sin(h * math.pi / 180);
    cosSum += math.cos(h * math.pi / 180);
  }
  if (sinSum != 0 || cosSum != 0) {
    final canonical = (math.atan2(sinSum, cosSum) * 180 / math.pi + 360) % 360;
    for (var k = 0; k < hints.length; k++) {
      if (materials[k] == 'hair') expHues[k] = canonical;
    }
  }

  var inkCount = 0;
  var synthCount = 0;
  var chromaAssigned = 0;
  var geoAssigned = 0;
  var bandedCount = 0;

  for (var i = 0; i < n; i++) {
    final px = (i % width).toDouble();
    final py = (i ~/ width).toDouble();
    final r = rgb[i * 3] / 255.0;
    final g = rgb[i * 3 + 1] / 255.0;
    final b = rgb[i * 3 + 2] / 255.0;
    final (h0, s0, v0) = _rgbToHsv(r, g, b);

    // 墨线/深色: 原样保留。
    if (v0 < 0.15) {
      out[i * 3] = rgb[i * 3];
      out[i * 3 + 1] = rgb[i * 3 + 1];
      out[i * 3 + 2] = rgb[i * 3 + 2];
      inkCount++;
      continue;
    }

    // 全图归属: 对每个像素全量扫描锚点(无半径上限)。
    var bestK = 0;
    var bestScore = double.infinity;
    for (var k = 0; k < hints.length; k++) {
      final dx = px - hints[k].x;
      final dy = py - hints[k].y;
      final geo = math.sqrt(dx * dx + dy * dy);
      double score;
      if (s0 >= 0.08) {
        // 强色度: 色相主导(×30), 修正跨区渗色。
        score = _hueDist(h0, expHues[k]) * 30 + geo;
      } else if (s0 >= 0.03) {
        // 弱色度: 几何为主, 色相轻微参考。
        score = _hueDist(h0, expHues[k]) * 5 + geo;
      } else {
        // 中性: 纯几何。
        score = geo;
      }
      if (score < bestScore) {
        bestScore = score;
        bestK = k;
      }
    }
    var mat = materials[bestK];

    // v8.1 文字框/白纸保护: 中性像素(s<0.03)落到 white 材质时保留纸白不上色,
    // 只有本来就是彩色的 white 区(如有底色气泡)才注入淡色。
    if (mat == 'white' && s0 < 0.03 && v0 >= 0.90) {
      out[i * 3] = rgb[i * 3];
      out[i * 3 + 1] = rgb[i * 3 + 1];
      out[i * 3 + 2] = rgb[i * 3 + 2];
      inkCount++;
      continue;
    }
    final (hh0, hs0, _) = _rgbToHsv(hints[bestK].r / 255, hints[bestK].g / 255,
        hints[bestK].b / 255);
    final spec = _specFor(mat, s0 >= 0.03 ? hh0 : expHues[bestK],
        s0 >= 0.03 ? hs0 : 0.2);
    if (s0 >= 0.03) {
      if (s0 >= 0.08) {
        chromaAssigned++;
      } else {
        geoAssigned++;
      }
    } else {
      synthCount++;
    }

    // 像素级确定性抖动。
    final jh = (noise.at(px, py) - 0.5) * 2 * hueJitter;
    final js = (noise2.at(px, py) - 0.5) * 2 * satJitter;
    final jl = (noise.at(px + 91.7, py + 37.3) - 0.5) * 2 * lumJitter;

    // 明暗分带: 以原稿亮度驱动暗部/亮部偏移。
    final y = lum[i];
    var hue = spec.hue;
    var sat = spec.sat;
    double val;
    if (s0 < 0.03) {
      // 中性合成: 饱和收敛 ×0.55, 亮度用展平场(网点→平涂)。
      sat = mat == 'white' ? 0.035 : spec.sat * 0.55;
      val = blurV[i];
    } else {
      // 结构耦合: 饱和随扩散置信度浮动, 色相向扩散色相偏移 35%。
      sat = spec.sat * (0.8 + 0.4 * math.min(s0 / 0.30, 1.0));
      final pull = _hueDist(h0, hue) < 90
          ? (h0 - hue) * 0.35
          : 0.0; // 色相差过大(>90°)不信任扩散色相
      hue = _shiftHue(hue, pull);
      val = v0;
    }
    if (banded) {
      final darkT = _smooth((0.62 - y) / 0.30);
      final lightT = _smooth((y - 0.86) / 0.12);
      if (darkT > 0) {
        hue = _shiftHue(hue, spec.darkHueShift * darkT);
        sat = (sat * (1 + (spec.darkSatGain - 1) * darkT)).clamp(0.0, 0.85);
        bandedCount++;
      }
      if (lightT > 0) {
        hue = _shiftHue(hue, spec.lightHueShift * lightT);
        sat = (sat * (1 - spec.lightSatDrop * lightT)).clamp(0.0, 0.85);
      }
    }

    hue = _shiftHue(hue, jh);
    sat = (sat + js).clamp(0.0, 0.9);
    val = (val + jl).clamp(0.0, 1.0);

    final (rr, gg, bb) = _hsvToRgb(hue, sat, val);
    out[i * 3] = rr;
    out[i * 3 + 1] = gg;
    out[i * 3 + 2] = bb;
  }
  final uncolored = n - inkCount - synthCount - chromaAssigned - geoAssigned;
  stdout.writeln('materialPass v8: 墨线保留 $inkCount, 中性合成 $synthCount, '
      '强色归属 $chromaAssigned, 弱色归属 $geoAssigned, 分带 $bandedCount, '
      '覆盖未及 $uncolored (${(100 * uncolored / n).toStringAsFixed(2)}%)');
  return out;
}
