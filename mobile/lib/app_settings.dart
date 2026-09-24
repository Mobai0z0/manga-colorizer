// 应用级设置的磁盘持久化：落在应用私有目录的 settings.json，读失败一律回退默认值
// （损坏/缺失不阻塞启动）。当前仅下载源一项，后续主题/配色可并入同一文件。
import 'dart:convert';
import 'dart:io';

import 'onnx/weights.dart';

class AppSettings {
  const AppSettings({this.downloadSource = DownloadSource.auto});

  /// 权重下载源，见 [DownloadSource]。默认自动（主站优先、失败回退镜像）。
  final DownloadSource downloadSource;

  static const _fileName = 'settings.json';

  static AppSettings defaults() => const AppSettings();

  Map<String, Object?> toJson() => {
        'downloadSource': downloadSource.name,
      };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final raw = json['downloadSource'];
    final src = raw is String
        ? DownloadSource.values.firstWhere(
            (s) => s.name == raw,
            orElse: () => DownloadSource.auto,
          )
        : DownloadSource.auto;
    return AppSettings(downloadSource: src);
  }

  static File _file(Directory base) =>
      File('${base.path}${Platform.pathSeparator}$_fileName');

  /// 从 [base] 目录读取设置；文件不存在或解析失败时返回 [defaults]。
  static AppSettings load(Directory base) {
    try {
      final f = _file(base);
      if (!f.existsSync()) return defaults();
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, Object?>) return AppSettings.fromJson(decoded);
      return defaults();
    } on Object {
      return defaults();
    }
  }

  /// 写回 [base] 目录（格式化 JSON，便于人工查看/编辑）。
  Future<void> save(Directory base) async => saveSync(base);

  /// [save] 的同步版本：设置体积极小，同步写盘避免异步在测试/快速切换路径上
  /// 引入时序不确定。
  void saveSync(Directory base) {
    final f = _file(base);
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
  }
}
