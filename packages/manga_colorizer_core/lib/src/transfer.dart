// 参考图色调迁移（纯 Dart，免模型）：把参考图的整体色调迁移到原稿/结果图上，
// 亮度 L 恒保持来源图不变（与包内其它上色路径同一亮度保真原则）。
// 桌面镜像实现在 tool/colorizer_service/service.py `_reference_transfer`，
// 改任何一侧必须同步另一侧并重新生成金样（test/goldens/）。
//
// 两个算法（颜色迁移文献的两大主流，均工作在 Lab a/b 上）：
//   · reinhard——均值/方差对齐（Reinhard et al. 2001），快而稳，整体氛围对齐；
//   · histogram——逐通道直方图规定化（CDF 匹配），分布对齐更彻底，对比感更强。
// 漫画特有处理：原稿近白（纸白）像素**不参与统计、不被染色**——漫画页常
// 90% 是纸白，整体统计会被纸白淹没（Reinhard 的 src_std≈3 被放大成 6 倍
// 增益，纸白反而吃满参考色）；纸白按 smoothstep(234,248) 软边界保护。
import 'dart:math' as math;
import 'dart:typed_data';

import 'finish.dart';
import 'lab.dart';

/// 迁移算法。
enum ReferenceMethod { reinhard, histogram }

/// 参考图迁移：[srcRgb]/[refRgb] 均为行优先 RGB n*3 字节。
///
/// [strength] ∈ [0,1]：0 = 原样返回，1 = 完全迁移。[protectPaper] 对近白
/// 像素按 smoothstep 软边界把迁移量收向 0（强度同 [strength] 缩放）。
/// 返回 RGB n*3。输出端经 [labToRgbFinish] 平增益色域映射（gain=1，与
/// 桌面 `_reference_transfer` 的收尾一致）。
Uint8List transferReference({
  required Uint8List srcRgb,
  required Uint8List refRgb,
  required int srcPixels,
  required int refPixels,
  ReferenceMethod method = ReferenceMethod.reinhard,
  double strength = 1.0,
  bool protectPaper = true,
}) {
  if (srcRgb.length != srcPixels * 3) {
    throw ArgumentError('srcRgb 长度 (${srcRgb.length}) 与 $srcPixels 像素不符');
  }
  if (refRgb.length != refPixels * 3) {
    throw ArgumentError('refRgb 长度 (${refRgb.length}) 与 $refPixels 像素不符');
  }
  final srcLab = rgbToLab(srcRgb, srcPixels);
  final refLab = rgbToLab(refRgb, refPixels);

  // 墨迹掩码：非纸白像素参与统计。掩码过小（近乎全白的页）退化为全图统计。
  var inkCount = 0;
  for (var i = 0; i < srcPixels; i++) {
    if (srcLab[i * 3] < 234) inkCount++;
  }
  final useAll = inkCount < srcPixels * 0.01;
  final statCount = useAll ? srcPixels : inkCount;

  // 新 a/b 的两种来源
  final newA = Float64List(srcPixels);
  final newB = Float64List(srcPixels);
  if (method == ReferenceMethod.reinhard) {
    final sA = _statsMasked(srcLab, srcPixels, 1, useAll, statCount);
    final sB = _statsMasked(srcLab, srcPixels, 2, useAll, statCount);
    final rA = _stats(refLab, refPixels, 1);
    final rB = _stats(refLab, refPixels, 2);
    final kA = rA.std / sA.std, kB = rB.std / sB.std;
    for (var i = 0; i < srcPixels; i++) {
      newA[i] = (srcLab[i * 3 + 1] - 128.0 - sA.mean) * kA + rA.mean;
      newB[i] = (srcLab[i * 3 + 2] - 128.0 - sB.mean) * kB + rB.mean;
    }
  } else {
    _histMatch(srcLab, refLab, srcPixels, refPixels, 1, useAll, statCount, newA);
    _histMatch(srcLab, refLab, srcPixels, refPixels, 2, useAll, statCount, newB);
  }

  // 强度混合 + 纸白保护 → 输出（gain=1 平映射，色域数学与桌面一致）
  final lab = Uint8List(srcPixels * 3);
  for (var i = 0; i < srcPixels; i++) {
    lab[i * 3] = srcLab[i * 3];
    final edge = protectPaper
        ? 1.0 - _smoothstep01(234.0, 248.0, srcLab[i * 3].toDouble())
        : 1.0;
    final s = (strength * edge).clamp(0.0, 1.0);
    final a = srcLab[i * 3 + 1] - 128.0;
    final b = srcLab[i * 3 + 2] - 128.0;
    lab[i * 3 + 1] = (a + (newA[i] - a) * s + 128.0).round().clamp(0, 255);
    lab[i * 3 + 2] = (b + (newB[i] - b) * s + 128.0).round().clamp(0, 255);
  }
  return labToRgbFinish(lab, srcPixels, const FinishOptions());
}

double _smoothstep01(double e0, double e1, double x) {
  var t = (x - e0) / (e1 - e0);
  t = t.clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

class _ChanStats {
  _ChanStats(this.mean, this.std);
  final double mean;
  final double std;
}

_ChanStats _stats(Uint8List lab, int n, int ch) {
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += lab[i * 3 + ch] - 128.0;
  }
  final mean = sum / n;
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    final d = lab[i * 3 + ch] - 128.0 - mean;
    acc += d * d;
  }
  final std = math.sqrt(acc / n);
  return _ChanStats(mean, std < 1e-6 ? 1.0 : std);
}

/// 掩码版统计（useAll=false 时只统计 L<234 的像素；std 为 0 时回退 1，
/// 常数通道不放大）。
_ChanStats _statsMasked(Uint8List lab, int n, int ch, bool useAll, int count) {
  if (useAll) return _stats(lab, n, ch);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    if (lab[i * 3] < 234) sum += lab[i * 3 + ch] - 128.0;
  }
  final mean = sum / count;
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    if (lab[i * 3] < 234) {
      final d = lab[i * 3 + ch] - 128.0 - mean;
      acc += d * d;
    }
  }
  final std = math.sqrt(acc / count);
  return _ChanStats(mean, std < 1e-6 ? 1.0 : std);
}

/// 直方图规定化：src（掩码内）逐字节值的 CDF → ref 逐字节值的 CDF 逆映射。
/// 结果写入 [out]（新 a/b 浮点，不含 +128 偏置）。
void _histMatch(Uint8List srcLab, Uint8List refLab, int srcPixels,
    int refPixels, int ch, bool useAll, int statCount, Float64List out) {
  final histS = List<int>.filled(256, 0);
  final histR = List<int>.filled(256, 0);
  for (var i = 0; i < srcPixels; i++) {
    if (useAll || srcLab[i * 3] < 234) histS[srcLab[i * 3 + ch]]++;
  }
  for (var i = 0; i < refPixels; i++) {
    histR[refLab[i * 3 + ch]]++;
  }
  final cdfS = Float64List(256);
  final cdfR = Float64List(256);
  var acc = 0;
  for (var v = 0; v < 256; v++) {
    acc += histS[v];
    cdfS[v] = acc / statCount;
  }
  acc = 0;
  for (var v = 0; v < 256; v++) {
    acc += histR[v];
    cdfR[v] = acc / refPixels;
  }
  final lut = Int16List(256);
  var j = 0;
  for (var v = 0; v < 256; v++) {
    while (j < 255 && cdfR[j] < cdfS[v]) {
      j++;
    }
    lut[v] = j;
  }
  for (var i = 0; i < srcPixels; i++) {
    out[i] = lut[srcLab[i * 3 + ch]].toDouble() - 128.0;
  }
}
