// sheet.dart — 多图横向拼版(可缩放)
// 用法: dart run tool/sheet.dart out.png pad maxW file1.png file2.png ...
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final outPath = args[0];
  final pad = int.parse(args[1]);
  final maxW = int.parse(args[2]);
  final files = args.sublist(3);
  final panels = files.map((f) {
    final im = img.decodePng(File(f).readAsBytesSync())!;
    if (im.width <= maxW) return im;
    final sc = maxW / im.width;
    return img.copyResize(im,
        width: maxW,
        height: (im.height * sc).round(),
        interpolation: img.Interpolation.cubic);
  }).toList();
  final h = panels.map((p) => p.height).reduce((a, b) => a > b ? a : b);
  final w = panels.fold<int>(0, (s, p) => s + p.width) + pad * (panels.length + 1);
  final sheet = img.Image(width: w, height: h + pad * 2, numChannels: 3);
  img.fill(sheet, color: img.ColorRgb8(246, 244, 239));
  var x = pad;
  for (final p in panels) {
    img.compositeImage(sheet, p, dstX: x, dstY: pad);
    x += p.width + pad;
  }
  File(outPath).writeAsBytesSync(img.encodePng(sheet));
  stdout.writeln('saved $outPath (${sheet.width}x${sheet.height})');
}
