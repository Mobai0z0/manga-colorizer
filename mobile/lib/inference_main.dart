// :inference 独立进程的 Dart 入口：android:process=":inference" 的
// InferenceService 经 FlutterEngineGroup 启动 headless 引擎并按名调用这里
// （Kotlin 侧 DartEntrypoint 二参构造只在根库 lib/main.dart 按名查找——
// 见 main.dart 的根库转发 inferenceMain，真入口从这里转发出去）。
//
// 参考 xororz/local-dream 的进程隔离架构：推理崩溃/OOM 被杀只终结本进程，
// UI 进程存活可报错重试；进程死亡即 ORT 双 session 全部归还，会话无泄漏
// 路径。主进程经 127.0.0.1 帧协议（onnx/socket_protocol.dart）与本进程通信。
import 'dart:async';
import 'dart:io' show stderr;

import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import 'forensics.dart' show startInferenceHeartbeat;
import 'inference/inference_server.dart';

/// 由 main.dart 的根库转发调用，@pragma 让 AOT 保留此入口。
@pragma('vm:entry-point')
void inferenceMain() {
  // 本进程是 headless FlutterEngine 的根 isolate：没有任何 Activity/runApp，
  // binding 不会被隐式初始化。而 backend.load() 首次 createSession 时
  // flutter_onnxruntime 走 MethodChannel，framework 的 _findBinaryMessenger
  // 对根 isolate（有 RootIsolateToken）取的是 ServicesBinding.instance
  // .defaultBinaryMessenger——binding 未初始化时 release AOT 下就是裸的
  // "Null check operator used on a null value"（debug 下会友好地报
  // "Binding has not yet been initialized."）。握手是纯 dart:io socket 所以
  // 一直正常，失败只发生在首个 job（v0.5.10 真机日志实锤）。
  WidgetsFlutterBinding.ensureInitialized();
  // v0.5.16 断连取证：心跳文件（1s 间隔 touch）。断连后主进程读 mtime：
  // 停滞 >3s＝进程先被冻结再杀；≈0＝活跃中死亡（遗嘱文件定罪崩溃 vs 被杀）。
  // 遗嘱安装（Forensics.install）在 Kotlin 侧 InferenceService.onStartCommand
  // 完成（那里才有 cacheDir 与原生库加载点）。
  unawaited(startInferenceHeartbeat());
  // 根 isolate 没有 runApp 的 zone 兜底：任何未捕获异步错误（弃置任务写帧
  // 的无监听 socket 错误、插件通道回调抛错等）都可能终结 isolate/引擎——
  // 外观恰是「连接断开但进程未死、系统无退出记录」（v0.5.11 真机 ~48s 断连
  // 的嫌疑机制）。拦下来落 logcat，进程继续服务。
  runZonedGuarded(() {
    unawaited(inferenceServerMain());
  }, (e, st) {
    stderr.writeln('[manga-inference] 未捕获异步错误: $e\n$st');
  });
}
