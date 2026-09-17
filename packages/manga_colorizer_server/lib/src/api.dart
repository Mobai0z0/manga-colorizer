import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'http_utils.dart';

/// 上色服务 API 路由。
///
/// 端点:
/// - GET  /api/health         健康检查 + 引擎信息
/// - GET  /api/presets        内置色调映射预设列表
/// - POST /api/colorize       multipart: image + hints + options → PNG
/// - POST /api/tint           multipart: image + preset/palette + options → PNG
class ColorizerApi {
  final String version;
  final Map<String, List<TintStop>> presets;

  ColorizerApi({this.version = '0.1.0', Map<String, List<TintStop>>? presets})
      : presets = presets ?? kTintPresets;

  Router get router {
    final router = Router()
      ..get('/health', _health)
      ..get('/presets', _presets)
      ..post('/colorize', _colorize)
      ..post('/tint', _tint);
    return router;
  }

  Response _health(Request request) => jsonResponse({
        'ok': true,
        'service': 'manga-colorizer-backend',
        'version': version,
        'engine': {
          'colorize': 'hint-based chroma diffusion (Levin 2004, SOR)',
          'tint': 'luminance gradient-map mapping',
        },
      });

  Response _presets(Request request) => jsonResponse({
        'ok': true,
        'presets': {
          for (final entry in presets.entries)
            entry.key: [
              for (final stop in entry.value)
                {'luminance': stop.luminance, 'r': stop.r, 'g': stop.g, 'b': stop.b},
            ],
        },
      });

  Future<Response> _colorize(Request request) async {
    try {
      final parsed = await _readMultipart(request);
      final imagePart = _requireImage(parsed);
      final source = MangaImageIO.decodeGrayscale(imagePart.bytes);
      final hints = parseHints(parsed.fields['hints'],
          width: source.width, height: source.height);
      final options = _parseOptions<ColorizeOptions>(
          parsed.fields['options'],
          (json) => ColorizeOptions.fromJson(json));
      final result = colorizeManga(
        grayscaleRgb: source.rgb,
        width: source.width,
        height: source.height,
        hints: hints,
        options: options,
      );
      final png = MangaImageIO.encodePng(
          rgb: result.rgb, width: result.width, height: result.height);
      return Response.ok(
        png,
        headers: {
          'content-type': 'image/png',
          'x-colorize-iterations': '${result.iterations}',
          'x-colorize-max-delta': result.maxDelta.toStringAsFixed(8),
          'x-colorize-hints': '${result.hintCount}',
          'x-colorize-locked-monochrome': '${result.lockedMonochromeCount}',
        },
      );
    } catch (error) {
      return errorResponse(error);
    }
  }

  Future<Response> _tint(Request request) async {
    try {
      final parsed = await _readMultipart(request);
      final imagePart = _requireImage(parsed);
      final source = MangaImageIO.decodeGrayscale(imagePart.bytes);
      final presetName = parsed.fields['preset'];
      final paletteJson = parsed.fields['palette'];
      final List<TintStop> palette;
      if (paletteJson != null && paletteJson.isNotEmpty) {
        final decoded = jsonDecode(paletteJson);
        if (decoded is! List) {
          throw const ApiException(400, 'palette 必须是 JSON 数组');
        }
        palette = decoded.asMap().entries.map((entry) {
          try {
            return TintStop.fromJson(entry.value);
          } on FormatException catch (e) {
            throw ApiException(400, 'palette[${entry.key}] 无效: ${e.message}');
          }
        }).toList();
      } else if (presetName != null && presetName.isNotEmpty) {
        final preset = presets[presetName];
        if (preset == null) {
          throw ApiException(404, '未知 preset: $presetName,可用: ${presets.keys.join(", ")}');
        }
        palette = preset;
      } else {
        throw const ApiException(400, '需要 preset 或 palette 字段之一');
      }
      final options = _parseOptions<TintOptions>(
          parsed.fields['options'],
          (json) => TintOptions.fromJson(json));
      final rgb = applyTint(
        grayscaleRgb: source.rgb,
        width: source.width,
        height: source.height,
        palette: palette,
        options: options,
      );
      final png = MangaImageIO.encodePng(
          rgb: rgb, width: source.width, height: source.height);
      return Response.ok(png, headers: {'content-type': 'image/png'});
    } catch (error) {
      return errorResponse(error);
    }
  }

  Future<MultipartParseResult> _readMultipart(Request request) async {
    final contentType = request.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().startsWith('multipart/form-data')) {
      throw const ApiException(
          400, '请求必须是 multipart/form-data (字段: image, hints, options)');
    }
    final body = await request.read().fold<BytesBuilder>(
        BytesBuilder(), (builder, chunk) => builder..add(chunk));
    return parseMultipart(
        contentTypeHeader: contentType, body: body.takeBytes());
  }

  MultipartFilePart _requireImage(MultipartParseResult parsed) {
    final part = parsed.files
        .firstWhere((f) => f.name == 'image', orElse: () => throw const ApiException(400, '缺少 image 文件字段'));
    if (part.bytes.isEmpty) {
      throw const ApiException(400, 'image 文件为空');
    }
    if (part.bytes.length > 64 * 1024 * 1024) {
      throw const ApiException(413, '图片超过 64MB 上限');
    }
    return part;
  }

  T _parseOptions<T>(String? raw, T Function(Object?) parse) {
    if (raw == null || raw.isEmpty) {
      return parse(null);
    }
    final decoded = jsonDecode(raw) as Object?;
    if (decoded is! Map) {
      throw const ApiException(400, 'options 必须是 JSON 对象');
    }
    try {
      return parse(decoded);
    } on FormatException catch (e) {
      throw ApiException(400, 'options 无效: ${e.message}');
    }
  }
}

/// 组合完整 pipeline: API + 静态演示页 (/ → demo/index.html)。
Handler buildApp({
  String version = '0.1.0',
  String? demoRoot,
  Map<String, List<TintStop>>? presets,
}) {
  final api = ColorizerApi(version: version, presets: presets);
  final router = Router();
  router.mount('/api/', api.router.call);
  if (demoRoot != null) {
    router.mount('/', createStaticHandler(demoRoot, defaultDocument: 'index.html'));
  }
  return router;
}
