// :inference 独立进程的 Dart 入口：android:process=":inference" 的
// InferenceService 经 FlutterEngineGroup 启动 headless 引擎并按名调用这里
// （Kotlin 侧 DartEntrypoint 二参构造只在根库 lib/main.dart 按名查找——
// 见 main.dart 的根库转发 inferenceMain，真入口从这里转发出去）。
//
// 参考 xororz/local-dream 的进程隔离架构：推理崩溃/OOM 被杀只终结本进程，
// UI 进程存活可报错重试；进程死亡即 ORT 双 session 全部归还，会话无泄漏
// 路径。主进程经 127.0.0.1 帧协议（onnx/socket_protocol.dart）与本进程通信。
import 'dart:async';

import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

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
  unawaited(inferenceServerMain());
}
