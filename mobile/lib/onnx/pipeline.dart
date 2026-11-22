// 端侧全自动上色管线：对齐桌面 tool/colorizer_service/service.py 的语义 —
//   · 单块（max(w,h)≤infer）＝ colorize()（service.py:401-410）：模型输出
//     INTER_CUBIC 放大回原尺寸后直取 a/b，**不做羽化归一**；L 恒取原稿。
//   · 多块 ＝ colorize_tiled（service.py:375-398）：tile=infer / overlap 重叠，
//     每块独立 缩 infer² → SAM+generator → 只羽化融合 a/b 色度；L 恒取原稿。
//   · 输出端色彩收尾 v2（两端同数学）：labToRgbFinish = 白色前景救援（封闭
//     近白区域跳过中和并按色度压低 L，见 core white_rescue.dart；L 压低是
//     「L 恒取原稿」的唯一例外——L=255 处色度没有渲染空间）→ 纸白中和（去
//     模型纸白暖偏——「偏黄」主因）→ 自适应软膝增益（弱色多提强色少提——
//     「偏灰」主因）→ 方案色温 → 色域映射（亮度不变等比收缩替代逐通道截断）。
//     方案表 kFinishSchemes 与桌面 FINISH_SCHEMES 同表（默认 standard，
//     桌面 COLORIZER_CHROMA_GAIN 环境变量可覆写 standard 增益）。已知微小
//     偏差：桌面 tiled 路径全程浮点直达收尾，本端在 8bit a/b 量化后收尾
//     （≤0.7 Lab 单位），与 resize 插值偏差同级，记入真机验收清单。
//   · 收尾之前有跨格一致性三 pass（core consistency.dart，两端同数学）：
//     主色相填充（一材质一固有色，修头发分区偏灰）+ 同材质色相统一（修跨格
//     异色）+ 中性区色度保底（修排线区灰块感）。
// 推理经 OnnxBackend 抽象（真机＝OrtOnnxBackend，宿主测试＝FakeBackend），
// 全程并发 1（逐块 await），每块前查取消、每块后按块上报进度。
// 内存压峰（v0.5.5）：浮点张量与整页累加缓冲的生命周期都收敛在子函数栈帧里——
// _inferToRgb8 返回后每块 ~50MB 浮点缓冲出作用域；_inferTilesToLab 返回后
// ~50MB 的 chroma/weight 累加缓冲出作用域，labToRgb/PNG 编码阶段不再背着它们。
import 'dart:typed_data';
import 'package:image/image.dart' as imglib;
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import '../mem_info.dart';
import 'backend_api.dart';
import 'tiles.dart';

/// 输出端色彩收尾方案（与桌面 FINISH_SCHEMES 同表，core finish.dart 注册）：
/// 纸白中和（去偏黄）+ 自适应软膝增益（去偏灰）+ 色域映射，默认 standard。
/// 旧的平增益常量 kAutoChromaGain=1.2 已被方案表取代（v0.6.0）。

/// 输入灰度 w*h（1B/px），输出上色 RGB w*h*3；null = 被取消。
Future<Uint8List?> autoColorize({
  required Uint8List gray,
  required int width,
  required int height,
  required OnnxBackend backend,
  int infer = 1024,
  int overlap = 256,
  FinishOptions? finish,
  void Function(double progress)? onProgress,
  bool Function()? cancelled,
  void Function(String line)? onLog,
}) async {
  final fin = finish ?? kFinishSchemes[kDefaultFinishScheme]!;
  if (cancelled?.call() ?? false) return null;
  final n = width * height;
  // 逐块推理 + 整页 Lab 合成都在子帧里：chroma/weight（@4.2MP ≈50MB）随
  // _inferTilesToLab 返回出作用域，此后的 refL/labToRgb 峰值不再叠它们。
  final outLab = await _inferTilesToLab(
    gray: gray,
    width: width,
    height: height,
    backend: backend,
    infer: infer,
    overlap: overlap,
    onProgress: onProgress,
    cancelled: cancelled,
    onLog: onLog,
  );
  if (outLab == null) return null;
  // 跨格一致性 v1（两端同数学, core consistency.dart）: ①同材质色相统一——
  // 「色调签名相同但色相冲突」的色块
  // 统一到质量更大的色相（修「同一人物/物件跨格不同色」）; ②中性区色度保底
  // ——L∈[64,234) 且色度低于随暗度增长的保底
  // 曲线的像素沿局部主色方向抬到保底（修「密集排线区平涂成灰块, 看起来没上
  // 色」）; ②主色相填充——截尾均值收敛到同明度带的主色相簇, 带内弱色度像素
  // 整块获得该簇平均色（只填不转）, 按「一材质一固有色」的专业原则修「头发
  // 颜色分区且偏灰」。放在白色前景救援之前: 都只动 a/b、L 恒取原稿, 且保底的局部
  // 主色统计不应看到救援/收尾改写后的色度场。ab 提取到 float 执行（桌面 tiled
  // 全程浮点; 本端进出各多一次 8bit 量化, 偏差 ≤0.7 Lab, 属文件头「已知微小
  // 偏差」同级）; lBytes 是 outLab 的 L 通道（= grayToLabL）的紧凑拷贝。
  final abF = Float32List(n * 2);
  final lBytes = Uint8List(n);
  for (var i = 0; i < n; i++) {
    lBytes[i] = outLab[i * 3];
    abF[i * 2] = outLab[i * 3 + 1].toDouble();
    abF[i * 2 + 1] = outLab[i * 3 + 2].toDouble();
  }
  applyConsistency(abF, lBytes, width, height);
  for (var i = 0; i < n; i++) {
    outLab[i * 3 + 1] = abF[i * 2].round().clamp(0, 255);
    outLab[i * 3 + 2] = abF[i * 2 + 1].round().clamp(0, 255);
  }
  // 白色前景救援: 封闭近白区域（白发/白衣/画格内背景）在 L=255 处没有色度
  // 渲染空间, 收尾对这些像素跳过纸白中和并按色度压低 L（与桌面 `_with_rescue`
  // 同公式）。放在推理返回之后计算——BFS 的临时缓冲（visited/queue ~20MB）
  // 不与块累加缓冲（~50MB）叠峰; marks（4B/px n≈4.2MP 时 4MB）活到收尾。
  final rescueMarks = whiteRescueMarks(gray, width, height);
  final rescueC0 = whiteRescueC0(outLab, rescueMarks, n);
  // 色彩收尾 v2：白色前景救援 → 纸白中和（去偏黄）→ 自适应软膝增益（去偏灰）
  // → 方案色温 → 色域映射，语义对拍桌面 _finish_bgr（金样 finish_golden.json ±1）。
  return labToRgbFinish(outLab, n, fin,
      rescue: rescueMarks,
      rescueC0: rescueC0,
      rescueC1: rescueC0 + kRescueGateWidth);
}

/// 逐块推理并把 a/b 色度加权累加进整页 Lab（L 由原稿灰度直取，见
/// lab.dart grayToLabL），返回 8bit Lab（n*3）；取消返回 null。
Future<Uint8List?> _inferTilesToLab({
  required Uint8List gray,
  required int width,
  required int height,
  required OnnxBackend backend,
  required int infer,
  required int overlap,
  void Function(double progress)? onProgress,
  bool Function()? cancelled,
  void Function(String line)? onLog,
}) async {
  final ys = tileBounds(height, infer, overlap);
  final xs = tileBounds(width, infer, overlap);
  final total = ys.length * xs.length;
  final n = width * height;
  // 加权色度累加（a/b 为 +128 偏置的 8bit Lab 值，与桌面同为 float 累加）。
  final chroma = Float32List(n * 2);
  final weight = Float32List(n);
  var done = 0;
  for (final (y0, y1) in ys) {
    for (final (x0, x1) in xs) {
      if (cancelled?.call() ?? false) return null;
      final sw = Stopwatch()..start();
      final pw = x1 - x0, ph = y1 - y0;
      final patch = _crop(gray, width, x0, y0, pw, ph);
      final tag = '块 ${done + 1}/$total';
      final rgb = await _inferPatch(patch, pw, ph, infer, backend,
          onLog: (line) => onLog?.call('$tag $line'));
      final lab = rgbToLab(rgb, pw * ph);
      // 单块路径无羽化（桌面 colorize 直取 a/b）；多块路径两端 ramp 到 0，
      // 与 _feather_weight 逐值同构（含权重 0 像素被 1e-6 归一的桌面行为）。
      final wy = total == 1 ? null : featherWeight(y0, y1, overlap);
      final wx = total == 1 ? null : featherWeight(x0, x1, overlap);
      for (var py = 0; py < ph; py++) {
        final m2 = wy == null ? 1.0 : wy[py];
        final rowBase = (y0 + py) * width + x0;
        final pBase = py * pw * 3;
        for (var px = 0; px < pw; px++) {
          final m = wx == null ? m2 : m2 * wx[px];
          if (m == 0.0) continue; // 零权像素两端都不贡献（桌面同：0*a 不改变结果）
          final g = rowBase + px;
          chroma[g * 2] += lab[(pBase + px * 3) + 1] * m;
          chroma[g * 2 + 1] += lab[(pBase + px * 3) + 2] * m;
          weight[g] += m;
        }
      }
      done++;
      onProgress?.call(done / total);
      onLog?.call(
          '块 $done/$total（$pw×$ph）耗时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
          '${rssSuffix()}');
    }
  }
  // L 恒取原稿：单通道直接算 Lab 的 L（灰度退化 RGB 的 a/b 恒为偏置 128，
  // 数值与 rgbToLab(展开三通道) 逐值一致，见 lab.dart grayToLabL）；a/b 用
  // 融合后的原始色度（收尾的增益/中和在 labToRgbFinish 里施加——桌面 tiled
  // 全程浮点直达收尾，本端先 8bit 量化再收尾，增益量化噪声 ≤0.7 Lab 单位，
  // 见文件头「已知微小偏差」）。
  final refL = grayToLabL(gray);
  final outLab = Uint8List(n * 3);
  for (var p = 0; p < n; p++) {
    final ww = weight[p] < 1e-6 ? 1e-6 : weight[p];
    outLab[p * 3] = refL[p];
    outLab[p * 3 + 1] = (chroma[p * 2] / ww).round().clamp(0, 255);
    outLab[p * 3 + 2] = (chroma[p * 2 + 1] / ww).round().clamp(0, 255);
  }
  return outLab;
}

Uint8List _crop(Uint8List g, int gw, int x0, int y0, int w, int h) {
  final o = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    o.setRange(y * w, y * w + w, g, (y0 + y) * gw + x0);
  }
  return o;
}

/// 一块的完整推理：缩 infer²（INTER_AREA 语义）→ SAM+generator（后端支持
/// tagger 时走 512 语义自举，输出 infer/2²）→ clip 反归一化 → 放大回块尺寸
/// （INTER_CUBIC 语义）→ 块原始分辨率 RGB。
/// 对应桌面 colorize_single（service.py:346-373）；GPU 回退是绑定层的事，不在这里。
Future<Uint8List> _inferPatch(Uint8List patch, int pw, int ph, int infer,
    OnnxBackend b,
    {void Function(String line)? onLog}) async {
  // 浮点张量只被推理本身需要：chw/grayPlane/sam 特征/输出（1024² 时 ~50MB）
  // 全部收敛在 _inferToRgb8 的栈帧里，返回 8bit 后即不可达——否则它们会活到
  // 下面的 cubic 放大与取回拷贝全程，白叠一个同量级的峰值。
  final (rgb8, size) =
      await _inferToRgb8(patch, pw, ph, infer, b, onLog: onLog);
  final mid = imglib.Image.fromBytes(
      width: size, height: size, bytes: rgb8.buffer, numChannels: 3);
  final big = imglib.copyResize(mid,
      width: pw,
      height: ph,
      // image 4.3 的枚举名 catmullRom 在 4.10（本 workspace 解析到的 4.10.1）
      // 改叫 Interpolation.cubic（getPixelCubic＝0.5 系数 Catmull-Rom，
      // 与 cv2 INTER_CUBIC 同族 Keys 三次卷积，a=-0.5 vs -0.75）。
      interpolation: imglib.Interpolation.cubic);
  // getBytes() 无参（order=null）是 image 4.10 内部存储的视图
  // （image_data.dart:71 → toUint8List → buffer.asUint8List），缓冲即 3n
  // 紧凑存储；big 是本函数私有的新鲜 Image、无人再写它，直接返回视图——
  // 旧实现在这里再 fromList 复制一份，多背 12.6MB/块。
  return big.getBytes();
}

/// 语义自举的生成器推理分辨率：FiLM 语义通路仅在训练分辨率 512 有效
/// （桌面 2026-11-21 取证，service.py `WD14_INFER_SIZE` 同值同注释）。
const kBootstrapInfer = 512;

/// 推理到 8bit RGB（返回 (rgb8, 边长)——语义自举路径输出 kBootstrapInfer²，
/// 否则 infer²）：缩放/归一化/双 session（+tagger）/clip 反归一化。
/// 所有浮点中间量（chw、grayPlane、sam 特征、rgb_pred）都是本函数局部量，
/// 返回即出作用域——这是「每块峰值」与「放大阶段」不叠加的保证。
/// [onLog] 逐阶段心跳（SAM 编码/生成开始）：真机推理中途进程死亡时，日志页
/// 的时间戳据此定位死在哪个模型（v0.5.11 真机「加载完 ~48s 断连、无任何块
/// 日志」的取证缺口）。
///
/// 语义自举（后端 supportsTagger 时，桌面 service.py `_run_pair` 同配方）:
/// SAM 特征共享 → gen@512 zeros 出图 → 去网点+白底补方 448² 喂 tagger 得
/// 嵌入 → gen@512 带嵌入出图（输出 512²，放大回块由 _inferPatch 承担）。
/// tagger 返回 null 或自举任一步抛错 → 回退 zeros@infer 旧路径（整块降级，
/// 不失败）。MNN 后端 supportsTagger 恒 false，走旧路径。
Future<(Uint8List, int)> _inferToRgb8(Uint8List patch, int pw, int ph,
    int infer, OnnxBackend b,
    {void Function(String line)? onLog}) async {
  // image 包 Interpolation.average：目标像素＝源像素整数窗口均值，
  // 与 cv2 INTER_AREA 同族（非整数比例时 cv2 按面积加权、这里有微小出入，
  // 属已知偏差：像素级对拍归并后真机验收清单，宿主语义测试不覆盖该差异）。
  // 注意 fromBytes 对传入缓冲做 Uint8List.view——必须先复制出独立缓冲，
  // 不让 Image 与调用方共享 patch（可能本身是别的缓冲的视图）。
  final src = imglib.Image.fromBytes(
    width: pw,
    height: ph,
    bytes: Uint8List.fromList(patch).buffer,
    numChannels: 1,
  );
  final small = imglib.copyResize(src,
      width: infer, height: infer, interpolation: imglib.Interpolation.average);
  final plane = small.getBytes(); // 1 通道 → infer² 字节
  final s2 = infer * infer;
  final chw = Float32List(3 * s2);
  final grayPlane = Float32List(s2);
  for (var i = 0; i < s2; i++) {
    // 桌面 GRAY2BGR + v/127.5-1（service.py:316-322）；L_bw 是单平面。
    final v = plane[i] / 127.5 - 1.0;
    grayPlane[i] = v;
    chw[i] = v;
    chw[s2 + i] = v;
    chw[2 * s2 + i] = v;
  }
  onLog?.call('SAM 编码开始${rssSuffix()}');
  final (s0, s1) = await b.runSam(chw, infer);
  if (kSemanticBootstrapEnabled && b.supportsTagger) {
    try {
      final (rgb8, size) = await _bootstrapToRgb8(
          src, plane, infer, (s0, s1), b, onLog: onLog);
      return (rgb8, size);
    } on Object catch (e) {
      // 自举中途失败（真机 OOM 等）整块降级 zeros 路径：宁可灰不可黑屏。
      onLog?.call('语义自举失败，本块回退 zeros 路径: $e');
    }
  }
  // runGen 契约：返回行优先 HWC 的 rgb_pred 原样浮点（后端已 CHW→HWC，不再转置）。
  onLog?.call('生成开始');
  final out = await b.runGen(grayPlane, infer, s0, s1);
  final rgb8 = Uint8List(3 * s2);
  for (var i = 0; i < rgb8.length; i++) {
    // clip((y+1)*127.5, 0, 255).astype(uint8)：截断取整，与桌面 astype 一致。
    rgb8[i] = ((out[i] + 1) * 127.5).clamp(0.0, 255.0).toInt();
  }
  return (rgb8, infer);
}

/// 语义自举单块：gen@512 zeros → tagger（去网点输入）→ gen@512 带嵌入。
/// 返回 (512²×3 RGB8, 512)。SAM 特征（[runSam] 原样，64²/32²）逐通道双线性
/// 缩到 32²/16²（桌面 `_feat_resize` 同语义, cv2.INTER_LINEAR≈双线性）。
Future<(Uint8List, int)> _bootstrapToRgb8(
    imglib.Image src,
    Uint8List plane,
    int infer,
    ((Float32List, List<int>), (Float32List, List<int>)) feats,
    OnnxBackend b,
    {void Function(String line)? onLog}) async {
  final r = kBootstrapInfer;
  final small512 = imglib.copyResize(src,
      width: r, height: r, interpolation: imglib.Interpolation.average);
  final plane512 = small512.getBytes();
  final gray512 = Float32List(r * r);
  for (var i = 0; i < gray512.length; i++) {
    gray512[i] = plane512[i] / 127.5 - 1.0;
  }
  final (s0, s1) = feats;
  final f0r = _resizeFeatures(s0, r ~/ 16, r ~/ 16);
  final f1r = _resizeFeatures(s1, r ~/ 32, r ~/ 32);

  Future<Float32List> gen(Float32List? wd14) async {
    onLog?.call('生成开始（512 语义自举${wd14 == null ? ' zeros' : ''}）');
    return b.runGen(gray512, r, f0r, f1r, wd14: wd14);
  }

  var out = await gen(null);
  var rgb8 = Uint8List(3 * r * r);
  for (var i = 0; i < rgb8.length; i++) {
    rgb8[i] = ((out[i] + 1) * 127.5).clamp(0.0, 255.0).toInt();
  }
  // tagger 输入：去网点（核心修复——网点高频污染嵌入，桌面 2026-11-21 取证）
  // → 白底补方 448² → BGR NHWC float32（0-255 原值）。
  final descreened = descreenRgb3x3(rgb8, r, r);
  final tagIn = taggerInputFromRgb(descreened, r, r, 448);
  final emb = await b.runTagger(tagIn, 448);
  if (emb == null) {
    // 竞态：supportsTagger 为真但会话刚被释放（空闲卸载）——保持 zeros 结果。
    onLog?.call('tagger 会话不可用，本块保持 zeros 结果');
    return (rgb8, r);
  }
  out = await gen(emb);
  for (var i = 0; i < rgb8.length; i++) {
    rgb8[i] = ((out[i] + 1) * 127.5).clamp(0.0, 255.0).toInt();
  }
  return (rgb8, r);
}

/// SAM 特征逐通道双线性缩放（桌面 `_feat_resize` 同语义：cv2.INTER_LINEAR
/// ≈双线性；特征平滑，插值族差异可忽略）。planar [1,C,H,W] → [1,C,th,tw]。
(Float32List, List<int>) _resizeFeatures(
    (Float32List, List<int>) f, int tw, int th) {
  final (data, shape) = f;
  final c = shape[1];
  final h = shape[2];
  final w = shape[3];
  final out = Float32List(c * th * tw);
  final sx = w / tw;
  final sy = h / th;
  for (var ch = 0; ch < c; ch++) {
    final base = ch * h * w;
    final obase = ch * th * tw;
    for (var ty = 0; ty < th; ty++) {
      final fyv = (ty + 0.5) * sy - 0.5;
      final y0 = fyv <= 0 ? 0 : (fyv >= h - 1 ? h - 2 : fyv.floor());
      final fy = (fyv - y0).clamp(0.0, 1.0);
      for (var tx = 0; tx < tw; tx++) {
        final fxv = (tx + 0.5) * sx - 0.5;
        final x0 = fxv <= 0 ? 0 : (fxv >= w - 1 ? w - 2 : fxv.floor());
        final fx = (fxv - x0).clamp(0.0, 1.0);
        final p00 = base + y0 * w + x0;
        final p01 = p00 + 1;
        final p10 = p00 + w;
        final p11 = p10 + 1;
        final top = data[p00] * (1 - fx) + data[p01] * fx;
        final bot = data[p10] * (1 - fx) + data[p11] * fx;
        out[obase + ty * tw + tx] = top * (1 - fy) + bot * fy;
      }
    }
  }
  return (out, [1, c, th, tw]);
}
