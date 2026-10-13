"""生成色彩收尾 v2 与参考图迁移的跨语言金样: 桌面 service.py 的输出作为
Dart 端 `labToRgbFinish` / `transferReference` / `blendReferenceAuto` 的期望值,
锁死两端同一套数学。

用法: ..\\.venv\\Scripts\\python.exe tool/colorizer_service/gen_finish_golden.py
输出: packages/manga_colorizer_core/test/goldens/finish_golden.json
      packages/manga_colorizer_core/test/goldens/transfer_golden.json
      packages/manga_colorizer_core/test/goldens/reference_blend_golden.json

finish 样本: 每方案（FINISH_SCHEMES 全表 + flat + rescue）各 2 路 × 512 像素:
  rgb  — 随机 sRGB 原色经 cv2 RGB2LAB（色域内, 含边界量化噪声）;
  grid — L/a/b 全随机（大量真超域, 触发等比收缩与纸白中和路径）。
rescue 用例额外带确定性掩码（每第 3 个像素, 值 2 = whiteRescueMarks 的封闭
近白标记——纸白标记 1 不救援, 与桌面 `marks==2` 同语义）与生产门限参数
（c0=3.0/c1=5.0 窄门限, 随 JSON 下发）, 锁白色前景救援「整体跳过纸白中和 +
按色度压低 L」路径两端同数学。

transfer 样本: 确定性合成 原稿(大面积纸白+墨迹渐变) × 参考图(彩色渐变),
reinhard/histogram × strength {1.0, 0.6}。

reference_blend 样本: 同款原稿/参考图 + 确定性合成「模型输出」(auto)——
肤色(vivid=False)与高饱和蓝/橙(vivid=True, 暗部强色度触发色域映射分支),
reinhard/histogram 各一, 过桌面 `_blend_reference_auto` 真值; Dart 侧
transferReference + blendReferenceAuto 组合对拍。
"""
import json
import os
import sys
from pathlib import Path

import cv2
import numpy as np

os.environ['COLORIZER_PRELOAD'] = '0'
os.environ.pop('COLORIZER_CHROMA_GAIN', None)  # 金样必须用方案表默认值
sys.path.insert(0, str(Path(__file__).resolve().parent))
import service

GOLDENS = Path(__file__).resolve().parents[2] / 'packages' / 'manga_colorizer_core' / 'test' / 'goldens'


def sample(mode: str, n: int) -> np.ndarray:
    rng = np.random.default_rng(42 if mode == 'rgb' else 43)
    if mode == 'rgb':
        rgb = rng.integers(0, 256, (1, n, 3), dtype=np.uint8)
        return cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)[0]
    l = rng.integers(0, 256, n, dtype=np.uint8)
    a = rng.integers(0, 256, n, dtype=np.uint8)
    b = rng.integers(0, 256, n, dtype=np.uint8)
    return np.stack([l, a, b], axis=-1)


def gen_finish() -> None:
    data = {}
    cases = {name: service._resolve_finish(name) for name in service.FINISH_SCHEMES}
    cases['flat'] = dict(service._FLAT_FINISH)
    # 白色前景救援用例: 固定门限参数（生产窄门限 c0=3.0/c1=5.0 的代表值）
    # + 确定性掩码（每第 3 个像素, 值 2 = 封闭近白标记; 纸白标记 1 不救援）
    cases['rescue'] = dict(service._resolve_finish('standard'),
                           rescue_c0=3.0, rescue_c1=5.0, rescue_dl=16.0)
    for name, opt in cases.items():
        l_all, ab_all, bgr_all, mask_all = [], [], [], []
        for mode in ('rgb', 'grid'):
            lab = sample(mode, 512)
            mask = None
            call_opt = opt
            if name == 'rescue':
                mask = (np.arange(512) % 3 == 0).astype(np.uint8) * 2
                call_opt = dict(opt, rescue_mask=mask.reshape(1, -1).astype(bool))
            bgr = service._finish_bgr(lab[:, 0].reshape(1, -1),
                                      lab[:, 1:].astype(np.float32).reshape(1, -1, 2),
                                      call_opt)[0]
            l_all.extend(int(v) for v in lab[:, 0])
            ab_all.extend([[float(a), float(b)] for a, b in lab[:, 1:]])
            bgr_all.extend([list(map(int, row)) for row in bgr])
            if mask is not None:
                mask_all.extend(int(v) for v in mask)
        data[name] = {'l': l_all, 'ab': ab_all, 'bgr': bgr_all}
        if mask_all:
            data[name]['mask'] = mask_all
            data[name]['rescue_c0'] = opt['rescue_c0']
            data[name]['rescue_c1'] = opt['rescue_c1']
            data[name]['rescue_dl'] = opt['rescue_dl']
    out = GOLDENS / 'finish_golden.json'
    out.write_text(json.dumps(data), encoding='utf-8')
    print(f'written {out} ({len(cases)} schemes x 1024 pixels)')


def gen_transfer() -> None:
    # 原稿: 纸白 90% + 左上角墨迹渐变块（参与统计的非纸白像素 ~10%）
    src = np.full((64, 64, 3), 255, np.uint8)
    grad = np.linspace(20, 230, 20 * 24, dtype=np.float64).astype(np.uint8)
    src[4:24, 4:28, 0] = grad.reshape(20, 24)
    src[4:24, 4:28, 1] = grad.reshape(20, 24)
    src[4:24, 4:28, 2] = grad.reshape(20, 24)
    # 参考图: 16×16 全字节斜坡（R/G/B 各相位错开）——直方图规定化是阶跃映射,
    # CDF 若有平台/空洞, 输入端 ±1 的 Lab 转换差会让 LUT 跳档、输出跳几十个
    # 字节; 全覆盖斜坡的 CDF 无平台, 金样锁的是数学而不是转换噪声。
    ramp = np.arange(256, dtype=np.uint8).reshape(16, 16)
    ref = np.stack([ramp,
                    np.roll(ramp, 85),
                    np.roll(ramp, 171)], axis=-1)

    data = {}
    for method in ('reinhard', 'histogram'):
        for strength in (1.0, 0.6):
            out = service._reference_transfer(src, ref, method=method, strength=strength)
            key = f'{method}_{strength}'
            # 金样统一存 RGB（与 Dart 端字节序一致; service 内部是 BGR, 存前翻转）
            data[key] = {
                'src': src[..., ::-1].reshape(-1, 3).tolist(),
                'ref': ref[..., ::-1].reshape(-1, 3).tolist(),
                'out': out[..., ::-1].reshape(-1, 3).tolist(),
            }
    out_path = GOLDENS / 'transfer_golden.json'
    out_path.write_text(json.dumps(data), encoding='utf-8')
    print(f'written {out_path} ({len(data)} cases)')


def _synth_auto(src: np.ndarray, vivid: bool) -> np.ndarray:
    """确定性合成「模型输出」: 纸白留白, 墨迹渐变换成肤色(vivid=False)或
    高饱和蓝/橙(vivid=True——暗部强色度, 触发融合后色域映射的收缩分支)。"""
    auto = np.full_like(src, 255)
    block = src[4:24, 4:28, 0].astype(np.float64)
    if not vivid:
        auto[4:24, 4:28, 0] = np.clip(196 + block * 0.23, 0, 255)
        auto[4:24, 4:28, 1] = np.clip(150 + block * 0.31, 0, 255)
        auto[4:24, 4:28, 2] = np.clip(120 + block * 0.35, 0, 255)
    else:
        dark = block < 128
        auto[4:24, 4:28, 0] = np.where(dark, 20, 255)
        auto[4:24, 4:28, 1] = np.where(dark, 40, 120)
        auto[4:24, 4:28, 2] = np.where(dark, 180, 30)
    return auto.astype(np.uint8)


def gen_reference_blend() -> None:
    # 原稿/参考图与 gen_transfer 同款（灰度原稿 → L 与 Dart grayToLabL 逐值相等）
    src = np.full((64, 64, 3), 255, np.uint8)
    grad = np.linspace(20, 230, 20 * 24, dtype=np.float64).astype(np.uint8)
    src[4:24, 4:28, 0] = grad.reshape(20, 24)
    src[4:24, 4:28, 1] = grad.reshape(20, 24)
    src[4:24, 4:28, 2] = grad.reshape(20, 24)
    ramp = np.arange(256, dtype=np.uint8).reshape(16, 16)
    ref = np.stack([ramp,
                    np.roll(ramp, 85),
                    np.roll(ramp, 171)], axis=-1)

    data = {}
    for method in ('reinhard', 'histogram'):
        styled = service._reference_transfer(src, ref, method=method, strength=1.0)
        for vivid in (False, True):
            auto = _synth_auto(src, vivid)
            out = service._blend_reference_auto(auto, styled, src)
            key = f'{method}_{"vivid" if vivid else "skin"}'
            # 金样统一存 RGB（与 Dart 端字节序一致; service 内部是 BGR, 存前翻转）
            data[key] = {
                'src': src[..., ::-1].reshape(-1, 3).tolist(),
                'ref': ref[..., ::-1].reshape(-1, 3).tolist(),
                'auto': auto[..., ::-1].reshape(-1, 3).tolist(),
                'out': out[..., ::-1].reshape(-1, 3).tolist(),
            }
    out_path = GOLDENS / 'reference_blend_golden.json'
    out_path.write_text(json.dumps(data), encoding='utf-8')
    print(f'written {out_path} ({len(data)} cases)')


if __name__ == '__main__':
    GOLDENS.mkdir(parents=True, exist_ok=True)
    gen_finish()
    gen_transfer()
    gen_reference_blend()
