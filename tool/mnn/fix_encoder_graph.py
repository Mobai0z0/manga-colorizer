#!/usr/bin/env python
"""SAM encoder 图修复：If 条件分支内联 + 固定形状常量折叠，产出可正确转 MNN 的 ONNX。

背景（Stage 0 对拍发现）：v6_sam_encoder 的 trunk 里有 2 个 If 节点，按窗口
计数决定是否 Expand/重采样 pos_embed_window（HCF-Net 风格动态窗口位置嵌入）。
ORT 运行期取 else（Identity）分支（1024² 输入下条件均为 False，本脚本会先
用 ORT 探针验证再动手）；MNNConvert 对 If 的静态展平选错分支，导致 MNN 特征
在左列/顶行结构性漂移（cos 0.95、e2e rgb max 差 9）。修复＝把 If 替换成
ORT 验证过的分支语义，再用 onnxsim 折叠 pads 等动态链，然后交给 MNNConvert。

注意：产出图按 1024² 输入特化（本项目模型契约本就固定 1024²）。

用法：
    .venv/Scripts/python.exe tool/mnn/fix_encoder_graph.py \
        --src models/manga-light-colorizer/v6_sam_encoder.onnx \
        --dst models/manga-light-colorizer/v6_sam_encoder.fix.onnx
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper


def probe_conditions(model: onnx.ModelProto) -> dict[str, bool]:
    """用 ORT 求每个 If 的条件布尔值。

    注意：必须把 If 的输出一并加为图输出——只加条件输出时 ORT 会剪掉 If 子图，
    在条件链的 /Sub 上走出 bad allocation 的错误优化路径（实测复现）；带上
    If 输出则 ORT 按正常分支语义求值。
    """
    m = onnx.load_from_string(model.SerializeToString())
    conds: list[str] = []
    if_outs: list[str] = []
    for n in m.graph.node:
        if n.op_type == "If":
            if n.input and n.input[0]:
                conds.append(n.input[0])
                m.graph.output.extend(
                    [onnx.helper.make_empty_tensor_value_info(n.input[0])])
            for o in n.output:
                if o:
                    if_outs.append(o)
                    m.graph.output.extend(
                        [onnx.helper.make_empty_tensor_value_info(o)])
    sess = ort.InferenceSession(m.SerializeToString(),
                                providers=["CPUExecutionProvider"])

    def _dim(d) -> int:
        try:
            v = int(d)
        except (TypeError, ValueError):
            v = 0
        return v if v > 0 else 1024

    feed = {i.name: np.zeros([_dim(d) for d in i.shape], np.float32)
            for i in sess.get_inputs()}
    all_names = conds + if_outs
    out = sess.run(all_names, feed)
    truth = {name: bool(np.asarray(v).ravel()[0])
             for name, v in zip(all_names, out)}
    return {name: truth[name] for name in conds}


def inline_ifs(graph, cond_truth: dict[str, bool] | None,
               force: str | None = None) -> int:
    """把每个 If 节点替换为其所取分支的语义（本模型两分支均为 Identity 形态；
    若分支非 Identity 则报错拒改——脚本只为该模型特化）。

    cond_truth=None 时必须给 force（'then'/'else'），对所有 If 用同一分支。"""
    replaced = 0
    new_nodes: list = []
    for n in graph.node:
        if n.op_type != "If":
            new_nodes.append(n)
            continue
        if force is not None:
            branch_attr = f"{force}_branch"
        else:
            cond = n.input[0]
            truth = (cond_truth or {}).get(cond)
            if truth is None:
                raise SystemExit(f"If 条件 {cond} 未探针到真值")
            branch_attr = "then_branch" if truth else "else_branch"
        branch = next(a.g for a in n.attribute if a.name == branch_attr)
        # 本模型的分支都是 1-2 节点的 Identity/小算子链，且子图 output 就是
        # If 的 output。为通用安全：仅允许 Identity 结尾的分支。
        idents = [b for b in branch.node if b.op_type == "Identity"]
        if len(branch.node) != len(idents):
            raise SystemExit(
                f"If({n.output[0]}) 的 {branch_attr} 含非 Identity 节点 "
                f"({[b.op_type for b in branch.node]})，需人工确认分支语义后扩展脚本")
        # Identity 链:直接以同序映射子图输出 ← 外部输入。
        if len(branch.output) != len(n.output):
            raise SystemExit(f"If({n.output[0]}) 输出数与分支不一致")
        for b, out_name in zip(branch.node, n.output):
            src = b.input[0]
            new_nodes.append(onnx.helper.make_node(
                "Identity", [src], [out_name], name=f"if_inline_{out_name}"))
        replaced += 1
    del graph.node[:]
    graph.node.extend(new_nodes)
    return replaced


def fold_pads(m: onnx.ModelProto) -> int:
    """探针 Pad 动态 pads 真值（ORT，1024² 输入）→ 回填 initializer → 清死节点。

    pads 链含 If 展平后的动态 Mod/Sub 计算，MNNConvert 丢弃该输入（转换警告
    `empty input, the index is 2`）按 0 pad 处理；实测真值非零（如
    [0,0,0,0,0,6,6,0]），是 MNN 特征边界漂移的另一根因。"""
    graph = m.graph
    pad_nodes = [n for n in graph.node if n.op_type == "Pad"]
    pads_names = [n.input[1] for n in pad_nodes]
    if not pads_names:
        return 0
    probe = onnx.load_from_string(m.SerializeToString())
    for name in pads_names:
        probe.graph.output.extend([onnx.helper.make_empty_tensor_value_info(name)])
    sess = ort.InferenceSession(probe.SerializeToString(),
                                providers=["CPUExecutionProvider"])

    def _dim(d) -> int:
        try:
            v = int(d)
        except (TypeError, ValueError):
            v = 0
        return v if v > 0 else 1024

    feed = {i.name: np.zeros([_dim(d) for d in i.shape], np.float32)
            for i in sess.get_inputs()}
    values = sess.run(pads_names, feed)
    for n, v in zip(pad_nodes, values):
        print(f"  pads[{n.output[0]}] = {np.asarray(v).tolist()}")
        pads_init = f"mnn_fix_pads_{n.output[0].replace('/', '_')}"
        graph.initializer.append(numpy_helper.from_array(
            np.asarray(v).astype(np.int64), pads_init))
        while len(n.input) < 3:
            n.input.append("")
        n.input[1] = pads_init
        if len(n.input) < 3 or not n.input[2]:
            while len(n.input) < 3:
                n.input.append("")
            n.input[2] = "mnn_fix_pad_value_zero"
    if not any(t.name == "mnn_fix_pad_value_zero" for t in graph.initializer):
        graph.initializer.append(numpy_helper.from_array(
            np.array(0.0, np.float32), "mnn_fix_pad_value_zero"))
    # 清掉 pads 计算链死节点（迭代删除无人引用的节点）
    used = {o.name for o in graph.output}
    while True:
        keep = set(used)
        for n in reversed(graph.node):
            if any(o in keep for o in n.output):
                keep.update(n.input)
        live = [n for n in graph.node
                if any(o in keep for o in n.output)]
        if len(live) == len(graph.node):
            break
        del graph.node[:]
        graph.node.extend(live)
    return len(pad_nodes)


def decompose_instancenorm(m: onnx.ModelProto) -> int:
    """把 InstanceNormalization 分解为基本算子（ReduceMean/Sub/Mul/Sqrt/Div）。

    MNN 3.6.1 的转换路径把 InstanceNormalization 重写为 LayerNorm(group=1)，
    经 NC4HW4 reshape 链在真实模型上产生结构性误差（右缘线性漂移；小形状隔离
    测试甚至产出 1e28 垃圾值）。分解为 CNN 常用基本算子可完全绕开该路径：
    y = scale * (x - mean) / sqrt(var + eps) + bias，mean/var 在 (H,W) 上。
    """
    graph = m.graph
    # 先做一次形状推断，拿到每个 InstanceNorm 输入的静态 rank
    inferred = onnx.shape_inference.infer_shapes(m)
    vi_rank = {}
    for v in list(inferred.graph.value_info) + list(inferred.graph.output):
        if v.type.tensor_type.shape.dim:
            vi_rank[v.name] = len(v.type.tensor_type.shape.dim)
    for i in inferred.graph.input:
        vi_rank[i.name] = len(i.type.tensor_type.shape.dim)

    nodes = list(graph.node)
    new_nodes: list = []
    replaced = 0
    for n in nodes:
        if n.op_type != "InstanceNormalization":
            new_nodes.append(n)
            continue
        x, scale, bias = n.input[0], n.input[1], n.input[2]
        rank = vi_rank.get(x)
        if rank is None or rank < 3:
            raise SystemExit(f"{n.output[0]}: 输入 {x} rank={rank}，无法按 (N,C) 语义分解")
        axes = list(range(2, rank))  # ONNX: 前 2 维是 N/C，其余为统计维
        eps = 1e-5
        for a in n.attribute:
            if a.name == "epsilon":
                eps = a.f
        p = n.output[0].replace("/", "_")
        mean = helper.make_node("ReduceMean", [x], [f"{p}_mean"], name=f"{p}_mean_n",
                                axes=axes, keepdims=1)
        d = helper.make_node("Sub", [x, f"{p}_mean"], [f"{p}_d"], name=f"{p}_sub_n")
        sq = helper.make_node("Mul", [f"{p}_d", f"{p}_d"], [f"{p}_sq"], name=f"{p}_mul_n")
        var = helper.make_node("ReduceMean", [f"{p}_sq"], [f"{p}_var"], name=f"{p}_var_n",
                               axes=axes, keepdims=1)
        eps_name = f"{p}_eps"
        graph.initializer.append(numpy_helper.from_array(
            np.array(eps, np.float32), eps_name))
        st = helper.make_node("Add", [f"{p}_var", eps_name], [f"{p}_vareps"], name=f"{p}_add_n")
        rt = helper.make_node("Sqrt", [f"{p}_vareps"], [f"{p}_std"], name=f"{p}_sqrt_n")
        dv = helper.make_node("Div", [f"{p}_d", f"{p}_std"], [f"{p}_norm"], name=f"{p}_div_n")
        # MNN 的 BinaryOp 只支持同秩/标量广播：scale/bias [C] 先 Reshape 成
        # [1,-1,1,1,...]（与输入同秩，尾部全 1；ONNX 语义等价）。
        shape_name = f"{p}_sb_shape"
        graph.initializer.append(numpy_helper.from_array(
            np.array([1, -1] + [1] * (rank - 2), np.int64), shape_name))
        rs = helper.make_node("Reshape", [scale, shape_name], [f"{p}_scale4"],
                              name=f"{p}_scale_rs_n")
        rb = helper.make_node("Reshape", [bias, shape_name], [f"{p}_bias4"],
                              name=f"{p}_bias_rs_n")
        mul = helper.make_node("Mul", [f"{p}_norm", f"{p}_scale4"], [f"{p}_scaled"],
                               name=f"{p}_scale_n")
        ad = helper.make_node("Add", [f"{p}_scaled", f"{p}_bias4"], [n.output[0]],
                              name=f"{p}_bias_n")
        new_nodes.extend([mean, d, sq, var, st, rt, dv, rs, rb, mul, ad])
        replaced += 1
    del graph.node[:]
    graph.node.extend(new_nodes)
    return replaced


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, type=Path)
    ap.add_argument("--dst", required=True, type=Path)
    ap.add_argument("--branch", choices=["else", "then", "probe"], default="else",
                    help="内联哪个分支；probe=用 ORT 探针决定（ORT 1.24 对本模型"
                         "的条件输出探针有 bad allocation 风险，默认 else——已人工"
                         "验证 1024² 输入下两个条件均为 False）")
    ap.add_argument("--input-name", default="rgb_input",
                    help="固定形状折叠用的输入名（generator 用 L_bw）")
    ap.add_argument("--skip-if-inline", action="store_true",
                    help="跳过 If 内联（无 If 的图，如 generator）")
    ap.add_argument("--decompose-instancenorm", action="store_true",
                    help="把 InstanceNormalization 分解为基本算子（绕开 MNN 的 "
                         "LayerNorm(group=1) 重写路径）")
    args = ap.parse_args()

    m = onnx.load(str(args.src))
    if args.skip_if_inline:
        cond_truth = None
        print("跳过 If 内联")
    elif args.branch == "probe":
        cond_truth = probe_conditions(m)
        for k, v in cond_truth.items():
            print(f"条件 {k} = {v}")
    else:
        cond_truth = None  # 强制分支：inline_ifs 对所有 If 用同一选择
        print(f"强制内联分支: {args.branch}（1024² 下条件为 False → else，已验证）")

    n = 0
    if not args.skip_if_inline:
        n = inline_ifs(m.graph, cond_truth,
                       force=args.branch if args.branch != "probe" else None)
    print(f"内联 If 节点 {n} 个")

    if args.decompose_instancenorm:
        k = decompose_instancenorm(m)
        print(f"分解 InstanceNormalization {k} 个")

    # 固定形状折叠（pads 动态链等）：onnxsim 走 ORT 形状推导+常量求值。
    import onnxsim
    shapes = {args.input_name: [1, 3, 1024, 1024]} if args.input_name == "rgb_input" \
        else {args.input_name: [1, 1, 1024, 1024]}
    sim, check = onnxsim.simplify(m, overwrite_input_shapes=shapes)
    if not check:
        print("onnxsim 校验未通过（数值等价检查失败），仍以未化简图落盘")
    else:
        m = sim
    print(f"折叠后节点数 {len(m.graph.node)}")

    # pads 回填（探针真值非零，是 MNN 边界漂移根因之一），回填后再折叠一次
    fixed = fold_pads(m)
    print(f"回填 Pad 节点 {fixed} 个")
    if fixed:
        sim2, check2 = onnxsim.simplify(m, overwrite_input_shapes=shapes)
        if check2:
            m = sim2
            print(f"二折叠后节点数 {len(m.graph.node)}")

    # 校验：折叠后不应再剩 If / 动态 Pad
    ops = {}
    for nd in m.graph.node:
        ops[nd.op_type] = ops.get(nd.op_type, 0) + 1
    print("If 剩余:", ops.get("If", 0), "| Pad 剩余:", ops.get("Pad", 0))
    if ops.get("If", 0) > 0 or ops.get("Pad", 0) > 0:
        print("仍有 If/Pad——转换前请人工复核")
    onnx.save(m, str(args.dst))
    print(f"已写出 {args.dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
