# v0.5.16 断连取证：原生信号遗嘱库（app 模块内最小 CMake 工程）。
# 遗嘱 handler 只用 signal-safe API，无需 C++ 标准库与异常。
cmake_minimum_required(VERSION 3.22.1)
project(app_native LANGUAGES C)

add_library(app_native SHARED forensics.c)
