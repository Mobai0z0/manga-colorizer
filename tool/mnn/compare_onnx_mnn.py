#!/usr/bin/env python
"""模型级数值对拍：同一输入分别喂 ONNX Runtime 与 MNN，比对输出张量。

三路对拍（先固定灰度样张，预处理与端侧契约一致：v/127.5-1 进，clip((y+1)*127.5) 出）：
  A. SAM encoder：ORT vs MNN 的 sam_level0/sam_level1（形状/余弦/相对误差）
  B. cross：ORT 的特征喂 MNN generator，对照 ORT 端到端 rgb_pred（隔离 generator 误差）
  C. 端到端：MNN encoder → MNN generator vs ORT 端到端（移动端用户实际拿到的误差）

用法：
    .venv/Scripts/python.exe tool/mnn/compare_onnx_mnn.py \
        --models-dir models/manga-light-colorizer --variants fp32 fp16 w8 [--gate]

通过门（--gate 时非零退出；阈值按 --max-rgb/--min-pct/--min-cos 调整）：
  rgb_pred 转 uint8 后 |diff|≤1 的像素占比 ≥ min-pct，max ≤ max-rgb；
  特征余弦相似度 ≥ min-cos。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

REPO = Path(__file__).resolve().parents[2]

MODEL_STEMS = ["v6_sam_encoder", "v6_generator"]
# 三个固定合成样张（确定性）+ 一个真实样张（mobile/assets/sample_bw.png）。


def make_inputs(s: int) -> list[tuple[str, np.ndarray]]:
    """返回 [(说明, 灰度 uint8 HxW)]，确定性可复现。"""
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32)
    g1 = (xx / s * 255.0).astype(np.uint8)
    g2 = ((np.sin(xx / 17.0) * 0.5 + 0.5) * 255).astype(np.uint8)
    g3 = np.where(((xx // 64 + yy // 64) % 2) == 0, 30, 220).astype(np.uint8)
    g3[yy > xx] = 128
    inputs = [("synthetic-ramp", g1), ("synthetic-sine", g2), ("synthetic-blocks", g3)]
    sample = REPO / "mobile" / "assets" / "sample_bw.png"
    if sample.is_file():
        img = cv2.imread(str(sample), cv2.IMREAD_GRAYSCALE)
        if img is not None:
            img = cv2.resize(img, (s, s), interpolation=cv2.INTER_AREA)
            inputs.append(("sample_bw.png", img))
    return inputs


def norm_chw(gray_u8: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """灰度 → (sam 输入 [1,3,S,S] CHW, L_bw [1,1,S,S] CHW)，v/127.5-1。"""
    g = gray_u8.astype(np.float32) / 127.5 - 1.0
    s = g.shape[0]
    sam = np.stack([g, g, g])[None]          # [1,3,S,S]
    lbw = g[None, None]                       # [1,1,S,S]
    return sam.astype(np.float32), lbw.astype(np.float32)


def denorm_u8(y: np.ndarray) -> np.ndarray:
    """模型输出浮点 → uint8（clip((y+1)*127.5)，四舍五入）。y 形状 [1,3,S,S]。"""
    return np.clip((y + 1.0) * 127.5, 0, 255).round().astype(np.int16)[0]


def ort_pair(models_dir: Path):
    enc = ort.InferenceSession(str(models_dir / "v6_sam_encoder.onnx"),
                               providers=["CPUExecutionProvider"])
    gen = ort.InferenceSession(str(models_dir / "v6_generator.onnx"),
                               providers=["CPUExecutionProvider"])
    return enc, gen


def run_ort(enc, gen, sam_in, lbw, wd14):
    out_names = {o.name for o in enc.get_outputs()}
    f0n = "sam_level0" if "sam_level0" in out_names else enc.get_outputs()[0].name
    f1n = "sam_level1" if "sam_level1" in out_names else enc.get_outputs()[1].name
    f0, f1 = enc.run([f0n, f1n], {enc.get_inputs()[0].name: sam_in})
    rgb = gen.run(None, {
        "L_bw": lbw,
        f0n: f0,
        f1n: f1,
        "wd14_embedding": wd14,
    })[0]
    return {f0n: f0, f1n: f1}, rgb


class MnnPair:
    """MNN encoder/generator 双 module。host 张量一律 NCHW placeholder，
    喂前 convert 到 NC4HW4（官方 demo 模式，规避内部布局差异）。"""

    def __init__(self, models_dir: Path, variant: str, thread_num: int = 4):
        import MNN
        import MNN.expr as F
        self._MNN, self._F = MNN, F
        mem = {"fp32": F.MemoryMode.Normal, "fp16": F.MemoryMode.Normal,
               "w8": F.MemoryMode.Low}[variant]
        # 精度模式一律 Normal：fp16 只是权重存储减半（加载时反量化回 fp32 计算），
        # Low 会在 x86 上启用 BF16 计算路径，误差来源就混进计算精度了。
        pre = F.PrecisionMode.Normal
        # shape_mutable 必须为 True：False（load 期预分配）在 Windows x86 对本
        # 子图模型触发 MNN 内部整数除零崩溃（threads 无关）。Android FFI 层用
        # C++ API 自行控制，不受此 Python 绑定路径影响。
        common = dict(backend=F.Backend.CPU, memory_mode=mem, precision_mode=pre,
                      thread_num=thread_num, shape_mutable=True)
        self.enc = MNN.nn.load_module_from_file(
            str(models_dir / f"v6_sam_encoder.{variant}.mnn"),
            ["rgb_input"], ["sam_level0", "sam_level1"], **common)
        self.gen = MNN.nn.load_module_from_file(
            str(models_dir / f"v6_generator.{variant}.mnn"),
            ["L_bw", "sam_level0", "sam_level1", "wd14_embedding"],
            ["rgb_pred"], **common)

    def _feed(self, arr: np.ndarray, nc4hw4: bool):
        F = self._F
        var = F.placeholder(list(arr.shape), F.NCHW)
        var.write(np.ascontiguousarray(arr, dtype=np.float32))
        return F.convert(var, F.NC4HW4) if nc4hw4 else var

    @staticmethod
    def _take(outs, i: int) -> np.ndarray:
        return outs[i].read()

    def run_enc(self, sam_in: np.ndarray):
        F = self._F
        outs = self.enc.forward([self._feed(sam_in, nc4hw4=True)])
        f0 = F.convert(outs[0], F.NCHW).read()
        f1 = F.convert(outs[1], F.NCHW).read()
        return [f0, f1]

    def run_gen(self, lbw: np.ndarray, feats: list[np.ndarray], wd14: np.ndarray):
        F = self._F
        feeds = [self._feed(lbw, nc4hw4=True),
                 self._feed(feats[0], nc4hw4=True),
                 self._feed(feats[1], nc4hw4=True),
                 self._feed(wd14, nc4hw4=False)]
        out = self.gen.forward(feeds)[0]
        return F.convert(out, F.NCHW).read()


def feat_metrics(a: np.ndarray, b: np.ndarray) -> dict:
    a64, b64 = a.astype(np.float64).ravel(), b.astype(np.float64).ravel()
    if a64.shape != b64.shape:
        return {"shape_mismatch": [list(a.shape), list(b.shape)]}
    d = np.abs(a64 - b64)
    denom = np.maximum(np.abs(a64).max(), 1e-9)
    cos = float(a64 @ b64 / (np.linalg.norm(a64) * np.linalg.norm(b64) + 1e-30))
    return {"shape": list(a.shape), "max_abs": float(d.max()),
            "mean_abs": float(d.mean()),
            "rel_err_max": float(d.max() / denom), "cos": cos}


def rgb_metrics(y_ort: np.ndarray, y_mnn: np.ndarray) -> dict:
    uo, um = denorm_u8(y_ort), denorm_u8(y_mnn)
    if uo.shape != um.shape:
        return {"shape_mismatch": [list(uo.shape), list(um.shape)]}
    d = np.abs(uo.astype(np.int32) - um.astype(np.int32))
    return {"pct_le1": float((d <= 1).mean() * 100), "pct_le2": float((d <= 2).mean() * 100),
            "max": int(d.max()), "mean": float(d.mean())}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models-dir", required=True, type=Path)
    ap.add_argument("--variants", nargs="+", default=["fp32", "fp16", "w8"])
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--gate", action="store_true", help="达标判定：失败非零退出")
    ap.add_argument("--min-pct", type=float, default=99.8,
                    help="rgb uint8 |diff|≤1 像素占比门限；fp32 实测真实样张 "
                         "99.896%%（残差=后端累加顺序噪声），99.9 过严")
    ap.add_argument("--max-rgb", type=int, default=3,
                    help="rgb uint8 最大 |diff| 门限；fp32 实测真实样张 max=3")
    ap.add_argument("--min-cos", type=float, default=0.999)
    ap.add_argument("--dump-dir", type=Path, default=None,
                    help="另存各变体输出 npz（供端侧回归夹具）")
    args = ap.parse_args()

    enc_ort, gen_ort = ort_pair(args.models_dir)
    s_in = enc_ort.get_inputs()[0].shape
    s = int(s_in[2])
    assert s_in[1] == 3 and s_in[2] == s_in[3], f"非预期 encoder 输入形状 {s_in}"
    wd14 = np.zeros((1, 1024), dtype=np.float32)
    samples = make_inputs(s)
    print(f"[setup] encoder 输入 S={s}，样张 {len(samples)} 张")

    report: dict = {}
    for variant in args.variants:
        mnn = MnnPair(args.models_dir, variant, args.threads)
        per_sample = []
        for name, gray in samples:
            sam_in, lbw = norm_chw(gray)
            feats_ort, rgb_ort = run_ort(enc_ort, gen_ort, sam_in, lbw, wd14)
            feats_mnn = mnn.run_enc(sam_in)
            rgb_mnn_e2e = mnn.run_gen(lbw, feats_mnn, wd14)
            rgb_mnn_cross = mnn.run_gen(lbw, list(feats_ort.values()), wd14)
            entry = {
                "encoder": {
                    "sam_level0": feat_metrics(feats_ort["sam_level0"], feats_mnn[0]),
                    "sam_level1": feat_metrics(feats_ort["sam_level1"], feats_mnn[1]),
                },
                "generator_cross": rgb_metrics(rgb_ort, rgb_mnn_cross),
                "e2e": rgb_metrics(rgb_ort, rgb_mnn_e2e),
            }
            per_sample.append({name: entry})
            print(f"[{variant}] {name}: "
                  f"e2e pct≤1={entry['e2e']['pct_le1']:.3f}% max={entry['e2e']['max']} "
                  f"cross max={entry['generator_cross'].get('max')} "
                  f"cos0={entry['encoder']['sam_level0'].get('cos', -1):.6f}")
            if args.dump_dir:
                args.dump_dir.mkdir(parents=True, exist_ok=True)
                np.savez_compressed(
                    args.dump_dir / f"{variant}_{name}.npz",
                    gray=gray,
                    rgb_ort=denorm_u8(rgb_ort),
                    rgb_mnn=denorm_u8(rgb_mnn_e2e))
        report[variant] = per_sample

    if args.gate:
        failed = []
        for variant, per_sample in report.items():
            for entry in per_sample:
                (name, e), = entry.items()
                e2e, enc = e["e2e"], e["encoder"]
                if "shape_mismatch" in e2e:
                    failed.append(f"{variant}/{name}: 输出形状不一致 {e2e['shape_mismatch']}")
                    continue
                if e2e["pct_le1"] < args.min_pct or e2e["max"] > args.max_rgb:
                    failed.append(f"{variant}/{name}: e2e rgb pct≤1={e2e['pct_le1']:.3f}% "
                                  f"max={e2e['max']}（门 {args.min_pct}%/{args.max_rgb}）")
                for lvl, m in enc.items():
                    if "shape_mismatch" in m:
                        failed.append(f"{variant}/{name}: {lvl} 形状不一致 {m['shape_mismatch']}")
                    elif m["cos"] < args.min_cos:
                        failed.append(f"{variant}/{name}: {lvl} cos={m['cos']:.6f} < {args.min_cos}")
        if failed:
            print("== 不达标 ==")
            for line in failed:
                print(" -", line)
            return 1
        print(f"== 通过门 OK（rgb pct≤1≥{args.min_pct}% & max≤{args.max_rgb}；"
              f"cos≥{args.min_cos}）==")
        (args.models_dir / "mnn-compare-report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
