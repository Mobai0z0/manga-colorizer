import 'package:flutter/widgets.dart';

import 'app.dart';
import 'inference_main.dart' as inference_entry;

// 移动端多页壳入口；构建详见 app.dart（根）+ shell/app_shell.dart（导航）。
void main() => runApp(const MangaColorizerApp());

/// :inference 进程第二入口的根库转发。引擎侧 `DartEntrypoint(bundle, name)`
/// 二参构造把 library 置空，dart_isolate.cc 的 RunFromLibrary 因此只在
/// `Dart_RootLibrary()`（= 本文件编译单元）里按名取函数——入口定义在
/// inference_main.dart 会 "Could not resolve main entrypoint function"，
/// 服务进程空转，主进程连接超时（10s）后回退进程内 isolate（v0.5.9 真机
/// 日志实锤）。故此转发必须留在根库，勿并入 inference_main.dart。
@pragma('vm:entry-point')
void inferenceMain() => inference_entry.inferenceMain();
