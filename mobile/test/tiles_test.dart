import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/tiles.dart';

void main() {
  test('short axis single bound', () {
    expect(tileBounds(800, 1024, 256), [(0, 800)]);
  });
  test('long axis tiles cover and overlap', () {
    final b = tileBounds(2000, 1024, 256);
    // 与 Python _tile_bounds(2000, 1024, 256) 逐值对拍的金样。
    expect(b, [(0, 1024), (768, 1792), (1536, 2000)]);
    expect(b.first, (0, 1024));
    expect(b.last.$2, 2000);
    for (var i = 1; i < b.length; i++) {
      expect(b[i - 1].$2 - b[i].$1, greaterThanOrEqualTo(0)); // 不重倒
      expect(b[i].$2 - b[i].$1, greaterThan(0));
    }
  });
  test('feather ramps at both ends, plateau middle', () {
    final w = featherWeight(0, 1024, 256);
    expect(w.length, 1024);
    expect(w[0], 0.0);
    expect(w[256], 1.0);
    expect(w[767], 1.0);
    expect(w[1023], 0.0);
    // 与 Python _feather_weight(0, 1024, 256) 逐点对拍: 前 ramp[128]=0.5,
    // 后 ramp 倒序 w[896]=(256-1-128)/256=0.49609375。
    expect(w[128], 0.5);
    expect(w[896], 0.49609375);
    // 与桌面 _feather_weight 对拍: len=300 时 lo 被 (a1-a0)~/2=150 截断,
    // 两端斜坡在 150 处相接、无平台, w[150]=149/150≈0.9933（service.py 同值）。
    expect(
        featherWeight(0, 300, 256)[150], closeTo(149 / 150, 1e-6)); // lo=150 上限
  });
}
