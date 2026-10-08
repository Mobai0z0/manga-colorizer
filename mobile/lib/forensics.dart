// v0.5.16 断连取证三件套的 Dart 侧：心跳文件（:inference 进程内写）+
// 原生遗嘱/心跳的主进程侧读取。
//
// 背景：:inference 进程恒死在首个 ORT Run 内部（v0.5.13/14/15 三轮真机
// 复现），ROM 拒绝 ApplicationExitInfo（DUMP 权限），logcat 不可得（用户
// 无电脑连接）。本轮在进程内自建三条证据线，断连后由主进程读取定罪：
//
//   1. 心跳文件（[startInferenceHeartbeat]）：:inference 进程每 1s touch
//      一次。断连后读 mtime：距死亡时刻 ≈0s＝活跃中死亡（崩溃/同步 SIGKILL）；
//      停滞 >3s＝进程先被冻结再杀（厂商冻结省电策略）。
//   2. 原生遗嘱（Forensics.install 经 JNI，Kotlin 侧 InferenceService 安装，
//      C 层 android/app/src/main/cpp/forensics.c 落笔）：fatal-signal handler
//      写「will signal=N addr=0x…」后 re-raise。遗嘱存在＝原生崩溃（N 即死
//      因）；SIGKILL 写不了遗嘱——遗嘱缺失＋心跳活跃＝被杀证据。
//   3. threads=1 末次重试（auto_service.dart）：第 2 次自动重试降单线程，
//      复活成功＝多线程并发缺陷实锤（且任务顺便完成）。
//
// 证据文件都落在应用私有 cacheDir 的 forensics/ 子目录（主进程与
// :inference 进程同包同沙箱，主进程可直接读）。全部尽力而为：任何失败只
// 降级为「无此项证据」，绝不妨碍推理主链路。
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';

/// 心跳文件的文件名（应用 cacheDir 下相对路径，:inference 写、主进程读）。
const String kHeartbeatFileName = 'forensics/heartbeat';

/// 遗嘱文件的文件名（C 层写入；InferenceService 传给 JNI 的同一路径）。
const String kWillFileName = 'forensics/will';

/// v0.5.17：stderr 镜像文件（C 层 dup2 落盘；:inference 进程内 fd2 输出
/// 全部进这里——ORT 报错原文 + Dart '[manga-inference]' 日志同框）。
const String kStderrFileName = 'forensics/stderr.log';

/// v0.5.17：崩溃时刻的 /proc/self/maps 快照（遗嘱 C 层同窗口落盘）。
const String kMapsFileName = 'forensics/will.maps';

/// 心跳间隔：断连后 mtime 停滞 >[kHeartbeatStallThreshold] 判「冻结后杀」。
const Duration kHeartbeatInterval = Duration(seconds: 1);

/// mtime 停滞阈值：超过即判「进程冻结后被杀」（心跳每 1s 应续命）。
const Duration kHeartbeatStallThreshold = Duration(seconds: 3);

/// :inference 进程内的心跳定时器（单例；inferenceMain 安装）。
Timer? _heartbeatTimer;
File? _heartbeatFile;

/// :inference 进程内启动心跳：每 [kHeartbeatInterval] touch 一次心跳文件。
/// 目录不存在则创建；任何失败静默放弃（取证不可妨碍服务）。
Future<void> startInferenceHeartbeat() async {
  _heartbeatTimer?.cancel();
  try {
    // 应用私有 cacheDir（/data/data/<pkg>/cache）：主进程与 :inference 同包
    // 同沙箱，主进程可直接读。headless 进程没有 Activity，path_provider 走
    // 的仍是 binding 的应用上下文——与 inferenceMain 里 ensureInitialized
    // 的顺序天然满足。宿主测试/非 Android：抛错静默放弃。
    final base = await getTemporaryDirectory(); // Android＝cacheDir
    final f = File('${base.path}/$kHeartbeatFileName');
    await f.parent.create(recursive: true);
    // 初始写一次：断连后 mtime 与死亡时刻的差值才有意义（无初始文件＝
    // 心跳从未跑起来，另作他判）。
    await f.writeAsString('${DateTime.now().microsecondsSinceEpoch}\n',
        mode: FileMode.append);
    _heartbeatFile = f;
  } on Object {
    _heartbeatFile = null;
  }
  _heartbeatTimer = Timer.periodic(kHeartbeatInterval, (_) {
    final f = _heartbeatFile;
    if (f == null) return;
    try {
      // touch：追加一行时间戳（mtime 即更新；文件按 20KB 截断防涨）。
      f.writeAsStringSync('${DateTime.now().microsecondsSinceEpoch}\n',
          mode: FileMode.append, flush: false);
      final len = f.lengthSync();
      if (len > 20 * 1024) f.writeAsStringSync('', mode: FileMode.write);
    } on Object {
      // 单次失败下轮再试。
    }
  });
}

/// 测试钩子：停心跳（宿主测试不触真文件，生产路径不调用）。
void stopInferenceHeartbeatForTest() {
  _heartbeatTimer?.cancel();
  _heartbeatTimer = null;
  _heartbeatFile = null;
}

/// 主进程侧：心跳/遗嘱所在 cacheDir（应用级，与 :inference 进程共享沙箱）。
Future<String?> _sharedCacheDir() async {
  if (!Platform.isAndroid) return null;
  try {
    final base = await getTemporaryDirectory(); // Android＝cacheDir
    return base.path;
  } on Object {
    return null;
  }
}

/// 主进程侧：读取 :inference 进程的最后心跳 mtime（null＝无文件/不可达）。
/// 返回距今时长——断连上报时换算「死亡前心跳还在不在」。
Future<Duration?> readInferenceHeartbeatAge() async {
  try {
    final dir = await _sharedCacheDir();
    if (dir == null) return null;
    final f = File('$dir/$kHeartbeatFileName');
    if (!f.existsSync()) return null;
    final age = DateTime.now().difference(f.statSync().modified);
    return age.isNegative ? Duration.zero : age;
  } on Object {
    return null;
  }
}

/// 主进程侧：读取原生遗嘱文本（null＝无遗嘱＝进程不是崩溃死的，或取证
/// 未安装）。
Future<String?> readInferenceWill() async {
  try {
    final dir = await _sharedCacheDir();
    if (dir == null) return null;
    final f = File('$dir/$kWillFileName');
    if (!f.existsSync()) return null;
    return f.readAsStringSync().trim();
  } on Object {
    return null;
  }
}

/// 主进程侧：清掉旧遗嘱（新 spawn 时调用——遗嘱只描述「上一次死亡」，带到
/// 下一次断连的取证里就是伪证）。
Future<void> clearInferenceWill() async {
  try {
    final dir = await _sharedCacheDir();
    if (dir == null) return;
    final f = File('$dir/$kWillFileName');
    if (f.existsSync()) await f.delete();
  } on Object {
    // 取证清理失败不影响主链路：遗嘱最多是旧的（读取侧按 mtime 判新旧）。
  }
}

/// 主进程侧：读取 stderr 镜像尾部（[maxChars] 上限；null＝无文件）。
/// SIGABRT 前 ORT/std::terminate 写的报错原文在这里——取证最值钱的一句。
Future<String?> readInferenceStderrTail({int maxChars = 4000}) async {
  try {
    final dir = await _sharedCacheDir();
    if (dir == null) return null;
    final f = File('$dir/$kStderrFileName');
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    if (bytes.isEmpty) return null;
    // 只取尾部：stderr 全量可能大（含 Dart 日志镜像），abort 原文总在最后。
    const maxBytes = 16 * 1024;
    final tail = bytes.length > maxBytes
        ? bytes.sublist(bytes.length - maxBytes)
        : bytes;
    var text = utf8.decode(tail, allowMalformed: true);
    if (text.length > maxChars) text = text.substring(text.length - maxChars);
    return text.trim();
  } on Object {
    return null;
  }
}

/// 遗嘱行里的 backtrace（v0.5.17）：「bt=0x…,0x…,…」裸 PC 列表。
final RegExp _btLinePattern = RegExp(r'bt=([0-9a-fx,]+)');

/// 从遗嘱文本解析 backtrace PC 列表（无 bt 行＝null）。
List<Uri>? parseWillBacktrace(String will) {
  for (final line in will.split('\n')) {
    final m = _btLinePattern.firstMatch(line);
    if (m == null) continue;
    final pcs = <Uri>[];
    for (final tok in m.group(1)!.split(',')) {
      final v = int.tryParse(tok.replaceFirst('0x', ''), radix: 16);
      if (v != null) pcs.add(Uri.parse('elf:0x${v.toRadixString(16)}'));
    }
    return pcs;
  }
  return null;
}

/// 主进程侧：读取 maps 快照文本（null＝无文件；v0.5.17 崩溃归属表）。
Future<String?> readInferenceMapsSnapshot() async {
  try {
    final dir = await _sharedCacheDir();
    if (dir == null) return null;
    final f = File('$dir/$kMapsFileName');
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  } on Object {
    return null;
  }
}

/// 信号编号 → 可读名（遗嘱行 will signal=N 的翻译；C 层只写十进制编号）。
String? describeFatalSignal(int sig) => switch (sig) {
      1 => 'SIGHUP',
      2 => 'SIGINT',
      3 => 'SIGQUIT',
      4 => 'SIGILL',
      5 => 'SIGTRAP',
      6 => 'SIGABRT',
      7 => 'SIGBUS',
      8 => 'SIGFPE',
      9 => 'SIGKILL', // 理论上到不了 handler（内核直杀），防御性列出
      11 => 'SIGSEGV',
      12 => 'SIGUSR2',
      13 => 'SIGPIPE',
      15 => 'SIGTERM',
      24 => 'SIGXCPU',
      25 => 'SIGXFSZ',
      31 => 'SIGSYS',
      _ => null,
    };
