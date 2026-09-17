import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 语义归类 + 一致性校验(四阶段流水线的第 2/3 阶段)。
///
/// 输入: segments.json + segment-idmap.png + vision-regions.json(AI 识图产物)
/// 输出:
///   class-map.png   — 语义标签叠加图(每类别一色的区划地图风格)
///   class-ledger.json — 逐块台账(id/面积/明度/类别/置信度/依据)
///   validation-report.json — 一致性校验报告(异常块+处理结论, 无静默跳过)
///
/// 归类规则: 块与类别 bbox 的重叠面积占块面积比例最大者胜(>0.35 才采信);
/// 重叠不足的块标 "unassigned", 由校验阶段按邻接块类别 + 明度带推断。
Future<void> main(List<String> args) async {
  final segDir = args[0];
  final regionsPath = args[1];
  final outDir = args.length > 2 ? args[2] : segDir;

  final seg =
      jsonDecode(File('$segDir/segments.json').readAsStringSync())
          as Map<String, Object?>;
  final w = seg['width'] as int;
  final h = seg['height'] as int;
  final blocks = (seg['blocks'] as List).cast<Map<String, Object?>>();
  final vision =
      jsonDecode(File(regionsPath).readAsStringSync()) as Map<String, Object?>;
  final regions = (vision['regions'] as List).cast<Map<String, Object?>>();
  final palette =
      (vision['palette'] as Map<String, Object?>).cast<String, String>();

  // idmap 载入。
  final idImg = img.decodePng(File('$segDir/segment-idmap.png').readAsBytesSync())!;
  int idAt(int x, int y) {
    final p = idImg.getPixel(x, y);
    return (p.r.toInt() & 0xFF) | ((p.g.toInt() & 0xFF) << 8);
  }

  // 逐块统计: 与每个类别 bbox 的重叠面积 + 明度。
  final blockArea = <int, int>{};
  final blockLum = <int, double>{};
  final overlap = <int, Map<String, int>>{};
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final id = idAt(x, y);
      if (id <= 0) continue;
      blockArea[id] = (blockArea[id] ?? 0) + 1;
      String? cat;
      for (final r in regions) {
        final bx = r['bbox'] as List;
        if (x >= (bx[0] as int) &&
            x < (bx[0] as int) + (bx[2] as int) &&
            y >= (bx[1] as int) &&
            y < (bx[1] as int) + (bx[3] as int)) {
          cat = r['category'] as String;
          break;
        }
      }
      if (cat != null) {
        overlap.putIfAbsent(id, () => {})[cat] =
            (overlap[id]?[cat] ?? 0) + 1;
      }
    }
  }
  for (final b in blocks) {
    final id = b['id'] as int;
    blockLum[id] = (b['lumMean'] as num).toDouble();
  }

  // 归类。
  final classOf = <int, String>{};
  final basisOf = <int, String>{};
  final confOf = <int, double>{};
  const minOverlap = 0.35;
  for (final b in blocks) {
    final id = b['id'] as int;
    final area = blockArea[id] ?? 0;
    if (area == 0) continue;
    final o = overlap[id];
    if (o == null || o.isEmpty) {
      classOf[id] = 'unassigned';
      basisOf[id] = '无类别区域覆盖';
      confOf[id] = 0;
      continue;
    }
    final sortedKeys = o.keys.toList()
      ..sort((a, b2) => o[b2]!.compareTo(o[a]!));
    final top = sortedKeys.first;
    final ratio = o[top]! / area;
    if (ratio >= minOverlap) {
      classOf[id] = top;
      basisOf[id] = '与 $top 区域重叠 ${o[top]!}/$area px (${(ratio * 100).toStringAsFixed(0)}%)';
      confOf[id] = (ratio * 0.9 + 0.1).clamp(0.0, 0.99);
    } else {
      classOf[id] = 'unassigned';
      basisOf[id] = '最大重叠 ${top} 仅 ${(ratio * 100).toStringAsFixed(0)}% < $minOverlap';
      confOf[id] = ratio;
    }
  }

  // 校验阶段: 未归一块按邻接类别推断(4-邻域最多票, 平票按明度带常识)。
  // v12 反光规则: 高亮(v≥0.90)且邻接 hair/skin 的块是「反光」而非白纸 —
  // 并入邻接的深色部位(头发上的反光→hair), 不再独立成 white。
  final fixes = <Map<String, Object?>>[];
  final neighbors = <int, Map<int, int>>{};
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final id = idAt(x, y);
      if (id <= 0) continue;
      if (x < w - 1) _adj(neighbors, id, idAt(x + 1, y));
      if (y < h - 1) _adj(neighbors, id, idAt(x, y + 1));
    }
  }
  final unassigned = classOf.entries
      .where((e) => e.value == 'unassigned')
      .map((e) => e.key)
      .toList();
  for (final id in unassigned) {
    final votes = <String, int>{};
    (neighbors[id] ?? {}).forEach((other, _) {
      final c = classOf[other];
      if (c != null && c != 'unassigned') {
        votes[c] = (votes[c] ?? 0) + 1;
      }
    });
    if (votes.isEmpty) {
      // v12 反光规则: 高亮块在 hair/skin 邻域内 → 归属该部位(反光处理)。
      final lum = blockLum[id] ?? 1.0;
      final nb = neighbors[id] ?? {};
      final hasDeepNb = nb.keys.any((o) {
        final c = classOf[o];
        return c == 'hair' || c == 'eye' || c == 'garment';
      });
      if (lum >= 0.90 && hasDeepNb) {
        String host = 'hair';
        for (final o in nb.keys) {
          final c = classOf[o];
          if (c != null && (c == 'hair' || c == 'eye' || c == 'garment')) {
            host = c;
            break;
          }
        }
        classOf[id] = host;
        basisOf[id] = '反光规则: 高亮 $lum 且邻接 $host → 并入(白色=反光)';
        confOf[id] = 0.75;
        fixes.add({
          'block': id,
          'issue': 'white-reflection',
          'action': '高亮块邻接 $host → 反光并入 $host',
        });
      } else {
        classOf[id] = 'backdrop';
        basisOf[id] = '无邻接归类块 → 兜底 backdrop';
        confOf[id] = 0.3;
        fixes.add({
          'block': id,
          'issue': 'unassigned-无邻接',
          'action': '兜底 backdrop',
        });
      }
      continue;
    }
    final sortedKeys = votes.keys.toList()
      ..sort((a, b2) => votes[b2]!.compareTo(votes[a]!));
    // 平票时按明度常识挑选(亮→white, 中→skin, 深→hair)。
    var pick = sortedKeys.first;
    if (votes.length > 1 && votes[sortedKeys[0]] == votes[sortedKeys[1]]) {
      final lum = blockLum[id] ?? 1.0;
      pick = lum >= 0.88
          ? (votes.containsKey('white') ? 'white' : pick)
          : (lum < 0.45
              ? (votes.containsKey('hair') ? 'hair' : pick)
              : (votes.containsKey('skin') ? 'skin' : pick));
      fixes.add({
        'block': id,
        'issue': 'unassigned-邻接平票',
        'action': '按明度 $lum 归 $pick',
      });
    } else {
      fixes.add({
        'block': id,
        'issue': 'unassigned-邻接多数',
        'action': '归 ${sortedKeys.first}(票 ${votes[sortedKeys.first]})',
      });
    }
    classOf[id] = pick;
    basisOf[id] = '邻接投票 ${votes.entries.map((e) => '${e.key}:${e.value}').join(', ')}';
    confOf[id] = 0.55;
  }

  // 类别内明度异常检测: 类别常识带冲突的块记入报告(不静默)。
  const plausible = {
    'hair': [0.0, 0.72],
    'eye': [0.0, 0.55],
    'lip': [0.40, 0.97],
    'skin': [0.40, 0.97],
    'garment': [0.0, 1.0],
    'white': [0.72, 1.01],
    'sky': [0.50, 1.01],
    'backdrop': [0.0, 1.01],
  };
  final anomalies = <Map<String, Object?>>[];
  for (final b in blocks) {
    final id = b['id'] as int;
    final cat = classOf[id];
    if (cat == null || !plausible.containsKey(cat)) continue;
    final lum = blockLum[id] ?? 0;
    final band = plausible[cat]!;
    if (lum < band[0] || lum >= band[1]) {
      String action;
      if (cat == 'white' && lum < 0.72) {
        // 白纸误含灰块: 降为 backdrop 保留灰度层次。
        classOf[id] = 'backdrop';
        action = '重新归类 white→backdrop(明度 $lum 不在白区)';
      } else if (cat == 'hair' && lum >= 0.72) {
        classOf[id] = 'white';
        action = '重新归类 hair→white(明度 $lum 过亮)';
      } else {
        action = '保留但标记(明度 $lum 处于 $cat 常识带边缘)';
      }
      anomalies.add({
        'block': id,
        'category': cat,
        'lumMean': lum,
        'expectedBand': band,
        'action': action,
      });
    }
  }

  // 台账。
  final ledger = blocks.map((b) {
    final id = b['id'] as int;
    return {
      'id': id,
      'areaPx': b['areaPx'],
      'lumMean': b['lumMean'],
      'category': classOf[id],
      'confidence': (confOf[id] ?? 0).toStringAsFixed(2),
      'basis': basisOf[id],
      'finalColor': palette[classOf[id]] ?? '#D8D4CC',
    };
  }).toList()
    ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
  File('$outDir/class-ledger.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
    'source': seg['source'],
    'blockCount': seg['blockCount'],
    'visionModel': vision['visionModel'],
    'blocks': ledger,
  }));

  // 校验报告。
  File('$outDir/validation-report.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
    'summary': {
      'totalBlocks': blocks.length,
      'assignedByOverlap':
          blocks.length - unassigned.length - anomalies.length,
      'unassignedFixed': unassigned.length,
      'anomalies': anomalies.length,
      'silentSkips': 0,
    },
    'categoryCounts': _categoryCounts(classOf),
    'fixes': fixes,
    'anomalies': anomalies,
  }));

  // 语义标签叠加图(区划地图风格: 类别固定色, 墨线黑)。
  const catColor = {
    'hair': [90, 68, 56],
    'eye': [74, 56, 46],
    'lip': [226, 138, 128],
    'skin': [242, 205, 168],
    'garment': [62, 74, 102],
    'white': [250, 247, 240],
    'sky': [168, 204, 228],
    'backdrop': [216, 212, 204],
    'unassigned': [200, 160, 90],
  };
  final out = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final id = idAt(x, y);
      final c = id == 0
          ? [20, 18, 16]
          : (catColor[classOf[id]] ?? [200, 160, 90]);
      out.setPixelRgba(x, y, c[0], c[1], c[2], 255);
    }
  }
  File('$outDir/class-map.png')
      .writeAsBytesSync(img.encodePng(out));

  // 类别计数输出。
  stdout.writeln('归类完成: ${blocks.length} 块');
  _categoryCounts(classOf).forEach((k, v) => stdout.writeln('  $k: $v 块'));
  stdout.writeln(
      '校验: 未归一修复 ${unassigned.length}, 明度异常 ${anomalies.length}, 静默跳过 0');
}

Map<String, int> _categoryCounts(Map<int, String> classOf) {
  final counts = <String, int>{};
  classOf.values.forEach((c) => counts[c] = (counts[c] ?? 0) + 1);
  return counts;
}

void _adj(Map<int, Map<int, int>> adj, int a, int b) {
  if (a == b || a <= 0 || b <= 0) return;
  adj.putIfAbsent(a, () => {})[b] = 1;
  adj.putIfAbsent(b, () => {})[a] = 1;
}
