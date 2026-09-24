// 端侧全自动上色管线：对齐桌面 tool/colorizer_service/service.py 的语义 —
//   · 单块（max(w,h)≤infer）＝ colorize()（service.py:401-410）：模型输出
//     INTER_CUBIC 放大回原尺寸后直取 a/b，**不做羽化归一**；L 恒取原稿灰度。
//   · 多块 ＝ colorize_tiled（service.py:375-398）：tile=infer / overlap 重叠，
//     每块独立 缩 infer² → SAM+generator → 只羽化融合 a/b 色度；L 恒取原稿。
// 推理经 OnnxBackend 抽象（真机＝OrtOnnxBackend，宿主测试＝FakeBackend），
// 全程并发 1（逐块 await），每块前查取消、每块后按块上报进度。
import 'dart:typed_data';
import 'package:image/image.dart' as imglib;
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'backend_api.dart';
import 'tiles.dart';

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
}) async {
  bool c() => cancelled?.call() ?? false;
  if (c()) return null;
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
      if (c()) return null;
      final pw = x1 - x0, ph = y1 - y0;
      final patch = _crop(gray, width, x0, y0, pw, ph);
      final rgb = await _inferPatch(patch, pw, ph, infer, backend);
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
    }
  }
  // L 恒取原稿: gray→(r=g=b)→Lab 的 L + 融合后的 a/b（service.py:393-397）。
  final refLab = rgbToLab(_expand3(gray), n);
  final outLab = Uint8List(n * 3);
  for (var p = 0; p < n; p++) {
    final ww = weight[p] < 1e-6 ? 1e-6 : weight[p];
    outLab[p * 3] = refLab[p * 3];
    outLab[p * 3 + 1] = (chroma[p * 2] / ww).clamp(0.0, 255.0).round();
    outLab[p * 3 + 2] = (chroma[p * 2 + 1] / ww).clamp(0.0, 255.0).round();
  }
  return labToRgb(outLab, n);
}

Uint8List _crop(Uint8List g, int gw, int x0, int y0, int w, int h) {
  final o = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    o.setRange(y * w, y * w + w, g, (y0 + y) * gw + x0);
  }
  return o;
}

Uint8List _expand3(Uint8List g) {
  final o = Uint8List(g.length * 3);
  for (var i = 0; i < g.length; i++) {
    o[i * 3] = o[i * 3 + 1] = o[i * 3 + 2] = g[i];
  }
  return o;
}

/// 一块的完整推理：缩 infer²（INTER_AREA 语义）→ SAM+generator →
/// clip 反归一化 → 放大回块尺寸（INTER_CUBIC 语义）→ 块原始分辨率 RGB。
/// 对应桌面 colorize_single（service.py:346-373）；GPU 回退是绑定层的事，不在这里。
Future<Uint8List> _inferPatch(
    Uint8List patch, int pw, int ph, int infer, OnnxBackend b) async {
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
  final (s0, s1) = await b.runSam(chw, infer);
  // runGen 契约：返回行优先 HWC 的 rgb_pred 原样浮点（后端已 CHW→HWC，不再转置）。
  final out = await b.runGen(grayPlane, infer, s0, s1);
  final rgb8 = Uint8List(3 * s2);
  for (var i = 0; i < rgb8.length; i++) {
    // clip((y+1)*127.5, 0, 255).astype(uint8)：截断取整，与桌面 astype 一致。
    rgb8[i] = ((out[i] + 1) * 127.5).clamp(0.0, 255.0).toInt();
  }
  final mid = imglib.Image.fromBytes(
      width: infer, height: infer, bytes: rgb8.buffer, numChannels: 3);
  final big = imglib.copyResize(mid,
      width: pw,
      height: ph,
      // image 4.3 的枚举名 catmullRom 在 4.10（本 workspace 解析到的 4.10.1）
      // 改叫 Interpolation.cubic（getPixelCubic＝0.5 系数 Catmull-Rom，
      // 与 cv2 INTER_CUBIC 同族 Keys 三次卷积，a=-0.5 vs -0.75）。
      interpolation: imglib.Interpolation.cubic);
  // cubic 三次卷积≈cv2 INTER_CUBIC（振铃/支撑核有微小差异，同上接受）；
  // 写回 uint8 通道时包内自动 clamp。返回独立拷贝，big/中间缓冲随作用域释放。
  return Uint8List.fromList(big.getBytes());
}
