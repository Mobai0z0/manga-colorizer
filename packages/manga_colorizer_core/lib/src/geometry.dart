import 'dart:math' as math;
import 'dart:typed_data';

import 'yuv.dart';

/// 色度扩散求解结果。
///
/// [u]/[v] 为与输入亮度图同尺寸的色度场([-0.5,0.5])。
class ChromaSolution {
  final Float32List u;
  final Float32List v;
  final int iterations;
  final double maxDelta;

  const ChromaSolution(this.u, this.v, this.iterations, this.maxDelta);
}

/// 3x3 窗口的 8 邻域 (行,列偏移,含对角)。
const List<List<int>> kNeighborhood8 = [
  [-1, -1],
  [-1, 0],
  [-1, 1],
  [0, -1],
  [0, 1],
  [1, -1],
  [1, 0],
  [1, 1],
];

/// Levin-Lischinski-Weiss (2004) 提示点色度扩散求解器。
///
/// 目标: 最小化 Σ_(i,j) w_ij · (u_i - u_j)^2,其中
/// w_ij = exp(-|Y_i - Y_j| / sigma) + epsilon。
/// 提示点(及锁定的纯黑白像素)作为固定边界条件,其余像素用
/// SOR(逐次超松弛)迭代求解离散 Laplace 方程。
class ChromaSolver {
  final int width;
  final int height;
  final Float32List luminance;

  final Float32List _u;
  final Float32List _v;
  final Uint8List _fixed;
  final Int32List _neighborIndex;
  final Float32List _neighborWeight;
  final Float32List _invDenominator;
  final double _sigma;
  final double _epsilon;
  int _hintCount = 0;
  int _lockedCount = 0;

  ChromaSolver({
    required this.width,
    required this.height,
    required this.luminance,
    double sigma = kDefaultSigma,
    double epsilon = kDefaultEpsilon,
    Float32List? initialU,
    Float32List? initialV,
  })  : _u = Float32List(width * height),
        _v = Float32List(width * height),
        _fixed = Uint8List(width * height),
        _neighborIndex = Int32List(width * height * 8),
        _neighborWeight = Float32List(width * height * 8),
        _invDenominator = Float32List(width * height),
        _sigma = sigma,
        _epsilon = epsilon {
    if (luminance.length != width * height) {
      throw ArgumentError(
          'luminance 长度 (${luminance.length}) 与 width*height '
          '($width*$height) 不一致');
    }
    if (sigma <= 0) throw ArgumentError('sigma 必须大于 0');
    if (epsilon < 0) throw ArgumentError('epsilon 不能为负');
    if (initialU != null) {
      if (initialU.length != width * height) {
        throw ArgumentError('initialU 长度与 width*height 不一致');
      }
      _u.setAll(0, initialU);
    }
    if (initialV != null) {
      if (initialV.length != width * height) {
        throw ArgumentError('initialV 长度与 width*height 不一致');
      }
      _v.setAll(0, initialV);
    }
    _precompute();
  }

  void _precompute() {
    for (var row = 0; row < height; row++) {
      for (var col = 0; col < width; col++) {
        final i = row * width + col;
        final yc = luminance[i];
        var denominator = 0.0;
        final base = i * 8;
        for (var k = 0; k < 8; k++) {
          final neighborRow = row + kNeighborhood8[k][0];
          final neighborCol = col + kNeighborhood8[k][1];
          if (neighborRow < 0 ||
              neighborRow >= height ||
              neighborCol < 0 ||
              neighborCol >= width) {
            _neighborIndex[base + k] = -1;
            _neighborWeight[base + k] = 0;
            continue;
          }
          final j = neighborRow * width + neighborCol;
          final w = _weight(yc, luminance[j]);
          _neighborIndex[base + k] = j;
          _neighborWeight[base + k] = w;
          denominator += w;
        }
        _invDenominator[i] = denominator > 0 ? 1.0 / denominator : 0.0;
      }
    }
  }

  double _weight(double a, double b) =>
      math.exp(-(a - b).abs() / _sigma) + _epsilon;

  int get hintCount => _hintCount;
  int get lockedMonochromeCount => _lockedCount;
  int get pixelCount => width * height;

  bool isFixedAt(int index) => _fixed[index] != 0;

  void addHint(int x, int y, {required double u, required double v}) {
    final i = _requireIndex(x, y);
    if (_fixed[i] == 0) {
      _fixed[i] = 1;
      _hintCount++;
    }
    _u[i] = u;
    _v[i] = v;
  }

  /// 以 8bit RGB 颜色添加提示点。
  void addRgbHint(int x, int y, int r, int g, int b) {
    final (_, u, v) = rgbToYuv(r / 255, g / 255, b / 255);
    addHint(x, y, u: u, v: v);
  }

  /// 将某像素锁定为中性色边界 (不计入 hintCount)。
  void lockNeutral(int index) {
    if (_fixed[index] == 0) {
      _fixed[index] = 1;
      _lockedCount++;
    }
    _u[index] = 0;
    _v[index] = 0;
  }

  int _requireIndex(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw ArgumentError('提示点坐标 ($x, $y) 超出图像范围 '
          '${width}x$height');
    }
    return y * width + x;
  }

  /// 迭代求解。返回 [ChromaSolution],内部数组会被复用。
  ChromaSolution solve({
    int maxIterations = 300,
    double sorOmega = kDefaultSorOmega,
    double tolerance = kDefaultTolerance,
  }) {
    if (maxIterations < 1) throw ArgumentError('maxIterations 至少为 1');
    if (sorOmega <= 0 || sorOmega >= 2) {
      throw ArgumentError('sorOmega 必须在 (0, 2) 区间');
    }
    var iteration = 0;
    var maxDelta = 0.0;
    for (iteration = 1; iteration <= maxIterations; iteration++) {
      maxDelta = _sweep(sorOmega, _u);
      final deltaV = _sweep(sorOmega, _v);
      if (deltaV > maxDelta) maxDelta = deltaV;
      if (maxDelta < tolerance) break;
    }
    return ChromaSolution(_u, _v, iteration, maxDelta);
  }

  /// 一次 in-place SOR 扫描,返回本扫单像素最大改变量。
  double _sweep(double omega, Float32List channel) {
    var maxDelta = 0.0;
    for (var i = 0; i < channel.length; i++) {
      if (_fixed[i] != 0) continue;
      var sum = 0.0;
      final base = i * 8;
      for (var k = 0; k < 8; k++) {
        final j = _neighborIndex[base + k];
        if (j >= 0) sum += _neighborWeight[base + k] * channel[j];
      }
      final gaussSeidel = sum * _invDenominator[i];
      final updated = (1 - omega) * channel[i] + omega * gaussSeidel;
      final diff = (updated - channel[i]).abs();
      if (diff > maxDelta) maxDelta = diff;
      channel[i] = updated;
    }
    return maxDelta;
  }
}

/// 默认亮度相似度带宽 (Y ∈ [0,1])。
const double kDefaultSigma = 0.03;

/// 权重下限,仅保证系统数值可解;取极小值使无提示区域保持中性、
/// 色度不会明显渗透过强亮度边界 (Levin 等的论文同款做法)。
const double kDefaultEpsilon = 1e-6;

/// 默认 SOR 松弛因子 (对中大型网格接近最优值 2/(1+sin(π/N)),
/// 配合多尺度求解可全局收敛)。
const double kDefaultSorOmega = 1.93;

/// 默认收敛阈值 (单扫最大改变量)。
const double kDefaultTolerance = 1e-5;
