import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:manga_colorizer_cli/src/cli_io.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 按块上色 v11: 读取色块-颜色映射, 全图逐块着色。
///
/// 机制: idmap 定位每像素所属块 → 该块最终色(用户指定 > AI 建议) →
/// 按块内展平明度相对块均值的偏差做亮度/饱和微调(保留网点阴影层次) →
/// 墨线(id=0)原样保留 → 全覆盖无漏涂。
///
/// 用法:
///   dart run bin/paint_blocks.dart -i in.png -s segDir -m colors.json -o out.png
/// colors.json: {"2": "#FAF7F0", "6": "#F2CDA8", ...}  (键=块 id 十进制字符串)
Future<void> main(List<String> args) async {
  String? input;
  String? segDir;
  String? mapPath;
  String? output;
  var keepUnassigned = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-i':
        input = args[++i];
      case '-s':
        segDir = args[++i];
      case '-m':
        mapPath = args[++i];
      case '-o':
        output = args[++i];
      case '--keep-unassigned':
        keepUnassigned = true;
      default:
        stderr.writeln('未知参数: ${args[i]}');
        exitCode = 64;
        return;
    }
  }
  if (input == null || segDir == null || output == null) {
    stderr.writeln('用法: dart run bin/paint_blocks.dart -i <输入> -s <分割目录> '
        '[-m colors.json] -o <输出> [--keep-unassigned]');
    exitCode = 64;
    return;
  }

  final seg =
      jsonDecode(File('$segDir/segments.json').readAsStringSync())
          as Map<String, Object?>;
  final w = seg['width'] as int;
  final h = seg['height'] as int;
  final blocks = (seg['blocks'] as List).cast<Map<String, Object?>>();
  final suggest = <int, List<int>>{};
  for (final b in blocks) {
    suggest[b['id'] as int] = _hex(b['suggest'] as String);
  }

  final userMap = <int, List<int>>{};
  var userBlockCount = 0;
  if (mapPath != null && File(mapPath).existsSync()) {
    final m = jsonDecode(File(mapPath).readAsStringSync())
        as Map<String, Object?>;
    m.forEach((k, v) {
      final id = int.parse(k);
      if (id > 0) {
        userMap[id] = _hex(v as String);
        userBlockCount++;
      }
    });
  }

  final source = CliIo.readGrayscale(input);
  if (source.width != w || source.height != h) {
    stderr.writeln(
        '错误: 输入尺寸 ${source.width}x${source.height} 与分割 ${w}x$h 不一致');
    exitCode = 64;
    return;
  }
  final idImg = img.decodePng(
      File('$segDir/segment-idmap.png').readAsBytesSync());
  if (idImg == null) {
    stderr.writeln('错误: segment-idmap.png 解码失败');
    exitCode = 70;
    return;
  }
  int idAt(int x, int y) {
    final p = idImg.getPixel(x, y);
    return (p.r.toInt() & 0xFF) | ((p.g.toInt() & 0xFF) << 8);
  }

  final n = w * h;
  final out = Uint8List(n * 3);
  final v0 = Float32List(n);
  for (var i = 0; i < n; i++) {
    v0[i] = source.rgb[i * 3] / 255.0;
  }
  final blurV = boxBlur(boxBlur(v0, w, h, 2), w, h, 2);

  // 块均值(展平明度)。
  final blkSum = Float64List(1 << 16);
  final blkCnt = Int64List(1 << 16);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final id = idAt(x, y);
      if (id <= 0 || id >= blkSum.length) continue;
      final i = y * w + x;
      blkSum[id] += blurV[i];
      blkCnt[id]++;
    }
  }

  var painted = 0, inked = 0, fallback = 0, keptGray = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final id = idAt(x, y);
      if (id == 0) {
        out[i * 3] = source.rgb[i * 3];
        out[i * 3 + 1] = source.rgb[i * 3 + 1];
        out[i * 3 + 2] = source.rgb[i * 3 + 2];
        inked++;
        continue;
      }
      List<int>? hex;
      var isUser = false;
      if (userMap.containsKey(id)) {
        hex = userMap[id];
        isUser = true;
      } else if (!keepUnassigned) {
        hex = suggest[id];
      }
      if (hex == null) {
        out[i * 3] = source.rgb[i * 3];
        out[i * 3 + 1] = source.rgb[i * 3 + 1];
        out[i * 3 + 2] = source.rgb[i * 3 + 2];
        keptGray++;
        continue;
      }
      if (!isUser) fallback++;

      final cnt = blkCnt[id] == 0 ? 1 : blkCnt[id];
      final mean = blkSum[id] / cnt;
      final dev = ((blurV[i] - mean) / math.max(mean, 0.05)).clamp(-0.6, 0.35);
      final lumK = 1.0 + dev * 0.45;
      final satK = 1.0 - dev * 0.55;

      final lr = hex[0] / 255.0, lg = hex[1] / 255.0, lb = hex[2] / 255.0;
      final mx = math.max(lr, math.max(lg, lb));
      final mn = math.min(lr, math.min(lg, lb));
      final sHsv = mx <= 0 ? 0.0 : (mx - mn) / mx;
      final d = mx - mn;
      double hh;
      if (d <= 0) {
        hh = 0;
      } else if (mx == lr) {
        hh = 60 * (((lg - lb) / d) % 6);
      } else if (mx == lg) {
        hh = 60 * ((lb - lr) / d + 2);
      } else {
        hh = 60 * ((lr - lg) / d + 4);
      }
      if (hh < 0) hh += 360;
      final s2 = (sHsv * satK).clamp(0.0, 0.9);
      final v2 = (mx * lumK).clamp(0.0, 1.0);

      final c = v2 * s2;
      final x2 = c * (1 - ((hh / 60) % 2 - 1).abs());
      final m2 = v2 - c;
      double rr, gg, bb;
      if (hh < 60) {
        rr = c;
        gg = x2;
        bb = 0;
      } else if (hh < 120) {
        rr = x2;
        gg = c;
        bb = 0;
      } else if (hh < 180) {
        rr = 0;
        gg = c;
        bb = x2;
      } else if (hh < 240) {
        rr = 0;
        gg = x2;
        bb = c;
      } else if (hh < 300) {
        rr = x2;
        gg = 0;
        bb = c;
      } else {
        rr = c;
        gg = 0;
        bb = x2;
      }
      out[i * 3] = ((rr + m2) * 255).round().clamp(0, 255);
      out[i * 3 + 1] = ((gg + m2) * 255).round().clamp(0, 255);
      out[i * 3 + 2] = ((bb + m2) * 255).round().clamp(0, 255);
      painted++;
    }
  }
  CliIo.writePng(output, out, w, h);
  stdout.writeln('paint_blocks 完成: 上色 $painted px, 墨线 $inked px, '
      'AI 建议兜底 $fallback px, 保留灰度 $keptGray px, 用户指定块 $userBlockCount');
}

List<int> _hex(String s) {
  final t = s.replaceFirst('#', '');
  return [
    int.parse(t.substring(0, 2), radix: 16),
    int.parse(t.substring(2, 4), radix: 16),
    int.parse(t.substring(4, 6), radix: 16)
  ];
}
