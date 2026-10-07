// 端侧全自动上色管线：对齐桌面 tool/colorizer_service/service.py 的语义 —
//   · 单块（max(w,h)≤infer）＝ colorize()（service.py:401-410）：模型输出
//     INTER_CUBIC 放大回原尺寸后直取 a/b，**不做羽化归一**；L 恒取原稿灰度。
//   · 多块 ＝ colorize_tiled（service.py:375-398）：tile=infer / overlap 重叠，
//     每块独立 缩 infer² → SAM+generator → 只羽化融合 a/b 色度；L 恒取原稿。
//   · 输出端色彩收尾（两端同数学）：融合色度先施加 [kAutoChromaGain] 增益
//     （桌面为 COLORIZER_CHROMA_GAIN，默认同为 1.2），再经 labToRgbGamut 做
//     色域映射（亮度不变、色度等比收缩，替代逐通道截断——截断把色相拉向
//     三原色，是输出发灰发闷的主因）。已知微小偏差：桌面 tiled 路径全程
//     浮点直达收尾，本端在 8bit a/b 量化后收尾（≤0.5 Lab 单位），与 resize
//     插值偏差同级，记入真机验收清单。
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

/// 全自动输出色度增益（与桌面 COLORIZER_CHROMA_GAIN 默认一致）：模型输出
/// 普遍偏灰，融合后的 a/b 在 8bit 量化前统一放大；1.0 = 关闭。超色域部分
/// 由 labToRgbGamut 的色域映射兜底，不会因增益产生截断脏色。
const kAutoChromaGain = 1.2;

/// 输入灰度 w*h（1B/px），输出上色 RGB w*h*3；null = 被取消。
Future<Uint8List?> autoColorize({
  required Uint8List gray,
  required int width,
  required int height,
  required OnnxBackend backend,
  int infer = 1024,
  int overlap = 256,
  void Function(double progress)? onProgress,
  bool Function()? cancelled,
  void Function(String line)? onLog,
}) async {
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
  // 色彩收尾：labToRgbGamut = labToRgb 的色域映射版（色域内像素逐位一致，
  // 超色域按亮度不变等比收缩替代逐通道截断），语义对拍桌面 _finish_bgr。
  return labToRgbGamut(outLab, n);
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
  // 融合后的色度（service.py:393-397）。
  final refL = grayToLabL(gray);
  final outLab = Uint8List(n * 3);
  for (var p = 0; p < n; p++) {
    final ww = weight[p] < 1e-6 ? 1e-6 : weight[p];
    outLab[p * 3] = refL[p];
    // 增益在 8bit 量化前施加（+128 偏置形式的 128+(v−128)·G，与桌面
    // _finish_bgr 的 (a−128)·gain 同语义；桌面 tiled 全程浮点更精确，
    // 见文件头「已知微小偏差」）。
    outLab[p * 3 + 1] =
        (128.0 + (chroma[p * 2] / ww - 128.0) * kAutoChromaGain)
            .clamp(0.0, 255.0)
            .round();
    outLab[p * 3 + 2] =
        (128.0 + (chroma[p * 2 + 1] / ww - 128.0) * kAutoChromaGain)
            .clamp(0.0, 255.0)
            .round();
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

/// 一块的完整推理：缩 infer²（INTER_AREA 语义）→ SAM+generator →
/// clip 反归一化 → 放大回块尺寸（INTER_CUBIC 语义）→ 块原始分辨率 RGB。
/// 对应桌面 colorize_single（service.py:346-373）；GPU 回退是绑定层的事，不在这里。
Future<Uint8List> _inferPatch(Uint8List patch, int pw, int ph, int infer,
    OnnxBackend b,
    {void Function(String line)? onLog}) async {
  // 浮点张量只被推理本身需要：chw/grayPlane/sam 特征/输出（1024² 时 ~50MB）
  // 全部收敛在 _inferToRgb8 的栈帧里，返回 8bit 后即不可达——否则它们会活到
  // 下面的 cubic 放大与取回拷贝全程，白叠一个同量级的峰值。
  final rgb8 = await _inferToRgb8(patch, pw, ph, infer, b, onLog: onLog);
  final mid = imglib.Image.fromBytes(
      width: infer, height: infer, bytes: rgb8.buffer, numChannels: 3);
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

/// 推理到 8bit RGB（infer²×3）：缩放/归一化/双 session/clip 反归一化。
/// 所有浮点中间量（chw、grayPlane、sam 特征、rgb_pred）都是本函数局部量，
/// 返回即出作用域——这是「每块峰值」与「放大阶段」不叠加的保证。
/// [onLog] 逐阶段心跳（SAM 编码/生成开始）：真机推理中途进程死亡时，日志页
/// 的时间戳据此定位死在哪个模型（v0.5.11 真机「加载完 ~48s 断连、无任何块
/// 日志」的取证缺口）。
Future<Uint8List> _inferToRgb8(Uint8List patch, int pw, int ph, int infer,
    OnnxBackend b,
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
  // runGen 契约：返回行优先 HWC 的 rgb_pred 原样浮点（后端已 CHW→HWC，不再转置）。
  onLog?.call('生成开始');
  final out = await b.runGen(grayPlane, infer, s0, s1);
  final rgb8 = Uint8List(3 * s2);
  for (var i = 0; i < rgb8.length; i++) {
    // clip((y+1)*127.5, 0, 255).astype(uint8)：截断取整，与桌面 astype 一致。
    rgb8[i] = ((out[i] + 1) * 127.5).clamp(0.0, 255.0).toInt();
  }
  return rgb8;
}
