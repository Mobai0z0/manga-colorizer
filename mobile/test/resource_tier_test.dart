// ResourceTier 的档位表契约：纯函数直测（detect 的通道探测在宿主测试不可用，
// 探测失败回退 fallback 的行为正是本表要守住的默认档）。
import 'package:flutter_test/flutter_test.dart';

import 'package:manga_colorizer_mobile/image_cap.dart';
import 'package:manga_colorizer_mobile/resource_tier.dart';

void main() {
  group('fromDevice 档位表', () {
    test('≥6GB：满配（2048/4）', () {
      final t = ResourceTier.fromDevice(
          totalMemBytes: 6 << 30, lowRamDevice: false);
      expect(t.maxPickSide, 2048);
      expect(t.intraThreads, 4);
    });

    test('4–6GB：中档（1536/4），只降像素不降线程', () {
      final t = ResourceTier.fromDevice(
          totalMemBytes: 5 << 30, lowRamDevice: false);
      expect(t.maxPickSide, 1536);
      expect(t.intraThreads, 4);
    });

    test('<4GB：低档（1280/2）', () {
      final t = ResourceTier.fromDevice(
          totalMemBytes: (4 << 30) - 1, lowRamDevice: false);
      expect(t.maxPickSide, 1280);
      expect(t.intraThreads, 2);
    });

    test('系统 lowRam 标记一票否决：大内存 lowRam 设备也进低档', () {
      final t =
          ResourceTier.fromDevice(totalMemBytes: 8 << 30, lowRamDevice: true);
      expect(t.maxPickSide, 1280);
      expect(t.intraThreads, 2);
    });
  });

  test('fallback 与 v0.5.4 行为逐值一致：2048/4（探测失败的安全回退）', () {
    expect(ResourceTier.fallback.maxPickSide, kMaxPickSide);
    expect(ResourceTier.fallback.intraThreads, 4);
    expect(
      ResourceTier.fromDevice(totalMemBytes: 16 << 30, lowRamDevice: false),
      same(ResourceTier.fallback),
    );
  });
}
