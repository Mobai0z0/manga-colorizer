import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;

import 'ort_ffi.dart';
import 'weights.dart';

const kColorTaggerInputSide = 384;

const kHairColorLabels = <String>[
  'aqua',
  'blue',
  'green',
  'brown',
  'orange',
  'pink',
  'purple',
  'red',
  'light',
  'black',
];

const kSkinColorLabels = <String>['dark', 'light', 'pale', 'colored'];

const kEyeColorLabels = <String>[
  'aqua',
  'blue',
  'green',
  'brown',
  'orange',
  'yellow',
  'pink',
  'purple',
  'red',
  'light',
  'black',
];

Float32List prepareColorTaggerInput({
  required Uint8List rgb,
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0 || rgb.length != width * height * 3) {
    throw ArgumentError('参考图 RGB 尺寸不符: $width×$height / ${rgb.length}');
  }
  final source = imglib.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgb.buffer,
    bytesOffset: rgb.offsetInBytes,
    rowStride: width * 3,
    numChannels: 3,
  );
  final resized = imglib.copyResize(source,
      width: kColorTaggerInputSide,
      height: kColorTaggerInputSide,
      interpolation: imglib.Interpolation.linear);
  final bytes = resized.getBytes();
  final plane = kColorTaggerInputSide * kColorTaggerInputSide;
  final input = Float32List(plane * 3);
  for (var i = 0; i < plane; i++) {
    final offset = i * 3;
    input[i] = (bytes[offset] / 255.0 - 0.5) / 0.5;
    input[plane + i] = (bytes[offset + 1] / 255.0 - 0.5) / 0.5;
    input[plane * 2 + i] = (bytes[offset + 2] / 255.0 - 0.5) / 0.5;
  }
  return input;
}

enum ReferenceColorPart { hair, skin, eye }

class ReferenceColorLabel {
  const ReferenceColorLabel(this.part, this.label, this.score);

  final ReferenceColorPart part;
  final String label;
  final double score;
}

class ReferenceColorLabels {
  const ReferenceColorLabels({
    required this.hair,
    required this.skin,
    required this.eye,
  });

  final ReferenceColorLabel hair;
  final ReferenceColorLabel skin;
  final ReferenceColorLabel eye;

  List<ReferenceColorLabel> get all => [hair, skin, eye];
}

abstract interface class ColorTaggerSession {
  Map<String, (Float32List, List<int>)> run(
      Map<String, (Float32List, List<int>)> inputs,
      {List<String>? outputs});

  void close();
}

class OrtColorTaggerSession implements ColorTaggerSession {
  OrtColorTaggerSession(this._session);

  final OrtFfiSession _session;

  @override
  Map<String, (Float32List, List<int>)> run(
          Map<String, (Float32List, List<int>)> inputs,
          {List<String>? outputs}) =>
      _session.run(inputs, outputs: outputs);

  @override
  void close() => _session.close();
}

typedef ColorTaggerSessionFactory = ColorTaggerSession Function(
  String path, {
  required int intraThreads,
  required bool useArena,
});

ColorTaggerSession openOrtColorTaggerSession(String path,
    {required int intraThreads, required bool useArena}) {
  final ort = OrtFfi.load();
  return OrtColorTaggerSession(
      ort.createSession(path, intraThreads: intraThreads, useArena: useArena));
}

typedef _ColorTaggerSpec = ({
  WeightFile file,
  ReferenceColorPart part,
  List<String> labels,
});

final _colorTaggerSpecs = <_ColorTaggerSpec>[
  (
    file: kAnimeChTaggerFiles[0],
    part: ReferenceColorPart.hair,
    labels: kHairColorLabels,
  ),
  (
    file: kAnimeChTaggerFiles[1],
    part: ReferenceColorPart.skin,
    labels: kSkinColorLabels,
  ),
  (
    file: kAnimeChTaggerFiles[2],
    part: ReferenceColorPart.eye,
    labels: kEyeColorLabels,
  ),
];

Future<ReferenceColorLabels> readReferenceColors({
  required Uint8List rgb,
  required int width,
  required int height,
  required String weightsDir,
  required int intraThreads,
}) =>
    Isolate.run(() => readReferenceColorsWithSession(
          rgb: rgb,
          width: width,
          height: height,
          weightsDir: weightsDir,
          intraThreads: intraThreads,
          open: openOrtColorTaggerSession,
        ));

Future<ReferenceColorLabels> readReferenceColorsWithSession({
  required Uint8List rgb,
  required int width,
  required int height,
  required String weightsDir,
  required int intraThreads,
  required ColorTaggerSessionFactory open,
}) async {
  final input = prepareColorTaggerInput(rgb: rgb, width: width, height: height);
  final root = weightsDir.replaceFirst(RegExp(r'[/\\]+$'), '');
  final decoded = <ReferenceColorPart, ReferenceColorLabel>{};
  for (final spec in _colorTaggerSpecs) {
    final session = open('$root/${spec.file.name}',
        intraThreads: intraThreads, useArena: false);
    late final (Float32List, List<int>) output;
    try {
      final outputs = session.run(
        {
          'input': (
            input,
            const [1, 3, kColorTaggerInputSide, kColorTaggerInputSide]
          )
        },
        outputs: const ['output'],
      );
      final value = outputs['output'];
      if (value == null ||
          value.$2.length != 2 ||
          value.$2[0] != 1 ||
          value.$2[1] != spec.labels.length ||
          value.$1.length != spec.labels.length) {
        throw StateError('色签 ${spec.file.name} 输出形状不符: ${value?.$2}');
      }
      output = value;
    } finally {
      session.close();
    }
    var best = 0;
    for (var i = 0; i < output.$1.length; i++) {
      if (!output.$1[i].isFinite) {
        throw StateError('色签 ${spec.file.name} 输出包含非有限分数');
      }
      if (output.$1[i] > output.$1[best]) best = i;
    }
    decoded[spec.part] =
        ReferenceColorLabel(spec.part, spec.labels[best], output.$1[best]);
  }
  return ReferenceColorLabels(
    hair: decoded[ReferenceColorPart.hair]!,
    skin: decoded[ReferenceColorPart.skin]!,
    eye: decoded[ReferenceColorPart.eye]!,
  );
}
