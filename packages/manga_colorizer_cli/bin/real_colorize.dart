import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:manga_colorizer_cli/src/cli_io.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 真彩漫质感上色 v4: 色度扩散(保结构) + celBoost 饱和度重建(空间掩码版)。
///
/// 相对 v3 的修复:
///   1) 皮肤色相带增益只作用在 role=skin 锚点周围的空间掩码内 — 背景不再被泛染 Sepia;
///   2) 掩码外弱色度 (s2<0.20) 压回近白 — 扩散渗漏的淡橙被清除;
///   3) 平坦弱色区 (s2<0.20) 亮度用 boxBlur 场替换 — 网点残粒展平, 接近彩漫平涂;
///   4) 墨线/中性灰(sHsv<0.02)原样保留, 强色度区(发/瞳/腮红/衣物)保留原纹理。
///
/// 用法:
///   dart run bin/real_colorize.dart -i in.png -o out.png --hints hints.json \
///     --options options.json [--sat-gain 2.6] [--skin-s 0.27] [--skin-dv 0.10]
Future<void> main(List<String> args) async {
  String? input;
  String? output;
  String? hintsPath;
  String? optionsPath;
  var satGain = 2.6;
  var vPull = 0.10;
  var satCap = 0.78;
  var skinS = 0.27;
  var skinDv = 0.10;
  var skinR = 240.0;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-i':
        input = args[++i];
      case '-o':
        output = args[++i];
      case '--hints':
        hintsPath = args[++i];
      case '--options':
        optionsPath = args[++i];
      case '--sat-gain':
        satGain = double.parse(args[++i]);
      case '--v-pull':
        vPull = double.parse(args[++i]);
      case '--sat-cap':
        satCap = double.parse(args[++i]);
      case '--skin-s':
        skinS = double.parse(args[++i]);
      case '--skin-dv':
        skinDv = double.parse(args[++i]);
      case '--skin-r':
        skinR = double.parse(args[++i]);
      default:
        stderr.writeln('未知参数: ${args[i]}');
        exitCode = 64;
        return;
    }
  }
  if (input == null || output == null || hintsPath == null) {
    stderr.writeln('用法: dart run bin/real_colorize.dart -i <输入> -o <输出> '
        '--hints <json> [--options <json>]');
    exitCode = 64;
    return;
  }

  final source = CliIo.readGrayscale(input);
  final hintsRaw = jsonDecode(File(hintsPath).readAsStringSync()) as List;
  final hints = hintsRaw
      .map((e) => ColorHint.fromJson(e as Map<String, Object?>))
      .toList();
  final options = optionsPath == null
      ? const ColorizeOptions(maxIterations: 1500, descreen: true)
      : ColorizeOptions.fromJson(
          jsonDecode(File(optionsPath).readAsStringSync()) as Object?);

  final watch = Stopwatch()..start();
  final result = colorizeManga(
    grayscaleRgb: source.rgb,
    width: source.width,
    height: source.height,
    hints: hints,
    options: options,
  );
  final boostMs = watch.elapsedMilliseconds;

  final out = celBoost(
    result.rgb,
    source.width,
    source.height,
    hints,
    satGain: satGain,
    vPull: vPull,
    satCap: satCap,
    skinS: skinS,
    skinDv: skinDv,
    skinR: skinR,
  );
  CliIo.writePng(output, out, source.width, source.height);
  stdout.writeln(
      'real_colorize 完成: 扩散 ${result.iterations} 次/${boostMs}ms, '
      'celBoost satGain=$satGain skinS=$skinS skinDv=$skinDv');
}

double _smooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

Uint8List celBoost(
  Uint8List rgb,
  int width,
  int height,
  List<ColorHint> hints, {
  required double satGain,
  required double vPull,
  required double satCap,
  required double skinS,
  required double skinDv,
  required double skinR,
}) {
  final n = rgb.length ~/ 3;
  final out = Uint8List(rgb.length);

  // 皮肤空间掩码: role=skin 锚点周围平滑衰减。
  final skinMask = Float32List(n);
  for (final h in hints) {
    if (h.role != 'skin') continue;
    final cx = h.x.toDouble();
    final cy = h.y.toDouble();
    final x0 = (cx - skinR).floor().clamp(0, width - 1);
    final x1 = (cx + skinR).ceil().clamp(0, width - 1);
    final y0 = (cy - skinR).floor().clamp(0, height - 1);
    final y1 = (cy + skinR).ceil().clamp(0, height - 1);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final dx = x - cx;
        final dy = y - cy;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d >= skinR) continue;
        final w = 1 - d / skinR;
        final idx = y * width + x;
        if (w > skinMask[idx]) skinMask[idx] = w;
      }
    }
  }

  // 平坦区亮度展平场: 对扩散结果的 V 做 boxBlur ×2。
  final vField = Float32List(n);
  for (var i = 0; i < n; i++) {
    final r = rgb[i * 3];
    final g = rgb[i * 3 + 1];
    final b = rgb[i * 3 + 2];
    vField[i] = math.max(r, math.max(g, b)) / 255.0;
  }
  final blurV = boxBlur(boxBlur(vField, width, height, 2), width, height, 2);

  var touched = 0;
  var skinned = 0;
  for (var i = 0; i < n; i++) {
    final r = rgb[i * 3] / 255.0;
    final g = rgb[i * 3 + 1] / 255.0;
    final b = rgb[i * 3 + 2] / 255.0;
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    final v = mx;
    final sHsv = mx <= 0 ? 0.0 : (mx - mn) / mx;

    // 墨线与中性灰原样保留。
    if (sHsv < 0.02 || v < 0.02) {
      out[i * 3] = rgb[i * 3];
      out[i * 3 + 1] = rgb[i * 3 + 1];
      out[i * 3 + 2] = rgb[i * 3 + 2];
      continue;
    }
    touched++;

    final d = mx - mn;
    double h;
    if (mx == r) {
      h = 60 * ((g - b) / d % 6);
    } else if (mx == g) {
      h = 60 * ((b - r) / d + 2);
    } else {
      h = 60 * ((r - g) / d + 4);
    }
    if (h < 0) h += 360;

    // 1) 饱和度重建; 3) 阴影再增饱和。
    var s2 = (sHsv * satGain).clamp(0.0, satCap);
    if (v < 0.6) s2 = (s2 * 1.08).clamp(0.0, 0.85);

    // 2) 高光下拉着色。
    var v2 = (v - vPull * s2 * _smooth((v - 0.8) / 0.2)).clamp(0.0, 1.0);

    final mask = skinMask[i];
    var band = 0.0;

    // 2b) 皮肤桃色: 只在掩码内 + 皮肤色相带 + 弱色度(纸白脸)生效。
    if (mask > 0 && h >= 8 && h <= 45 && s2 < 0.15) {
      band = mask * _smooth((0.15 - s2) / 0.06);
      s2 = (s2 + (skinS - s2) * band).clamp(0.0, 0.5);
    }

    // 4) 平坦弱色区: 展平网点残粒 + 掩码外渗漏压制。
    if (s2 < 0.20) {
      if (mask < 0.5) {
        s2 = s2 * (0.25 + 0.75 * _smooth((s2 - 0.02) / 0.18));
      }
      final bv = blurV[i];
      v2 = (bv - vPull * s2 * _smooth((bv - 0.8) / 0.2)).clamp(0.0, 1.0);
    }
    v2 = (v2 - skinDv * band).clamp(0.55, 1.0);
    if (band > 0.3) skinned++;

    // HSV -> RGB。
    final c = v2 * s2;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = v2 - c;
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
    out[i * 3] = ((rr + m) * 255).round().clamp(0, 255);
    out[i * 3 + 1] = ((gg + m) * 255).round().clamp(0, 255);
    out[i * 3 + 2] = ((bb + m) * 255).round().clamp(0, 255);
  }
  stdout.writeln(
      'celBoost: $touched/$n 像素重建饱和度, 皮肤掩码染色 $skinned 像素');
  return out;
}
