import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:manga_colorizer_cli/src/cli_io.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 第四阶段: 按语义类别台账统一上色。
///
/// 规则: 同类别所有块用同一基色(台账 finalColor), 块内按"块均明度→像素明度"
/// 的相对偏差做深浅调制 — 类别内深浅层次保留(阴影更暗/高光更亮),
/// 类别间色值一致(头发统一/衣服统一/眼镜两侧一致/面部肤色正确)。
/// 另存分图层 PNG(每类别一层, 透明背景)。
///
/// 用法:
///   dart run bin/paint_classified.dart -i in.png -s segDir -o out.png [-l layersDir]
Future<void> main(List<String> args) async {
  String? input;
  String? segDir;
  String? output;
  String? layersDir;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-i':
        input = args[++i];
      case '-s':
        segDir = args[++i];
      case '-o':
        output = args[++i];
      case '-l':
        layersDir = args[++i];
      default:
        stderr.writeln('未知参数: ${args[i]}');
        exitCode = 64;
        return;
    }
  }
  if (input == null || segDir == null || output == null) {
    stderr.writeln(
        '用法: dart run bin/paint_classified.dart -i <输入> -s <分割目录> -o <输出> [-l <图层目录>]');
    exitCode = 64;
    return;
  }

  final ledger = jsonDecode(
          File('$segDir/class-ledger.json').readAsStringSync())
      as Map<String, Object?>;
  final blocks = (ledger['blocks'] as List).cast<Map<String, Object?>>();
  final colorOf = <int, List<int>>{};
  final catOf = <int, String>{};
  for (final b in blocks) {
    final id = b['id'] as int;
    colorOf[id] = _hex(b['finalColor'] as String);
    catOf[id] = b['category'] as String;
  }

  final source = CliIo.readGrayscale(input);
  final w = source.width;
  final h = source.height;
  final n = w * h;
  final idImg = img.decodePng(
      File('$segDir/segment-idmap.png').readAsBytesSync())!;
  int idAt(int x, int y) {
    final p = idImg.getPixel(x, y);
    return (p.r.toInt() & 0xFF) | ((p.g.toInt() & 0xFF) << 8);
  }

  final v0 = Float32List(n);
  for (var i = 0; i < n; i++) {
    v0[i] = source.rgb[i * 3] / 255.0;
  }
  final blurV = boxBlur(boxBlur(v0, w, h, 2), w, h, 2);

  // 类别内块均明度与类别明度范围(用于深浅归一: 类别内相对偏差, 而非块内偏差 —
  // 这样同类别内深块/浅块之间的过渡也被保留)。
  final catSum = <String, double>{};
  final catCnt = <String, int>{};
  final blkSum = Float64List(1 << 16);
  final blkCnt = Int64List(1 << 16);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final id = idAt(x, y);
      if (id <= 0 || id >= blkSum.length) continue;
      final i = y * w + x;
      final cat = catOf[id] ?? 'backdrop';
      catSum[cat] = (catSum[cat] ?? 0) + blurV[i];
      catCnt[cat] = (catCnt[cat] ?? 0) + 1;
      blkSum[id] += blurV[i];
      blkCnt[id]++;
    }
  }
  final catMean = <String, double>{};
  catSum.forEach((k, v) => catMean[k] = v / math.max(catCnt[k] ?? 1, 1));

  // 类别明度范围(用于类别内深浅归一): 面积加权统计 + 噪声块(area<10)过滤。
  // v12.1 修复: 1px 噪声块把 hair 全距拉到 0.1-0.7, 中位锚被拉低致头发灰白。
  final catBand = <String, List<double>>{};
  final catBandMin = <String, double>{};
  final catBandMax = <String, double>{};
  for (final b in blocks) {
    final cat = b['category'] as String?;
    if (cat == null) continue;
    final area = (b['areaPx'] as num).toInt();
    if (area < 10) continue; // 噪声块不参与明度带统计
    final lo = (b['lumMin'] ?? 1.0) as num;
    final hi = (b['lumMax'] ?? 0.0) as num;
    catBandMin[cat] = math.min(catBandMin[cat] ?? 2.0, lo.toDouble());
    catBandMax[cat] = math.max(catBandMax[cat] ?? 0.0, hi.toDouble());
  }
  catBandMin.forEach((k, lo) {
    catBand[k] = [lo, catBandMax[k] ?? math.min(lo + 0.3, 1.0)];
  });

  // 分图层(每类别一层)。
  final layers = <String, Uint8List>{};

  final out = Uint8List(n * 3);
  var painted = 0, inked = 0;
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
      final cat = catOf[id] ?? 'backdrop';
      final hex = colorOf[id] ?? _hex('#D8D4CC');
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

      // 深浅调制 v12: 渐变保留模式 —
      // 以像素展平明度 v 相对 0.5 的位置, 在「基色」与「高光白/阴影色」之间连续插值:
      //   v>0.5: 基色→白(高光), 按 smooth((v-0.5)/0.5) 混入白;
      //   v<0.5: 基色→黑(阴影), 按 smooth((0.5-v)/0.5) 混入黑;
      // 原灰阶渐变完整保留(逐像素连续), 不再有纯色平涂感。
      final catM = catMean[cat] ?? 1.0;
      final v = blurV[i];
      // 类别内相对位置: 用类别明度范围归一, 使同类别内深浅映射一致。
      final band = catBand[cat] ?? [0.2, 0.9];
      // v12.2 修复: rel 以【块自身 lumMean】为 0.5 锚点(块均色=基色原亮度),
      // 像素在块内相对块均做深浅微调 — 发主块整体呈现基色棕, 发内高光丝偏亮,
      // 而非被类别全距重新分配(那会把深发块推到灰白)。
      final blkMean = blkCnt[id] == 0
          ? (catBand[cat]?[1] ?? 0.8)
          : blkSum[id] / blkCnt[id];
      final blkSpread = math.max(band[1] - band[0], 0.06);
      final rel = (0.5 + (v - blkMean) / (blkSpread * 0.9)).clamp(0.0, 1.0);
      final hi = _smooth((rel - 0.55) / 0.45); // 高光混合量
      final lo = _smooth((0.45 - rel) / 0.45); // 阴影混合量
      // 高光/阴影端点: 中间调(rel≈0.5)基本保持基色原亮度;
      // 高光端向白推 65%, 阴影端保 55% 亮度(不再过暗)。
      final hiR = lr + (1 - lr) * 0.65, hiG = lg + (1 - lg) * 0.65,
          hiB = lb + (1 - lb) * 0.65;
      final loR = lr * 0.55, loG = lg * 0.55, loB = lb * 0.55;
      var mixR = lr + (hiR - lr) * hi - (lr - loR) * lo;
      var mixG = lg + (hiG - lg) * hi - (lg - loG) * lo;
      var mixB = lb + (hiB - lb) * hi - (lb - loB) * lo;
      // 纸白类别: 白纸就保持白, 不做明暗调制(文字框/留白干净)。
      if (cat == 'white') {
        mixR = lr;
        mixG = lg;
        mixB = lb;
      }
      final or = (mixR * 255).round().clamp(0, 255);
      final og = (mixG * 255).round().clamp(0, 255);
      final ob = (mixB * 255).round().clamp(0, 255);
      out[i * 3] = or;
      out[i * 3 + 1] = og;
      out[i * 3 + 2] = ob;
      painted++;

      if (layersDir != null) {
        layers.putIfAbsent(cat, () => Uint8List(n * 4));
        final buf = layers[cat]!;
        buf[i * 4] = or;
        buf[i * 4 + 1] = og;
        buf[i * 4 + 2] = ob;
        buf[i * 4 + 3] = 255;
      }
    }
  }
  CliIo.writePng(output, out, w, h);

  if (layersDir != null) {
    final dir = Directory(layersDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    layers.forEach((cat, buf) {
      final layer = img.Image.fromBytes(
          width: w,
          height: h,
          bytes: buf.buffer,
          numChannels: 4);
      File('$layersDir/layer-$cat.png')
          .writeAsBytesSync(img.encodePng(layer));
    });
    stdout.writeln('分图层: ${layers.keys.join(", ")} → $layersDir');
  }
  stdout.writeln(
      'paint_classified 完成: 上色 $painted px, 墨线 $inked px, 类别 ${catOf.values.toSet().length}');
}

double _smooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

List<int> _hex(String s) {
  final t = s.replaceFirst('#', '');
  return [
    int.parse(t.substring(0, 2), radix: 16),
    int.parse(t.substring(2, 4), radix: 16),
    int.parse(t.substring(4, 6), radix: 16)
  ];
}
