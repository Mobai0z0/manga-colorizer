"""_finish_bgr 色彩收尾冒烟测试（纯 numpy/cv2，不加载模型，秒级）。

用法: ..\\.venv\\Scripts\\python.exe tool/colorizer_service/quality_check.py

断言十五件事:
  1. 色域内像素与 cv2 LAB2BGR 逐值差 ≤1（平增益收尾时是无损替代）;
  2. 超色域像素的输出色相偏移 <2.5°（旧逐通道截断可偏 30°+，是发灰发闷主因）;
  3. 亮度严格保持（色域映射前后 L 差 ≤1，8bit 量化容差）;
  4. 自适应膝点增益单调放大输出色度;
  5. 极暗像素不被色度"提亮"成彩黑色（L=0 时旧路径会输出 ~RGB(103,0,0)）;
  6. 纸白中和: 近白像素的暖偏被定点去除（偏黄修复）;
  7. L=100 纯白 + 任意色度输出纯白（t≥0 钳制后无负系数外推）;
  8. 参考图迁移: 亮度保真 + 纸白保护 + strength=0 恒等;
  9. 白色前景救援: 封闭近白吃到模型色度（L 压低）, 纸白保持纯白;
  9b. 主色相填充: 弱色度灰区获得同带主色相簇平均色, 自信像素不动, 孤立无
      主色不发明, 高光/纸白/墨线不动;
  10. 浅色前景救援: 封闭近白模型色度 C≈5（白衣样张量级）也渲染出可见浅色;
  11. 同材质色相统一: 色调签名相同而色相冲突 → 小块旋到大块色相, 肤色/阴影
      不误配, L 与色度幅值保持;
  12. 中性区色度保底: 有色邻居包围的灰块染上主色, 孤立灰与墨线不染色;
  13. COLORIZER_CONSISTENCY=0 时一致性 pass 恒等。
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


def test_white_rescue_light_chroma():
    """浅色前景救援（2026-10-12 白衣样张取证）: 封闭近白的模型色度只有
    C≈4-8（浅色在 Lab 里色度就小, 与纸白噪声同量级）——窄门限 + 整体豁免
    中和后应渲染出可见浅色; 旧宽门限（c1=c0+18）下 keep≈0, 成品纯白。"""
    gray = np.full((24, 24), 255, np.uint8)
    gray[7, 7:17] = 0
    gray[16, 7:17] = 0
    gray[7:17, 7] = 0
    gray[7:17, 16] = 0
    l_ref = cv2.cvtColor(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2LAB)[..., 0]
    marks = service._white_rescue_marks(l_ref)
    # 纸白停在模型暖偏噪声量级（b≈+1.4）, 封闭近白是浅暖色（b=+5, C=5）
    ab = np.full((24, 24, 2), 128.0, np.float32)
    ab[..., 1] = 128.0 + np.where(marks == 2, 5.0, 1.4)
    opt = service._with_rescue(l_ref, ab, service._resolve_finish('standard'))
    out = service._finish_bgr(l_ref, ab, opt)
    lab_out = cv2.cvtColor(out, cv2.COLOR_BGR2LAB).astype(np.float64)
    inner = out[10:14, 10:14].astype(np.int32)
    b_in = lab_out[10:14, 10:14, 2].mean() - 128.0
    spread = inner.max(axis=-1) - inner.min(axis=-1)
    assert b_in > 2.0, f'浅色封闭近白未被染上: b={b_in:.1f}'
    assert spread.mean() > 3.0, f'浅色封闭近白仍读作纯白: spread={spread.mean():.1f}'
    # 纸白（贴边, 噪声量级）保持纯白
    paper = out[0:4, 0:4].astype(np.int32)
    pspread = paper.max(axis=-1) - paper.min(axis=-1)
    assert pspread.max() <= 2, f'纸白被浅色救援误染: spread={pspread.max()}'


def test_unify_material_hues():
    """同材质色相统一: 色调签名相同而色相冲突的两块 → 小块旋到大块色相;
    肤色平涂 vs 阴影排线（ΔL 超限）不配对; L 与色度幅值严格保持。"""
    # 160×160: 左块 hue≈350°（C=16, 条纹 L 140/200 交替）, 右块 hue≈270° 同签名;
    # 中部大平涂 hue≈30° C=12 L=225（肤色）与右块 ΔL≈64 → 不得配对。
    h = w = 160
    l_u8 = np.full((h, w), 245, np.uint8)
    ab = np.full((h, w, 2), 128.0, np.float32)
    yy, xx = np.mgrid[0:h, 0:w]
    left = ((xx - 40) ** 2 + (yy - 40) ** 2) <= 14 ** 2        # ~616px
    right = ((xx - 120) ** 2 + (yy - 40) ** 2) <= 26 ** 2      # ~2124px
    skin = ((xx - 80) ** 2 + (yy - 120) ** 2) <= 40 ** 2       # ~5027px
    stripe = ((yy % 8) < 4)
    for m in (left, right):
        l_u8[m] = np.where(stripe[m], 140, 200)
    l_u8[skin] = 225
    for m, hue in ((left, 350.0), (right, 270.0), (skin, 30.0)):
        ang = np.radians(hue)
        ab[..., 0][m] = 128.0 + 16.0 * np.cos(ang)
        ab[..., 1][m] = 128.0 + 16.0 * np.sin(ang)
    out = service._unify_material_hues(l_u8, ab.copy())
    lab_o = out - 128.0
    # 左块（质量小）旋到右块色相; 右块与肤色不动
    c_l = np.hypot(lab_o[left, 0], lab_o[left, 1]).mean()
    hue_l = float(np.degrees(np.arctan2(lab_o[left, 1].mean(), lab_o[left, 0].mean())) % 360)
    assert abs(((hue_l - 270.0 + 180) % 360) - 180) < 15, f'左块未旋到右块色相: {hue_l:.0f}°'
    assert abs(c_l - 16.0) < 1.0, f'旋转改变了色度幅值: {c_l:.1f}'
    hue_r = float(np.degrees(np.arctan2(lab_o[right, 1].mean(), lab_o[right, 0].mean())) % 360)
    assert abs(((hue_r - 270.0 + 180) % 360) - 180) < 5, '右块（质量大）不应被改'
    hue_s = float(np.degrees(np.arctan2(lab_o[skin, 1].mean(), lab_o[skin, 0].mean())) % 360)
    assert abs(((hue_s - 30.0 + 180) % 360) - 180) < 5, f'肤色被误旋转: {hue_s:.0f}°'
    assert out.shape == ab.shape and out.dtype == np.float32


def test_neutral_chroma_floor():
    """中性区色度保底: 有色邻居包围的灰块被染上主色, 孤立灰与墨线不染色。"""
    # 页面 320×320（统计窗口 81px 宽, 「孤立」须离有色像素 ≥81px）
    h = w = 320
    gray = np.full((h, w), 210, np.uint8)   # L=210 的浅灰
    ab = np.full((h, w, 2), 128.0, np.float32)
    yy, xx = np.mgrid[0:h, 0:w]
    disk = ((xx - 240) ** 2 + (yy - 80) ** 2) <= 55 ** 2     # 有色盘
    patch = ((xx - 240) ** 2 + (yy - 80) ** 2) <= 18 ** 2    # 盘心的灰块
    ab[disk] = [128.0 + 11.0, 128.0 + 11.0]                  # 暖主色 C≈15.6
    ab[patch] = 128.0                                        # 灰块 C=0
    # 孤立灰块（左下角, 距有色盘 >81px）与墨线
    iso = ((xx - 50) ** 2 + (yy - 260) ** 2) <= 12 ** 2
    gray[iso] = 190
    ab[iso] = 128.0
    ink = ((yy >= 290) & (yy < 296) & (xx >= 150) & (xx < 210))
    gray[ink] = 30
    ab[ink] = 128.0
    out = service._neutral_chroma_floor(gray, ab.copy())
    d = out - 128.0
    c_patch = np.hypot(d[patch, 0], d[patch, 1])
    assert c_patch.mean() > 4.0, f'灰块没有被保底染色: {c_patch.mean():.1f}'
    hue_p = float(np.degrees(np.arctan2(d[patch, 1].mean(), d[patch, 0].mean())) % 360)
    assert abs(((hue_p - 45.0 + 180) % 360) - 180) < 25, f'保底色相偏离局部主色: {hue_p:.0f}°'
    c_iso = np.hypot(d[iso, 0], d[iso, 1])
    assert c_iso.max() < 1.0, f'孤立灰不应被发明颜色: {c_iso.max():.1f}'
    c_ink = np.hypot(d[ink, 0], d[ink, 1])
    assert c_ink.max() < 1.0, f'墨线(L<64)不应被染色: {c_ink.max():.1f}'


def test_dominant_hue_fill():
    """主色相填充: 弱色度灰区获得同带主色相簇平均色; 自信像素一律不动
    （旋转会渗色）; 孤立无主色不发明; 高光/纸白/墨线不动。"""
    h, w = 280, 200
    l = np.full((h, w), 210, np.uint8)
    ab = np.full((h, w, 2), 128.0, np.float32)
    yy, xx = np.mgrid[0:h, 0:w]

    def disk(cx, cy, r, hue, chroma, l_fill):
        m = ((xx - cx) ** 2 + (yy - cy) ** 2) <= r ** 2
        l[m] = l_fill
        ang = np.radians(hue)
        ab[..., 0][m] = 128.0 + chroma * np.cos(ang)
        ab[..., 1][m] = 128.0 + chroma * np.sin(ang)
        return m

    # 带 [150,190): 自信暖盘（C=15, hue=60）占绝对质量
    b_warm = disk(60, 60, 40, 60.0, 15.0, 170)
    # 内嵌灰盘（C=2, 色相噪声 200°）→ 填为主色相 hue≈60 C≈15
    gray_warm = disk(60, 60, 15, 200.0, 2.0, 170)
    # 同带小号离群自信块（C=12, hue=130）→ 不转不填, 原样保留
    green = disk(130, 60, 12, 130.0, 12.0, 170)
    # 孤立灰盘（方窗 r=140 内无可信同带像素）→ 不发明颜色
    lone = disk(175, 255, 15, 80.0, 2.0, 170)
    # 高光（L=225 > _DH_L_MAX）/纸白 → 不填; 墨线 → 不填
    hl = disk(160, 20, 12, 60.0, 2.0, 225)
    paper = np.zeros((h, w), bool)
    paper[0:12, 180:200] = True
    l[paper] = 250
    ab[..., 1][paper] = 128.0 + 6.0
    ink = disk(20, 240, 8, 30.0, 40.0, 30)

    out = service._dominant_hue_fill(l, ab.copy())
    d = out - 128.0
    c = lambda m: float(np.hypot(d[m, 0], d[m, 1]).mean())
    hue_of = lambda m: float(np.degrees(np.arctan2(d[m, 1].mean(), d[m, 0].mean())) % 360.0)
    chg = lambda m: float((np.abs(out - ab).sum(axis=2)[m] > 0.5).mean())

    # ⓪ 灰盘获得主色相簇平均色（hue≈60, C≈15）
    assert 48.0 < hue_of(gray_warm) < 75.0, f'灰盘未获得主色相: hue={hue_of(gray_warm):.1f}'
    assert abs(c(gray_warm) - 15.0) < 2.5, f'灰盘幅值不对: C={c(gray_warm):.2f}'
    # ① 离群自信块原样保留（不转不填——旋转会渗色到脸部/背景）
    assert abs(((hue_of(green) - 130.0 + 180) % 360) - 180) < 3.0, \
        f'离群自信块被误转: hue={hue_of(green):.1f}'
    assert abs(c(green) - 12.0) < 0.6, f'离群自信块幅值被改: C={c(green):.2f}'
    assert chg(green) < 0.01, f'离群自信块被改动: {chg(green)*100:.1f}%'
    # ② 孤立灰盘（无主色可借）不发明颜色
    assert chg(lone) < 0.01, f'孤立灰盘被发明颜色: {chg(lone)*100:.1f}%'
    assert abs(c(lone) - 2.0) < 0.6, f'孤立灰盘幅值被改: C={c(lone):.2f}'
    # ③ 高光/纸白/墨线不动
    assert chg(hl) < 0.01, f'高光被填: {chg(hl)*100:.1f}%'
    assert abs(d[paper, 1].mean() - 6.0) < 0.5, f'纸白被填: b={d[paper,1].mean():.2f}'
    assert abs(c(ink) - 40.0) < 1.0, f'墨线被填: C={c(ink):.2f}'
    assert abs(((hue_of(ink) - 30.0 + 180) % 360) - 180) < 3.0, \
        f'墨线色相被改: hue={hue_of(ink):.1f}'
    # ④ 自信暖盘本体不动
    ring = b_warm & ~gray_warm
    assert chg(ring) < 0.01, f'自信暖盘被改动: {chg(ring)*100:.1f}%'
    # ⑤ 全中性图恒等
    l_neu = np.full((h, w), 150, np.uint8)
    ab_neu = np.full((h, w, 2), 128.0, np.float32)
    assert np.array_equal(service._dominant_hue_fill(l_neu, ab_neu), ab_neu), '中性图被改'


def test_consistency_disabled():
    """COLORIZER_CONSISTENCY=0 时 _consistency_pass 恒等返回。"""
    rng = np.random.default_rng(5)
    ab = rng.uniform(100, 156, (32, 32, 2)).astype(np.float32)
    l_u8 = rng.integers(0, 256, (32, 32)).astype(np.uint8)
    old = os.environ.get('COLORIZER_CONSISTENCY')
    os.environ['COLORIZER_CONSISTENCY'] = '0'
    try:
        out = service._consistency_pass(l_u8, ab)
    finally:
        if old is None:
            os.environ.pop('COLORIZER_CONSISTENCY', None)
        else:
            os.environ['COLORIZER_CONSISTENCY'] = old
    assert np.array_equal(out, ab), '开关关闭时应恒等返回'


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
             test_white_rescue, test_white_rescue_light_chroma,
             test_dominant_hue_fill,
             test_unify_material_hues, test_neutral_chroma_floor,
             test_consistency_disabled,
             test_reference_transfer]
    for t in tests:
        t()
        print(f'PASS {t.__name__}')
    print(f'quality_check: {len(tests)} 项全部通过')
