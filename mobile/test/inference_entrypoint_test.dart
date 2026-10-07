// :inference 进程入口解析的编译级守卫：引擎侧 DartEntrypoint 二参构造只在
// 根库（lib/main.dart）按名查找入口（dart_isolate.cc RunFromLibrary 对空
// library 走 Dart_GetField(Dart_RootLibrary(), name)），入口放在别的文件会
// 静默解析失败 → 服务进程空转 → 主进程连接超时回退进程内 isolate（v0.5.9
// 真机事故）。这里只取符号不调用（调用会起 ServerSocket/exit 路径）——
// main.dart 的转发一旦丢失，本文件编译即失败。
//
// 另守卫 inferenceMain 内必须先 WidgetsFlutterBinding.ensureInitialized 再
// 起服务：headless 引擎的根 isolate 无人隐式初始化 binding，而首个 job 的
// createSession 走 MethodChannel → ServicesBinding.instance，release AOT 下
// 未初始化即裸空指针「Null check operator used on a null value」（v0.5.10
// 真机事故；host 测试起不来真引擎、无法运行时复现，只能结构级守卫）。
import 'dart:io';

import 'package:manga_colorizer_mobile/main.dart' as root_library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inferenceMain 必须是根库（lib/main.dart）顶层符号', () {
    expect(root_library.inferenceMain, isA<void Function()>());
  });

  test('inferenceMain 必须先 ensureInitialized 再起服务', () {
    final src = File('lib/inference_main.dart').readAsStringSync();
    final init = src.indexOf('WidgetsFlutterBinding.ensureInitialized()');
    final server = src.indexOf('inferenceServerMain()');
    expect(init, greaterThanOrEqualTo(0),
        reason: 'inferenceMain 缺 binding 初始化：首个 job 的 createSession 会'
            '在 release AOT 下抛 "Null check operator used on a null value"');
    expect(server, greaterThan(init),
        reason: 'binding 初始化必须在 inferenceServerMain 之前（同步完成，'
            '主进程连接后随时可能发 job）');
  });
}
