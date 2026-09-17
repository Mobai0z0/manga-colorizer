// triple.dart — 原稿|旧版|新版 三方对比图拼装
// 用法: dart run tool/triple.dart <bw.png> <old.png> <new.png> <out.png> [maxW=640]
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final bw = img.decodePng(File(args[0]).readAsBytesSync())!;
  final old = img.decodePng(File(args[1]).readAsBytesSync())!;
  final newI = img.decodePng(File(args[2]).readAsBytesSync())!;
  final outPath = args[3];
  final maxW = args.length > 4 ? int.parse(args[4]) : 640;

  final panels = [bw, old, newI].map((im) {
    if (im.width <= maxW) return im;
    final sc = maxW / im.width;
    return img.copyResize(im, width: maxW, height: (im.height * sc).round(),
        interpolation: img.Interpolation.cubic);
  }).toList();

  const pad = 8;
  final h = panels.map((p) => p.height).reduce((a, b) => a > b ? a : b);
  final w = panels.fold(0, (s, p) => s + p.width) + pad * (panels.length + 1);
  final sheet = img.Image(width: w, height: h, numChannels: 3);
  img.fill(sheet, color: img.ColorRgb8(246, 244, 239));
  var x = pad;
  for (final p in panels) {
    img.compositeImage(sheet, p, dstX: x, dstY: 0);
    x += p.width + pad;
  }
  File(outPath).writeAsBytesSync(img.encodePng(sheet));
  stdout.writeln('saved $outPath (${w}x$h)');
}
