# v0.5.16 断连取证：原生信号遗嘱库（app 模块内最小 CMake 工程）。
# 遗嘱 handler 只用 signal-safe API，无需 C++ 标准库与异常。
cmake_minimum_required(VERSION 3.22.1)
project(app_native LANGUAGES C CXX)

add_library(app_native SHARED forensics.c)

# ---- MNN 推理后端（v0.6.x Stage 2）----
# third_party/mnn 为 git submodule（钉 3.6.1 tag），从源码编译进 APK——
# 与 xororz/local-dream 的 vendor 形态一致，绕开已停更的官方 maven 产物。
# submodule 未初始化时跳过（不阻塞不含 MNN 的构建）。
set(MNN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/mnn)
if(EXISTS ${MNN_DIR}/CMakeLists.txt)
    # 构建开关（在 add_subdirectory 前钉死）：
    #   · MNN_LOW_MEMORY：memory=Low 运行时模式的动态反量化支持（低内存档备用）
    #   · MNN_ARM82：ARM v8.2 fp16 计算内核（真机按档位实验用；v1 用 Normal 精度）
    #   · GPU 后端全关：第一轮锁定 CPU 路线（Stage 0/真机探底结论）
    #   · converter/train/opencv/audio 等全部不需要
    set(MNN_LOW_MEMORY ON CACHE BOOL "" FORCE)
    set(MNN_ARM82 ON CACHE BOOL "" FORCE)
    set(MNN_BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
    set(MNN_BUILD_CONVERTER OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_TRAIN OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_DEMO OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_BENCHMARK OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_TEST OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_QUANTOOLS OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_OPENCV OFF CACHE BOOL "" FORCE)
    set(MNN_BUILD_AUDIO OFF CACHE BOOL "" FORCE)
    set(MNN_IMGCODECS OFF CACHE BOOL "" FORCE)
    set(MNN_SUPPORT_RENDER OFF CACHE BOOL "" FORCE)
    set(MNN_OPENCL OFF CACHE BOOL "" FORCE)
    set(MNN_VULKAN OFF CACHE BOOL "" FORCE)
    set(MNN_SEP_BUILD OFF CACHE BOOL "" FORCE)
    set(MNN_AAPL_FMWK OFF CACHE BOOL "" FORCE)
    add_subdirectory(${MNN_DIR} mnn_build EXCLUDE_FROM_ALL)

    # 薄 C ABI 封装：dart:ffi 直调（mobile/lib/onnx/mnn_ffi.dart）
    add_library(mnn_ffi SHARED mnn_ffi/mnn_ffi.cpp)
    target_include_directories(mnn_ffi PRIVATE ${MNN_DIR}/include)
    target_link_libraries(mnn_ffi MNN)
    target_compile_options(mnn_ffi PRIVATE -fexceptions -frtti)
endif()
