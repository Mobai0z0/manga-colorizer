import 'dart:typed_data';

import 'colorize.dart';
import 'skin.dart';
import 'yuv.dart';

/// 平涂带提示的封闭近白区域。四邻接防止跨轮廓角点串色；
/// 连到图像边缘的区域视为纸白，保守地不填充，不自动补缝。
/// 多个提示按区域内测地距离分配，而不是混合为渐变。
/// 返回被填充的非提示像素数，用于扣除原来的白色锁定计数。
int fillClosedWhiteRegions({
  required Uint8List source,
  required Uint8List output,
  required int width,
  required int height,
  required List<ColorHint> hints,
  required double threshold,
  required bool naturalSkin,
}) {
  if (hints.isEmpty) return 0;
  final n = width * height;
  final labels = Int32List(n)..fillRange(0, n, -1);
  final queue = Int32List(n);
  final touchesBorder = <bool>[];
  bool isWhite(int i) =>
      luminanceOfRgb(source[i * 3], source[i * 3 + 1], source[i * 3 + 2]) >=
      threshold;

  // 原分辨率连通域；不从缩略图推断闭合性。
  for (var start = 0; start < n; start++) {
    if (labels[start] >= 0 || !isWhite(start)) continue;
    final label = touchesBorder.length;
    var head = 0;
    var tail = 1;
    queue[0] = start;
    labels[start] = label;
    var border = false;
    while (head < tail) {
      final i = queue[head++];
      final x = i % width;
      final y = i ~/ width;
      if (x == 0 || x == width - 1 || y == 0 || y == height - 1) {
        border = true;
      }
      void visit(int j) {
        if (labels[j] < 0 && isWhite(j)) {
          labels[j] = label;
          queue[tail++] = j;
        }
      }
      if (x > 0) visit(i - 1);
      if (x + 1 < width) visit(i + 1);
      if (y > 0) visit(i - width);
      if (y + 1 < height) visit(i + width);
    }
    touchesBorder.add(border);
  }

  final owner = Int32List(n)..fillRange(0, n, -1);
  var head = 0;
  var tail = 0;
  final colors = <(double, double, double)>[];
  for (var t = 0; t < hints.length; t++) {
    final hint = hints[t];
    var (hy, hu, hv) = rgbToYuv(hint.r / 255, hint.g / 255, hint.b / 255);
    if (naturalSkin && hint.role == 'skin') {
      (hu, hv) = enforceNaturalSkin(hu, hv);
    }
    colors.add(yuvToRgbGamut(hy, hu, hv));
    final i = hint.y * width + hint.x;
    final label = labels[i];
    if (label < 0 || touchesBorder[label]) continue;
    if (owner[i] < 0) queue[tail++] = i;
    owner[i] = t; // 同坐标以最后一个提示为准，与求解器一致。
  }
  final seedCount = tail;
  while (head < tail) {
    final i = queue[head++];
    final x = i % width;
    final y = i ~/ width;
    void visit(int j) {
      if (owner[j] < 0 && labels[j] == labels[i]) {
        owner[j] = owner[i];
        queue[tail++] = j;
      }
    }
    if (x > 0) visit(i - 1);
    if (x + 1 < width) visit(i + 1);
    if (y > 0) visit(i - width);
    if (y + 1 < height) visit(i + width);
  }
  for (var q = 0; q < tail; q++) {
    final i = queue[q];
    final (r, g, b) = colors[owner[i]];
    // 原图近白明暗作为乘法遮罩，保留轻微纹理和抗锯齿。
    final shade = luminanceOfRgb(
        source[i * 3], source[i * 3 + 1], source[i * 3 + 2]);
    output[i * 3] = (r * shade * 255).round().clamp(0, 255);
    output[i * 3 + 1] = (g * shade * 255).round().clamp(0, 255);
    output[i * 3 + 2] = (b * shade * 255).round().clamp(0, 255);
  }
  return tail - seedCount;
}
