// make_palette_html.dart — 生成自包含交互选色页(原始 RGBA 同步内嵌, 双击即用)
// 用法: dart run tool/make_palette_html.dart <segDir> [outHtml]
import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final dir = args[0];
  final out = args.length > 1 ? args[1] : '$dir/palette.html';
  final seg = File('$dir/segments.json').readAsStringSync();

  // 原始 RGB→RGBA 内嵌(同步解码, 无异步等待)。
  String rgba(String f) {
    final im = img.decodePng(File('$dir/$f').readAsBytesSync())!;
    final buf = StringBuffer();
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final p = im.getPixel(x, y);
        buf.writeCharCode(p.r.toInt());
        buf.writeCharCode(p.g.toInt());
        buf.writeCharCode(p.b.toInt());
      }
    }
    return base64Encode(buf.toString().codeUnits);
  }

  final tpl = File(
          'C:/Users/yukai/.openclaw-autoclaw/workspace/manga-colorizer/out/semtest/palette-template.html')
      .readAsStringSync();
  final html = tpl
      .replaceAll('__SEG_JSON__', seg.replaceAll('\\', '\\\\').replaceAll("'", "\\'"))
      .replaceAll('__IDMAPRGBA__', rgba('segment-idmap.png'))
      .replaceAll('__PREVIEWRGBA__', rgba('segment-preview.png'))
      .replaceAll('__BWRGBA__', rgba('source-bw.png'))
      .replaceAll('__BASERGBA__', rgba('base-painted.png'));
  File(out).writeAsStringSync(html);
  final mb = (File(out).lengthSync() / 1024 / 1024).toStringAsFixed(1);
  print('saved $out ($mb MB, 同步内嵌 RGBA)');
}
