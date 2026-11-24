import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;

import '../mem_info.dart';
import 'backend_log.dart';
import 'ort_ffi.dart';

abstract interface class LineCleanSession {
  List<String> get inputNames;
  List<String> get outputNames;

  Map<String, (Float32List, List<int>)> run(
      Map<String, (Float32List, List<int>)> inputs,
      {List<String>? outputs});

  void close();
}

class OrtLineCleanSession implements LineCleanSession {
  OrtLineCleanSession(this._session);

  final OrtFfiSession _session;

  @override
  List<String> get inputNames => _session.inputNames;

  @override
  List<String> get outputNames => _session.outputNames;

  @override
  Map<String, (Float32List, List<int>)> run(
      Map<String, (Float32List, List<int>)> inputs,
      {List<String>? outputs}) {
    final sw = Stopwatch()..start();
    backendLog('MLE Run 开始（${inputs['gray']!.$2.sublist(2).join('×')}）'
        '${rssSuffix()}');
    final out = _session.run(inputs, outputs: outputs);
    backendLog('MLE Run 完成（${sw.elapsedMilliseconds}ms）${rssSuffix()}');
    return out;
  }

  @override
  void close() => _session.close();
}

typedef LineCleanSessionFactory = LineCleanSession Function(String path,
    {required int intraThreads, required bool useArena});

LineCleanSession openOrtLineCleanSession(String path,
    {required int intraThreads, required bool useArena}) {
  backendLog('MLE session 创建开始（threads=$intraThreads，arena=$useArena）'
      '${rssSuffix()}');
  final ort = OrtFfi.load();
  final session =
      ort.createSession(path, intraThreads: intraThreads, useArena: useArena);
  backendLog('MLE session 创建完成${rssSuffix()}');
  return OrtLineCleanSession(session);
}

typedef LineCleanRun = Future<Float32List> Function(
    Float32List gray, int height, int width);

class _PreparedLineArt {
  const _PreparedLineArt({
    required this.input,
    required this.workWidth,
    required this.workHeight,
    required this.padWidth,
    required this.padHeight,
  });

  final Float32List input;
  final int workWidth;
  final int workHeight;
  final int padWidth;
  final int padHeight;
}

_PreparedLineArt _prepareLineArt({
  required Uint8List gray,
  required int width,
  required int height,
  int workingMaxSide = 384,
}) {
  final maxSide = width > height ? width : height;
  final scale = maxSide <= workingMaxSide ? 1.0 : workingMaxSide / maxSide;
  final workWidth = (width * scale).round().clamp(1, workingMaxSide);
  final workHeight = (height * scale).round().clamp(1, workingMaxSide);
  final src = imglib.Image.fromBytes(
      width: width,
      height: height,
      bytes: Uint8List.fromList(gray).buffer,
      numChannels: 1);
  final small = imglib.copyResize(src,
      width: workWidth,
      height: workHeight,
      interpolation: imglib.Interpolation.average);
  final padWidth = ((workWidth + 15) ~/ 16) * 16;
  final padHeight = ((workHeight + 15) ~/ 16) * 16;
  final padded = Uint8List(padWidth * padHeight)
    ..fillRange(0, padWidth * padHeight, 255);
  final smallBytes = small.getBytes();
  for (var y = 0; y < workHeight; y++) {
    padded.setRange(
        y * padWidth, y * padWidth + workWidth, smallBytes, y * workWidth);
  }
  final input = Float32List(padded.length);
  for (var i = 0; i < padded.length; i++) {
    input[i] = padded[i].toDouble();
  }
  return _PreparedLineArt(
      input: input,
      workWidth: workWidth,
      workHeight: workHeight,
      padWidth: padWidth,
      padHeight: padHeight);
}

Uint8List _restoreLineArt({
  required Float32List output,
  required _PreparedLineArt prepared,
  required int width,
  required int height,
}) {
  if (output.length != prepared.input.length) {
    throw StateError(
        'MLE 输出尺寸不符: ${output.length} != ${prepared.input.length}');
  }
  final croppedBytes = Uint8List(prepared.workWidth * prepared.workHeight);
  for (var y = 0; y < prepared.workHeight; y++) {
    for (var x = 0; x < prepared.workWidth; x++) {
      croppedBytes[y * prepared.workWidth + x] =
          output[y * prepared.padWidth + x].round().clamp(0, 255);
    }
  }
  final cropped = imglib.Image.fromBytes(
      width: prepared.workWidth,
      height: prepared.workHeight,
      bytes: croppedBytes.buffer,
      numChannels: 1);
  final restored = imglib.copyResize(cropped,
      width: width, height: height, interpolation: imglib.Interpolation.cubic);
  return restored.getBytes();
}

Future<Uint8List> cleanLineArt({
  required Uint8List gray,
  required int width,
  required int height,
  required LineCleanRun run,
  int workingMaxSide = 384,
}) async {
  final prepared = _prepareLineArt(
      gray: gray, width: width, height: height, workingMaxSide: workingMaxSide);
  final output =
      await run(prepared.input, prepared.padHeight, prepared.padWidth);
  return _restoreLineArt(
      output: output, prepared: prepared, width: width, height: height);
}

Future<Uint8List> cleanLineArtWithSession({
  required Uint8List gray,
  required int width,
  required int height,
  required String path,
  required int intraThreads,
  required LineCleanSessionFactory open,
}) async {
  final prepared = _prepareLineArt(gray: gray, width: width, height: height);
  final session = open(path, intraThreads: intraThreads, useArena: false);
  late final Float32List output;
  try {
    final outputs = session.run(
      {
        'gray': (prepared.input, [1, 1, prepared.padHeight, prepared.padWidth])
      },
      outputs: const ['line'],
    );
    final line = outputs['line'];
    if (line == null) {
      throw StateError('MLE 输出缺少 line');
    }
    if (line.$2.length != 4 ||
        line.$2[0] != 1 ||
        line.$2[1] != 1 ||
        line.$2[2] != prepared.padHeight ||
        line.$2[3] != prepared.padWidth) {
      throw StateError('MLE line 形状不符: ${line.$2}');
    }
    output = line.$1;
  } finally {
    session.close();
  }
  return _restoreLineArt(
      output: output, prepared: prepared, width: width, height: height);
}

Future<Uint8List> maybeCleanLineArt({
  required bool enabled,
  required Uint8List gray,
  required int width,
  required int height,
  required String weightsDir,
  required int intraThreads,
  required void Function(String line) onWarning,
  void Function(String line)? onLog,
  LineCleanSessionFactory? open,
}) async {
  if (!enabled) return gray;
  final path = '$weightsDir/manga_line_extraction.onnx';
  if (!File(path).existsSync()) {
    onWarning('线稿净化权重缺失（$path），按原稿继续');
    return gray;
  }
  final sw = Stopwatch()..start();
  try {
    final out = await cleanLineArtWithSession(
      gray: gray,
      width: width,
      height: height,
      path: path,
      intraThreads: intraThreads,
      open: open ?? openOrtLineCleanSession,
    );
    onLog?.call('线稿净化完成（${sw.elapsedMilliseconds}ms）${rssSuffix()}');
    return out;
  } on Object catch (e) {
    onWarning('线稿净化失败（$e），按原稿继续');
    return gray;
  }
}
