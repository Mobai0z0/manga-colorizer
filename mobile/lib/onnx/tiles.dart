// 长图分块几何: 与桌面 tool/colorizer_service/service.py 的 _tile_bounds/_feather_weight
// 同语义（线性羽化、重叠 256、末块强制触边）。
import 'dart:typed_data';

List<(int, int)> tileBounds(int total, int tile, int overlap) {
  if (total <= tile) return [(0, total)];
  final step = tile - overlap;
  final bounds = <(int, int)>[];
  var start = 0;
  while (true) {
    final end = start + tile < total ? start + tile : total;
    bounds.add((start, end));
    if (end >= total) break;
    start = end - overlap > start ? end - overlap : start + step;
  }
  return bounds;
}

Float32List featherWeight(int a0, int a1, int overlap) {
  final w = Float32List(a1 - a0)..fillRange(0, a1 - a0, 1.0);
  var lo = overlap;
  if (lo > (a1 - a0) ~/ 2) lo = (a1 - a0) ~/ 2;
  for (var i = 0; i < lo; i++) {
    w[i] = i / lo;
    final j = a1 - a0 - lo + i;
    final ramp = (lo - 1 - i) / lo;
    if (ramp < w[j]) w[j] = ramp;
  }
  return w;
}
