library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'colorize.dart';
import 'white_regions.dart';
import 'yuv.dart';

/// 图像分块上色管线 (借鉴 Manga-Colorization-FJ 的 tile 推理设计)。
///
/// 大图整图上色时,提示点扩散的有效范围随分辨率稀释;分块(带重叠)让每个
/// tile 内部保持局部一致性,再在重叠区羽化拼接,避免接缝色差。
/// 参照 FJ 的经验参数: tile 512、重叠 64。
///
/// v0.4 新增:
/// - [colorizeMangaTiledAsync] 用 Isolate 并行处理各 tile (多核近似线性加速);
/// - 边界感知羽化: 贴图像边界的侧不做羽化,避免外圈塌零 (v0.3 修复保留);
/// - tile 划分与拼接逻辑抽为共享内部函数,并行/串行输出逐字节一致。

/// 分块上色结果。
class TiledColorizeResult {
  final int width;
  final int height;
  final Uint8List rgb;
  final int tileCount;
  final int tileSize;
  final int overlap;

  const TiledColorizeResult(this.width, this.height, this.rgb, this.tileCount,
      this.tileSize, this.overlap);
}

class _TileSpec {
  final int ox;
  final int oy;
  final int tw;
  final int th;
  const _TileSpec(this.ox, this.oy, this.tw, this.th);
}

/// 生成 tile 原点序列: 从 0 步进 [step],最后一块贴齐图像右/下边界。
List<_TileSpec> _planTiles(int width, int height, int tileSize, int step) {
  final originsX = <int>[];
  if (width <= tileSize) {
    originsX.add(0);
  } else {
    for (var x = 0; x + tileSize < width; x += step) {
      originsX.add(x);
    }
    originsX.add(width - tileSize);
  }
  final originsY = <int>[];
  if (height <= tileSize) {
    originsY.add(0);
  } else {
    for (var y = 0; y + tileSize < height; y += step) {
      originsY.add(y);
    }
    originsY.add(height - tileSize);
  }
  return [
    for (final oy in originsY)
      for (final ox in originsX)
        _TileSpec(ox, oy,
            ox + tileSize <= width ? tileSize : width - ox,
            oy + tileSize <= height ? tileSize : height - oy),
  ];
}

Uint8List _extractTile(
    Uint8List gray, _TileSpec s, int width) {
  final tile = Uint8List(s.tw * s.th * 3);
  for (var y = 0; y < s.th; y++) {
    final srcBase = ((s.oy + y) * width + s.ox) * 3;
    tile.setRange(
        y * s.tw * 3, (y + 1) * s.tw * 3, gray.sublist(srcBase, srcBase + s.tw * 3));
  }
  return tile;
}

List<ColorHint> _tileHintsFor(
    List<ColorHint> hints, _TileSpec s, int overlapHalf) {
  final tileHints = <ColorHint>[];
  for (final h in hints) {
    final lx = h.x - s.ox;
    final ly = h.y - s.oy;
    if (lx >= -overlapHalf &&
        lx < s.tw + overlapHalf &&
        ly >= -overlapHalf &&
        ly < s.th + overlapHalf) {
      tileHints.add(ColorHint(
        x: lx.clamp(0, s.tw - 1),
        y: ly.clamp(0, s.th - 1),
        r: h.r,
        g: h.g,
        b: h.b,
        role: h.role,
      ));
    }
  }
  return tileHints;
}

/// 同步分块上色 (串行)。小图直接整图求解。
TiledColorizeResult colorizeMangaTiled({
  required Uint8List grayscaleRgb,
  required int width,
  required int height,
  required List<ColorHint> hints,
  ColorizeOptions options = const ColorizeOptions(),
  int tileSize = 512,
  int overlap = 64,
}) {
  _validateParams(tileSize, overlap);
  final plan = _planTiles(width, height, tileSize, tileSize - overlap);
  if (plan.length == 1) {
    final r = colorizeManga(
        grayscaleRgb: grayscaleRgb,
        width: width,
        height: height,
        hints: hints,
        options: options);
    return TiledColorizeResult(width, height, r.rgb, 1, tileSize, overlap);
  }
  final outputs = <(_TileSpec, Uint8List)>[];
  for (final s in plan) {
    final tile = _extractTile(grayscaleRgb, s, width);
    final r = colorizeManga(
        grayscaleRgb: tile,
        width: s.tw,
        height: s.th,
        hints: _tileHintsFor(hints, s, overlap ~/ 2),
        options: options);
    outputs.add((s, r.rgb));
  }
  return TiledColorizeResult(width, height,
      _finishTiles(outputs, grayscaleRgb, width, height, hints, options, tileSize, overlap),
      plan.length, tileSize, overlap);
}

/// 并行分块上色: 各 tile 在独立 Isolate 中求解 (多核加速)。
///
/// 输出与串行 [colorizeMangaTiled] 逐字节一致 (tile 相互独立,拼接顺序固定)。
Future<TiledColorizeResult> colorizeMangaTiledAsync({
  required Uint8List grayscaleRgb,
  required int width,
  required int height,
  required List<ColorHint> hints,
  ColorizeOptions options = const ColorizeOptions(),
  int tileSize = 512,
  int overlap = 64,
  bool parallel = true,
}) async {
  _validateParams(tileSize, overlap);
  final plan = _planTiles(width, height, tileSize, tileSize - overlap);
  if (plan.length == 1 || !parallel) {
    return colorizeMangaTiled(
        grayscaleRgb: grayscaleRgb,
        width: width,
        height: height,
        hints: hints,
        options: options,
        tileSize: tileSize,
        overlap: overlap);
  }
  // 准备各 tile 任务 (主 isolate 完成裁剪,worker 只做求解)。
  final jobs = <(_TileSpec, Uint8List, List<ColorHint>)>[
    for (final s in plan)
      (
        s,
        _extractTile(grayscaleRgb, s, width),
        _tileHintsFor(hints, s, overlap ~/ 2),
      ),
  ];
  final outputs = <(_TileSpec, Uint8List)>[];
  final workers = jobs.map((job) async {
    final (s, tile, tileHints) = job;
    final r = await Isolate.run(() => colorizeManga(
        grayscaleRgb: tile,
        width: s.tw,
        height: s.th,
        hints: tileHints,
        options: options));
    return (s, r.rgb);
  });
  outputs.addAll(await Future.wait(workers));
  return TiledColorizeResult(width, height,
      _finishTiles(outputs, grayscaleRgb, width, height, hints, options, tileSize, overlap),
      plan.length, tileSize, overlap);
}

void _validateParams(int tileSize, int overlap) {
  if (tileSize < 128) throw ArgumentError('tileSize 至少 128');
  if (overlap < 0 || overlap * 2 >= tileSize) {
    throw ArgumentError('overlap 必须满足 0 ≤ overlap < tileSize/2');
  }
}

/// 边界感知羽化拼接。
Uint8List _blendTiles(List<(_TileSpec, Uint8List)> outputs, int width,
    int height, int tileSize, int overlap) {
  final outR = Float32List(width * height);
  final outG = Float32List(width * height);
  final outB = Float32List(width * height);
  final outW = Float32List(width * height);
  for (final (s, rgb) in outputs) {
    for (var y = 0; y < s.th; y++) {
      for (var x = 0; x < s.tw; x++) {
        final gx = s.ox + x;
        final gy = s.oy + y;
        final wx = _featherEdge(x, s.tw, overlap,
            hasLeft: s.ox > 0, hasRight: s.ox + s.tw < width);
        final wy = _featherEdge(y, s.th, overlap,
            hasLeft: s.oy > 0, hasRight: s.oy + s.th < height);
        final w = wx * wy;
        final gi = gy * width + gx;
        final pi = (y * s.tw + x) * 3;
        outR[gi] += rgb[pi] * w;
        outG[gi] += rgb[pi + 1] * w;
        outB[gi] += rgb[pi + 2] * w;
        outW[gi] += w;
      }
    }
  }
  final out = Uint8List(width * height * 3);
  for (var i = 0; i < width * height; i++) {
    final w = outW[i];
    if (w > 0) {
      out[i * 3] = (outR[i] / w).round().clamp(0, 255);
      out[i * 3 + 1] = (outG[i] / w).round().clamp(0, 255);
      out[i * 3 + 2] = (outB[i] / w).round().clamp(0, 255);
    }
  }
  return out;
}

/// 有邻居的侧从 0.5 起坡 (共享边界两块 tile 权重互补);
/// 贴图像边界的侧保持 1.0 (没有邻居补权重)。
double _featherEdge(int pos, int len, int feather,
    {required bool hasLeft, required bool hasRight}) {
  var t = 1.0;
  if (hasLeft && feather > 0 && pos < feather) {
    t = math.min(t, 0.5 + 0.5 * pos / feather);
  }
  if (hasRight && feather > 0 && pos >= len - feather) {
    t = math.min(t, 0.5 + 0.5 * (len - 1 - pos) / feather);
  }
  return t;
}

// 白区闭合性必须按完整原稿判断，不能把 tile 边缘误当作纸张边缘。
Uint8List _finishTiles(
    List<(_TileSpec, Uint8List)> outputs, Uint8List source,
    int width, int height, List<ColorHint> hints, ColorizeOptions options,
    int tileSize, int overlap) {
  final out = _blendTiles(outputs, width, height, tileSize, overlap);
  if (options.fillClosedWhiteRegions && options.lockPureMonochrome) {
    // 清除局部 tile 的填色/羽化结果，使用原始提示点做一次全图平涂。
    for (var i = 0; i < width * height; i++) {
      final y = luminanceOfRgb(source[i * 3], source[i * 3 + 1], source[i * 3 + 2]);
      if (y >= options.monochromeHighThreshold) {
        out.setRange(i * 3, i * 3 + 3, source, i * 3);
      }
    }
    fillClosedWhiteRegions(source: source, output: out, width: width,
        height: height, hints: hints, threshold: options.monochromeHighThreshold,
        naturalSkin: options.enforceNaturalSkin);
  }
  return out;
}
