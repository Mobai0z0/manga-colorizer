"""_finish_bgr 色彩收尾冒烟测试（纯 numpy/cv2，不加载模型，秒级）。

用法: ..\\.venv\\Scripts\\python.exe tool/colorizer_service/quality_check.py

断言九件事:
  1. 色域内像素与 cv2 LAB2BGR 逐值差 ≤1（平增益收尾时是无损替代）;
  2. 超色域像素的输出色相偏移 <2.5°（旧逐通道截断可偏 30°+，是发灰发闷主因）;
  3. 亮度严格保持（色域映射前后 L 差 ≤1，8bit 量化容差）;
  4. 自适应膝点增益单调放大输出色度;
  5. 极暗像素不被色度"提亮"成彩黑色（L=0 时旧路径会输出 ~RGB(103,0,0)）;
  6. 纸白中和: 近白像素的暖偏被定点去除（偏黄修复）;
  7. L=100 纯白 + 任意色度输出纯白（t≥0 钳制后无负系数外推）;
  8. 参考图迁移: 亮度保真 + 纸白保护 + strength=0 恒等;
  9. 白色前景救援: 封闭近白吃到模型色度（L 压低）, 纸白保持纯白。
"""
import math
import os
import sys
from pathlib import Path

import cv2
import numpy as np

# import service 会按 COLORIZER_PRELOAD=1（默认）起预热线程加载双模型——
# 冒烟测试只测收尾函数，不加载模型。
os.environ['COLORIZER_PRELOAD'] = '0'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import service


def _lab_bytes(l_real, a_real, b_real):
    """0-100 的 L 与真实 a/b → cv2 8bit Lab 打包（L×255/100，a/b+128）。"""
    l = np.clip(np.round(np.asarray(l_real, dtype=np.float64) * 255.0 / 100.0), 0, 255).astype(np.uint8)
    a = np.clip(np.round(np.asarray(a_real, dtype=np.float64) + 128.0), 0, 255).astype(np.uint8)
    b = np.clip(np.round(np.asarray(b_real, dtype=np.float64) + 128.0), 0, 255).astype(np.uint8)
    return l, a, b


def _ab_float(a_u8, b_u8):
    return np.stack([a_u8.astype(np.float32), b_u8.astype(np.float32)], axis=-1)


def _out_chroma_hue(bgr_pix):
    lab = cv2.cvtColor(bgr_pix.reshape(1, 1, 3), cv2.COLOR_BGR2LAB)[0, 0].astype(np.float64)
    a, b = lab[1] - 128.0, lab[2] - 128.0
    return math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360.0


def _flat():
    return dict(service._FLAT_FINISH)


def test_in_gamut_matches_cv2():
    rng = np.random.default_rng(7)
    rgb = rng.integers(0, 256, (64, 64, 3), dtype=np.uint8)
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)
    ours = service._finish_bgr(lab[..., 0], _ab_float(lab[..., 1], lab[..., 2]), _flat())
    ref = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
    diff = np.abs(ours.astype(np.int32) - ref.astype(np.int32))
    assert diff.max() <= 1, f'色域内与 cv2 最大偏差 {diff.max()}（应为 ≤1）'


def test_out_of_gamut_hue_and_luma():
    bad_hue, bad_luma, neutralized = [], [], []
    for lv in range(10, 96, 5):
        for hd in range(0, 360, 15):
            rad = math.radians(hd)
            ar, br = 60.0 * math.cos(rad), 60.0 * math.sin(rad)
            l1, a1, b1 = _lab_bytes([[lv]], [[ar]], [[br]])
            out = service._finish_bgr(l1, _ab_float(a1, b1), _flat())
            lab_out = cv2.cvtColor(out.reshape(1, 1, 3), cv2.COLOR_BGR2LAB)[0, 0].astype(np.float64)
            mag, hue_out = _out_chroma_hue(out[0, 0])
            l_out = lab_out[0] * 100.0 / 255.0
            if abs(l_out - lv) > 1.5:
                bad_luma.append((lv, hd, l_out))
            if mag < 5.0:
                neutralized.append((lv, hd, mag))
                continue
            hue_in = math.degrees(math.atan2(br, ar)) % 360.0
            err = abs(hue_out - hue_in)
            err = min(err, 360.0 - err)
            # 深阴影区色域极窄、色度被大幅收缩后 Lab 色相角对低色度天然敏感,
            # 用感知口径: 色相弦长 2·C·sin(Δh/2) ≤3 个 Lab 单位（ΔE≈3, 暗部不可见）;
            # 对照: 旧逐通道截断在 L=10 处色相可偏 80°+（发脏主因）。
            tol_deg = max(2.5, math.degrees(2.0 * math.asin(min(1.0, 3.0 / mag))))
            if err > tol_deg:
                bad_hue.append((lv, hd, round(err, 2), round(mag, 1)))
    assert not bad_hue, f'色相偏移超感知容差: {bad_hue[:8]}'
    assert not bad_luma, f'亮度未保持: {bad_luma[:8]}'
    # 中部亮度不允许被收缩成全中性（色度被抹平）
    mid = [m for m in neutralized if 25 <= m[0] <= 85]
    assert not mid, f'中部亮度色度被抹平: {mid[:8]}'


def test_knee_boosts_chroma():
    l1, a1, b1 = _lab_bytes([[60]], [[35]], [[20]])  # 柔和肤色类（色域内）
    ab = _ab_float(a1, b1)
    base = _out_chroma_hue(service._finish_bgr(l1, ab, _flat())[0, 0])[0]
    boosted = _out_chroma_hue(
        service._finish_bgr(l1, ab, service._resolve_finish('standard'))[0, 0])[0]
    assert boosted > base, f'膝点增益未提升色度: {base} -> {boosted}'


def test_gain_leaves_neutral_unchanged():
    l1, a1, b1 = _lab_bytes([[20, 60, 90]], [[0, 0, 0]], [[0, 0, 0]])
    out = service._finish_bgr(l1, _ab_float(a1, b1), service._resolve_finish('standard'))
    rgb = cv2.cvtColor(out, cv2.COLOR_BGR2RGB).astype(np.int32)
    spread = rgb.max(axis=-1) - rgb.min(axis=-1)
    assert spread.max() <= 1, f'中性色被增益染色: max spread {spread.max()}'


def test_black_not_tinted():
    l1, a1, b1 = _lab_bytes([[0]], [[80]], [[30]])  # 纯黑 + 强红: 旧路径输出 ~RGB(103,0,0)
    out = service._finish_bgr(l1, _ab_float(a1, b1), _flat())[0, 0].astype(np.int32)
    assert out.max() <= 2, f'纯黑被色度提亮: BGR={out.tolist()}'


def test_paper_neutralization():
    """纸白中和: L≥248 的暖偏像素输出回到中性白（偏黄修复）。"""
    # 模型纸白实测偏差量级: a≈+0.4, b≈+3.4。L=100 纯白在平收尾下也会被色域
    # 收缩成纯白（t≥0 钳制）, 中和开关要用半程亮度 L≈95 验证。
    l1, a1, b1 = _lab_bytes([[100.0, 95.0, 60.0, 60.0]], [[0.4, 0.4, 0.4, 0.4]],
                            [[3.4, 3.4, 3.4, 3.4]])
    out = service._finish_bgr(l1, _ab_float(a1, b1), service._resolve_finish('standard'))
    lab = cv2.cvtColor(out, cv2.COLOR_BGR2LAB)[0].astype(np.float64)
    b_out = lab[:, 2] - 128.0
    assert abs(b_out[0]) <= 1.0, f'L=100 纸白未中和: b={b_out[0]}'
    assert b_out[0] < b_out[1] - 0.5, \
        f'中和应随亮度下降而减弱: b(100)={b_out[0]} b(95)={b_out[1]}'
    assert abs(b_out[3]) > 1.5, f'L=60 亮灰不应被过度中和: b={b_out[3]}'
    # 关闭中和（flat）时暖偏保留——开关有效
    out2 = service._finish_bgr(l1, _ab_float(a1, b1), _flat())
    b2 = cv2.cvtColor(out2, cv2.COLOR_BGR2LAB)[0].astype(np.float64)[:, 2] - 128.0
    assert abs(b2[1]) > 1.5, f'flat 收尾不应中和 L=95: b={b2[1]}'


def test_pure_white_no_negative_extrapolation():
    """L=100 纯白 + 任意色度: t 钳 ≥0 后输出收敛纯白, 不再色相畸变。"""
    rng = np.random.default_rng(3)
    ab = rng.uniform(-40, 40, (16, 16, 2)).astype(np.float32) + 128.0
    l1 = np.full((16, 16), 255, np.uint8)  # L 字节 255 = L 100
    out = service._finish_bgr(l1, ab, _flat())
    # 纯白输出: 通道 spread ≤1（任何色度在 L=100 都被收缩到白）
    spread = out.astype(np.int32).max(axis=-1) - out.astype(np.int32).min(axis=-1)
    assert spread.max() <= 1, f'L=100 未收敛纯白: max spread {spread.max()}'


def test_colorize_wiring():
    """colorize() → _finish_bgr 接线（桩掉 colorize_single, 不加载模型）。"""
    rng = np.random.default_rng(1)
    rgb_stub = rng.integers(0, 256, (48, 64, 3), dtype=np.uint8)  # colorize_single 的 RGB 语义
    gray = rng.integers(0, 256, (48, 64), dtype=np.uint8)
    orig = service.colorize_single
    service.colorize_single = lambda _gray: rgb_stub
    try:
        out = service.colorize(gray, service._resolve_finish('standard'))
    finally:
        service.colorize_single = orig
    assert out.shape == (48, 64, 3) and out.dtype == np.uint8
    # 亮度保真: 输出 L == 原稿灰度的 L（±2 = 8bit BGR 量化回环 Lab 的地板;
    # 随机域外色度映射后 L 线性严格保持, 误差只来自量化）。白色前景救援像素
    # 除外——救援按设计压低封闭近白区的 L 给色度让位。
    l_out = cv2.cvtColor(out, cv2.COLOR_BGR2LAB)[..., 0]
    l_ref = cv2.cvtColor(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2LAB)[..., 0]
    marks = service._white_rescue_marks(l_ref)
    exempt = (marks == 2) if marks is not None else np.zeros(gray.shape, bool)
    diff = np.abs(l_out.astype(int) - l_ref.astype(int))
    assert diff[~exempt].max() <= 2, 'L 未保真'
    if exempt.any():
        assert diff[exempt].max() >= 3 or (l_ref[exempt] < 244).all(), \
            '救援像素既未压低 L 也不在无需压低的亮度'
    # 增益生效: 标准方案输出色度高于平增益收尾
    lab_stub = cv2.cvtColor(rgb_stub, cv2.COLOR_RGB2LAB)
    ab = lab_stub[..., 1:].astype(np.float32)
    out_g1 = service._finish_bgr(l_ref, ab, _flat())
    c = lambda im: float(np.hypot(cv2.cvtColor(im, cv2.COLOR_BGR2LAB)[..., 1].astype(float) - 128,
                                 cv2.cvtColor(im, cv2.COLOR_BGR2LAB)[..., 2].astype(float) - 128).mean())
    assert c(out) > c(out_g1), 'colorize() 输出色度未高于平增益基线'


def test_white_rescue():
    """白色前景救援: 封闭近白吃到模型色度（L 压低）, 纸白保持纯白。"""
    # 24×24 全纸白, 中央 8×8 纯白块被墨线框住（封闭 → 救援候选）,
    # 全图 b=+25（模拟模型对白色前景的显性配色; 平收尾下 L=100 处必然纯白）
    gray = np.full((24, 24), 255, np.uint8)
    gray[7, 7:17] = 0
    gray[16, 7:17] = 0
    gray[7:17, 7] = 0
    gray[7:17, 16] = 0
    l_ref = cv2.cvtColor(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2LAB)[..., 0]
    ab = np.full((24, 24, 2), 128.0, np.float32)
    ab[..., 1] = 128.0 + 25.0
    marks = service._white_rescue_marks(l_ref)
    assert marks is not None and (marks == 2).sum() == 64, \
        f'封闭近白识别错误: {(marks == 2).sum()}'
    assert (marks[0:4, 0:4] == 1).all(), '贴边纸白应标记为纸白'
    # 无救援: 封闭块输出纯白（L=100 色域收缩）; 有救援: 吃到黄色
    opt = service._with_rescue(l_ref, ab, dict(service._FLAT_FINISH))
    assert 'rescue_mask' in opt, '救援参数未注入'
    out = service._finish_bgr(l_ref, ab, opt)
    lab_out = cv2.cvtColor(out, cv2.COLOR_BGR2LAB).astype(np.float64)
    b_in = lab_out[10:14, 10:14, 2].mean() - 128.0
    assert b_in > 8.0, f'封闭近白没有被上色: b={b_in:.1f}'
    l_in = lab_out[10:14, 10:14, 0].mean()
    assert l_in < 253.0, f'救援未压低 L: {l_in:.1f}'
    spread = out[0:4, 0:4].astype(int).max(axis=-1) - out[0:4, 0:4].astype(int).min(axis=-1)
    assert spread.max() <= 2, f'贴边纸白被染色: spread={spread.max()}'
    # 无救援 opt 时封闭块仍是纯白（向后兼容路径）
    out0 = service._finish_bgr(l_ref, ab, dict(service._FLAT_FINISH))
    spread0 = out0[10:14, 10:14].astype(int).max(axis=-1) - out0[10:14, 10:14].astype(int).min(axis=-1)
    assert spread0.max() <= 2, '无救援参数时行为应与旧版一致（纯白）'


def test_reference_transfer():
    """参考图迁移: 亮度保真 / 纸白保护 / strength=0 恒等 / 方法可用。"""
    rng = np.random.default_rng(11)
    src = rng.integers(0, 256, (40, 50, 3), dtype=np.uint8)
    src[:, :, :] = 255  # 全纸白 + 少量墨线
    src[10:20, 10:30] = rng.integers(0, 200, (10, 20, 1), dtype=np.uint8)
    ref = rng.integers(0, 256, (30, 30, 3), dtype=np.uint8)
    l_src = cv2.cvtColor(cv2.cvtColor(src, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2LAB)[..., 0] \
        if src.ndim == 2 else cv2.cvtColor(src, cv2.COLOR_BGR2LAB)[..., 0]
    for method in ('reinhard', 'histogram'):
        out0 = service._reference_transfer(src, ref, method=method, strength=0.0)
        assert np.array_equal(out0, src) or np.abs(out0.astype(int) - src.astype(int)).max() <= 2, \
            f'{method}: strength=0 应近似恒等'
        out1 = service._reference_transfer(src, ref, method=method, strength=1.0)
        l_out = cv2.cvtColor(out1, cv2.COLOR_BGR2LAB)[..., 0]
        assert np.abs(l_out.astype(int) - l_src.astype(int)).max() <= 2, f'{method}: L 未保真'
        # 纸白区（大块 255）保持近白: 色度幅值不高于墨迹区均值
        lab_out = cv2.cvtColor(out1, cv2.COLOR_BGR2LAB).astype(np.float64)
        paper_c = np.hypot(lab_out[:5, :5, 1] - 128, lab_out[:5, :5, 2] - 128).mean()
        ink_c = np.hypot(lab_out[10:20, 10:30, 1] - 128, lab_out[10:20, 10:30, 2] - 128).mean()
        assert paper_c <= max(ink_c, 6.0) + 6.0, \
            f'{method}: 纸白色度({paper_c:.1f})不应显著高于墨迹({ink_c:.1f})'


if __name__ == '__main__':
    tests = [test_in_gamut_matches_cv2, test_out_of_gamut_hue_and_luma,
             test_knee_boosts_chroma, test_gain_leaves_neutral_unchanged,
             test_black_not_tinted, test_paper_neutralization,
             test_pure_white_no_negative_extrapolation, test_colorize_wiring,
             test_reference_transfer, test_white_rescue]
    for t in tests:
        t()
        print(f'PASS {t.__name__}')
    print(f'quality_check: {len(tests)} 项全部通过')
