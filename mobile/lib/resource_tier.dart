// 端侧资源档位：v0.5.4 的「按端分级」只有固定 2048/4 线程一刀切（全仓无任何
// 读设备内存的代码），本文件补上真正的按设备内存分级——主 isolate 经平台
// 通道读 ActivityManager.MemoryInfo，按总内存收敛选图上限与 ORT intra-op
// 线程数，两条上色管线的整页缓冲随之按像素数同比收缩。
//
// 探测失败（非 Android、宿主测试无通道、字段缺失）一律回退
// [ResourceTier.fallback]，与 v0.5.4 行为逐值一致：探测永不阻塞、不破坏功能。
import 'package:flutter/services.dart';

import 'image_cap.dart';
import 'logs/log_bus.dart';

class ResourceTier {
  const ResourceTier(
      {required this.maxPickSide,
      required this.intraThreads,
      required this.useArena});

  /// 选图长边上限（像素）：贯通 image_picker 的 maxWidth/maxHeight 与
  /// capDecodeRgba 的解码兜底。
  final int maxPickSide;

  /// ORT 双 session 的 intra-op 线程数：低内存档降为 2，压每线程的原生执行
  /// 缓冲与栈（分块推理本身并发 1，线程数只影响单块内部并行度）。
  final int intraThreads;

  /// arena 策略（用户授权「用时间换资源占用」）：true＝arena 开启 +
  /// 每次 Run 后收缩（快，但 Run 期间仍有 arena 高水位与 2^n 扩展过冲）；
  /// false＝彻底关闭 arena，张量走 malloc 即用即还——**单块原生峰值最低**，
  /// 代价是逐块推理变慢（GitHub #11627 实证）。中/低内存档选 false：
  /// 慢可以接受，被系统杀进程不可接受。
  final bool useArena;

  /// 与 v0.5.4 相同的默认档：无探测数据时的安全回退。
  static const ResourceTier fallback = ResourceTier(
      maxPickSide: kMaxPickSide, intraThreads: 4, useArena: true);

  /// 档位表（纯函数，宿主测试直测）：<4GB 或系统 lowRam 标记 → 最低档；
  /// 4–6GB → 中档；≥6GB → 满配（即 [fallback]）。内存越紧，越偏向
  /// 「峰值最低」的 arena 关闭。
  static ResourceTier fromDevice(
      {required int totalMemBytes, required bool lowRamDevice}) {
    if (lowRamDevice || totalMemBytes < 4 << 30) {
      return const ResourceTier(
          maxPickSide: 1280, intraThreads: 2, useArena: false);
    }
    if (totalMemBytes < 6 << 30) {
      return const ResourceTier(
          maxPickSide: 1536, intraThreads: 4, useArena: false);
    }
    return fallback;
  }

  static const MethodChannel _channel = MethodChannel('manga_colorizer/device');

  static ResourceTier? _cache;

  /// 探测一次并缓存；必须在主 isolate 调用（平台通道约束）。
  static Future<ResourceTier> detect() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('memoryInfo');
      if (raw == null) return fallback;
      final tier = fromDevice(
        totalMemBytes: raw['totalMem'] as int,
        lowRamDevice: raw['lowRam'] as bool,
      );
      _cache = tier;
      LogBus.current?.info(
          'startup',
          '资源档位：总内存 '
          '${((raw['totalMem'] as int) / (1 << 30)).toStringAsFixed(1)}GB'
          '${raw['lowRam'] as bool ? '（lowRam 设备）' : ''} → '
          '选图上限 ${tier.maxPickSide}px / 推理 ${tier.intraThreads} 线程 / '
          'arena ${tier.useArena ? '开启+收缩' : '关闭（时间换峰值）'}');
      return tier;
    } on Object {
      return fallback;
    }
  }
}
