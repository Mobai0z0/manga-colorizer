"""生成跨格一致性三个 pass 的跨语言金样: 桌面 service.py
`_unify_material_hues` + `_dominant_hue_fill` + `_neutral_chroma_floor` 的输出作为 Dart 端
core consistency.dart `applyConsistency` 的期望值，锁死两端同一套数学。

用法: python tool/colorizer_service/gen_consistency_golden.py
输出: packages/manga_colorizer_core/test/goldens/consistency_golden.json

样本（结构化合成页, 值都远离门限边界, 避免浮点翻转造成两端 blob/掩码分歧）:
  two_bows   — 同色调签名、色相冲突的两块 → 小块旋到大块色相（保 C/L）;
  floor_patch — 有色盘包围的灰块 → 沿盘主色抬到保底;
  isolated   — 81px 内无可借色的孤立灰块与墨线 → 完全不变;
  gate_reject — 肤色平涂 vs 深色阴影（ΔL>20）不配对, 双双原样;
  multi_blob — 三个互不相邻的冲突块 + 各自灰心, 锁连通域/分组/旋转顺序无关性。

容差 ±0.5（Lab 单位）: 桌面 boxFilter 走 float32, Dart 滑动窗口 float64;
旋转三角函数与圆均值累加精度差异都在 1e-3 量级。grow 掩码边界（C≈target）
在样本设计上已避开。
"""
import json
import os
import sys
from pathlib import Path

import cv2
import numpy as np

os.environ['COLORIZER_PRELOAD'] = '0'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import service

GOLDENS = Path(__file__).resolve().parents[2] / 'packages' / 'manga_colorizer_core' / 'test' / 'goldens'


def _blob(h, w, cx, cy, r, hue, chroma, l_fill=None):
    yy, xx = np.mgrid[0:h, 0:w]
    m = ((xx - cx) ** 2 + (yy - cy) ** 2) <= r ** 2
    return m


def _paint(ab, m, hue, chroma):
    ang = np.radians(hue)
    ab[..., 0][m] = 128.0 + chroma * np.cos(ang)
    ab[..., 1][m] = 128.0 + chroma * np.sin(ang)


def case_two_bows():
    h = w = 96
    l = np.full((h, w), 245, np.uint8)
    ab = np.full((h, w, 2), 128.0, np.float32)
    stripe = (np.mgrid[0:h, 0:w][0] % 8) < 4
    left = _blob(h, w, 28, 28, 12, 350, 16)
    right = _blob(h, w, 68, 28, 20, 280, 16)
    for m in (left, right):
        l[m] = np.where(stripe[m], 140, 200)  # 同一色调签名
    _paint(ab, left, 350.0, 16.0)
    _paint(ab, right, 280.0, 16.0)
    return l, ab


def case_floor_patch():
    h = w = 160
    l = np.full((h, w), 210, np.uint8)
    ab = np.full((h, w, 2), 128.0, np.float32)
    disk = _blob(h, w, 110, 80, 46, 45, 15.6)
    patch = _blob(h, w, 110, 80, 14, 0, 0)
    _paint(ab, disk, 45.0, 15.6)
    ab[patch] = 128.0
    return l, ab


def case_isolated():
    h = w = 200
    l = np.full((h, w), 210, np.uint8)
    ab = np.full((h, w, 2), 128.0, np.float32)
    iso = _blob(h, w, 50, 150, 12, 0, 0)
    l[iso] = 190
    ink = (np.mgrid[0:h, 0:w][0] >= 178) & (np.mgrid[0:h, 0:w][0] < 184) \
        & (np.mgrid[0:h, 0:w][1] >= 40) & (np.mgrid[0:h, 0:w][1] < 110)
    l[ink] = 30
    return l, ab


def case_gate_reject():
    h = w = 160
    l = np.full((h, w), 245, np.uint8)
    ab = np.full((h, w, 2), 128.0, np.float32)
    skin = _blob(h, w, 50, 80, 26, 30, 12)
    shadow = _blob(h, w, 110, 80, 18, 300, 14)
    l[skin] = 228
    l[shadow] = 160  # ΔL ≈ 68 > 20 → 不配对
    _paint(ab, skin, 30.0, 12.0)
    _paint(ab, shadow, 300.0, 14.0)
    return l, ab


def case_multi_blob():
    h = w = 240
    l = np.full((h, w), 245, np.uint8)
    ab = np.full((h, w, 2), 128.0, np.float32)
    stripe = (np.mgrid[0:h, 0:w][0] % 8) < 4
    a1 = _blob(h, w, 40, 40, 11, 350, 15)
    a2 = _blob(h, w, 200, 40, 14, 10, 15)
    b1 = _blob(h, w, 120, 60, 24, 280, 16)   # 质量、色相都与 a1/a2 冲突
    for m in (a1, a2, b1):
        l[m] = np.where(stripe[m], 140, 200)
    _paint(ab, a1, 350.0, 15.0)
    _paint(ab, a2, 10.0, 15.0)
    _paint(ab, b1, 280.0, 16.0)
    heart1 = _blob(h, w, 120, 60, 8, 0, 0)   # b1 内的灰心 → 保底染色
    ab[heart1] = 128.0
    return l, ab


def main():
    cases = {}
    for name, fn in [('two_bows', case_two_bows), ('floor_patch', case_floor_patch),
                     ('isolated', case_isolated), ('gate_reject', case_gate_reject),
                     ('multi_blob', case_multi_blob)]:
        l, ab = fn()
        out = service._neutral_chroma_floor(
            l, service._dominant_hue_fill(
                l, service._unify_material_hues(l, ab.copy())))
        cases[name] = {
            'w': int(ab.shape[1]), 'h': int(ab.shape[0]),
            'l': l.reshape(-1).tolist(),
            'ab': [[round(float(a), 4), round(float(b), 4)]
                   for a, b in ab.reshape(-1, 2)],
            'ab_out': [[round(float(a), 4), round(float(b), 4)]
                       for a, b in out.reshape(-1, 2)],
        }
    GOLDENS.mkdir(parents=True, exist_ok=True)
    path = GOLDENS / 'consistency_golden.json'
    path.write_text(json.dumps(cases, ensure_ascii=False), encoding='utf-8')
    print(f'written {path} ({len(cases)} cases)')


if __name__ == '__main__':
    main()
