library;

import 'dart:typed_data';

/// 灰度场滤波工具 (仅用于权重场/图层分解, 不改变输出亮度)。
///
/// 3×3 中值滤波是经典去网点 (descreen) 手段: 消除孤立高频网点,
/// 同时保留强边缘; 用于上色权重场时让色度在网点区域内均匀扩散。
/// 可分离盒式模糊用于赛璐璐分解的背景场估计。

/// 3×3 中值滤波, 可多次迭代。
Float32List medianFilter3(Float32List src, int width, int height,
    {int passes = 1}) {
  var cur = src;
  for (var p = 0; p < passes; p++) {
    final next = Float32List(width * height);
    final buf = Float32List(9);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var k = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = (y + dy).clamp(0, height - 1);
          for (var dx = -1; dx <= 1; dx++) {
            final xx = (x + dx).clamp(0, width - 1);
            buf[k++] = cur[yy * width + xx];
          }
        }
        for (var i = 1; i < 9; i++) {
          final v = buf[i];
          var j = i - 1;
          while (j >= 0 && buf[j] > v) {
            buf[j + 1] = buf[j];
            j--;
          }
          buf[j + 1] = v;
        }
        next[y * width + x] = buf[4];
      }
    }
    cur = next;
  }
  return cur;
}

/// 可分离盒式模糊 (半径 r), 用于图层分解的背景场估计。
Float32List boxBlur(Float32List src, int width, int height, int radius) {
  if (radius <= 0) return src;
  final tmp = Float32List(width * height);
  final out = Float32List(width * height);
  // 横向。
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      var count = 0;
      for (var dx = -radius; dx <= radius; dx++) {
        final xx = (x + dx).clamp(0, width - 1);
        sum += src[y * width + xx];
        count++;
      }
      tmp[y * width + x] = sum / count;
    }
  }
  // 纵向。
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      var count = 0;
      for (var dy = -radius; dy <= radius; dy++) {
        final yy = (y + dy).clamp(0, height - 1);
        sum += tmp[yy * width + x];
        count++;
      }
      out[y * width + x] = sum / count;
    }
  }
  return out;
}
