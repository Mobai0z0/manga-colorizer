// 莫奈流动背景（Monet Ambient Canvas）：页面最底层固定全屏的画布，
// 三个低饱和柔和色球（赤陶 / 鼠尾草 / 暖砂金）呼吸漫游，营造印象派油画般的
// 通透流动质感。与桌面端 web/dist 的 .monet-canvas / .monet-blob 同设计：
//   · 尺寸 46 / 40 / 34 vmax（vmax = max(宽, 高) / 100，随屏幕自适应）；
//   · 位置：赤陶左上角出血、鼠尾草右下角出血、砂金 left 32vw / top 28vh；
//   · 渲染：实芯色块 + 柔边（近似 CSS filter: blur(90~140px) 的实心圆），
//     而非从中心衰减的光晕——这是与网页观感一致的关键；
//   · 动效：三球各自周期 38s / 44s / 30s 往复，位移与缩放端点对齐网页
//     keyframes（monet-a / monet-b / monet-c）。
//
// 用法：挂在 MaterialApp.builder 的 Stack 最底层（见 app.dart），
// Scaffold 背景保持透明即可透出。系统「移除动画」开启时静止在各关键帧
// 的 to 态（与网页 prefers-reduced-motion 行为一致）。
import 'dart:math' show max;

import 'package:flutter/material.dart';

import 'warm_tokens.dart';

class MonetBackground extends StatefulWidget {
  const MonetBackground({super.key});

  @override
  State<MonetBackground> createState() => _MonetBackgroundState();
}

class _MonetBackgroundState extends State<MonetBackground>
    with SingleTickerProviderStateMixin {
  /// 驱动时基：取三球最长周期（鼠尾草 44s），其余球按周期比例换算相位。
  static const _cycle = Duration(seconds: 44);

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _cycle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  /// 系统无障碍「移除动画」：停止漫游，渲染静态构图（各球 to 态）。
  void _syncMotion() {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduced) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 把 0→1 的线性进度换算为指定周期的往复进度（0→1→0），
  /// 等价于网页的 animation-direction: alternate。
  static double _pingPong(double t) {
    final m = t - t.floorToDouble();
    return m <= 0.5 ? m * 2 : 2 - m * 2;
  }

  @override
  Widget build(BuildContext context) {
    final p = WarmPalette.of(context);
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: ColoredBox(
          // 画布底色即主题画布色（羊皮纸 / 暖黑），与网页 .monet-canvas 一致。
          color: Theme.of(context).colorScheme.surface,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              // 静止态：固定在各球关键帧的 to 态（与网页 reduced-motion 一致）。
              final v = reduced ? 1.0 : _controller.value;
              return LayoutBuilder(
                builder: (context, cons) {
                  final w = cons.maxWidth;
                  final h = cons.maxHeight;
                  final vmax = max(w, h) / 100;
                  return Stack(
                    children: [
                      // 赤陶：46vmax，左上角出血（left/top 负值），周期 38s，
                      // 平移 (+5vw, +4vh)、缩放 1 → 1.12。
                      _blob(
                        color: p.monetTerracotta,
                        size: 46 * vmax,
                        center: Offset(13 * vmax, 11 * vmax),
                        progress: _pingPong(v * 44 / 38),
                        drift: Offset(0.05 * w, 0.04 * h),
                        scaleFrom: 1.0,
                        scaleTo: 1.12,
                        solidTo: 0.75,
                        opacity: p.monetOpacity,
                        canvas: Size(w, h),
                      ),
                      // 鼠尾草：40vmax，右下角出血，周期 44s，
                      // 平移 (-6vw, -3vh)、缩放 1.08 → 0.94。
                      _blob(
                        color: p.monetSage,
                        size: 40 * vmax,
                        center: Offset(w - 12 * vmax, h - 10 * vmax),
                        progress: _pingPong(v),
                        drift: Offset(-0.06 * w, -0.03 * h),
                        scaleFrom: 1.08,
                        scaleTo: 0.94,
                        solidTo: 0.72,
                        opacity: p.monetOpacity,
                        canvas: Size(w, h),
                      ),
                      // 砂金：34vmax，left 32vw / top 28vh，周期 30s，
                      // 平移 (-4vw, +6vh)、缩放 0.96 → 1.10。
                      _blob(
                        color: p.monetSand,
                        size: 34 * vmax,
                        center:
                            Offset(0.32 * w + 17 * vmax, 0.28 * h + 17 * vmax),
                        progress: _pingPong(v * 44 / 30),
                        drift: Offset(-0.04 * w, 0.06 * h),
                        scaleFrom: 0.96,
                        scaleTo: 1.10,
                        solidTo: 0.78,
                        opacity: p.monetOpacity,
                        canvas: Size(w, h),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// 单颗色球：柔边径向渐变，近似网页 `filter: blur()` 实心圆被稀释后的
  /// 观感——不设高浓度实芯（网页的 blur 会把颜色摊薄），整体低峰值宽衰减，
  /// 只动 transform、不重跑着色器；位移与缩放按网页 keyframes 端点插值。
  Widget _blob({
    required Color color,
    required double size,
    required Offset center,
    required double progress,
    required Offset drift,
    required double scaleFrom,
    required double scaleTo,
    required double solidTo,
    required double opacity,
    required Size canvas,
  }) {
    // 像素中心 → Alignment（Alignment(0,0) 即画布中心）。
    final alignment = Alignment(
      (center.dx - canvas.width / 2) / (canvas.width / 2),
      (center.dy - canvas.height / 2) / (canvas.height / 2),
    );
    final scale = scaleFrom + (scaleTo - scaleFrom) * progress;
    return Align(
      alignment: alignment,
      child: Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: drift * progress,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // 低峰值宽衰减：峰值 0.55（而非满色），55% 半径内缓降，
                // 边缘才归零——视觉上接近 blur 稀释后的柔团，而非光晕。
                gradient: RadialGradient(
                  colors: [
                    color.withValues(alpha: 0.55),
                    color.withValues(alpha: 0.42),
                    color.withValues(alpha: 0.18),
                    color.withValues(alpha: 0),
                  ],
                  stops: [0.0, solidTo, solidTo + (1 - solidTo) * 0.6, 1.0],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
