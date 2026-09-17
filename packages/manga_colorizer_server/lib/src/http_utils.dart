import 'dart:convert';
import 'dart:typed_data';

import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:shelf/shelf.dart';

/// 请求 / 响应相关异常与工具。
class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  Map<String, dynamic> toJson() => {'ok': false, 'error': message};
}

/// 解析 multipart/form-data 请求体。
///
/// 返回: 字段表 (name → 文本值) 与二进制文件列表 (name, filename, bytes)。
/// 仅支持 application/x-www-form-urlencoded 之外的 multipart 变体,
/// 不依赖 chunked 之外的高级特性,满足本 API 需要的 image + hints 字段。
class MultipartParseResult {
  final Map<String, String> fields;
  final List<MultipartFilePart> files;

  const MultipartParseResult(this.fields, this.files);
}

class MultipartFilePart {
  final String name;
  final String? filename;
  final Uint8List bytes;

  const MultipartFilePart(this.name, this.filename, this.bytes);
}

MultipartParseResult parseMultipart({
  required String contentTypeHeader,
  required Uint8List body,
}) {
  final match = RegExp(r'boundary=([^;]+)', caseSensitive: false)
      .firstMatch(contentTypeHeader);
  final boundaryToken = match?.group(1)?.trim();
  if (boundaryToken == null || boundaryToken.isEmpty) {
    throw const ApiException(400, 'multipart 请求缺少 boundary');
  }
  // RFC 2046: boundary 以 -- 为前缀出现在分隔行中。
  final boundary = '--${boundaryToken.replaceAll('"', '')}';
  final boundaryBytes = utf8.encode(boundary);

  final fields = <String, String>{};
  final files = <MultipartFilePart>[];

  // 按 boundary 切分 (二进制安全: 在字节流中查找)。
  var cursor = _indexOf(body, boundaryBytes, 0);
  if (cursor < 0) {
    throw const ApiException(400, 'multipart 请求体格式错误: 找不到 boundary');
  }
  cursor += boundaryBytes.length;
  while (true) {
    // 终止分隔 "--boundary--"。
    if (cursor + 1 < body.length &&
        body[cursor] == 0x2D &&
        body[cursor + 1] == 0x2D) {
      break;
    }
    // 跳过 CRLF。
    cursor = _skipCrlf(body, cursor);
    // 每部分: headers CRLF CRLF content CRLF。
    final headerEnd = _indexOf(body, utf8.encode('\r\n\r\n'), cursor);
    if (headerEnd < 0) {
      throw const ApiException(400, 'multipart 部件缺少 header 结束标记');
    }
    final headerText = utf8.decode(body.sublist(cursor, headerEnd),
        allowMalformed: true);
    final contentStart = headerEnd + 4;
    final nextBoundary = _indexOf(body, boundaryBytes, contentStart);
    if (nextBoundary < 0) {
      throw const ApiException(400, 'multipart 部件缺少结束 boundary');
    }
    var contentEnd = nextBoundary;
    // 去掉内容尾部 CRLF。
    if (contentEnd >= 2 && body[contentEnd - 2] == 0x0D && body[contentEnd - 1] == 0x0A) {
      contentEnd -= 2;
    }
    final content = Uint8List.sublistView(body, contentStart, contentEnd);

    // 解析 Content-Disposition。
    String? name;
    String? filename;
    for (final rawLine in headerText.split('\r\n')) {
      final line = rawLine.trim();
      if (line.toLowerCase().startsWith('content-disposition:')) {
        final value = line.substring('content-disposition:'.length);
        name = _headerParam(value, 'name');
        filename = _headerParam(value, 'filename');
      }
    }
    if (name == null) {
      throw const ApiException(400, 'multipart 部件缺少 name');
    }
    if (filename != null) {
      files.add(MultipartFilePart(name, filename, content));
    } else {
      fields[name] = utf8.decode(content, allowMalformed: true);
    }
    cursor = nextBoundary + boundaryBytes.length;
  }
  return MultipartParseResult(fields, files);
}

int _skipCrlf(Uint8List body, int index) {
  if (index + 1 < body.length && body[index] == 0x0D && body[index + 1] == 0x0A) {
    return index + 2;
  }
  if (index < body.length && body[index] == 0x0A) return index + 1;
  return index;
}

int _indexOf(Uint8List haystack, List<int> needle, int start) {
  if (needle.isEmpty) return start;
  final last = haystack.length - needle.length;
  for (var i = start; i <= last; i++) {
    var found = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        found = false;
        break;
      }
    }
    if (found) return i;
  }
  return -1;
}

String? _headerParam(String headerValue, String param) {
  final match = RegExp('$param=("([^"]*)"|([^;\\r\\n]*))', caseSensitive: false)
      .firstMatch(headerValue);
  if (match == null) return null;
  final quoted = match.group(2);
  if (quoted != null) return quoted;
  final bare = match.group(3)?.trim();
  return (bare == null || bare.isEmpty) ? null : bare;
}

/// 解析 hints JSON 字段为 [ColorHint] 列表,并做基础形状校验。
List<ColorHint> parseHints(Object? hintsJson, {int? width, int? height}) {
  if (hintsJson == null) return const [];
  final decoded = hintsJson is String
      ? (jsonDecode(hintsJson) as Object?)
      : hintsJson;
  if (decoded is! List) {
    throw const ApiException(400, 'hints 必须是 JSON 数组');
  }
  if (decoded.length > 4096) {
    throw const ApiException(400, 'hints 数量超过上限 4096');
  }
  return decoded.asMap().entries.map((entry) {
    final index = entry.key;
    final w = width;
    final h = height;
    try {
      final hint = ColorHint.fromJson(entry.value);
      if (w != null && h != null && (hint.x >= w || hint.y >= h)) {
        throw ApiException(
            400, 'hints[$index] 坐标 (${hint.x},${hint.y}) 超出图像 ${w}x$h');
      }
      return hint;
    } on FormatException catch (e) {
      throw ApiException(400, 'hints[$index] 无效: ${e.message}');
    }
  }).toList();
}

/// 统一 JSON 响应。
Response jsonResponse(Object? data, {int status = 200}) => Response.ok(
      jsonEncode(data),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// 将上色错误映射为 HTTP 响应。
Response errorResponse(Object error) {
  if (error is ApiException) {
    return Response(error.statusCode, body: jsonEncode(error.toJson()),
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
  if (error is FormatException || error is ArgumentError) {
    return Response.badRequest(
        body: jsonEncode({'ok': false, 'error': error.toString()}),
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
  return Response.internalServerError(
      body: jsonEncode({'ok': false, 'error': error.toString()}),
      headers: {'content-type': 'application/json; charset=utf-8'});
}
