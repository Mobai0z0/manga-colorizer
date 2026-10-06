// 端侧选图资源上限：相册照片动辄 12–50MP，而全自动/提示点两条管线的整页
// 缓冲（chroma/weight 累加、Lab 往返、求解器平面）都随像素数线性膨胀——
// 4000×3000 时 Dart 侧峰值可达数百 MB，叠加 ONNX 原生内存就是「开始上色
// 就闪退」。分块推理本身固定 1024²（SAM encoder 输入写死），输出再放大回
// 原尺寸，长边超过 2048 对手机屏与分享场景几乎没有收益。
// 参照 local-dream 的按端分级思路与桌面 service 的 MAX_BYTES 入口限制：
// 缩放优先由 image_picker 的 maxWidth/maxHeight 在原生侧完成（不落全分辨率
// 位图）；本文件的 capDecodeGrayscale 只做兜底——部分 OEM 相册路径不认
// picker 尺寸参数，返回原图时在这里拦下。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 选图长边上限（像素）。2048 长边 ≈ ≤3.1MP：整页缓冲峰值压到 ~百 MB 内。
const int kMaxPickSide = 2048;

/// 解码为灰度 RGB；长边超过 [kMaxPickSide] 时按比例缩到上限内（average
/// 插值＝cv2 INTER_AREA 同族，与 pipeline 的分块缩放语义一致）。
/// 返回缩放后的图与原始尺寸（未触发缩放时 origWidth/origHeight 为 null）。
/// 必须是顶层函数：调用点在工作 isolate 的闭包里，不可捕 this（v0.5.1 教训）。
({DecodedImage image, int? origWidth, int? origHeight}) capDecodeGrayscale(
    List<int> bytes) {
  final d = MangaImageIO.decodeGrayscale(bytes);
  final long = math.max(d.width, d.height);
  if (long <= kMaxPickSide) {
    return (image: d, origWidth: null, origHeight: null);
  }
  final scale = kMaxPickSide / long;
  final nw = (d.width * scale).round().clamp(1, kMaxPickSide);
  final nh = (d.height * scale).round().clamp(1, kMaxPickSide);
  // fromBytes 对传入缓冲做 Uint8List.view：先复制出独立缓冲，不让 Image 与
  // d.rgb 共享（同 pipeline._inferPatch 的注释）。
  final src = imglib.Image.fromBytes(
    width: d.width,
    height: d.height,
    bytes: Uint8List.fromList(d.rgb).buffer,
    numChannels: 3,
  );
  final small = imglib.copyResize(src,
      width: nw, height: nh, interpolation: imglib.Interpolation.average);
  final plane = small.getBytes(); // 3 通道 → n*3 字节
  return (
    image: DecodedImage(nw, nh, plane),
    origWidth: d.width,
    origHeight: d.height,
  );
}
