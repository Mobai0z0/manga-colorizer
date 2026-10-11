// 色彩收尾 v2（两端同数学的 Dart 侧）：纸白中和 → 自适应色度 → 方案色温 →
// 色域映射 →（可选）纸色渲染。桌面镜像实现在 tool/colorizer_service/service.py
// `_finish_bgr`，改任何一侧必须同步另一侧并重新生成金样（test/goldens/）。
//
// 背景取证（2026-10-10，样张 + 模型实测）：
//   · 偏黄——模型对近白区域有系统性暖偏（纸白 a≈+0.4、b≈+3.4，与推理分辨率
//     无关，512/768/1024 实测同在）；L≥234 的 smoothstep 中和可定点去除；
//   · 偏灰——模型色度普遍偏低（中间调色度 ~6.6），且平坦增益会把已经鲜艳的
//   · 强色一起放大造成过饱和；自适应膝点（弱色全增益、强色趋缓）两全；
//   · L=255 纯白在色域映射下必然输出纯白（任何 a/b 都超域被收缩），因此
//     「昭和复古」的暖纸改为映射后的 RGB 空间纸色渲染才可见。
import 'dart:math' as math;
import 'dart:typed_data';

/// 色彩收尾参数（语义与桌面 `_finish_bgr` 一一对应）。
class FinishOptions {
  /// 弱色度处的最大增益（自适应膝点下，强色度趋近 1）。
  final double gain;

  /// 自适应膝点 C0：色度 C 处的增益 = 1+(gain-1)/(1+(C/C0)²)。
  /// 0 = 关闭膝点，退化为平增益（旧行为）。
  final double knee;

  /// 纸白中和：源稿 L 字节 234→248 smoothstep，把近白像素的 a/b 收向中性。
  /// 去除模型对纸白的系统性暖偏（偏黄主因）。
  final bool neutralPaper;

  /// 方案色温偏移（a/b 各加 warmth*wt，wt = C/(C+warmthC0)，纸白不吃色）。
  final double warmthA;
  final double warmthB;
  final double warmthC0;

  /// 纸色渲染（RGB 空间，映射后向目标纸色按 L smoothstep 混合）。
  /// null = 关闭。[paperToneStrength] ∈ [0,1]。
  final int? paperToneR;
  final int? paperToneG;
  final int? paperToneB;
  final double paperToneStrength;

  const FinishOptions({
    this.gain = 1.0,
    this.knee = 0.0,
    this.neutralPaper = false,
    this.warmthA = 0.0,
    this.warmthB = 0.0,
    this.warmthC0 = 16.0,
    this.paperToneR,
    this.paperToneG,
    this.paperToneB,
    this.paperToneStrength = 0.0,
  });

  /// 平增益 + 色域映射（= 旧 `labToRgbGamut(chromaGain)` 语义）。
  const FinishOptions.flat(double chromaGain)
      : this(gain: chromaGain);
}

/// 内置色彩方案（id 稳定，跨端共用；桌面 service.py FINISH_SCHEMES 同表）。
/// 参数经 tmp 调参实验在样张上定档（2026-10-10）。
const Map<String, FinishOptions> kFinishSchemes = {
  // 标准：纸白中和 + 适度自适应增益——修复偏黄偏灰的新默认。
  'standard': FinishOptions(gain: 1.40, knee: 16.0, neutralPaper: true),
  // 鲜明赛璐璐：高饱和高清晰的人气赛璐璐投稿感。
  'vivid-cel': FinishOptions(gain: 1.80, knee: 24.0, neutralPaper: true),
  // 柔和淡彩：ふんわり低饱和淡色，奶油白纸面。
  'soft-pastel': FinishOptions(gain: 0.95, knee: 10.0, neutralPaper: true),
  // 厚涂浓郁：油画感重彩，强色度也增益，微暖色温。
  'impasto': FinishOptions(
      gain: 1.70,
      knee: 40.0,
      neutralPaper: true,
      warmthA: 0.5,
      warmthB: 2.0,
      warmthC0: 20.0),
  // 昭和复古：暖褐阴影 + 奶油暖纸（保留模型暖偏 + 纸色渲染）。
  'retro-showa': FinishOptions(
      gain: 1.20,
      knee: 16.0,
      neutralPaper: false,
      warmthA: 2.0,
      warmthB: 8.0,
      warmthC0: 24.0,
      paperToneR: 248,
      paperToneG: 238,
      paperToneB: 216,
      paperToneStrength: 0.55),
};

/// 默认方案 id（两端一致）。
const String kDefaultFinishScheme = 'standard';

double _smoothstep01(double e0, double e1, double x) {
  var t = (x - e0) / (e1 - e0);
  t = t.clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// 色彩收尾 v2：8bit Lab（n*3，L 恒取原稿）→ RGB（n*3）。
///
/// [lab] 的 L 字节同时充当「源稿亮度」用于纸白判定；a/b 为 +128 偏置。
/// 数学次序：①纸白中和 → ②自适应色度 → ③方案色温 → ④色域映射（t 钳 ≥0，
/// 修 L=100 处 Y>1 的负系数退化）→ ⑤纸色渲染。与桌面 `_finish_bgr` 同数学，
/// 金样对拍容差 ±1（8bit 查表/舍入路径差异，既有约定）。
Uint8List labToRgbFinish(Uint8List lab, int n, FinishOptions o) {
  final out = Uint8List(n * 3);
  final hasTone = o.paperToneR != null && o.paperToneStrength > 0.0;
  for (var i = 0; i < n; i++) {
    final lByte = lab[i * 3].toDouble();
    var a = lab[i * 3 + 1] - 128.0;
    var b = lab[i * 3 + 2] - 128.0;
    var paperT = 0.0;
    if (o.neutralPaper) {
      paperT = _smoothstep01(234.0, 248.0, lByte);
      a *= 1.0 - paperT;
      b *= 1.0 - paperT;
    }
    final c0 = math.sqrt(a * a + b * b);
    final boost = o.knee > 0.0
        ? 1.0 + (o.gain - 1.0) / (1.0 + (c0 / o.knee) * (c0 / o.knee))
        : o.gain;
    a *= boost;
    b *= boost;
    if (o.warmthA != 0.0 || o.warmthB != 0.0) {
      // 色温权重用增益后的色度（与桌面 _finish_bgr 一致: C 在增益后重算）
      final cg = math.sqrt(a * a + b * b);
      final wt = cg / (cg + o.warmthC0);
      a += o.warmthA * wt;
      b += o.warmthB * wt;
    }
    final l = lByte / 255.0 * 100.0;
    final fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
    final x = _invLab(fx) * 0.950456,
        y = l > 8 ? fy * fy * fy : l / 903.3,
        z = _invLab(fz) * 1.088754;
    var r = 3.240481 * x - 1.537152 * y - 0.498536 * z;
    var g = -0.969254 * x + 1.875990 * y + 0.041556 * z;
    var bl = 0.055643 * x - 0.203997 * y + 1.057311 * z;
    final yy = 0.212671 * r + 0.715160 * g + 0.072169 * bl;
    var t = _gamutCap(r, yy, _gamutCap(g, yy, _gamutCap(bl, yy, 1.0)));
    if (t < 0.0) t = 0.0; // L=100 处 Y>1 的退化：钳 0 → 收缩到纯白（与桌面一致）
    if (t < 0.95) {
      r = yy + (r - yy) * t;
      g = yy + (g - yy) * t;
      bl = yy + (bl - yy) * t;
    } else {
      r = r.clamp(0.0, 1.0);
      g = g.clamp(0.0, 1.0);
      bl = bl.clamp(0.0, 1.0);
    }
    var or_ = _gammaLab(r), og = _gammaLab(g), ob = _gammaLab(bl);
    if (hasTone) {
      final tp =
          _smoothstep01(234.0, 248.0, lByte) * o.paperToneStrength;
      // 与桌面 astype(uint8) 截断同语义（金样逐值一致）。
      or_ = (or_ * (1.0 - tp) + o.paperToneR! * tp).clamp(0, 255).toInt();
      og = (og * (1.0 - tp) + o.paperToneG! * tp).clamp(0, 255).toInt();
      ob = (ob * (1.0 - tp) + o.paperToneB! * tp).clamp(0, 255).toInt();
    }
    out[i * 3] = or_;
    out[i * 3 + 1] = og;
    out[i * 3 + 2] = ob;
  }
  return out;
}

// lab.dart 的私有转换在这里复用会引入跨文件私有依赖，按同公式内联命名，
// 数值语义与 lab.dart 逐值一致（lab_test 全 256 值对拍覆盖两处等价性）。
double _invLab(double t) =>
    t > 6 / 29 ? t * t * t : 3 * (6 / 29) * (6 / 29) * (t - 4 / 29);
int _gammaLab(double c) {
  final v = c > 0.0031308 ? 1.055 * math.pow(c, 1 / 2.4) - 0.055 : 12.92 * c;
  return (v.clamp(0.0, 1.0) * 255).round();
}

double _gamutCap(double c, double y, double t) {
  final d = c - y;
  if (d > 1e-12) {
    final lim = (1.0 - y) / d;
    return lim < t ? lim : t;
  }
  if (d < -1e-12) {
    final lim = y / -d;
    return lim < t ? lim : t;
  }
  return t;
}

/// 方案 id 是否有效。
bool isValidFinishScheme(String id) => kFinishSchemes.containsKey(id);

/// 解析方案 id（未知回退默认，调用方无需预校验；UI 侧用 [isValidFinishScheme]
/// 给出明确报错）。
FinishOptions finishOptionsFor(String schemeId) =>
    kFinishSchemes[schemeId] ?? kFinishSchemes[kDefaultFinishScheme]!;
