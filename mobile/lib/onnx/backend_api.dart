// ONNX 推理层的抽象出口：端侧管线（pipeline.dart）与 isolate 服务
// （auto_service.dart）只依赖本文件，flutter_onnxruntime 的绑定差异全部封闭在
// 同目录的 backend.dart 里（宿主测试用 test/fake_backend.dart 替身驱动，
// 永不触碰真实 ORT）。
import 'dart:typed_data';

/// 两 session（SAM encoder → generator）的最小推理后端契约。
///
/// 归一化与张量布局对齐桌面 tool/colorizer_service/service.py:331-342：
/// 像素值 `v` 一律以 `v / 127.5 - 1`（即 [-1,1]）进出模型，反归一化由调用方做
/// `clip((y + 1) * 127.5)`。
abstract class OnnxBackend {
  /// 加载权重（幂等：已加载则直接返回）。失败时抛绑定原始异常。
  Future<void> load();

  /// 输入 [1,3,S,S] CHW 归一化浮点（三通道同为灰度，对应桌面 GRAY2BGR）；
  /// 返回 SAM 两级特征（数据 + 形状，原样透传给 [runGen]）。
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(
      Float32List chw, int s);

  /// 输入 S*S 灰度平面（模型侧 [1,1,S,S]，同归一化）+ [runSam] 的两级特征；
  /// 返回 S×S、行优先、每像素 3 通道的 RGB。
  /// 后端对模型输出**既不 clip 也不反归一化**：原样透传 `rgb_pred` 的浮点值，
  /// 值域约定（约 [-1,1]）与 `clip((y+1)*127.5)` 都由调用方负责。
  /// [wd14] 为 WD14 语义嵌入（1024 维，2026-11-21 语义自举）；null＝零嵌入
  /// （模型欠饱和退化态，语义自举不可用时的回退，与桌面 zeros 路径同语义）。
  ///
  /// 注意：模型原生输出是 CHW（`rgb_pred [1,3,S,S]`），本接口刻意转成行优先 HWC
  /// 再返回，因为消费方（管线的 Lab 融合）按像素遍历；转换发生在后端内部，
  /// 替身与真实后端布局一致，管线层无需感知。
  Future<Float32List> runGen(Float32List grayPlane, int s,
      (Float32List, List<int>) sam0, (Float32List, List<int>) sam1,
      {Float32List? wd14});

  /// WD14 tagger（MOAT, 输入 [1,448,448,3] NHWC float32 0-255 BGR, 输出
  /// 第 2 项＝1024 维 hidden state 嵌入）。返回 null＝本后端不可用
  /// （MNN 后端 / 权重缺失 / 加载失败）——调用方回退 zeros 路径。
  /// 仅 OrtOnnxBackend 在权重就绪时实现；默认实现＝不可用。
  Future<Float32List?> runTagger(Float32List nhwc, int s) async => null;

  /// [runTagger] 是否可用（tagger 会话已加载）。默认 false。
  bool get supportsTagger => false;

  /// 释放 session（空闲即释放；可重复调用）。
  Future<void> dispose();
}

/// 预留的取消契约信号：当前管线的取消语义是**返回 null**（见 autoColorize），
/// 本类型今天不会被管线抛出——保留它是为未来需要显式区分"取消 vs 失败"的
/// 消费方，属于契约的一部分，删除前须同步审视整条调用链。
class OnnxCancelled implements Exception {
  const OnnxCancelled();

  @override
  String toString() => 'OnnxCancelled: 推理已取消';
}

/// WD14 语义自举的总开关（2026-11-22 默认关闭）：真机 8 页回归（桌面
/// gpu-directml，用户画廊 0001-0008）证实全强度自举在典型漫画页把 pass-1
/// 暖偏自强化成整页黄绿泛染+脸部过曝，α 阻尼/白平衡 tagger 输入均无效
/// （桌面 tmp/fix_matrix.py 取证）——比 zeros 旧路径差。机制保留待模型迁移
/// （Sana-manga-coloring ONNX, Apache-2.0）后重新评估；置 true 仅供实验
/// （非常量：宿主测试注入用，改后须还原）。
// ignore: library_private_types_in_public_api
bool kSemanticBootstrapEnabled = false;
