"""Sana-manga-coloring ONNX int8 引擎（2026-11-22 模型迁移主线）。

来源: https://huggingface.co/masterofaudio2077/sana-manga-coloring-onnx-int8
(Apache-2.0; 基座 NVlabs/SANA 600M i2i, 漫画上色微调)。推理逻辑移植自其
run_onnx.py（纯 onnxruntime+numpy, 无 PyTorch; FlowMatchEuler 调度器 20 步,
CFG=2.0）。与 v6 GAN 的关键差异:
  · 整页 i2i（短边 512、两边 32 倍数），无分块；
  · 输出是完整上色图（自带明度与手涂质感），不再做「取色度+原稿 L 回写」；
  · 语义条件是闭集五维标签（mood/time_of_day/lighting/saturation/palette），
    代替 v6 那条失败的 wd14 FiLM 通路（2026-11-21/22 两轮取证：自举在典型
    漫画页黄绿泛染，α 阻尼/白平衡均无效，已回退默认）；
  · CPU int8 20 步 ≈ 70s/页（4 线程, 512×736）; cache=0.15 首块步缓存
    ≈1.6x 提速; DirectML fp16 转换是后续性能主线。
内存: arena/mem_pattern 关闭（页面尺寸变化时 ORT 内存计划会逐页累积——
run_onnx.py 原注释），权重 ~2.7GB 常驻由 service 的空闲卸载统一管理。
"""
from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import onnxruntime as ort

# 闭集标签词表（模型训练分布, 顺序即五维 id 顺序; 0 = "<null>" 让模型自选）。
TAGS: dict[str, list[str]] = {
    "mood": ["calm", "tense", "horror", "sad", "action", "comedic", "romantic",
             "nostalgic", "mysterious", "cheerful", "melancholic", "dramatic"],
    "time_of_day": ["morning", "dawn", "day", "evening", "night"],
    "lighting": ["soft diffuse", "golden warm", "neutral", "strong contrast",
                 "flat gray-blue", "golden orange", "warm orange-yellow",
                 "cool blue", "cool silver", "pale harsh", "magenta-cyan"],
    "saturation": ["muted", "moderate", "vivid"],
    "palette": [
        "cold blue-gray with a touch of dull red", "warm amber and brown",
        "soft pastel pinks and blues", "soft pastel pink and light blue",
        "deep teal and orange", "green and earthy brown", "green and brown",
        "purple and midnight blue", "purple and dark navy",
        "bright primary colors", "bright red, blue and yellow",
        "sepia and cream", "sepia brown and cream", "crimson and black",
        "crimson red and black", "fresh spring greens and sky blue",
        "light green and light blue",
    ],
}
SHORT_SIDE, SNAP = 512, 32

# 色彩方案 → tag 预设（与 FINISH_SCHEMES 同名的观感对应, 仅 sana 引擎消费;
# None = "<null>" 让模型自选）。取证: null 档偏 sepia 低调, vivid 标签在
# 用户样张上得到明亮教室氛围且无伪影（2026-11-22 tmp/sana_p0008*.png）。
SANA_SCHEMES: dict[str, dict[str, str | None]] = {
    'standard': {},
    'vivid-cel': {'saturation': 'vivid', 'palette': 'bright primary colors',
                  'mood': 'cheerful'},
    'soft-pastel': {'saturation': 'muted',
                    'palette': 'soft pastel pinks and blues'},
    'impasto': {'saturation': 'vivid', 'lighting': 'strong contrast'},
    'retro-showa': {'mood': 'nostalgic', 'palette': 'sepia and cream',
                    'time_of_day': 'evening'},
}


def tag_ids(tags: dict[str, str | None]) -> np.ndarray:
    ids = []
    for field, values in TAGS.items():
        value = tags.get(field)
        if value and value != "<null>":
            ids.append(values.index(value) + 1)
        else:
            ids.append(0)
    return np.array([ids], dtype=np.int64)


def prepare_page(gray: np.ndarray) -> np.ndarray:
    """灰度 uint8 [H,W] → 短边 512、两边 32 倍数 → (1,3,H,W) float32 [-1,1]。
    （cv2.INTER_AREA 替代官方 demo 的 PIL BILINEAR, 下采样族更优。）"""
    h, w = gray.shape
    scale = SHORT_SIDE / min(h, w)
    th = max(SNAP, round(h * scale / SNAP) * SNAP)
    tw = max(SNAP, round(w * scale / SNAP) * SNAP)
    x = cv2_resize_gray(gray, tw, th).astype(np.float32) / 255.0
    return ((x - 0.5) / 0.5)[None, None].repeat(3, axis=1)


def cv2_resize_gray(gray: np.ndarray, tw: int, th: int) -> np.ndarray:
    import cv2
    return cv2.resize(gray, (tw, th), interpolation=cv2.INTER_AREA)


def sigmas(steps: int, shift: float) -> np.ndarray:
    """diffusers FlowMatchEulerDiscreteScheduler(shift).set_timesteps 的噪声
    序列 + 末位 0（移植 run_onnx.py）。"""
    shifted = lambda s: shift * s / (1 + (shift - 1) * s)  # noqa: E731
    return np.append(shifted(np.linspace(1.0, shifted(1 / 1000), steps)),
                     0.0).astype(np.float32)


class SanaColorizer:
    """五个 session（encode/decode/head/blocks/out）。head+blocks+out 三段
    拆分是为了首块步缓存跳过 blocks（≈1.6x）。所有 run 的会话级 arena 关闭
    （页面尺寸变化时 ORT 的 shape 内存计划会逐页累积——run_onnx.py 原注释）。
    """

    def __init__(self, model_dir: str | Path, threads: int = 4):
        opts = ort.SessionOptions()
        opts.enable_cpu_mem_arena = False
        opts.enable_mem_pattern = False
        opts.intra_op_num_threads = threads
        d = str(model_dir)
        load = lambda name: ort.InferenceSession(  # noqa: E731
            os.path.join(d, name), opts, providers=['CPUExecutionProvider'])
        self.encode = load('encode.onnx')
        self.decode = load('decode.onnx')
        self.head = load('head.onnx')
        self.blocks = load('blocks.onnx')
        self.out = load('out.onnx')

    def __call__(self, bw: np.ndarray, tags: dict[str, str | None],
                 steps: int = 20, cfg: float = 2.0, shift: float = 3.0,
                 ink: float = 1.0, cache: float = 0.0,
                 noise: np.ndarray | None = None,
                 on_step=None, cancelled=None) -> np.ndarray | None:
        """bw: prepare_page 产物。返回 (1,3,H,W) RGB [0,1]；取消返回 None。
        noise 由调用方给（固定种子可复现; 缺省用安全随机）。"""
        cond = tag_ids(tags)
        uncond = np.zeros_like(cond)
        z_bw, feat = self.encode.run(None, {'bw': bw})
        z_bw2 = np.concatenate([z_bw, z_bw])
        feat2 = np.concatenate([feat, feat])
        ids = np.concatenate([cond, uncond])
        rng = np.random.default_rng(20261122 if noise is None else None)
        if noise is None:
            noise = rng.standard_normal((1, 32, bw.shape[2] // 32,
                                         bw.shape[3] // 32)).astype(np.float32)
        z = noise.astype(np.float32)
        s = sigmas(steps, shift)
        last_r0 = tail = None
        in_a_row = 0
        for i in range(steps):
            if cancelled and cancelled():
                return None
            t = np.full(2, s[i] * 1000, dtype=np.float32)
            h0, r0, enc, temb, emb_t = self.head.run(
                None, {'z_t': np.concatenate([z, z]), 'z_bw': z_bw2,
                       'feat': feat2, 't': t, 'tag_ids': ids})
            skip = bool(cache) and tail is not None and in_a_row < 2 and (
                np.abs(r0 - last_r0).mean()
                / max(np.abs(last_r0).mean(), 1e-8) < cache)
            if skip:
                hn, in_a_row = h0 + tail, in_a_row + 1
            else:
                (hn,) = self.blocks.run(None, {'h0': h0, 'feat': feat2,
                                               'enc': enc, 'temb': temb})
                last_r0, tail, in_a_row = r0, hn - h0, 0
            (v,) = self.out.run(None, {'hn': hn, 'emb_t': emb_t,
                                       'feat': feat2})
            vc, vu = v[:1], v[1:]
            z = z + (s[i + 1] - s[i]) * (vu + cfg * (vc - vu))
            if on_step:
                on_step(i + 1, steps)
        if cancelled and cancelled():
            return None
        (rgb,) = self.decode.run(None, {'z': z, 'bw': bw,
                                        'ink': np.array([ink],
                                                        dtype=np.float32)})
        return rgb
