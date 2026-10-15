// 跨格一致性 v1（两端同数学的 Dart 侧）：桌面镜像在
// tool/colorizer_service/service.py `_unify_material_hues` / `_neutral_chroma_floor`，
// 改任何一侧必须同步另一侧并重新生成金样（test/goldens/consistency_golden.json）。
//
// 动机（2026-10-11 用户样张取证）: ①模型对同质网点/排线区域跨格任意赋色相——
// 同一蝴蝶结两格粉/蓝紫（色相差 74°）而原稿色调签名几乎相同（L 直方图交叠
// 0.73）；②密集排线区被平涂成低色度灰蓝（C≈5 @ L≈203），在有色页面上读作
// 「没上色的灰块」。两个 pass 都只动收尾前的融合色度场 a/b，L 恒取原稿：
//   ① 同材质色相统一: 「色调签名相同但色相冲突」的色块统一到质量更大的色相
//     （整块旋转 a/b，保 C 与 L，内部明暗纹理关系不变）；
//   ② 中性区色度保底: L∈[64,234) 且色度低于「随暗度增长的保底曲线」的像素，
//     沿局部主色方向抬到保底（上限=局部主色强度）——周围没有可借色的孤立
//     灰区不发明颜色。
// 边界语义对齐: box 求和用零填充（桌面 cv2.BORDER_CONSTANT, 边缘像素不重复
// 投票; Dart 滑动窗口越界贡献 0 即同语义）；形态学 3×3 腐蚀时界外视为置位、
// 膨胀时视为未置位（cv2 morphology 默认常量边界的等效行为）；标签近邻归回取
// 3×3 内最大标签（cv2.dilate 的 max 语义）。
// 内存: 本文件所有临时缓冲都是函数栈帧内局部量，返回即不可达；调用方
// （pipeline）在块累加缓冲释放后调用，不与推理叠峰。
import 'dart:math' as math;
import 'dart:typed_data';

// ---- 常量（与桌面 service.py 同名常量同值） ----
const double kUnifyCGate = 10.0; // 有色像素门限（Lab 色度幅值, 增益前）
const double _unifyMinPxFrac = 3e-4; // blob 最小像素占比（兼 256px 下限）
const double _unifyHueDiff = 30.0; // 圆距超过此值才视为「赋色冲突」
const double _unifyDL = 20.0; // 允许的平均 L 差（色调签名闸门）
const double _unifyHistInt = 0.65; // 色调签名（L 8bin 直方图）最小交叠
const double _unifyR = 0.60; // blob 自身色相相干度下限（混色 blob 不参与）
const double _unifySizeRatio = 24.0; // 配对 blob 的像素数比上限（材质常被墨线
// 分裂成小块, 比值要放得下「半只蝴蝶结 vs 整只」; 24 仍挡百倍噪点）
// ---- 主色相填充（consistency 第二步, 与桌面 _DH_* 同值） ----
// 动机（2026-10-13/14/15 用户样张四轮取证 + 赛璐璐上色教程检索）: 漫画/动画
// 上色的专业原则是「一材质一固有色（平色）」——同材质明暗只改明度/饱和度,
// 不换色相; 教程明确指出「画面花」的病因是色相太多。模型对发丝的色度输出恰恰
// 违反这条: 同材质内色相分区跳变（实测头发自信像素色相主簇占 60%, 另有绿黄/
// 蓝离群簇）, 且大部分区域色度极弱（C≈2-5, 读作偏灰）。弱色度区在局部窗口里
// 找不到同材质自信色, 而均值/投票类算法会把多个色相混成第三种颜色（用户实证
// 「颜色错误」）。故用「截尾均值收敛到主色相簇」:
//   ① 窗口（半径 kDhR）内同 L 带（kDhBands——漫画同一材质的明暗画在同一
//      明度带, 是材质分界的廉价代理）的自信像素（C≥kDhConf）求向量均值定向;
//   ② 只用与均值圆距 ≤kDhSpread 的像素重算——离群色相被剔除, 收敛到主色相簇;
//   ③ 主色相簇占窗口自信像素 ≥kDhShare 且幅值 ≥kDhMinMag 才生效（无明确主色
//      不猜——材质交界/混合区不动）;
//   ④ 带内弱色度像素（C<kDhWeakC, L∈[64,kDhLMax)）整块采用主色相簇平均色;
// 张力描绘（原稿明暗）不动: 只动色度, L 恒取原稿; 高光/纸白（L≥kDhLMax）与
// 墨线（L<64）不在处理范围。
const double kDhConf = 10.0; // 自信像素门限（Lab 幅度）
const int kDhR = 140; // 投票窗口半径（px, box 方形窗）
const double kDhSpread = 45.0; // 截尾窗口（与均值圆距 ±度）
const double kDhShare = 0.50; // 主色相簇占比门限（窗内自信像素计数占比）
const double kDhMinMag = 4.0; // 票色幅值门限（无颜色能量不填）
const double kDhMinConf = 0.03; // 窗口内自信像素 ≥3% 才统计（防纯噪声区）
const double kDhWeakC = 10.0; // 待填像素门限（C 低于此视为灰区）
const double kDhLMax = 210.0; // 只填 L∈[64,210)（比这亮的是高光/纸白, 不填）
// L 带（与桌面 _DH_BANDS 同值）
const int kDhBand0Lo = 64, kDhBand0Hi = 110;
const int kDhBand1Lo = 110, kDhBand1Hi = 150;
const int kDhBand2Lo = 150, kDhBand2Hi = 190;
const int kDhBand3Lo = 190, kDhBand3Hi = 234;
const double kFloorMax = 14.0; // 中性区保底色度上限（增益前 Lab 单位）
const int kFloorBlurR = 40; // 局部主色统计窗口半径（px）
const double kFloorVoteC = 4.0; // 局部主色投票的色度门槛

double _smoothstep(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// ① 主色相填充（就地修改 [ab]）: 截尾均值收敛到主色相簇——弱色度灰区获得
/// 同带主色相簇平均色（只填不转, 自信像素不动）。门控与统计量详见文件头与
/// 桌面 _DH_* 常量块; 无命中时恒等。
void dominantHueFill(Float32List ab, Uint8List lBytes, int width, int height) {
  final n = width * height;
  final a = Float32List(n);
  final b = Float32List(n);
  final c = Float32List(n);
  for (var i = 0; i < n; i++) {
    final aa = ab[i * 2] - 128.0;
    final bb = ab[i * 2 + 1] - 128.0;
    a[i] = aa;
    b[i] = bb;
    c[i] = math.sqrt(aa * aa + bb * bb);
  }
  final ones = Float32List(n);
  for (var i = 0; i < n; i++) {
    ones[i] = 1.0;
  }
  final cnt = _boxSumR(ones, width, height, kDhR);
  final pixH = Float64List(n);
  for (var i = 0; i < n; i++) {
    pixH[i] = math.atan2(b[i], a[i]) * 180.0 / math.pi % 360.0;
  }
  final mask = Float32List(n);
  final am = Float32List(n);
  final bm = Float32List(n);
  final near = Float32List(n);
  final an = Float32List(n);
  final bn = Float32List(n);
  final bands = [
    [kDhBand0Lo, kDhBand0Hi],
    [kDhBand1Lo, kDhBand1Hi],
    [kDhBand2Lo, kDhBand2Hi],
    [kDhBand3Lo, kDhBand3Hi],
  ];
  for (final band in bands) {
    final lo = band[0], hi = band[1];
    for (var i = 0; i < n; i++) {
      final inBand = c[i] >= kDhConf && lBytes[i] >= lo && lBytes[i] < hi;
      mask[i] = inBand ? 1.0 : 0.0;
      am[i] = inBand ? a[i] : 0.0;
      bm[i] = inBand ? b[i] : 0.0;
    }
    // ① 全带自信像素的向量均值（定向）
    final n1 = _boxSumR(mask, width, height, kDhR);
    final sa1 = _boxSumR(am, width, height, kDhR);
    final sb1 = _boxSumR(bm, width, height, kDhR);
    for (var i = 0; i < n; i++) {
      final meanH = math.atan2(sb1[i], sa1[i]) * 180.0 / math.pi % 360.0;
      // ② 截尾: 只用与均值圆距 ≤kDhSpread 的自信像素
      final dev1 = ((pixH[i] - meanH + 180.0) % 360.0).abs() - 180.0;
      final isNear = mask[i] == 1.0 && dev1.abs() <= kDhSpread;
      near[i] = isNear ? 1.0 : 0.0;
      an[i] = isNear ? a[i] : 0.0;
      bn[i] = isNear ? b[i] : 0.0;
    }
    final n2 = _boxSumR(near, width, height, kDhR);
    final sa2 = _boxSumR(an, width, height, kDhR);
    final sb2 = _boxSumR(bn, width, height, kDhR);
    for (var i = 0; i < n; i++) {
      final l = lBytes[i];
      if (l < lo || l >= hi) continue;
      final denom1 = n1[i] > 1e-6 ? n1[i] : 1e-6;
      final share = n2[i] / denom1;
      final denom2 = n2[i] > 1e-6 ? n2[i] : 1e-6;
      final va = sa2[i] / denom2;
      final vb = sb2[i] / denom2;
      final voteMag = math.sqrt(va * va + vb * vb);
      if (share < kDhShare || voteMag < kDhMinMag) continue;
      if (n1[i] < kDhMinConf * cnt[i]) continue;
      final inRange = l >= 64 && l < kDhLMax;
      // ④ 弱色度像素整块采用主色相簇平均色
      // 注意: 不旋转自信像素——窗口主色相会被邻带物质稀释, 旋转自信块会把
      // 脸部/背景带黄绿（2026-10-15 用户实证「颜色偏绿/四边颜色不对」后移除）;
      // 且头发内的绿黄 confident 块在自身窗口里就是主簇, 旋转也修不动。自信块
      // 的色相冲突交由既有 unifyMaterialHues 按色调签名处理。
      if (inRange && c[i] < kDhWeakC) {
        ab[i * 2] = va + 128.0;
        ab[i * 2 + 1] = vb + 128.0;
      }
    }
  }
}

/// 跨格一致性入口：在融合色度场 [ab]（2n, a0,b0,a1,b1… +128 偏置）上按序
/// 执行 ①同材质色相统一 ②主色相填充 ③中性区色度保底，就地修改。
/// [lBytes] 为原稿 L 字节。
void applyConsistency(Float32List ab, Uint8List lBytes, int width, int height) {
  dominantHueFill(ab, lBytes, width, height);
  unifyMaterialHues(ab, lBytes, width, height);
  neutralChromaFloor(ab, lBytes, width, height);
}

/// ① 同材质色相统一（就地修改 [ab]）。
void unifyMaterialHues(
    Float32List ab, Uint8List lBytes, int width, int height) {
  final n = width * height;
  final a = Float32List(n);
  final b = Float32List(n);
  final mask = Uint8List(n);
  var maskCount = 0;
  for (var i = 0; i < n; i++) {
    final aa = ab[i * 2] - 128.0;
    final bb = ab[i * 2 + 1] - 128.0;
    a[i] = aa;
    b[i] = bb;
    final l = lBytes[i];
    if (l >= 64 && l < 234) {
      final c = math.sqrt(aa * aa + bb * bb);
      if (c >= kUnifyCGate) {
        mask[i] = 1;
        maskCount++;
      }
    }
  }
  if (maskCount < 500) return;
  final nMin = math.max(256, (n * _unifyMinPxFrac).toInt());
  // 3×3 开运算断开 1-2px 窄桥（腐蚀: 界外视为置位; 膨胀: 界外视为未置位——
  // 与 cv2 morphology 默认常量边界语义一致）。
  final eroded = Uint8List(n);
  for (var y = 0; y < height; y++) {
    final y0 = y > 0 ? y - 1 : 0, y1 = y + 1 < height ? y + 1 : height - 1;
    for (var x = 0; x < width; x++) {
      final x0 = x > 0 ? x - 1 : 0, x1 = x + 1 < width ? x + 1 : width - 1;
      var all = 1;
      for (var yy = y0; yy <= y1 && all != 0; yy++) {
        for (var xx = x0; xx <= x1; xx++) {
          if (mask[yy * width + xx] == 0) {
            all = 0;
            break;
          }
        }
      }
      eroded[y * width + x] = all;
    }
  }
  final opened = Uint8List(n);
  for (var y = 0; y < height; y++) {
    final y0 = y > 0 ? y - 1 : 0, y1 = y + 1 < height ? y + 1 : height - 1;
    for (var x = 0; x < width; x++) {
      final x0 = x > 0 ? x - 1 : 0, x1 = x + 1 < width ? x + 1 : width - 1;
      var any = 0;
      for (var yy = y0; yy <= y1 && any == 0; yy++) {
        for (var xx = x0; xx <= x1; xx++) {
          if (eroded[yy * width + xx] != 0) {
            any = 1;
            break;
          }
        }
      }
      opened[y * width + x] = any;
    }
  }
  // 8 连通域标记（BFS, 模式与 white_rescue.dart 一致; 标签编号顺序与桌面
  // cv2 不同, 但分组/主选/旋转都与顺序无关）。
  final labels = Int32List(n);
  final queue = Int32List(n);
  var numLabels = 0;
  for (var start = 0; start < n; start++) {
    if (opened[start] == 0 || labels[start] != 0) continue;
    numLabels++;
    labels[start] = numLabels;
    var head = 0;
    var tail = 1;
    queue[0] = start;
    while (head < tail) {
      final i = queue[head++];
      final x = i % width;
      final y = i ~/ width;
      void visit(int j) {
        if (opened[j] != 0 && labels[j] == 0) {
          labels[j] = numLabels;
          queue[tail++] = j;
        }
      }

      if (x > 0) visit(i - 1);
      if (x + 1 < width) visit(i + 1);
      if (y > 0) visit(i - width);
      if (y + 1 < height) visit(i + width);
      if (x > 0 && y > 0) visit(i - width - 1);
      if (x + 1 < width && y > 0) visit(i - width + 1);
      if (x > 0 && y + 1 < height) visit(i + width - 1);
      if (x + 1 < width && y + 1 < height) visit(i + width + 1);
    }
  }
  // 开运算丢掉的原 mask 像素按近邻归回（2 轮; 取 3×3 内最大标签 = cv2.dilate
  // 的 max 语义; 标签远小于 2^24, 与桌面 float32 膨胀精度一致）。
  for (var round = 0; round < 2; round++) {
    var remaining = false;
    final grown = Int32List.fromList(labels);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        if (labels[i] != 0 || mask[i] == 0) continue;
        remaining = true;
        var mx = 0;
        final yy0 = y > 0 ? y - 1 : 0,
            yy1 = y + 1 < height ? y + 1 : height - 1;
        final xx0 = x > 0 ? x - 1 : 0, xx1 = x + 1 < width ? x + 1 : width - 1;
        for (var yy = yy0; yy <= yy1; yy++) {
          for (var xx = xx0; xx <= xx1; xx++) {
            final v = labels[yy * width + xx];
            if (v > mx) mx = v;
          }
        }
        grown[i] = mx;
      }
    }
    labels.setAll(0, grown);
    if (!remaining) break;
  }
  // 按 label 收集像素 id（计数排序到单块 Int32List, 每 blob 一段连续区间,
  // 段内按行序 = 桌面 flatnonzero 顺序）。
  final counts = Int32List(numLabels + 1);
  for (var i = 0; i < n; i++) {
    final lb = labels[i];
    if (lb != 0) counts[lb]++;
  }
  final offsets = Int32List(numLabels + 2);
  for (var lb = 1; lb <= numLabels; lb++) {
    offsets[lb + 1] = offsets[lb] + counts[lb];
  }
  final ids = Int32List(n);
  final cursor = Int32List.fromList(offsets);
  for (var i = 0; i < n; i++) {
    final lb = labels[i];
    if (lb != 0) ids[cursor[lb]++] = i;
  }
  // blob 统计: 圆均值色相/相干度 R/平均 L/L 8bin 直方图（色调签名）/色度质量。
  final blobIdx = <int>[]; // 通过审核的 blob → (start,end) 段
  final segStart = <int>[];
  final segEnd = <int>[];
  final hues = <double>[];
  final meanLs = <double>[];
  final masses = <double>[];
  final pxs = <int>[];
  final lhs = <Float64List>[];
  for (var lb = 1; lb <= numLabels; lb++) {
    final s = offsets[lb], e = offsets[lb + 1];
    if (e - s < nMin) continue;
    var sSum = 0.0, cSum = 0.0, lSum = 0.0, mass = 0.0;
    final lh = Float64List(8);
    for (var k = s; k < e; k++) {
      final i = ids[k];
      final aa = a[i], bb = b[i];
      final c = math.sqrt(aa * aa + bb * bb);
      mass += c;
      final ang = math.atan2(bb, aa);
      sSum += math.sin(ang);
      cSum += math.cos(ang);
      final l = lBytes[i];
      lSum += l;
      lh[math.min((l / 32).toInt(), 7)]++;
    }
    final cnt = (e - s).toDouble();
    final r = math.sqrt(sSum * sSum + cSum * cSum) / cnt;
    if (r < _unifyR) continue;
    blobIdx.add(lb);
    segStart.add(s);
    segEnd.add(e);
    hues.add(((math.atan2(sSum, cSum) * 180.0 / math.pi) % 360.0));
    meanLs.add(lSum / cnt);
    masses.add(mass);
    pxs.add(e - s);
    for (var k = 0; k < 8; k++) {
      lh[k] /= cnt;
    }
    lhs.add(lh);
  }
  // 并查集: 色调签名相近而色相冲突的 blob 并组。
  final m = blobIdx.length;
  final parent = List<int>.generate(m, (i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  for (var i = 0; i < m; i++) {
    for (var j = i + 1; j < m; j++) {
      final dh = ((hues[i] - hues[j] + 180.0) % 360.0) - 180.0;
      if (dh.abs() < _unifyHueDiff) continue;
      if ((meanLs[i] - meanLs[j]).abs() > _unifyDL) continue;
      var inter = 0.0;
      for (var k = 0; k < 8; k++) {
        inter += math.min(lhs[i][k], lhs[j][k]);
      }
      if (inter < _unifyHistInt) continue;
      final pMin = math.min(pxs[i], pxs[j]);
      if (math.max(pxs[i], pxs[j]) > pMin * _unifySizeRatio) continue;
      final ri = find(i), rj = find(j);
      if (ri != rj) parent[math.max(ri, rj)] = math.min(ri, rj);
    }
  }
  // 组内按色度质量选主, 其余整块旋转（保 C 与 L）。
  final groups = <int, List<int>>{};
  for (var i = 0; i < m; i++) {
    groups.putIfAbsent(find(i), () => <int>[]).add(i);
  }
  for (final g in groups.values) {
    if (g.length < 2) continue;
    var tgt = g[0];
    for (final k in g) {
      if (masses[k] > masses[tgt]) tgt = k;
    }
    final th = hues[tgt];
    for (final k in g) {
      if (k == tgt) continue;
      final d = ((th - hues[k] + 540.0) % 360.0) - 180.0;
      if (d.abs() < 12.0) continue;
      final rad = d * math.pi / 180.0;
      final ca = math.cos(rad), sa = math.sin(rad);
      for (var p = segStart[k]; p < segEnd[k]; p++) {
        final i = ids[p] * 2;
        final aa = ab[i] - 128.0, bb = ab[i + 1] - 128.0;
        ab[i] = aa * ca - bb * sa + 128.0;
        ab[i + 1] = aa * sa + bb * ca + 128.0;
      }
    }
  }
}

/// ② 中性区色度保底（就地修改 [ab]）。
void neutralChromaFloor(
    Float32List ab, Uint8List lBytes, int width, int height) {
  final n = width * height;
  final a = Float32List(n);
  final b = Float32List(n);
  final cw = Float32List(n);
  for (var i = 0; i < n; i++) {
    final aa = ab[i * 2] - 128.0;
    final bb = ab[i * 2 + 1] - 128.0;
    a[i] = aa;
    b[i] = bb;
    cw[i] = math.max(math.sqrt(aa * aa + bb * bb) - kFloorVoteC, 0.0);
  }
  // 局部主色 = C>kFloorVoteC 像素的加权 box 均值（零填充边界, 半径 kFloorBlurR）。
  // 桌面: Va = boxSum(a·cw)/sw —— 加权和必须除回权重和, 否则 Vm−4 上限失效。
  final sw = _boxSum(cw, width, height);
  final va = _boxSum(_mul(a, cw), width, height);
  final vb = _boxSum(_mul(b, cw), width, height);
  for (var i = 0; i < n; i++) {
    final s = sw[i] < 1e-6 ? 1e-6 : sw[i];
    va[i] /= s;
    vb[i] /= s;
  }
  var any = false;
  for (var i = 0; i < n; i++) {
    final l = lBytes[i].toDouble();
    // 作用域硬闸门: 墨线(L<64)永不染色, 纸白(L≥234)走救援/中和（与桌面一致）。
    if (l < 64.0 || l >= 234.0) continue;
    final vm = math.sqrt(va[i] * va[i] + vb[i] * vb[i]);
    final t = kFloorMax * _smoothstep(6.0, 48.0, 234.0 - l);
    final target = math.min(t, math.max(vm - kFloorVoteC, 0.0));
    final c = math.sqrt(a[i] * a[i] + b[i] * b[i]);
    if (c < target) {
      any = true;
      final inv = 1.0 / math.max(vm, 1e-6);
      // a/b 是 +128 偏置存储, 填充值要加回（与桌面 out[...,0] = na + 128 一致）
      ab[i * 2] = a[i] + (va[i] * inv * target - a[i]) + 128.0;
      ab[i * 2 + 1] = b[i] + (vb[i] * inv * target - b[i]) + 128.0;
    }
  }
  if (!any) return;
}

Float32List _mul(Float32List x, Float32List y) {
  final o = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    o[i] = x[i] * y[i];
  }
  return o;
}

/// box 求和（窗口 (2r+1)², 零填充 = 桌面 cv2.BORDER_CONSTANT）:
/// 行、列两次滑动窗口, O(n)；越界贡献 0。
Float32List _boxSum(Float32List src, int width, int height) {
  return _boxSumR(src, width, height, kFloorBlurR);
}

/// [_boxSum] 的半径参数化版本（主色相填充用 kDhR, 保底用 kFloorBlurR）。
Float32List _boxSumR(Float32List src, int width, int height, int r) {
  final tmp = Float32List(src.length);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    var sum = 0.0;
    for (var x = 0; x <= r && x < width; x++) {
      sum += src[row + x];
    }
    for (var x = 0; x < width; x++) {
      tmp[row + x] = sum;
      final add = x + r + 1 < width ? src[row + x + r + 1] : 0.0;
      final sub = x - r >= 0 ? src[row + x - r] : 0.0;
      sum += add - sub;
    }
  }
  final out = Float32List(src.length);
  for (var x = 0; x < width; x++) {
    var sum = 0.0;
    for (var y = 0; y <= r && y < height; y++) {
      sum += tmp[y * width + x];
    }
    for (var y = 0; y < height; y++) {
      out[y * width + x] = sum;
      final add = y + r + 1 < height ? tmp[(y + r + 1) * width + x] : 0.0;
      final sub = y - r >= 0 ? tmp[(y - r) * width + x] : 0.0;
      sum += add - sub;
    }
  }
  return out;
}
