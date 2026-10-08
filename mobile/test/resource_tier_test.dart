// ResourceTier 的档位表契约：纯函数直测（detect 的通道探测在宿主测试不可用，
// 探测失败回退 fallback 的行为正是本表要守住的默认档）。
import 'package:flutter_test/flutter_test.dart';

import 'package:manga_colorizer_mobile/image_cap.dart';
import 'package:manga_colorizer_mobile/resource_tier.dart';

void main() {
  group('fromDevice 档位表', () {
    test('≥6GB：满配（2048/4，arena 关闭——峰值最低优先，空闲保留 5min）', () {
      final t = ResourceTier.fromDevice(
          totalMemBytes: 6 << 30, lowRamDevice: false);
      expect(t.maxPickSide, 2048);
      expect(t.intraThreads, 4);
      expect(t.useArena, isFalse);
      expect(t.idleRelease, const Duration(minutes: 5));
    });

    test('4–6GB：中档（1536/4，arena 关闭——时间换峰值，空闲保留 2min）', () {
      final t = ResourceTier.fromDevice(
          totalMemBytes: 5 << 30, lowRamDevice: false);
      expect(t.maxPickSide, 1536);
      expect(t.intraThreads, 4);
      expect(t.useArena, isFalse);
      expect(t.idleRelease, const Duration(minutes: 2));
    });

    test('<4GB：低档（1280/2，arena 关闭，空闲保留 60s）', () {
      final t = ResourceTier.fromDevice(
          totalMemBytes: (4 << 30) - 1, lowRamDevice: false);
      expect(t.maxPickSide, 1280);
      expect(t.intraThreads, 2);
      expect(t.useArena, isFalse);
      expect(t.idleRelease, const Duration(seconds: 60));
    });

    test('系统 lowRam 标记一票否决：大内存 lowRam 设备也进低档', () {
      final t =
          ResourceTier.fromDevice(totalMemBytes: 8 << 30, lowRamDevice: true);
      expect(t.maxPickSide, 1280);
      expect(t.intraThreads, 2);
      expect(t.useArena, isFalse);
      expect(t.idleRelease, const Duration(seconds: 60));
    });
  });

  test('fallback 与 v0.5.14 行为一致：2048/4/arena 关（探测失败的安全回退）', () {
    expect(ResourceTier.fallback.maxPickSide, kMaxPickSide);
    expect(ResourceTier.fallback.intraThreads, 4);
    expect(ResourceTier.fallback.useArena, isFalse);
    // 探测失败=未知设备：空闲保留取保守默认 60s（≥6GB 满配档是 5min，
    // 二者不再是同一对象——fallback 只服务「无探测数据」场景）。
    expect(ResourceTier.fallback.idleRelease, const Duration(seconds: 60));
    final t = ResourceTier.fromDevice(
        totalMemBytes: 16 << 30, lowRamDevice: false);
    expect(t.maxPickSide, ResourceTier.fallback.maxPickSide);
    expect(t.intraThreads, ResourceTier.fallback.intraThreads);
    expect(t.useArena, ResourceTier.fallback.useArena);
  });
}
