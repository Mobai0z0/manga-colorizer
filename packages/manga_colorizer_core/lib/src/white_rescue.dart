// 白色前景救援（两端同数学的 Dart 侧）：桌面镜像在
// tool/colorizer_service/service.py `_white_rescue_marks` / `_with_rescue`，
// 改任何一侧必须同步另一侧并重新生成金样（test/goldens/）。
//
// 封闭近白区域（白发/白衣/画格内背景等被墨线包围的白色前景）在原稿
// L=255（Lab L=100）处没有色度渲染空间——收尾对这些像素跳过纸白中和并按
// 色度把 L 压低（见 finish.dart `labToRgbFinish` 的 rescue 参数）。
// 判定: 近白(L≥234, 与纸白 smoothstep 起点一致)四邻接连通域——接触图像
// 边缘的是纸白; 被墨线包围的是白色前景。极端图（近白占比 <0.2% 或全图）
// 不救援（全 0 标记, finish 端 keep 恒 0, 与旧版逐值一致）。
// 门限自适应: 纸白像素的色度中位数即模型暖偏（实测 ~3.4, 增益前测量所以
// 与方案无关）, c0 = clamp(bias+1.5, 4.5, 8)。扫描黑边会把页边距切成
// 「封闭」, 误判的纸白色度停在暖偏量级、远低于门限, 不会被染色。
import 'dart:math' as math;
import 'dart:typed_data';

import 'lab.dart';

/// 门限全程宽度: c1 = c0 + [kRescueGateWidth]（桌面 _RESCUE_GATE_W 同值）。
const double kRescueGateWidth = 18.0;

/// 白色前景救援标记: 0=非近白 1=纸白(连通边缘) 2=封闭近白(救援候选)。
/// [gray] 为原稿灰度 w*h（1B/px），内部经 [grayToLabL] 转 L 字节。
Uint8List whiteRescueMarks(Uint8List gray, int width, int height) {
  final n = width * height;
  final lBytes = grayToLabL(gray);
  final marks = Uint8List(n);
  var nearCount = 0;
  for (var i = 0; i < n; i++) {
    if (lBytes[i] >= 234) {
      marks[i] = 1;
      nearCount++;
    }
  }
  if (nearCount < n * 0.002 || nearCount >= n) return Uint8List(n);
  // 四邻接连通域（与桌面 cv2.connectedComponents(connectivity=4) 同语义;
  // BFS 模式与 white_regions.dart 一致）。visited/queue 是本函数栈帧内的
  // 临时量, 返回即不可达——调用方（pipeline）在推理返回后才调这里, 不与
  // 块累加缓冲叠峰。
  final visited = Uint8List(n);
  final queue = Int32List(n);
  for (var start = 0; start < n; start++) {
    if (visited[start] != 0 || marks[start] != 1) continue;
    var head = 0;
    var tail = 1;
    queue[0] = start;
    visited[start] = 1;
    var border = false;
    while (head < tail) {
      final i = queue[head++];
      final x = i % width;
      final y = i ~/ width;
      if (x == 0 || x == width - 1 || y == 0 || y == height - 1) {
        border = true;
      }
      void visit(int j) {
        if (visited[j] == 0 && marks[j] == 1) {
          visited[j] = 1;
          queue[tail++] = j;
        }
      }
      if (x > 0) visit(i - 1);
      if (x + 1 < width) visit(i + 1);
      if (y > 0) visit(i - width);
      if (y + 1 < height) visit(i + width);
    }
    if (!border) {
      for (var q = 0; q < tail; q++) {
        marks[queue[q]] = 2;
      }
    }
  }
  return marks;
}

/// 救援色度门限 c0：纸白像素色度中位数（0.5 Lab 步进直方图取上中位,
/// 与桌面 `_with_rescue` 同公式, 不排序不分配大数组）+ 1.5, 钳 [4.5, 8]。
/// [lab] 为 8bit Lab（n*3）; 无纸白像素时回退 5.0（模型暖偏 ~3.4 + 1.6）。
double whiteRescueC0(Uint8List lab, Uint8List marks, int n) {
  final bins = Int32List(512); // C*2 量化; 8bit Lab 的 C ≤ ~180, 越界钳 511
  var count = 0;
  for (var i = 0; i < n; i++) {
    if (marks[i] != 1) continue;
    final a = lab[i * 3 + 1] - 128.0;
    final b = lab[i * 3 + 2] - 128.0;
    final c2 = math.sqrt(a * a + b * b) * 2.0;
    bins[c2 >= 511.0 ? 511 : c2.toInt()]++;
    count++;
  }
  if (count == 0) return 5.0;
  var acc = 0;
  var median2 = 511;
  for (var k = 0; k < 512; k++) {
    acc += bins[k];
    if (acc * 2 >= count) {
      median2 = k;
      break;
    }
  }
  final c0 = median2 / 2.0 + 1.5;
  return c0 < 4.5 ? 4.5 : (c0 > 8.0 ? 8.0 : c0);
}
