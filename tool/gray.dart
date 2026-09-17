import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final src = args[0];
  final bytes = File(src).readAsBytesSync();
  final image = img.decodePng(bytes);
  if (image == null) { stderr.writeln('decode fail'); exit(65); }
  img.grayscale(image);
  File(src).writeAsBytesSync(img.encodePng(image));
  stdout.writeln('grayscaled: $src');
}