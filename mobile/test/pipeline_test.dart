// 全自动管线（mobile/lib/onnx/pipeline.dart）的宿主测试：用 FakeBackend 替身驱动，
// 不触碰真实 ORT。断言对齐桌面 service.py 语义：
//   · 单块（max(w,h)≤infer）＝ colorize()：直取模型 a/b，L 恒取原稿（service.py:401-410）；
//   · 多块 ＝ colorize_tiled：tile/overlap 分块、只羽化融合 a/b（service.py:375-398）。
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:manga_colorizer_mobile/onnx/pipeline.dart';
import 'package:manga_colorizer_mobile/onnx/tiles.dart';
import 'fake_backend.dart';

void main() {
  test('single tile keeps luminance of original', () async {
    final w = 64, h = 48;
    // 中灰段(96..112)：FakeBackend 的色度是极端饱和色(a≈195/b≈170 红、
    // a≈187/b≈43 蓝)，叠在带外亮度上会得到 **域外 Lab**——labToRgb→rgbToLab
    // 回环连 cv2 自己都会把 L 搬移 几十(如 L=0,a=195,b=170 → RGB(79,0,0) →
    // L≈34；扫描实证仅 g∈[96,112] 对两种假色度回环误差 ≤1，故任务说明禁止
    // 对 8bit Lab 断言全域 ±1 RGB 回环)。±1 保真断言限定域内段；全域另断
    // "L 偏移有界"（回环损失，非管线偷换亮度）。
    final gray = Uint8List(w * h);
    for (var i = 0; i < gray.length; i++) {
      gray[i] = 96 + (i * 7) % 17;
    }
    final b = FakeBackend();
    final out = await autoColorize(
        gray: gray, width: w, height: h, backend: b, infer: 1024);
    expect(out, isNotNull);
    expect(out!.length, w * h * 3);
    final lab = rgbToLab(out, w * h);
    // L 通道来自原稿：结果转 Lab 的 L 与 gray 转 Lab 的 L 完全一致（同一 lut 函数）。
    final refLab = rgbToLab(_gray3(gray), w * h);
    for (var p = 0; p < w * h; p++) {
      expect((lab[p * 3] - refLab[p * 3]).abs(), lessThanOrEqualTo(1),
          reason: 'L@$p');
    }
    // 全域兜底：任何像素的 L 偏移都有界（回环损失 ≠ 管线拿模型亮度覆盖原稿）。
    for (var p = 0; p < w * h; p++) {
      expect((lab[p * 3] - refLab[p * 3]).abs(), lessThanOrEqualTo(40),
          reason: 'L-bound@$p gray=${gray[p]}');
    }
  });

  test('cancelled returns null', () async {
    final w = 64, h = 48;
    final b = FakeBackend();
    final out = await autoColorize(
        gray: Uint8List(w * h),
        width: w,
        height: h,
        backend: b,
        cancelled: () => true);
    expect(out, isNull);
    expect(b.calls, isEmpty); // 取消检查必须先于任何推理
  });

  test('two tiles fuse chroma in overlap', () async {
    final w = 1400, h = 100; // x 轴两块, y 轴一块
    final b = FakeBackend();
    final progress = <double>[];
    final out = await autoColorize(
        gray: Uint8List(w * h)..fillRange(0, w * h, 128),
        width: w,
        height: h,
        backend: b,
        overlap: 256,
        onProgress: progress.add);
    expect(out, isNotNull);
    // 左半偏红、右半偏蓝: 中位区（远离两块接缝）两侧色相差明显
    final lab = rgbToLab(out!, w * h);
    int ab(int x) =>
        (lab[(50 * w + x) * 3 + 1] - 128).abs() +
        (lab[(50 * w + x) * 3 + 2] - 128).abs();
    expect(ab(100), greaterThan(0));
    expect((ab(100) - ab(1300)).abs(), greaterThan(0)); // 两侧色相不同
    expect(ab(896), greaterThan(0)); // 重叠区中央也被融合上色
    // 进度按块上报，终值 1.0
    expect(progress.length, 2);
    expect(progress.last, 1.0);
    expect(b.calls.where((c) => c.startsWith('sam:')).length, 2); // 块数×2
    expect(b.calls.where((c) => c.startsWith('gen:')).length, 2);
  });

  test('backend called twice per tile', () async {
    final b = FakeBackend();
    await autoColorize(
        gray: Uint8List(64 * 48), width: 64, height: 48, backend: b);
    expect(b.calls.where((c) => c.startsWith('sam:')).length, 1);
    expect(b.calls.where((c) => c.startsWith('gen:')).length, 1);
  });

  test('cancel mid-run stops after current tile', () async {
    final w = 1400, h = 100; // 两块
    final b = FakeBackend();
    var reported = 0;
    final out = await autoColorize(
        gray: Uint8List(w * h)..fillRange(0, w * h, 128),
        width: w,
        height: h,
        backend: b,
        onProgress: (_) => reported++,
        cancelled: () => reported > 0); // 第一块上报后即"取消"
    expect(out, isNull);
    expect(b.calls.where((c) => c.startsWith('gen:')).length, 1);
  });

  test('single tile keeps chroma at image edge (no feather zeroing)', () async {
    // 桌面 colorize()（service.py:401-410）对 ≤1024 单块图直接回写 lab_c 的 a/b，
    // 不做羽化归一 → 图像最左列必须保留色度。若误走羽化路径，边缘权重 0 会把
    // a/b 除法压成 0（伪彩色），此断言即炸。
    final w = 64, h = 48;
    final out = await autoColorize(
        gray: Uint8List(w * h)..fillRange(0, w * h, 128),
        width: w,
        height: h,
        backend: FakeBackend());
    final lab = rgbToLab(out!, w * h);
    expect(lab[1], greaterThan(140)); // (0,0) 红侧 a 通道仍远高于中性 128
  });

  test('feather odd length keeps plateau at middle', () {
    // Task 2 评审遗留核对项（几何模块本体不改，只在本任务补测试）：
    // len=301、overlap=256 → lo=301~/2=150，两斜坡占 0..149 与 151..300，
    // 中间 w[150] 保持平台值 1.0（偶数 300 时无平台，见 tiles_test）。
    final wt = featherWeight(0, 301, 256);
    expect(wt.length, 301);
    expect(wt[150], 1.0);
    expect(wt[0], 0.0);
    expect(wt[300], 0.0);
    expect(wt[75], 0.5);
  });
}

Uint8List _gray3(Uint8List g) {
  final o = Uint8List(g.length * 3);
  for (var i = 0; i < g.length; i++) {
    o[i * 3] = o[i * 3 + 1] = o[i * 3 + 2] = g[i];
  }
  return o;
}
