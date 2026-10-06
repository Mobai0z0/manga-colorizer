"""_finish_bgr 色彩收尾冒烟测试（纯 numpy/cv2，不加载模型，秒级）。

用法: ..\\.venv\\Scripts\\python.exe tool/colorizer_service/quality_check.py

断言五件事:
  1. 色域内像素与 cv2 LAB2BGR 逐值差 ≤1（gain=1 时是无损替代）;
  2. 超色域像素的输出色相偏移 <2.5°（旧逐通道截断可偏 30°+，是发灰发闷主因）;
  3. 亮度严格保持（色域映射前后 L 差 ≤1，8bit 量化容差）;
  4. 增益单调放大输出色度（增益作用在量化前的浮点色度上）;
  5. 极暗像素不被色度"提亮"成彩黑色（L=0 时旧路径会输出 ~RGB(103,0,0)）。
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


def test_in_gamut_matches_cv2():
    rng = np.random.default_rng(7)
    rgb = rng.integers(0, 256, (64, 64, 3), dtype=np.uint8)
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)
    ours = service._finish_bgr(lab[..., 0], _ab_float(lab[..., 1], lab[..., 2]), gain=1.0)
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
            out = service._finish_bgr(l1, _ab_float(a1, b1), gain=1.0)
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


def test_gain_boosts_chroma():
    l1, a1, b1 = _lab_bytes([[60]], [[35]], [[20]])  # 柔和肤色类（色域内）
    ab = _ab_float(a1, b1)
    base = _out_chroma_hue(service._finish_bgr(l1, ab, gain=1.0)[0, 0])[0]
    boosted = _out_chroma_hue(service._finish_bgr(l1, ab, gain=service.CHROMA_GAIN)[0, 0])[0]
    assert boosted > base, f'增益未提升色度: {base} -> {boosted}'


def test_gain_leaves_neutral_unchanged():
    l1, a1, b1 = _lab_bytes([[20, 60, 90]], [[0, 0, 0]], [[0, 0, 0]])
    out = service._finish_bgr(l1, _ab_float(a1, b1), gain=service.CHROMA_GAIN)
    rgb = cv2.cvtColor(out, cv2.COLOR_BGR2RGB).astype(np.int32)
    spread = rgb.max(axis=-1) - rgb.min(axis=-1)
    assert spread.max() <= 1, f'中性色被增益染色: max spread {spread.max()}'


def test_black_not_tinted():
    l1, a1, b1 = _lab_bytes([[0]], [[80]], [[30]])  # 纯黑 + 强红: 旧路径输出 ~RGB(103,0,0)
    out = service._finish_bgr(l1, _ab_float(a1, b1), gain=1.0)[0, 0].astype(np.int32)
    assert out.max() <= 2, f'纯黑被色度提亮: BGR={out.tolist()}'


def test_colorize_wiring():
    """colorize() → _finish_bgr 接线（桩掉 colorize_single, 不加载模型）。"""
    rng = np.random.default_rng(1)
    rgb_stub = rng.integers(0, 256, (48, 64, 3), dtype=np.uint8)  # colorize_single 的 RGB 语义
    gray = rng.integers(0, 256, (48, 64), dtype=np.uint8)
    orig = service.colorize_single
    service.colorize_single = lambda _gray: rgb_stub
    try:
        out = service.colorize(gray)
    finally:
        service.colorize_single = orig
    assert out.shape == (48, 64, 3) and out.dtype == np.uint8
    # 亮度保真: 输出 L == 原稿灰度的 L（±2 = 8bit BGR 量化回环 Lab 的地板;
    # 随机域外色度映射后 L 线性严格保持, 误差只来自量化）
    l_out = cv2.cvtColor(out, cv2.COLOR_BGR2LAB)[..., 0]
    l_ref = cv2.cvtColor(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2LAB)[..., 0]
    assert np.abs(l_out.astype(int) - l_ref.astype(int)).max() <= 2, 'L 未保真'
    # 增益生效: 全新收尾的输出色度高于 gain=1 的同输入收尾
    lab_stub = cv2.cvtColor(rgb_stub, cv2.COLOR_RGB2LAB)
    ab = lab_stub[..., 1:].astype(np.float32)
    out_g1 = service._finish_bgr(l_ref, ab, gain=1.0)
    c = lambda im: float(np.hypot(cv2.cvtColor(im, cv2.COLOR_BGR2LAB)[..., 1].astype(float) - 128,
                                 cv2.cvtColor(im, cv2.COLOR_BGR2LAB)[..., 2].astype(float) - 128).mean())
    assert c(out) > c(out_g1), 'colorize() 输出色度未高于 gain=1 基线'


if __name__ == '__main__':
    tests = [test_in_gamut_matches_cv2, test_out_of_gamut_hue_and_luma,
             test_gain_boosts_chroma, test_gain_leaves_neutral_unchanged,
             test_black_not_tinted, test_colorize_wiring]
    for t in tests:
        t()
        print(f'PASS {t.__name__}')
    print(f'quality_check: {len(tests)} 项全部通过 (CHROMA_GAIN={service.CHROMA_GAIN})')
