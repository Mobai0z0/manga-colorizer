// crop.dart — 裁剪并可选放大
// 用法: dart run tool/crop.dart in.png out.png x y w h [scale]
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final src = img.decodePng(File(args[0]).readAsBytesSync())!;
  final x = int.parse(args[2]);
  final y = int.parse(args[3]);
  final w = int.parse(args[4]);
  final h = int.parse(args[5]);
  final scale = args.length > 6 ? double.parse(args[6]) : 1.0;
  final cropped = img.copyCrop(src,
      x: x.clamp(0, src.width - 1),
      y: y.clamp(0, src.height - 1),
      width: w.clamp(1, src.width - x),
      height: h.clamp(1, src.height - y));
  final out = scale == 1.0
      ? cropped
      : img.copyResize(cropped,
          width: (cropped.width * scale).round(),
          height: (cropped.height * scale).round(),
          interpolation: img.Interpolation.cubic);
  File(args[1]).writeAsBytesSync(img.encodePng(out));
  stdout.writeln('saved ${args[1]} (${out.width}x${out.height})');
}
