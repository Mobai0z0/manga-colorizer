#!/usr/bin/env python
"""MNN 转换脚本：把 v6 两个 ONNX 权重转成 .mnn 多档变体。

转换走 pymnn 3.6.1 的进程内入口 `_tools.mnnconvert`（不经 subprocess）。
pymnn 须先从 MNN 3.6.1 源码构建安装（PyPI mnn==2.9.6 太旧，禁用）：
    cd tmp/mnn-src/pymnn/pip_package && pip install . --no-build-isolation

用法：
    .venv/Scripts/python.exe tool/mnn/convert_models.py \
        --models-dir models/manga-light-colorizer --variants fp32 fp16 w8

输出：<models-dir>/v6_<name>.<variant>.mnn 与 <models-dir>/mnn-manifest.json
（清单含每档 name/stem/variant/size/sha256，供桌面 weights-manifest.json 与
移动端 kMnnWeightFiles 填值）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

# encoder 先转：ViT+Conv 混合图是转换器覆盖度的最大风险，失败早停。
MODEL_STEMS = ["v6_sam_encoder", "v6_generator"]

# 转换源：优先用 fix_encoder_graph.py 产出的修复图（If 内联 + pads 常量化 +
# InstanceNorm 分解，Stage 0 实测三处都是 MNN 数值漂移根因），缺省回退原 ONNX。
def source_for(models_dir: Path, stem: str) -> Path:
    fix = models_dir / f"{stem}.fix.onnx"
    return fix if fix.is_file() else models_dir / f"{stem}.onnx"

VARIANTS: dict[str, list[str]] = {
    "fp32": [],
    "fp16": ["--fp16"],
    "w8": ["--weightQuantBits", "8"],
}
# Stage 0 对拍结论：仅 fp32 过门（真实样张 99.896% ≤1 / max 3）；fp16 权重存储
# 使 GAN 型 generator 漂移至 max 17，w8 max 119，均不采用。默认只转 fp32。
DEFAULT_VARIANTS = ["fp32"]


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def convert_one(argv: list[str]) -> None:
    # 进程内转换：_tools 是 pymnn wheel 自带的 C 扩展，接受 argv 风格列表并
    # 自行解析；转换失败时以异常/非零路径抛出。
    import _tools

    print(f"[convert] mnnconvert {' '.join(argv[1:])}")
    _tools.mnnconvert(argv)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models-dir", required=True, type=Path)
    ap.add_argument("--variants", nargs="+", default=DEFAULT_VARIANTS,
                    choices=sorted(VARIANTS))
    args = ap.parse_args()

    try:
        import _tools  # noqa: F401  探测 pymnn 是否已构建安装
    except ImportError:
        print("未找到 _tools（pymnn wheel）：请先从 MNN 3.6.1 源码构建安装 pymnn，"
              "见文件头注释。PyPI 的 mnn==2.9.6 不可用。", file=sys.stderr)
        return 2

    models_dir = args.models_dir
    if not models_dir.is_dir():
        print(f"模型目录不存在: {models_dir}", file=sys.stderr)
        return 2

    manifest: dict = {"schemaVersion": 1, "mnnVersion": "3.6.1", "files": {}}
    for stem in MODEL_STEMS:
        onnx_path = source_for(models_dir, stem)
        if not onnx_path.is_file():
            print(f"缺少模型: {onnx_path}", file=sys.stderr)
            return 2
        print(f"[source] {stem} <- {onnx_path.name}")
        for variant in args.variants:
            out_path = models_dir / f"{stem}.{variant}.mnn"
            extra = VARIANTS[variant]
            convert_one([
                "mnnconvert", "-f", "ONNX",
                "--modelFile", str(onnx_path),
                "--MNNModel", str(out_path),
                "--bizCode", "manga",
                *extra,
            ])
            if not out_path.is_file():
                print(f"转换后未产出文件: {out_path}", file=sys.stderr)
                return 1
            print(f"[convert] OK -> {out_path.name} ({out_path.stat().st_size:,} B)")
            manifest["files"][out_path.name] = {
                "stem": stem,
                "variant": variant,
                "size": out_path.stat().st_size,
                "sha256": sha256_of(out_path),
            }

    manifest_path = models_dir / "mnn-manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2),
                             encoding="utf-8")
    print(f"[manifest] {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
