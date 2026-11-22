// WD14 tagger 输入预处理（纯 Dart，两端同语义）：桌面镜像在
// tool/colorizer_service/service.py `_tagger_input`，改任何一侧须评估另一侧。
// 移动端在管线 isolate 内对本端生成的 512² pass-1 彩色输出执行同款预处理，
// 喂给 OrtOnnxBackend.runTagger（MOAT tagger, 输入 [1,448,448,3] NHWC
// float32 0-255 BGR——SmilingWolf 官方 demo 预处理，模型内置归一化）。
// 去网点（3×3 中值×2）是语义自举的关键一步：网点高频会让 tagger 把角色读成
// bandages/black_background，嵌入把脸部引导成绿色（桌面 2026-11-21 用户样张
// 取证）；去网点后读出 smile/1girl 等真实语义。
import 'dart:typed_data';

/// 3×3 中值滤波（每通道独立）×2，去网点用。rgb 为 w*h*3 紧凑存储；返回新
/// 缓冲（不污染输入）。中值取 9 窗口的中位数（网络常见缩窗网络写法：小窗口
/// 排序网络求中位），与 cv2.medianBlur(ksize=3) 语义一致（边界复制）。
Uint8List descreenRgb3x3(Uint8List rgb, int width, int height) {
  // 从输入的拷贝出发：两遍乒乓后结果缓冲不与调用方缓冲别名（输入不被污染）。
  var src = Uint8List.fromList(rgb);
  var dst = Uint8List(rgb.length);
  for (var pass = 0; pass < 2; pass++) {
    _median3x3(src, dst, width, height);
    final t = src;
    src = dst;
    dst = t;
  }
  // 两遍后结果在 src 里（偶数次交换）；dst 是另一份缓冲，丢弃
  return src;
}

void _median3x3(Uint8List src, Uint8List dst, int width, int height) {
  final w9 = Uint8List(9);
  for (var y = 0; y < height; y++) {
    final yUp = y > 0 ? y - 1 : 0;
    final yDn = y < height - 1 ? y + 1 : height - 1;
    for (var x = 0; x < width; x++) {
      final xL = x > 0 ? x - 1 : 0;
      final xR = x < width - 1 ? x + 1 : width - 1;
      final base = (y * width + x) * 3;
      for (var c = 0; c < 3; c++) {
        var k = 0;
        for (final yy in [yUp, y, yDn]) {
          final row = (yy * width) * 3 + c;
          w9[k++] = src[row + xL * 3];
          w9[k++] = src[row + x * 3];
          w9[k++] = src[row + xR * 3];
        }
        // 9 元素中位数：完整排序（128 长度上限的插入排序足够快）
        for (var i = 1; i < 9; i++) {
          final v = w9[i];
          var j = i - 1;
          while (j >= 0 && w9[j] > v) {
            w9[j + 1] = w9[j];
            j--;
          }
          w9[j + 1] = v;
        }
        dst[base + c] = w9[4];
      }
    }
  }
}

/// WD14 tagger 输入：RGB (w*h*3) → 白底补方 → 双线性缩放 target² → RGB→BGR
/// → NHWC float32（0-255 原值，模型内置归一化）。与桌面 `_tagger_input`
/// 的差异仅插值族（桌面 cv2.INTER_AREA，此处双线性；tagger 对此不敏感，
/// 官方 demo 自身用 BICUBIC）与去网点发生在调用方（[descreenRgb3x3]）。
Float32List taggerInputFromRgb(
    Uint8List rgb, int width, int height, int target) {
  // 白底补方（SmilingWolf demo：max 边撑方，内容贴左上）
  final m = width > height ? width : height;
  final padded = Uint8List(m * m * 3);
  for (var i = 0; i < padded.length; i += 3) {
    padded[i] = 255;
    padded[i + 1] = 255;
    padded[i + 2] = 255;
  }
  for (var y = 0; y < height; y++) {
    final srcRow = y * width * 3;
    final dstRow = y * m * 3;
    for (var x = 0; x < width; x++) {
      padded[dstRow + x * 3] = rgb[srcRow + x * 3];
      padded[dstRow + x * 3 + 1] = rgb[srcRow + x * 3 + 1];
      padded[dstRow + x * 3 + 2] = rgb[srcRow + x * 3 + 2];
    }
  }
  // 双线性缩放 m² → target²（中心对齐半像素采样）
  final scale = m / target;
  final out = Float32List(target * target * 3);
  for (var ty = 0; ty < target; ty++) {
    final sy = (ty + 0.5) * scale - 0.5;
    final y0 = sy <= 0 ? 0 : (sy >= m - 1 ? m - 2 : sy.floor());
    final fy = (sy - y0).clamp(0.0, 1.0);
    for (var tx = 0; tx < target; tx++) {
      final sx = (tx + 0.5) * scale - 0.5;
      final x0 = sx <= 0 ? 0 : (sx >= m - 1 ? m - 2 : sx.floor());
      final fx = (sx - x0).clamp(0.0, 1.0);
      final p00 = (y0 * m + x0) * 3;
      final p01 = p00 + 3;
      final p10 = p00 + m * 3;
      final p11 = p10 + 3;
      final o = (ty * target + tx) * 3;
      for (var c = 0; c < 3; c++) {
        // RGB→BGR：通道 0↔2 互换（c=0 取源通道 2, c=2 取源通道 0, c=1 原样）
        final sc = c == 0 ? 2 : (c == 2 ? 0 : 1);
        final top = padded[p00 + sc] * (1 - fx) + padded[p01 + sc] * fx;
        final bot = padded[p10 + sc] * (1 - fx) + padded[p11 + sc] * fx;
        out[o + c] = top * (1 - fy) + bot * fy;
      }
    }
  }
  return out;
}
