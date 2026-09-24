// 图库单条记录的纯数据模型：账本一行即一个 GalleryEntry。
// 时间以 ISO-8601 字符串存储；elapsedS/hintCount/sourceLabel 仅提示点上色有值，
// 全自动为 null。文件字段存相对 basename，不存绝对路径（跨重装目录仍可用）。
class GalleryEntry {
  const GalleryEntry({
    required this.id,
    required this.timeIso,
    required this.mode,
    required this.width,
    required this.height,
    required this.resultFile,
    required this.sourceFile,
    required this.thumbFile,
    this.elapsedS,
    this.hintCount,
    this.sourceLabel,
  });

  final String id;
  final String timeIso;
  final String mode; // 'hints' | 'auto'
  final int width;
  final int height;
  final String resultFile;
  final String sourceFile;
  final String thumbFile;
  final double? elapsedS;
  final int? hintCount;
  final String? sourceLabel;

  Map<String, Object?> toJson() => {
        'id': id,
        'time': timeIso,
        'mode': mode,
        'width': width,
        'height': height,
        'elapsed_s': elapsedS,
        'hint_count': hintCount,
        'source_label': sourceLabel,
        'result_file': resultFile,
        'source_file': sourceFile,
        'thumb_file': thumbFile,
      };

  factory GalleryEntry.fromJson(Map<String, Object?> j) => GalleryEntry(
        id: j['id'] as String,
        timeIso: j['time'] as String,
        mode: j['mode'] as String,
        width: (j['width'] as num).toInt(),
        height: (j['height'] as num).toInt(),
        elapsedS: (j['elapsed_s'] as num?)?.toDouble(),
        hintCount: (j['hint_count'] as num?)?.toInt(),
        sourceLabel: j['source_label'] as String?,
        resultFile: j['result_file'] as String,
        sourceFile: j['source_file'] as String,
        thumbFile: j['thumb_file'] as String,
      );

  /// 供网格/灯箱展示的本地时间标签（yyyy-MM-dd HH:mm）。
  String get timeLabel {
    final dt = DateTime.tryParse(timeIso);
    if (dt == null) return timeIso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
