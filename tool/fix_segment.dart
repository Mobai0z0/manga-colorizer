// fix_segment.dart — 一次性修复 segment_blocks.dart 的 hslHexLocal 定义位置
import 'dart:io';

void main(List<String> args) {
  final f = args[0];
  var c = File(f).readAsStringSync();
  if (c.contains('String hslHexLocal(')) {
    print('already defined');
    return;
  }
  const anchor = '  // v11.1 全色相空间渐变';
  const fn = "  String hslHexLocal(double h, double s, double v) {\n"
      "    final (rr, gg, bb) = _hsvToRgb(h, s, v);\n"
      "    return '#'\n"
      "        '\${rr.toRadixString(16).padLeft(2, '0')}'\n"
      "        '\${gg.toRadixString(16).padLeft(2, '0')}'\n"
      "        '\${bb.toRadixString(16).padLeft(2, '0')}';\n"
      "  }\n\n";
  if (!c.contains(anchor)) {
    print('anchor not found!');
    exit(1);
  }
  c = c.replaceFirst(anchor, fn + anchor);
  File(f).writeAsStringSync(c);
  print('hslHexLocal inserted before spatialHue');
}
