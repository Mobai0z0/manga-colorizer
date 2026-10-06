"""生成 labToRgbGamut 跨语言金样: 桌面 service.py `_finish_bgr` 的输出作为
Dart 端 `labToRgbGamut` 的期望值，锁死两端同一套色彩收尾数学。

用法: ..\\.venv\\Scripts\\python.exe tool/colorizer_service/gen_gamut_golden.py
输出: packages/manga_colorizer_core/test/goldens/gamut_golden.json

样本两路各 1024 像素 × 增益 {1.0, 1.2}:
  rgb  — 随机 sRGB 原色经 cv2 RGB2LAB（色域内, 含边界量化噪声）;
  grid — L/a/b 全随机（大量真超域, 触发等比收缩路径）。
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

OUT = Path(__file__).resolve().parents[2] / 'packages' / 'manga_colorizer_core' / 'test' / 'goldens' / 'gamut_golden.json'


def sample(mode: str, n: int) -> np.ndarray:
    rng = np.random.default_rng(42 if mode == 'rgb' else 43)
    if mode == 'rgb':
        rgb = rng.integers(0, 256, (1, n, 3), dtype=np.uint8)
        return cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)[0]
    l = rng.integers(0, 256, n, dtype=np.uint8)
    a = rng.integers(0, 256, n, dtype=np.uint8)
    b = rng.integers(0, 256, n, dtype=np.uint8)
    return np.stack([l, a, b], axis=-1)


def main() -> None:
    data = {}
    for gain in (1.0, service.CHROMA_GAIN):
        l_all, ab_all, bgr_all = [], [], []
        for mode in ('rgb', 'grid'):
            lab = sample(mode, 1024)
            bgr = service._finish_bgr(lab[:, 0].reshape(1, -1),
                                      lab[:, 1:].astype(np.float32).reshape(1, -1, 2),
                                      gain=gain)[0]
            l_all.extend(int(v) for v in lab[:, 0])
            ab_all.extend([[float(a), float(b)] for a, b in lab[:, 1:]])
            bgr_all.extend([list(map(int, row)) for row in bgr])
        data[f'gain_{gain}'] = {'l': l_all, 'ab': ab_all, 'bgr': bgr_all}
    OUT.write_text(json.dumps(data), encoding='utf-8')
    n = len(data['gain_1.0']['l'])
    print(f'written {OUT} ({n} pixels x 2 gains)')


if __name__ == '__main__':
    main()
