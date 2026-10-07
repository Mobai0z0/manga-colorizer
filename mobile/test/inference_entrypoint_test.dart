// :inference 进程入口解析的编译级守卫：引擎侧 DartEntrypoint 二参构造只在
// 根库（lib/main.dart）按名查找入口（dart_isolate.cc RunFromLibrary 对空
// library 走 Dart_GetField(Dart_RootLibrary(), name)），入口放在别的文件会
// 静默解析失败 → 服务进程空转 → 主进程连接超时回退进程内 isolate（v0.5.9
// 真机事故）。这里只取符号不调用（调用会起 ServerSocket/exit 路径）——
// main.dart 的转发一旦丢失，本文件编译即失败。
import 'package:manga_colorizer_mobile/main.dart' as root_library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inferenceMain 必须是根库（lib/main.dart）顶层符号', () {
    expect(root_library.inferenceMain, isA<void Function()>());
  });
}
