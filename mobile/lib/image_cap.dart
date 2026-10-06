// 端侧选图资源上限：相册照片动辄 12–50MP，而全自动/提示点两条管线的整页
// 缓冲（chroma/weight 累加、Lab 往返、求解器平面）都随像素数线性膨胀——
// 4000×3000 时 Dart 侧峰值可达数百 MB，叠加 ONNX 原生内存就是「开始上色
// 就闪退」。分块推理本身固定 1024²（SAM encoder 输入写死），输出再放大回
// 原尺寸，长边超过 2048 对手机屏与分享场景几乎没有收益。
//
// v0.5.5 起解码改走 dart:ui 的按目标尺寸解码（[capDecodeRgba]）：旧路径
// （image 包全量解码 → 灰度 → 再缩放）必须先物化全分辨率位图并做多次整图
// 拷贝，50MP 原图瞬时可达 ~300MB——这正是 picker 兜底路径的灾难峰值；
// dart:ui 解码器在引擎线程直接下采样，Dart 侧只出现 ≤maxSide 的 RGBA。
// 参照 local-dream 的按端分级思路：maxSide 由 ResourceTier 按设备内存下发，
// 本文件只提供上限常量与纯解码逻辑。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 选图长边上限（像素）。2048 长边 ≈ ≤3.1MP：整页缓冲峰值压到 ~百 MB 内。
const int kMaxPickSide = 2048;

/// 长边超过 [maxSide] 时的缩小目标（纵横比保持，四舍五入到 1..maxSide）；
/// 未超限返回 null。与旧 image 包路径的取整公式逐值一致。
(int, int)? cappedTargetSize(int width, int height, {int maxSide = kMaxPickSide}) {
  final long = math.max(width, height);
  if (long <= maxSide) return null;
  final scale = maxSide / long;
  return (
    (width * scale).round().clamp(1, maxSide),
    (height * scale).round().clamp(1, maxSide),
  );
}

/// 主 isolate 按目标尺寸解码：返回 ≤[maxSide] 的 RGBA 像素与原始尺寸
/// （未触发缩放时 orig* 为 null）。必须在主 isolate 调用——解码工作在引擎
/// 线程执行，主 isolate 只等 Future，不卡 UI；RGBA→灰度与 PNG 编码由调用方
/// 扔进工作 isolate（[rgbaToGrayPlanes]）。
///
/// 不支持 HEIC：dart:ui 与旧 image 包路径同样解不了（相册经 picker 缩放后
/// 通常回 JPEG），失败统一抛 FormatException，UI 走「读取失败」分支。
Future<({Uint8List rgba, int width, int height, int? origWidth, int? origHeight})>
    capDecodeRgba(Uint8List bytes, {int maxSide = kMaxPickSide}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final cap = cappedTargetSize(descriptor.width, descriptor.height,
        maxSide: maxSide);
    // 只在超限时给目标尺寸：instantiateCodec 双维同时指定＝精确缩放到该尺寸
    // （无纵横比保持），缩小目标由 cappedTargetSize 自己算，语义与旧路径一致。
    codec = await descriptor.instantiateCodec(
        targetWidth: cap?.$1, targetHeight: cap?.$2);
    image = (await codec.getNextFrame()).image;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw const FormatException('解码失败：引擎未返回 RGBA 像素');
    }
    return (
      rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      width: image.width,
      height: image.height,
      origWidth: cap == null ? null : descriptor.width,
      origHeight: cap == null ? null : descriptor.height,
    );
  } on FormatException {
    rethrow;
  } on Object catch (e) {
    throw FormatException('无法解码图像（支持 PNG/JPEG/WebP/BMP/GIF）：$e');
  } finally {
    // 逆序释放：descriptor/codec 还引用 buffer，最后才放。
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// RGBA（[capDecodeRgba] 产物）→ 灰度单通道 + 灰度 RGB 三通道
/// （r=g=b=感知亮度）。亮度公式与 core 的 MangaImageIO.decodeGrayscale 逐位
/// 一致（0.299/0.587/0.114 + round + clamp）；alpha 忽略——相册照片不透明，
/// 与旧路径 decodeGrayscale 对 alpha 的行为一致。
/// 在工作 isolate 调用：两个平面都是 ≤maxSide 大小，峰值只此一份。
({Uint8List gray, Uint8List grayRgb}) rgbaToGrayPlanes(Uint8List rgba) {
  final n = rgba.length ~/ 4;
  final gray = Uint8List(n);
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    final y = (0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2])
        .round()
        .clamp(0, 255);
    gray[i] = y;
    rgb[i * 3] = y;
    rgb[i * 3 + 1] = y;
    rgb[i * 3 + 2] = y;
  }
  return (gray: gray, grayRgb: rgb);
}
