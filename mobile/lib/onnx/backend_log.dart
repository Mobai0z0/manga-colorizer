// backend（OrtOnnxBackend）内部阶段日志的唯一出口：Run 前/Run 后、大张量
// asFlattenedList 回传、session 创建等埋点经此转发。默认 sink 为 null（静默）
// ——宿主测试不碰真实 ORT 本就不会触发；真机由两条服务路径注入：
//   · :inference 独立进程（inference/inference_server.dart）→ log 帧（日志页）
//     + stderr（logcat）双通道：进程死亡后 logcat 是唯一取证来源；
//   · isolate worker（onnx/auto_service.dart）→ ['log'] 事件 → LogBus。
// 埋点只进日志、不进控制流：sink 抛错由 [backendLog] 吞掉，绝不连坐推理。
//
// 为什么不直接用 stderr/print：isolate 路径没有 stderr 取证需求但需要日志页
// 可见；:inference 路径两者都要——通道形态属服务方决策，backend 只管上报。

/// backend 阶段日志的输出通道（null＝静默）。
typedef BackendLogSink = void Function(String line);

BackendLogSink? backendLogSink;

/// 转发一条 backend 阶段日志；sink 抛错吞掉（观测绝不影响推理）。
void backendLog(String line) {
  final sink = backendLogSink;
  if (sink == null) return;
  try {
    sink(line);
  } on Object {
    // 日志通道故障不连坐推理。
  }
}
