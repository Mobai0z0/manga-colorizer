import 'dart:math' as math;
import 'dart:typed_data';

import 'filters.dart';
import 'geometry.dart';
import 'skin.dart';
import 'yuv.dart';
import 'white_regions.dart';

/// 提示点在色板体系下的可选部位标签 (如 skin/hair/uniform),
/// 用于肤色常识约束与验收取样。
class ColorHint {
  final int x;
  final int y;
  final int r;
  final int g;
  final int b;
  final String? role;

  const ColorHint({
    required this.x,
    required this.y,
    required this.r,
    required this.g,
    required this.b,
    this.role,
  });

  factory ColorHint.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('hint 必须是对象 {"x","y","r","g","b"}');
    }
    final role = json['role'];
    if (role != null && role is! String) {
      throw const FormatException('hint.role 必须是字符串');
    }
    return ColorHint(
      x: _readInt(json, 'x'),
      y: _readInt(json, 'y'),
      r: _readInt(json, 'r', min: 0, max: 255),
      g: _readInt(json, 'g', min: 0, max: 255),
      b: _readInt(json, 'b', min: 0, max: 255),
      role: role as String?,
    );
  }

  Map<String, Object> toJson() => role == null
      ? {'x': x, 'y': y, 'r': r, 'g': g, 'b': b}
      : {
          'x': x,
          'y': y,
          'r': r,
          'g': g,
          'b': b,
          'role': role!,
        };
}

int _readInt(Map json, String key, {int min = 0, int max = 1 << 31}) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('options.$key 必须是整数,实际为 $value');
  }
  if (value < min || value > max) {
    throw FormatException('options.$key=$value 超出允许范围 [$min, $max]');
  }
  return value;
}

/// 可选整数字段: 缺键返回 [fallback],存在时校验范围。
int _readOptionalInt(Map json, String key, int fallback,
    {required int min, required int max}) {
  final value = json[key];
  if (value == null) return fallback;
  return _readInt(json, key, min: min, max: max);
}

/// 上色参数。
class ColorizeOptions {
  /// 亮度相似度带宽,越小越尊重线稿边界。
  final double sigma;

  /// 权重下限 (默认 1e-6,仅作数值稳定;调大会让色度跨边界渗透)。
  final double epsilon;

  /// 最大迭代次数。
  final int maxIterations;

  /// SOR 松弛因子, ∈ (0,2)。
  final double sorOmega;

  /// 收敛阈值。
  final double tolerance;

  /// 将接近纯黑/纯白的像素锁定为无色,稳定求解并保持纸白与墨色
  /// (与 manga-colorization-v2 的 scribble 预处理行为一致)。
  final bool lockPureMonochrome;

  /// 把提示色的色度幅值按 目标亮度/提示色亮度 缩放后再作为边界条件。
  ///
  /// 提示色只传达"色相意图": 深色提示色自身色度幅值小,直接使用会在
  /// 深色区域染不上色;开启后按亮度比例放大/缩小色度,上色更饱满
  /// (Levin 参考实现同款技巧)。缩放系数限幅 [0.2, 5]。
  final bool adaptHintChromaToLuminance;

  /// 区域色度校正 (后处理): 按最近提示点归属,把区域内色度幅值
  /// 拉向提示色目标,修复远端发灰与多提示点同区混色发闷。
  final bool regionChromaCorrection;

  /// 区域校正幅值增益 (1.0 = 提示色目标幅值;>1 加饱和,&lt;1 减饱和)。
  final double chromaMagnitudeGain;

  /// 区域校正色向插值强度 (0 = 完全保留扩散场色向,1 = 完全对齐提示色相)。
  final double hueCorrectionStrength;

  /// 区域归属度量中亮度距离的权重 (亮度差异越大越视为不同区域)。
  final double regionLuminanceWeight;

  /// 网点去噪 (descreen): 对色度扩散的权重亮度场做 3×3 中值滤波 ×2,
  /// 消除网点高频振荡导致的色块发闷; 输出亮度仍保留原稿。
  /// 日漫网点页建议开启。
  final bool descreen;

  /// 对 role=skin 的提示区域施加自然肤色扇区约束:
  /// 色相钳进暖色窄带、幅值限幅,从机制上杜绝发绿/发灰/蜡像感。
  final bool enforceNaturalSkin;

  /// 亮度 ≤ 该值视为墨黑。
  final double monochromeLowThreshold;

  /// 平涂有明确提示的封闭近白区域；关闭可恢复严格保亮度模式。
  final bool fillClosedWhiteRegions;

  /// 亮度 ≥ 该值视为纸白。
  final double monochromeHighThreshold;

  const ColorizeOptions({
    this.sigma = kDefaultSigma,
    this.epsilon = kDefaultEpsilon,
    this.maxIterations = 300,
    this.sorOmega = kDefaultSorOmega,
    this.tolerance = kDefaultTolerance,
    this.lockPureMonochrome = true,
    this.adaptHintChromaToLuminance = true,
    this.regionChromaCorrection = true,
    this.chromaMagnitudeGain = 1.0,
    this.hueCorrectionStrength = 0.35,
    this.regionLuminanceWeight = 4.0,
    this.enforceNaturalSkin = true,
    this.descreen = false,
    this.fillClosedWhiteRegions = true,
    this.monochromeLowThreshold = 0.05,
    this.monochromeHighThreshold = 0.95,
  });

  factory ColorizeOptions.fromJson(Object? json) {
    if (json == null) return const ColorizeOptions();
    if (json is! Map) {
      throw const FormatException('options 必须是对象');
    }
    const defaults = ColorizeOptions();
    return ColorizeOptions(
      sigma: _readDouble(json, 'sigma', defaults.sigma,
          min: 0.001, max: 1.0),
      epsilon: _readDouble(json, 'epsilon', defaults.epsilon,
          min: 0.0, max: 1.0),
      maxIterations: _readOptionalInt(
          json, 'maxIterations', defaults.maxIterations,
          min: 1, max: 5000),
      sorOmega: _readDouble(json, 'sorOmega', defaults.sorOmega,
          min: 0.05, max: 1.95),
      tolerance: _readDouble(json, 'tolerance', defaults.tolerance,
          min: 1e-8, max: 1.0),
      lockPureMonochrome: _readBool(
          json, 'lockPureMonochrome', defaults.lockPureMonochrome),
      adaptHintChromaToLuminance: _readBool(json,
          'adaptHintChromaToLuminance', defaults.adaptHintChromaToLuminance),
      regionChromaCorrection: _readBool(
          json, 'regionChromaCorrection', defaults.regionChromaCorrection),
      chromaMagnitudeGain: _readDouble(json, 'chromaMagnitudeGain',
          defaults.chromaMagnitudeGain,
          min: 0.0, max: 2.0),
      hueCorrectionStrength: _readDouble(json, 'hueCorrectionStrength',
          defaults.hueCorrectionStrength,
          min: 0.0, max: 1.0),
      regionLuminanceWeight: _readDouble(json, 'regionLuminanceWeight',
          defaults.regionLuminanceWeight,
          min: 0.0, max: 100.0),
      enforceNaturalSkin:
          _readBool(json, 'enforceNaturalSkin', defaults.enforceNaturalSkin),
      descreen: _readBool(json, 'descreen', defaults.descreen),
      fillClosedWhiteRegions: _readBool(
          json, 'fillClosedWhiteRegions', defaults.fillClosedWhiteRegions),
      monochromeLowThreshold: _readDouble(
          json, 'monochromeLowThreshold', defaults.monochromeLowThreshold,
          min: 0.0, max: 0.5),
      monochromeHighThreshold: _readDouble(
          json, 'monochromeHighThreshold', defaults.monochromeHighThreshold,
          min: 0.5, max: 1.0),
    );
  }
}

double _readDouble(Map json, String key, double fallback,
    {required double min, required double max}) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is! num) {
    throw FormatException('options.$key 必须是数字,实际为 $value');
  }
  final d = value.toDouble();
  if (d.isNaN || d < min || d > max) {
    throw FormatException('options.$key=$d 超出允许范围 [$min, $max]');
  }
  return d;
}

bool _readBool(Map json, String key, bool fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is! bool) {
    throw FormatException('options.$key 必须是布尔值,实际为 $value');
  }
  return value;
}

/// 上色结果。
class ColorizeResult {
  final int width;
  final int height;

  /// 8bit RGB (3 通道交错)。
  final Uint8List rgb;
  final int iterations;
  final double maxDelta;
  final int hintCount;
  final int lockedMonochromeCount;

  const ColorizeResult(
      this.width, this.height, this.rgb, this.iterations, this.maxDelta,
      this.hintCount, this.lockedMonochromeCount);
}

/// 对黑白漫画灰度图做提示点上色 (核心入口)。
///
/// [grayscaleRgb] 为 8bit RGB 三通道交错 (通常 r=g=b,由调用方保证),
/// 提示点颜色按 YUV 色度扩散到亮度相近的连通区域。
ColorizeResult colorizeManga({
  required Uint8List grayscaleRgb,
  required int width,
  required int height,
  List<ColorHint> hints = const [],
  ColorizeOptions options = const ColorizeOptions(),
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('图像宽高必须大于 0');
  }
  for (final hint in hints) {
    if (hint.x < 0 || hint.x >= width || hint.y < 0 || hint.y >= height) {
      throw ArgumentError('提示点坐标超出图像范围');
    }
  }
  final pixelCount = width * height;
  if (grayscaleRgb.length != pixelCount * 3) {
    throw ArgumentError(
        'grayscaleRgb 长度 (${grayscaleRgb.length}) 与 ${width}x$height 的 '
        'RGB 图像不匹配');
  }
  final luminance = Float32List(pixelCount);
  for (var i = 0; i < pixelCount; i++) {
    luminance[i] = luminanceOfRgb(
        grayscaleRgb[i * 3], grayscaleRgb[i * 3 + 1], grayscaleRgb[i * 3 + 2]);
  }
  // 多尺度预解: 粗层全局色场作为全分辨率初值 (大图收敛加速)。
  // descreen 开启时, 求解/锁定/归属统一用均值场 (网点→灰阶的反解:
  // 盒模糊对 50% 棋盘网点收敛到均值; 中值滤波对半频棋盘无效, 仍交替),
  // 输出亮度仍用原稿 (线稿/明暗无损, 展平条件见下方输出循环)。
  final descreenField =
      options.descreen ? boxBlur(luminance, width, height, 2) : luminance;
  final weightLum = descreenField;
  final initial =
      _coarseInitialField(width, height, weightLum, hints, options);
  final solver = ChromaSolver(
    width: width,
    height: height,
    luminance: weightLum,
    sigma: options.sigma,
    epsilon: options.epsilon,
    initialU: initial?.$1,
    initialV: initial?.$2,
  );
  // 先加用户提示点 (用户意图优先),再锁定剩余纯黑白像素。
  // role=skin 的提示点色度先钳进自然肤色扇区。
  for (final hint in hints) {
    final (hintY, hintU, hintV) =
        rgbToYuv(hint.r / 255, hint.g / 255, hint.b / 255);
    var (bu, bv) = (hintU, hintV);
    if (options.enforceNaturalSkin && hint.role == 'skin') {
      (bu, bv) = enforceNaturalSkin(hintU, hintV);
    }
    if (options.adaptHintChromaToLuminance && hintY > 1 / 255) {
      final pixelY = weightLum[hint.y * width + hint.x];
      final scale = (pixelY / hintY).clamp(0.2, 5.0);
      solver.addHint(hint.x, hint.y,
          u: (bu * scale).clamp(-0.5, 0.5),
          v: (bv * scale).clamp(-0.5, 0.5));
    } else {
      solver.addHint(hint.x, hint.y, u: bu, v: bv);
    }
  }
  if (options.lockPureMonochrome) {
    for (var i = 0; i < pixelCount; i++) {
      if (solver.isFixedAt(i)) continue;
      // descreen 时按均值场判定黑白锁定: 网点块的均值是真实灰阶,
      // 原亮度 0/255 会把整块网点锁成中性, 色度无法扩散。
      final y = weightLum[i];
      if (y <= options.monochromeLowThreshold ||
          y >= options.monochromeHighThreshold) {
        solver.lockNeutral(i);
      }
    }
  }
  final solution = solver.solve(
    maxIterations: options.maxIterations,
    sorOmega: options.sorOmega,
    tolerance: options.tolerance,
  );
  // 区域色度校正: 把每个区域的色度幅值/色向拉向提示色目标,修
  // ① 深色提示在远端幅值衰减发灰 ② 多提示点同区混色发闷。
  final correctedU = Float32List.fromList(solution.u);
  final correctedV = Float32List.fromList(solution.v);
  Int32List? assignment;
  if (hints.isNotEmpty) {
    assignment = _nearestHintAssignment(
        correctedU, correctedV, luminance, width, height, hints, options);
  }
  if (options.regionChromaCorrection && hints.isNotEmpty) {
    _applyRegionChromaCorrection(correctedU, correctedV, luminance, width,
        height, hints, options, assignment!);
  }
  // 后处理不能覆盖用户固定的提示点；同坐标最后一个提示优先。
  for (var t = 0; t < hints.length; t++) {
    final i = hints[t].y * width + hints[t].x;
    correctedU[i] = solution.u[i];
    correctedV[i] = solution.v[i];
    assignment![i] = t;
  }
  final out = Uint8List(pixelCount * 3);
  final skinHintIdx = <int>[
    for (var t = 0; t < hints.length; t++)
      if (hints[t].role == 'skin') t
  ];
  for (var i = 0; i < pixelCount; i++) {
    var cu = correctedU[i];
    var cv = correctedV[i];
    // 仅 skin 提示归属区域: 输出前把非中性色度二次钳进自然肤色扇区。
    if (options.enforceNaturalSkin &&
        skinHintIdx.isNotEmpty &&
        assignment != null &&
        skinHintIdx.contains(assignment[i]) &&
        (_mag(cu, cv) > 1e-4)) {
      final (su, sv) = enforceNaturalSkin(cu, cv);
      cu = su;
      cv = sv;
    }
    // 输出亮度: descreen 开启时网点像素展平为均值场 (网点→均匀色层);
    // 均值场亮 ≤0.12 的墨线原样保留 (与原行为在无网点图上等价)。
    var outY = luminance[i];
    if (options.descreen && descreenField[i] > 0.12) {
      outY = descreenField[i];
    }
    // 保色相色域映射: 超出色域时等比缩小色度,不逐通道截断。
    final (r, g, b) = yuvToRgbGamut(outY, cu, cv);
    out[i * 3] = (r * 255).round().clamp(0, 255);
    out[i * 3 + 1] = (g * 255).round().clamp(0, 255);
    out[i * 3 + 2] = (b * 255).round().clamp(0, 255);
  }
  final filled = options.fillClosedWhiteRegions && options.lockPureMonochrome
      ? fillClosedWhiteRegions(
          source: grayscaleRgb, output: out, width: width, height: height,
          hints: hints, threshold: options.monochromeHighThreshold,
          naturalSkin: options.enforceNaturalSkin)
      : 0;
  return ColorizeResult(width, height, out, solution.iterations,
      solution.maxDelta, solver.hintCount, solver.lockedMonochromeCount - filled);
}

/// 按 "亮度距离 + 空间距离" 给每个带色度像素标记最近提示点索引。
/// 中性像素 (锁定黑白/无色区) 标记 -1。
Int32List _nearestHintAssignment(Float32List u, Float32List v,
    Float32List luminance, int width, int height, List<ColorHint> hints,
    ColorizeOptions options) {
  final assignment = Int32List(width * height)..fillRange(0, width * height, -1);
  // 比较原稿亮度，而不是目标提示色的亮度。
  final hintLumas = [for (final h in hints) luminance[h.y * width + h.x]];
  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      final i = row * width + col;
      if (_mag(u[i], v[i]) < 1e-4) continue;
      var bestT = -1;
      var bestDist = double.infinity;
      for (var t = 0; t < hints.length; t++) {
        final dx = (col - hints[t].x) / width;
        final dy = (row - hints[t].y) / height;
        final dxy = dx * dx + dy * dy;
        final dlu = (luminance[i] - hintLumas[t]).abs();
        final dist = math.sqrt(dxy + options.regionLuminanceWeight * dlu * dlu);
        if (dist < bestDist) {
          bestDist = dist;
          bestT = t;
        }
      }
      assignment[i] = bestT;
    }
  }
  return assignment;
}

/// 区域色度校正 (最近提示点归属)。
///
/// 对每个可着色像素,按预计算的 [assignment] 找归属提示点 t:
/// 幅值校正把 |chroma| 向 targetScale×|target| 拉齐 (每像素独立限幅,
/// 避免越过色域);色向校正把色度向目标色相插值 (强度 [hueCorrectionStrength])。
/// 随空间距离线性衰减,边缘处自然过渡回扩散原值。
void _applyRegionChromaCorrection(
    Float32List u,
    Float32List v,
    Float32List luminance,
    int width,
    int height,
    List<ColorHint> hints,
    ColorizeOptions options,
    Int32List assignment) {
  final targets = <(double, double)>[];
  for (final hint in hints) {
    final (hy, hu, hv) = rgbToYuv(hint.r / 255, hint.g / 255, hint.b / 255);
    targets.add((hu, hv));
  }
  final magGain = options.chromaMagnitudeGain.clamp(0.0, 2.0);
  final hueStrength = options.hueCorrectionStrength.clamp(0.0, 1.0);
  // 预计算提示色色度与亮度 (避免逐像素重复转换)。
  final hintChromaMag = <double>[];
  final hintLumas = <double>[];
  for (var t = 0; t < targets.length; t++) {
    hintChromaMag.add(_mag(targets[t].$1, targets[t].$2));
    hintLumas.add(_hintLuminance(hints[t]));
  }
  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      final i = row * width + col;
      final cm = _mag(u[i], v[i]);
      if (cm < 1e-4) continue; // 中性像素 (锁定的黑白/无色区) 不动。
      final bestT = assignment[i];
      if (bestT < 0) continue;
      final (tu, tv) = targets[bestT];
      final targetMag = _mag(tu, tv);
      // 幅值校正: 目标幅值按色度-亮度适配比例缩放后作为该区基准。
      final hintY = hintLumas[bestT];
      final adapt = (hintY > 1 / 255 && options.adaptHintChromaToLuminance)
          ? (luminance[i] / hintY).clamp(0.2, 5.0)
          : 1.0;
      final wanted = (targetMag * adapt * magGain).clamp(0.0, 0.5);
      if (wanted > 1e-4) {
        // 幅值向 wanted 逐像素限幅逼近 (每次最多 ±0.5×cm,保持渐变平滑)。
        final delta = (wanted - cm).clamp(-0.5 * cm, 0.5 * cm);
        final scale = (cm + delta) / cm;
        u[i] *= scale;
        v[i] *= scale;
      }
      // 色向校正: 提示色有明显色度时,向目标色相插值。
      // 注意: 目标方向 = 目标色度 × 适配系数(正数),保留各通道符号。
      if (hintChromaMag[bestT] > 0.04 && hueStrength > 0) {
        final dirU = tu * adapt;
        final dirV = tv * adapt;
        final dirMag = _mag(dirU, dirV);
        if (dirMag > 1e-6) {
          final blendedU = u[i] * (1 - hueStrength) +
              (dirU / dirMag) * _mag(u[i], v[i]) * hueStrength;
          final blendedV = v[i] * (1 - hueStrength) +
              (dirV / dirMag) * _mag(u[i], v[i]) * hueStrength;
          u[i] = blendedU;
          v[i] = blendedV;
        }
      }
    }
  }
}

/// 提示色归一化亮度 (无适配)。
double _hintLuminance(ColorHint hint) =>
    (0.299 * hint.r + 0.587 * hint.g + 0.114 * hint.b) / 255;

double _mag(double u, double v) => math.sqrt(u * u + v * v);

/// 粗到细多尺度预解 (V-cycle 风格):
///
/// 在逐级减半的金字塔上从最粗层向上求解全局色度场
/// (SOR 在粗网格上全局扩散快),逐层双线性上采样作为下一级初值,
/// 最后上采样到全分辨率返回。返回 null 表示小图无需预解。
/// 提示点在每层按坐标比例映射并重新适配色度。
(Float32List, Float32List)? _coarseInitialField(
    int width,
    int height,
    Float32List luminance,
    List<ColorHint> hints,
    ColorizeOptions options) {
  if (width < 96 || height < 96) return null;
  // 金字塔层 (不含全分辨率),从全尺寸逐级减半。
  final levels = <_PyramidLevel>[];
  var w = width;
  var h = height;
  while (w >= 96 && h >= 96) {
    levels.add(_PyramidLevel(
        w, h, _downsampleLuminance(luminance, width, height, w, h)));
    w = (w / 2).floor();
    h = (h / 2).floor();
  }
  if (levels.length < 2) return null;
  Float32List? u;
  Float32List? v;
  for (var level = levels.length - 1; level >= 1; level--) {
    final lvl = levels[level];
    final levelSolver = ChromaSolver(
      width: lvl.width,
      height: lvl.height,
      luminance: lvl.luminance,
      sigma: options.sigma,
      epsilon: options.epsilon,
      initialU: u,
      initialV: v,
    );
    _addScaledHints(levelSolver, hints, width, height, lvl, options);
    // 屏障: 粗层上亮度梯度大的像素锁定为中性, 阻断色度跨轮廓线扩散
    // (脸部→背景渗漏的根因)。线稿在粗层是强梯度带。
    _lockStrongEdges(levelSolver, lvl.luminance, lvl.width, lvl.height);
    final solution = levelSolver.solve(
      maxIterations: options.maxIterations,
      sorOmega: options.sorOmega,
      tolerance: options.tolerance,
    );
    final finer = levels[level - 1];
    u = _upsampleField(
        solution.u, lvl.width, lvl.height, finer.width, finer.height);
    v = _upsampleField(
        solution.v, lvl.width, lvl.height, finer.width, finer.height);
  }
  return (u!, v!);
}

/// 把粗层上亮度梯度超过阈值的像素锁定为中性 (轮廓线屏障)。
void _lockStrongEdges(
    ChromaSolver solver, Float32List lum, int width, int height) {
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final i = y * width + x;
      final gx = (lum[i + 1] - lum[i - 1]).abs() * 0.5;
      final gy = (lum[i + width] - lum[i - width]).abs() * 0.5;
      if (!solver.isFixedAt(i) && math.sqrt(gx * gx + gy * gy) > 0.09) {
        solver.lockNeutral(i);
      }
    }
  }
}

/// 把全分辨率提示点按比例映射到金字塔层坐标并添加。
void _addScaledHints(ChromaSolver solver, List<ColorHint> hints, int srcWidth,
    int srcHeight, _PyramidLevel level, ColorizeOptions options) {
  for (final hint in hints) {
    final cx = (hint.x * level.width ~/ srcWidth).clamp(0, level.width - 1);
    final cy = (hint.y * level.height ~/ srcHeight).clamp(0, level.height - 1);
    final (hintY, hintU, hintV) =
        rgbToYuv(hint.r / 255, hint.g / 255, hint.b / 255);
    if (options.adaptHintChromaToLuminance && hintY > 1 / 255) {
      final pixelY = level.luminance[cy * level.width + cx];
      final scale = (pixelY / hintY).clamp(0.2, 5.0);
      solver.addHint(cx, cy,
          u: (hintU * scale).clamp(-0.5, 0.5),
          v: (hintV * scale).clamp(-0.5, 0.5));
    } else {
      solver.addHint(cx, cy, u: hintU, v: hintV);
    }
  }
}

class _PyramidLevel {
  final int width;
  final int height;
  final Float32List luminance;
  const _PyramidLevel(this.width, this.height, this.luminance);
}

/// 盒式降采样 (区域平均)。
Float32List _downsampleLuminance(
    Float32List src, int srcW, int srcH, int dstW, int dstH) {
  final out = Float32List(dstW * dstH);
  for (var y = 0; y < dstH; y++) {
    final y0 = y * srcH ~/ dstH;
    final y1 = math.max((y + 1) * srcH ~/ dstH, y0 + 1);
    for (var x = 0; x < dstW; x++) {
      final x0 = x * srcW ~/ dstW;
      final x1 = math.max((x + 1) * srcW ~/ dstW, x0 + 1);
      var sum = 0.0;
      var count = 0;
      for (var sy = y0; sy < y1 && sy < srcH; sy++) {
        for (var sx = x0; sx < x1 && sx < srcW; sx++) {
          sum += src[sy * srcW + sx];
          count++;
        }
      }
      out[y * dstW + x] = count > 0 ? sum / count : 0;
    }
  }
  return out;
}

/// 双线性上采样色度场。
Float32List _upsampleField(
    Float32List src, int srcW, int srcH, int dstW, int dstH) {
  final out = Float32List(dstW * dstH);
  for (var y = 0; y < dstH; y++) {
    final gy = (y + 0.5) * srcH / dstH - 0.5;
    var y0 = gy.floor();
    final fy = gy - y0;
    if (y0 < 0) {
      y0 = 0;
    }
    final y1 = math.min(y0 + 1, srcH - 1);
    for (var x = 0; x < dstW; x++) {
      final gx = (x + 0.5) * srcW / dstW - 0.5;
      var x0 = gx.floor();
      final fx = gx - x0;
      if (x0 < 0) {
        x0 = 0;
      }
      final x1 = math.min(x0 + 1, srcW - 1);
      final v00 = src[y0 * srcW + x0];
      final v10 = src[y0 * srcW + x1];
      final v01 = src[y1 * srcW + x0];
      final v11 = src[y1 * srcW + x1];
      out[y * dstW + x] = v00 * (1 - fx) * (1 - fy) +
          v10 * fx * (1 - fy) +
          v01 * (1 - fx) * fy +
          v11 * fx * fy;
    }
  }
  return out;
}
