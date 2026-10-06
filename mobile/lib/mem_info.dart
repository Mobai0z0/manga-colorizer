// 进程 RSS 采样：只读 /proc/self/status（Android/Linux）。主 isolate 与工作
// isolate 同进程，读到的都是整个进程的占用（ORT 原生内存含在内）——这是端侧
// 「开始上色闪退」归因的唯一零成本探针：不用平台通道、不加依赖，Windows 宿主
// 测试无此文件，静默返回 null（调用方拼日志时得到空尾巴）。
//
// 只进日志、不进控制流：探测失败对功能毫无影响，属纯观测埋点。
import 'dart:io';

/// 当前进程 RSS 与峰值（kB）；不可用平台返回 null。
({int rssKb, int hwmKb})? readProcRss() {
  try {
    final text = File('/proc/self/status').readAsStringSync();
    final rss = _statusKb(text, 'VmRSS:');
    if (rss == null) return null;
    return (rssKb: rss, hwmKb: _statusKb(text, 'VmHWM:') ?? rss);
  } on Object {
    return null;
  }
}

int? _statusKb(String text, String key) {
  final i = text.indexOf(key);
  if (i < 0) return null;
  final m = RegExp(r'(\d+)').firstMatch(text.substring(i + key.length));
  return m == null ? null : int.parse(m.group(1)!);
}

/// 拼进日志行的 RSS 尾巴（如「，RSS=412MB（峰值 512MB）」）；不可用平台为空串。
String rssSuffix() {
  final m = readProcRss();
  if (m == null) return '';
  return '，RSS=${(m.rssKb / 1024).round()}MB（峰值 ${(m.hwmKb / 1024).round()}MB）';
}
