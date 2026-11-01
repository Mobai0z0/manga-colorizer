// MNN 推理的薄 C ABI 封装（供 dart:ffi 直调，对应 mobile/lib/onnx/mnn_ffi.dart）。
//
// 设计要点：
//   · 基于 Express Module API（Module::load + forward）而非 Interpreter/Session
//     ——v6 模型含 subgraphs，转换器明示「please use MNN::Express::Module」，
//     Session 直跑在实测中失败（rc=4）；Stage 0/1 的数值对拍也全程走 Module。
//   · 输入输出一律 NCHW host 语义：输入 _Input(NCHW)+writeMap+memcpy 后
//     _Convert(NC4HW4)（与 pymnn 官方 demo 同路径），输出 _Convert(NCHW) 后
//     readMap 拷出——内部布局差异封在本层。
//   · mmp 加载：Module::load(fileName) 内部 mmap 权重（文件背页可被系统回收，
//     这是引入 MNN 的核心内存收益）。
//   · 创建期做一次零输入探测前向：既当预热，也拿到输出形状（Module::Info 只含
//     输入形状）；形状缓存随每次运行刷新。
//   · 错误：C++ 异常全部拦在边界，转成错误码（1=加载失败 2=名字越界 3=形状/容量
//     不符 4=运行失败），msg_buf 带回截断文本供 Dart 日志。
//   · 线程模型：Dart isolate 串行调用，无内部锁。
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <numeric>
#include <string>
#include <vector>

#include "MNN/expr/Expr.hpp"
#include "MNN/expr/Executor.hpp"
#include "MNN/expr/Module.hpp"
#include "MNN/expr/NeuralNetWorkOp.hpp"
#include "MNN/MNNForwardType.h"

namespace {

using namespace MNN::Express;

constexpr int kErrLoad = 1;
constexpr int kErrName = 2;
constexpr int kErrShape = 3;
constexpr int kErrRun = 4;

struct ModuleBundle {
    // pymnn 同款生命周期：shared_ptr 默认 delete（RuntimeManager 析构公开）。
    std::shared_ptr<Executor::RuntimeManager> rtMgr;
    std::shared_ptr<Module> module;
    std::vector<std::string> inputNames;
    std::vector<std::string> outputNames;
    std::map<std::string, std::vector<int>> inputHints;  // 动态维兜底（Dart 契约）
    std::map<std::string, std::vector<int>> inputShapes;
    std::map<std::string, std::vector<int>> outputShapes;
};

void copyName(char* buf, int cap, const std::string& name) {
    if (buf == nullptr || cap <= 0) return;
    const int n = static_cast<int>(name.size());
    const int copy = n < cap - 1 ? n : cap - 1;
    std::memcpy(buf, name.data(), copy);
    buf[copy] = '\0';
}

std::vector<std::string> takeNames(const char* const* names, int count) {
    std::vector<std::string> out;
    if (names != nullptr) {
        for (int i = 0; i < count; ++i) {
            if (names[i] != nullptr && names[i][0] != '\0') {
                out.emplace_back(names[i]);
            }
        }
    }
    return out;
}

// 一次前向（输入按名取零数据），成功后把输出形状写进缓存并返回 0。
// Module::Info->inputs 与 inputNames 按序对齐（Info 无名字段）。
int probeForward(ModuleBundle* b) {
    std::vector<VARP> vars;
    const Module::Info* info = b->module->getInfo();
    for (size_t i = 0; i < b->inputNames.size(); ++i) {
        if (info == nullptr || i >= info->inputs.size()) return kErrName;
        const auto& inp = info->inputs[i];
        std::vector<int> dims = inp.dim;
        // 动态维（-1）用 Dart 契约提示兜底；无提示则探测无法进行。
        const bool hasDynamic =
            std::any_of(dims.begin(), dims.end(), [](int d) { return d < 0; });
        if (hasDynamic) {
            auto hint = b->inputHints.find(b->inputNames[i]);
            if (hint == b->inputHints.end()) return kErrShape;
            dims = hint->second;
        }
        b->inputShapes[b->inputNames[i]] = dims;
        auto x = _Input(dims, NCHW);
        ::memset(x->writeMap<float>(), 0,
                 static_cast<size_t>(x->getTensor()->elementSize()) * sizeof(float));
        // 仅 4D（带通道）输入转 NC4HW4；2D（wd14_embedding）原样喂入。
        vars.push_back(inp.dim.size() == 4 ? _Convert(x, NC4HW4) : x);
    }
    auto outs = b->module->onForward(vars);
    if (outs.size() != b->outputNames.size()) return kErrRun;
    for (size_t i = 0; i < outs.size(); ++i) {
        auto o = _Convert(outs[i], NCHW);
        auto t = o->getTensor();
        b->outputShapes[b->outputNames[i]] = t->shape();
    }
    return 0;
}

}  // namespace

extern "C" {

// 创建会话：CPU 后端。in_names/out_names 为契约 IO 名（与模型张量名逐字一致；
// 计数为 0 或名字为空串 = 全部输入/输出按声明序）。in_shape_lens/in_shapes_flat
// 为可选输入形状提示（逐输入的秩 + 拼接维度；某输入秩 0 = 无提示）——模型声明
// 含动态维（-1）时用提示兜底建探测输入。创建期做零输入探测前向（兼预热）。
// memory_mode: 0=Normal 1=High 2=Low；precision: 0=Normal 1=High 2=Low。
void* mnn_create(const char* model_path, int threads, int memory_mode,
                 int precision, const char* const* in_names, int in_count,
                 const int64_t* in_shape_lens, const int64_t* in_shapes_flat,
                 const char* const* out_names, int out_count,
                 int* error_code, char* msg_buf, int msg_cap) {
    auto* bundle = new (std::nothrow) ModuleBundle();
    if (bundle == nullptr) {
        if (error_code) *error_code = kErrLoad;
        copyName(msg_buf, msg_cap, "alloc failed");
        return nullptr;
    }
    try {
        MNN::ScheduleConfig sc;
        sc.type = MNN_FORWARD_CPU;
        sc.numThread = threads > 0 ? threads : 1;
        MNN::BackendConfig backendConfig;
        if (memory_mode == 2) backendConfig.memory = MNN::BackendConfig::Memory_Low;
        else if (memory_mode == 1) backendConfig.memory = MNN::BackendConfig::Memory_High;
        else backendConfig.memory = MNN::BackendConfig::Memory_Normal;
        if (precision == 1) backendConfig.precision = MNN::BackendConfig::Precision_High;
        else if (precision == 2) backendConfig.precision = MNN::BackendConfig::Precision_Low;
        else backendConfig.precision = MNN::BackendConfig::Precision_Normal;
        sc.backendConfig = &backendConfig;
        bundle->rtMgr.reset(Executor::RuntimeManager::createRuntimeManager(sc));

        Module::Config config;
        config.shapeMutable = true;
        Module::BackendInfo backendInfo;
        backendInfo.type = MNN_FORWARD_CPU;
        backendInfo.config = &backendConfig;
        config.backend = &backendInfo;

        bundle->module.reset(Module::load(
            takeNames(in_names, in_count), takeNames(out_names, out_count),
            model_path, bundle->rtMgr, &config));
        if (bundle->module == nullptr) {
            delete bundle;
            if (error_code) *error_code = kErrLoad;
            copyName(msg_buf, msg_cap, "Module::load failed");
            return nullptr;
        }
        bundle->inputNames = bundle->module->getInfo()->inputNames;
        bundle->outputNames = bundle->module->getInfo()->outputNames;
        // 输入形状提示按名入表（无提示的输入名不出现在表中）。
        {
            int64_t offset = 0;
            for (int i = 0; i < in_count && in_names != nullptr; ++i) {
                const int64_t len = in_shape_lens != nullptr ? in_shape_lens[i] : 0;
                if (len > 0 && in_shapes_flat != nullptr && in_names[i] != nullptr) {
                    std::vector<int> dims;
                    for (int64_t k = 0; k < len; ++k) {
                        dims.push_back(static_cast<int>(in_shapes_flat[offset + k]));
                    }
                    bundle->inputHints.emplace(std::string(in_names[i]),
                                               std::move(dims));
                }
                offset += len > 0 ? len : 0;
            }
        }
        const int rc = probeForward(bundle);
        if (rc != 0) {
            delete bundle;
            if (error_code) *error_code = rc == kErrName ? kErrLoad : kErrRun;
            copyName(msg_buf, msg_cap, "probe forward failed");
            return nullptr;
        }
        if (error_code) *error_code = 0;
        if (msg_buf != nullptr && msg_cap > 0) msg_buf[0] = '\0';
        return bundle;
    } catch (const std::exception& e) {
        delete bundle;
        if (error_code) *error_code = kErrLoad;
        copyName(msg_buf, msg_cap, e.what());
        return nullptr;
    } catch (...) {
        delete bundle;
        if (error_code) *error_code = kErrLoad;
        copyName(msg_buf, msg_cap, "unknown native error");
        return nullptr;
    }
}

void mnn_destroy(void* handle) {
    if (handle == nullptr) return;
    auto* bundle = static_cast<ModuleBundle*>(handle);
    bundle->module.reset();
    bundle->rtMgr.reset();
    delete bundle;  // 引用全释放（mmap 映射随对象销毁解除）
}

int mnn_input_count(void* handle) {
    auto* b = static_cast<ModuleBundle*>(handle);
    return b == nullptr ? 0 : static_cast<int>(b->inputNames.size());
}

int mnn_output_count(void* handle) {
    auto* b = static_cast<ModuleBundle*>(handle);
    return b == nullptr ? 0 : static_cast<int>(b->outputNames.size());
}

int mnn_input_name(void* handle, int index, char* buf, int cap) {
    auto* b = static_cast<ModuleBundle*>(handle);
    if (b == nullptr || index < 0 || index >= static_cast<int>(b->inputNames.size())) return -1;
    copyName(buf, cap, b->inputNames[index]);
    return 0;
}

int mnn_output_name(void* handle, int index, char* buf, int cap) {
    auto* b = static_cast<ModuleBundle*>(handle);
    if (b == nullptr || index < 0 || index >= static_cast<int>(b->outputNames.size())) return -1;
    copyName(buf, cap, b->outputNames[index]);
    return 0;
}

// 形状查询（NCHW host 维度顺序；来自创建期探测与运行期刷新的缓存）。
int mnn_tensor_shape(void* handle, const char* name, int is_input,
                     int64_t* dims, int cap, int* rank) {
    auto* b = static_cast<ModuleBundle*>(handle);
    if (b == nullptr || name == nullptr) return kErrName;
    const auto& table = is_input ? b->inputShapes : b->outputShapes;
    auto it = table.find(name);
    if (it == table.end()) return kErrName;
    const int r = static_cast<int>(it->second.size());
    if (rank != nullptr) *rank = r;
    if (r > cap) return kErrShape;
    for (int i = 0; i < r; ++i) {
        dims[i] = it->second[i];
    }
    return 0;
}

// 多输出版运行：按名写入输入（每个 input_sizes[i] 个 float），一次前向取全部
// 输出（encoder 的 sam_level0/sam_level1 必须同批）。任一输出容量不足 → 拷出
// 放得下的、out_elements[i] 全部带回所需大小，返回 kErrShape（Dart 重试一次）。
int mnn_run_multi(void* handle, const char** input_names, const float** input_data,
                  const int64_t* input_sizes, int input_count,
                  const char** output_names, float** out_bufs,
                  const int64_t* out_caps, int64_t* out_elements, int output_count) {
    auto* b = static_cast<ModuleBundle*>(handle);
    if (b == nullptr || b->module == nullptr) return kErrRun;
    try {
        // 按模块声明序构建输入（Dart 侧 map 顺序可能漂移，forward 按序接线）。
        std::vector<VARP> vars;
        vars.reserve(b->inputNames.size());
        for (const auto& declared : b->inputNames) {
            int found = -1;
            for (int i = 0; i < input_count; ++i) {
                if (input_names[i] != nullptr && declared == input_names[i]) {
                    found = i;
                    break;
                }
            }
            if (found < 0) return kErrName;
            auto it = b->inputShapes.find(declared);
            if (it == b->inputShapes.end()) return kErrName;
            const int64_t need = it->second.empty()
                ? 0
                : std::accumulate(it->second.begin(), it->second.end(), 1LL,
                                  std::multiplies<int64_t>());
            if (need != input_sizes[found]) return kErrShape;
            auto x = _Input(it->second, NCHW);
            std::memcpy(x->writeMap<float>(), input_data[found],
                        static_cast<size_t>(need) * sizeof(float));
            // 仅 4D（带通道）输入转 NC4HW4；2D（wd14_embedding）原样喂入。
            vars.push_back(it->second.size() == 4 ? _Convert(x, NC4HW4) : x);
        }
        // 输入名顺序必须与模块声明一致（Dart 按 bundle 的 inputNames 顺序喂入）。
        auto outs = b->module->onForward(vars);
        if (static_cast<int>(outs.size()) != output_count ||
            outs.size() != b->outputNames.size()) {
            return kErrRun;
        }
        bool shortBuf = false;
        for (int i = 0; i < output_count; ++i) {
            auto o = _Convert(outs[i], NCHW);
            auto t = o->getTensor();
            const std::vector<int> shape = t->shape();
            b->outputShapes[b->outputNames[i]] = shape;
            int64_t elements = 1;
            for (const int d : shape) {
                elements *= d;
            }
            if (out_elements != nullptr) out_elements[i] = elements;
            if (elements > out_caps[i]) {
                shortBuf = true;
                continue;
            }
            const float* src = o->readMap<float>();
            std::memcpy(out_bufs[i], src,
                        static_cast<size_t>(elements) * sizeof(float));
        }
        return shortBuf ? kErrShape : 0;
    } catch (const std::exception& e) {
        if (out_elements != nullptr) {
            for (int i = 0; i < output_count; ++i) out_elements[i] = 0;
        }
        return kErrRun;
    } catch (...) {
        return kErrRun;
    }
}

}  // extern "C"
