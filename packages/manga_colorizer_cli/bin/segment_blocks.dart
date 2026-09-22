import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:manga_colorizer_cli/src/cli_io.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 色块分割 v11: 按黑白灰度明暗区分色块（分块上色流水线的第一步）。
///
/// 机制: 展平亮度(boxBlur 去网点) → 等面积分位切成 K 个明度带 →
/// 带内 4-连通域成块(边界自动贴合墨线) → 小块并入相邻最大块 →
/// 输出分割预览图 / 块 id 图(idmap, R=低8位 G=高8位) / 台账 JSON(AI 建议色)。
///
/// 用法:
///   dart run bin/segment_blocks.dart -i in.png -o outDir [--bands 12] [--min-area 600]
Future<void> main(List<String> args) async {
  String? input;
  String? outDir;
  var bands = 12;
  var minArea = 600;
  String? hintsPath;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-i':
        input = args[++i];
      case '-o':
        outDir = args[++i];
      case '--bands':
        bands = int.parse(args[++i]);
      case '--min-area':
        minArea = int.parse(args[++i]);
      case '--hints':
        hintsPath = args[++i];
      default:
        stderr.writeln('未知参数: ${args[i]}');
        exitCode = 64;
        return;
    }
  }
  if (input == null || outDir == null) {
    stderr.writeln('用法: dart run bin/segment_blocks.dart -i <输入> -o <输出目录> '
        '[--bands 12] [--min-area 600]');
    exitCode = 64;
    return;
  }
  final dir = Directory(outDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final source = CliIo.readGrayscale(input);
  final w = source.width;
  final h = source.height;
  final n = w * h;

  // 亮度场: 原稿 v(墨线判定) + 展平场(分带)。
  final v0 = Float32List(n);
  for (var i = 0; i < n; i++) {
    v0[i] = source.rgb[i * 3] / 255.0;
  }
  final blurV = boxBlur(boxBlur(v0, w, h, 2), w, h, 2);

  // 等面积分位分带。
  final vals = Float32List(n);
  var vn = 0;
  for (var i = 0; i < n; i++) {
    if (v0[i] >= 0.15) vals[vn++] = blurV[i];
  }
  final sorted = Float32List.sublistView(vals, 0, vn);
  sorted.sort();
  final thresholds = Float32List(bands - 1);
  for (var b = 0; b < bands - 1; b++) {
    thresholds[b] = sorted[((b + 1) * vn ~/ bands).clamp(0, vn - 1)];
  }
  int bandOf(double v) {
    var lo = 0;
    var hi = thresholds.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (v < thresholds[mid]) {
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  // 连通域(BFS)。
  final labels = Int32List(n)..fillRange(0, n, -1); // -1 未定, -2 墨线
  for (var i = 0; i < n; i++) {
    if (v0[i] < 0.15) labels[i] = -2;
  }
  final stack = Int32List(n);
  var nextId = 0;
  for (var start = 0; start < n; start++) {
    if (labels[start] != -1) continue;
    final band = bandOf(blurV[start]);
    var sp = 0;
    stack[sp++] = start;
    labels[start] = nextId;
    while (sp > 0) {
      final p = stack[--sp];
      final x = p % w;
      final y = p ~/ w;
      void push(int q) {
        if (q >= 0 && q < n && labels[q] == -1 && bandOf(blurV[q]) == band) {
          labels[q] = nextId;
          stack[sp++] = q;
        }
      }
      if (x > 0) push(p - 1);
      if (x < w - 1) push(p + 1);
      if (y > 0) push(p - w);
      if (y < h - 1) push(p + w);
    }
    nextId++;
  }

  // 块统计。
  var area = Int64List(nextId);
  var lumSum = Float64List(nextId);
  var lumMin = Float32List(nextId)..fillRange(0, nextId, 2.0);
  var lumMax = Float32List(nextId);  var sumX = Float64List(nextId);
  var sumY = Float64List(nextId);
  var minX = Int32List(nextId)..fillRange(0, nextId, 1 << 30);
  var maxX = Int32List(nextId);
  var minY = Int32List(nextId)..fillRange(0, nextId, 1 << 30);
  var maxY = Int32List(nextId);
  for (var i = 0; i < n; i++) {
    final l = labels[i];
    if (l < 0) continue;
    area[l]++;
    lumSum[l] += blurV[i];
    if (blurV[i] < lumMin[l]) lumMin[l] = blurV[i];
    if (blurV[i] > lumMax[l]) lumMax[l] = blurV[i];
    final x = i % w;
    final y = i ~/ w;
    sumX[l] += x;
    sumY[l] += y;
    if (x < minX[l]) minX[l] = x;
    if (x > maxX[l]) maxX[l] = x;
    if (y < minY[l]) minY[l] = y;
    if (y > maxY[l]) maxY[l] = y;
  }

  // 小块合并: 并入邻接面积和最大的块(迭代直到稳定)。
  var labels2 = labels;
  var area2 = area;
  var activeMax = nextId;
  for (var round = 0; round < 12; round++) {
    final small = <int>[];
    for (var l = 0; l < activeMax; l++) {
      if (area2[l] >= minArea) continue;
      if (area2[l] == 0) continue;
      small.add(l);
    }
    if (small.isEmpty) break;
    // 邻接统计。
    final adj = <int, Map<int, int>>{};
    for (var i = 0; i < n; i++) {
      final l = labels2[i];
      if (l < 0) continue;
      final x = i % w;
      if (x < w - 1) _adjPair(adj, l, labels2[i + 1]);
      if (i + w < n) _adjPair(adj, l, labels2[i + w]);
    }
    // 重映射表。
    final remap = Int32List(activeMax);
    for (var l = 0; l < activeMax; l++) {
      remap[l] = l;
    }
    var changed = 0;
    for (final l in small) {
      final neighbors = adj[l];
      if (neighbors == null || neighbors.isEmpty) continue;
      int best = -1;
      var bestArea = 0;
      neighbors.forEach((other, _) {
        // 找 other 的最终代表。
        var o = other;
        while (remap[o] != o) {
          o = remap[o];
        }
        final oa = area2[o];
        if (o != l && oa > bestArea) {
          bestArea = oa;
          best = o;
        }
      });
      if (best >= 0) {
        remap[l] = best;
        area2[best] += area2[l];
        area2[l] = 0;
        changed++;
      }
    }
    if (changed == 0) break;
    // 压缩路径 + 重算统计。
    for (var l = 0; l < activeMax; l++) {
      var o = l;
      while (remap[o] != o) {
        o = remap[o];
      }
      remap[l] = o;
    }
    final newMax = activeMax;
    final newArea = Int64List(newMax);
    final newLumSum = Float64List(newMax);
    final newLumMin = Float32List(newMax)..fillRange(0, newMax, 2.0);
    final newLumMax = Float32List(newMax);
    final newSumX = Float64List(newMax);
    final newSumY = Float64List(newMax);
    final newMinX = Int32List(newMax)..fillRange(0, newMax, 1 << 30);
    final newMaxX = Int32List(newMax);
    final newMinY = Int32List(newMax)..fillRange(0, newMax, 1 << 30);
    final newMaxY = Int32List(newMax);
    for (var i = 0; i < n; i++) {
      final l = labels2[i];
      if (l < 0) continue;
      final t = remap[l];
      labels2[i] = t;
      newArea[t]++;
      newLumSum[t] += blurV[i];
      if (blurV[i] < newLumMin[t]) newLumMin[t] = blurV[i];
      if (blurV[i] > newLumMax[t]) newLumMax[t] = blurV[i];
      final x = i % w;
      final y = i ~/ w;
      newSumX[t] += x;
      newSumY[t] += y;
      if (x < newMinX[t]) newMinX[t] = x;
      if (x > newMaxX[t]) newMaxX[t] = x;
      if (y < newMinY[t]) newMinY[t] = y;
      if (y > newMaxY[t]) newMaxY[t] = y;
    }
    area2 = newArea;
    lumSum = newLumSum;
    lumMin = newLumMin;
    lumMax = newLumMax;
    sumX = newSumX;
    sumY = newSumY;
    minX = newMinX;
    maxX = newMaxX;
    minY = newMinY;
    maxY = newMaxY;
  }

  // 重编号 1..N(墨线=0)。
  final remap2 = Int32List(activeMax)..fillRange(0, activeMax, -1);
  var idc = 0;
  for (var l = 0; l < activeMax; l++) {
    if (area2[l] > 0) remap2[l] = ++idc;
  }
  for (var i = 0; i < n; i++) {
    final l = labels2[i];
    labels2[i] = l < 0 ? -1 : remap2[l]; // 墨线 -1 → 0
  }
  for (var i = 0; i < n; i++) {
    if (labels2[i] < 0) labels2[i] = 0;
  }
  final blockCount = idc;

  // 重编号后从 labels2 重算统计(合并/重编号后的真实值)。
  area2 = Int64List(blockCount + 1);
  lumSum = Float64List(blockCount + 1);
  lumMin = Float32List(blockCount + 1)..fillRange(0, blockCount + 1, 2.0);
  lumMax = Float32List(blockCount + 1);
  sumX = Float64List(blockCount + 1);
  sumY = Float64List(blockCount + 1);
  minX = Int32List(blockCount + 1)..fillRange(0, blockCount + 1, 1 << 30);
  maxX = Int32List(blockCount + 1);
  minY = Int32List(blockCount + 1)..fillRange(0, blockCount + 1, 1 << 30);
  maxY = Int32List(blockCount + 1);
  for (var i = 0; i < n; i++) {
    final l = labels2[i];
    if (l <= 0) continue;
    area2[l]++;
    lumSum[l] += blurV[i];
    if (blurV[i] < lumMin[l]) lumMin[l] = blurV[i];
    if (blurV[i] > lumMax[l]) lumMax[l] = blurV[i];
    final x = i % w;
    final y = i ~/ w;
    sumX[l] += x;
    sumY[l] += y;
    if (x < minX[l]) minX[l] = x;
    if (x > maxX[l]) maxX[l] = x;
    if (y < minY[l]) minY[l] = y;
    if (y > maxY[l]) maxY[l] = y;
  }

  // v11.1 语义配色: 材质提示点(--hints)就近分配 —
  // 距块中心最近的 hint 且在影响半径(500px)内, 该块继承 hint 材质的常识色。
  Map<int, String>? semanticByBlock;
  if (hintsPath != null && File(hintsPath!).existsSync()) {
    final hintsRaw = jsonDecode(File(hintsPath).readAsStringSync()) as List;
    final hints = hintsRaw.cast<Map<String, Object?>>();
    semanticByBlock = {};
    const influence = 170.0;
    for (var l = 1; l <= blockCount; l++) {
      if (area2[l] <= 0) continue;
      final cx = sumX[l] / area2[l];
      final cy = sumY[l] / area2[l];
      var bestD = influence;
      String? bestMat;
      for (final hp in hints) {
        final hx = (hp['x'] as num).toDouble();
        final hy = (hp['y'] as num).toDouble();
        final d = math.sqrt((cx - hx) * (cx - hx) + (cy - hy) * (cy - hy));
        if (d < bestD) {
          bestD = d;
          bestMat = (hp['material'] ?? hp['role'] ?? 'backdrop') as String;
        }
      }
      if (bestMat != null) semanticByBlock[l] = bestMat;
    }
  }

  // 台账 JSON + AI 建议色。
  final blocks = <Map<String, Object?>>[];
  String hslHexLocal(double h, double s, double v) {
    final (rr, gg, bb) = _hsvToRgb(h, s, v);
    return '#'
        '${rr.toRadixString(16).padLeft(2, '0')}'
        '${gg.toRadixString(16).padLeft(2, '0')}'
        '${bb.toRadixString(16).padLeft(2, '0')}';
  }

  // v11.1 全色相空间渐变: 块按中心位置取色相(左→右 0-360° 隔行偏移),
  // 饱和/明度按块自身明度带缩放 — 黄色不再霸屏, 蓝绿红紫都进画面。
  String spatialHue(int l, double meanLum, int area) {
    final cx = sumX[l] / math.max(area2[l], 1);
    final cy = sumY[l] / math.max(area2[l], 1);
    final hue = ((cx / w) * 300 + (cy / h) * 60) % 360;
    final s = (meanLum >= 0.945 || area > 15000 && meanLum >= 0.92)
        ? 0.05
        : (meanLum >= 0.86 ? 0.14 : (meanLum >= 0.60 ? 0.26 : 0.30));
    final v = meanLum >= 0.945
        ? 0.98
        : (meanLum >= 0.86 ? 0.94 : (meanLum >= 0.60 ? 0.82 : 0.55));
    return hslHexLocal(hue, s, v);
  }

  String matHex(String mat, double meanLum, int blockId) {
    // 材质常识色 × 明度常识校验: 块均明度与材质常识带冲突时(如白纸亮度被判发色),
    // 降级为空间色相 — 防止密集提示点页全部被少数材质色霸屏。
    bool lumPlausible(String m, double lum) {
      switch (m) {
        case 'hair':
        case 'eye':
          return lum < 0.62; // 发/瞳是深色
        case 'skin':
        case 'blush':
          return lum >= 0.45 && lum < 0.97; // 肤色是中亮色, 不含纸白
        case 'white':
          return lum >= 0.82; // 白纸/白衣是高亮
        case 'sky':
          return lum >= 0.55; // 天空是中亮
        default:
          return true;
      }
    }

    if (!lumPlausible(mat, meanLum)) {
      // 明度常识冲突: 块与材质不符 — 按同材质的明度带内合格色处理,
      // 保持同材质一致: 深色块→材质深色, 中亮块→材质中色, 极亮块→材质亮色。
      // 仅当无该材质常识可用时才退回空间色相。
      switch (mat) {
        case 'hair':
        case 'eye':
          return '#5A4438'; // 深灰背景误判为发: 按发色统一
        case 'skin':
        case 'blush':
          return meanLum >= 0.97 ? '#FAF7F0' : '#F2CDA8';
        case 'white':
          return '#FAF7F0';
        case 'sky':
          return '#A8CCE4';
        default:
          return spatialHue(blockId, meanLum, 1000);
      }
    }
    // 材质常识色(自然物色, 非米黄单色) — 同材质块永远同色, 一致性优先。
    switch (mat) {
      case 'skin':
        return '#F2CDA8';
      case 'blush':
        return '#F0A898';
      case 'hair':
        return '#5A4438';
      case 'eye':
        return '#4A382E';
      case 'garment':
        return '#3E4A66';
      case 'garment2':
        return '#6E5A70';
      case 'sky':
        return '#A8CCE4';
      case 'white':
        return '#FAF7F0';
      default:
        return spatialHue(blockId, meanLum, 1000);
    }
  }

  String _hslHex(double h, double s, double v) => hslHexLocal(h, s, v);

  for (var l = 1; l <= blockCount; l++) {
    if (area2[l] <= 0) continue;
    final a = area2[l];
    final mean = lumSum[l] / a;
    String suggest;
    if (semanticByBlock != null && semanticByBlock.containsKey(l)) {
      // 语义块: 材质常识色。
      suggest = matHex(semanticByBlock[l]!, mean, l);
    } else {
      // 非语义块: 空间渐变全色相(取代暖色偏斜的旧色板)。
      suggest = spatialHue(l, mean, a);
    }
    blocks.add({
      'id': l,
      'areaPx': area2[l],
      'lumMin': _r2(lumMin[l]),
      'lumMax': _r2(lumMax[l]),
      'lumMean': _r2(mean),
      'bbox': [minX[l], minY[l], maxX[l] - minX[l] + 1, maxY[l] - minY[l] + 1],
      'center': [(sumX[l] / a).round(), (sumY[l] / a).round()],
      'material': semanticByBlock?[l],
      'suggest': suggest,
    });
  }
  File('$outDir/segments.json').writeAsStringSync(const JsonEncoder.withIndent(
          '  ')
      .convert({
    'source': input!.replaceAll('\\', '/'),
    'width': w,
    'height': h,
    'bands': bands,
    'minArea': minArea,
    'blockCount': blockCount,
    'blocks': blocks,
  }));

  // idmap (R=低8位, G=高8位)。
  final idRgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final id = labels2[i];
    idRgb[i * 3] = id & 0xFF;
    idRgb[i * 3 + 1] = (id >> 8) & 0xFF;
    idRgb[i * 3 + 2] = 0;
  }
  CliIo.writePng('$outDir/segment-idmap.png', idRgb, w, h);

  // 预览图: 金角散色相伪色 + 墨线黑。
  final prev = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final id = labels2[i];
    if (id == 0) {
      prev[i * 3] = 20;
      prev[i * 3 + 1] = 18;
      prev[i * 3 + 2] = 16;
      continue;
    }
    final hue = (id * 137.508) % 360;
    final (rr, gg, bb) = _hsvToRgb(hue, 0.32, 0.86);
    prev[i * 3] = rr;
    prev[i * 3 + 1] = gg;
    prev[i * 3 + 2] = bb;
  }
  CliIo.writePng('$outDir/segment-preview.png', prev, w, h);

  stdout.writeln('分割完成: $blockCount 块 (bands=$bands, minArea=$minArea), '
      '台账 ${dir.path}/segments.json');
  for (final b in blocks.take(8)) {
    stdout.writeln(
        '  #${b['id']} area=${b['areaPx']} lum=${b['lumMean']} suggest=${b['suggest']}');
  }
  if (blockCount > 8) stdout.writeln('  ... 共 $blockCount 块');
}

void _adjPair(Map<int, Map<int, int>> adj, int a, int b) {
  if (a == b || a < 0 || b < 0) return;
  adj.putIfAbsent(a, () => {}).update(b, (v) => v + 1, ifAbsent: () => 1);
  adj.putIfAbsent(b, () => {}).update(a, (v) => v + 1, ifAbsent: () => 1);
}

double _r2(double v) => (v * 100).round() / 100;

/// AI 建议色: 明度带 × 面积的常识规则(全局常数, 低饱和日系和谐色板)。
String _suggest(double meanLum, int area, int id) {
  String pick(List<String> palette) =>
      palette[(id * 2654435761) % palette.length];
  if (meanLum >= 0.945 && area > 15000) return '#FAF7F0';
  if (meanLum >= 0.86) {
    return pick(['#F1ECE2', '#E8ECEF', '#EFE9DF', '#F3EEE8']);
  }
  if (meanLum >= 0.60) {
    return pick(
        ['#F2CDA8', '#E9D8C4', '#DCE4E8', '#E4E0D4', '#F0DCC8', '#D8E2DC']);
  }
  if (meanLum >= 0.36) {
    return pick(['#7E8CA0', '#9E8A78', '#8A9E8E', '#A08498', '#6E7E92']);
  }
  if (meanLum >= 0.18) {
    return pick(['#4A382E', '#2E3A50', '#3E3A36']);
  }
  return '#1E1A18';
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
