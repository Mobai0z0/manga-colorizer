// 液态玻璃组件（Apple Liquid Glass）：backdrop blur(16px) + 半透明内衬
// (rgba 白 72%) + 高光边框 + 顶部内发光立体倒角。与桌面端 web/dist 的
// .glass-* 令牌同值同构（令牌在 warm_tokens.dart 的 WarmPalette）。
//
// - [GlassAppBar]：各屏共享的顶部栏（替代 Material AppBar 的透明变体，
//   自带返回键推断与设置齿轮由调用方传入）。
// - [GlassBottomBar]：底部悬浮条外衣（NavigationBar / 工具栏内衬其中）。
// - [GlassCard]：悬浮卡片（首页四卡 / 参考图卡等）。
import 'package:flutter/material.dart';
import 'dart:ui';

import 'warm_tokens.dart';

/// 玻璃模糊半径（sigma）：与 web 的 blur(16px) 对应。
const double kGlassBlurSigma = 16;

/// 液态玻璃 AppBar：毛玻璃底 + 暖色高光底边 + 衬线标题。
///
/// 玻璃经 AppBar 的 [flexibleSpace] 承载（BackdropFilter 画在工具栏之下），
/// 状态栏高度、返回键推断等布局一律交给框架的 AppBar——自绘 PreferredSize
/// 在状态栏 24/28/48px 各异机型上极易溢出，故不重造轮子。
/// 实现 [PreferredSizeWidget] 可直接作 Scaffold.appBar。
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.leading,
  });

  final String title;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final warm = WarmPalette.of(context);
    return AppBar(
      title: Text(title, style: Theme.of(context).textTheme.titleLarge),
      leading: leading,
      actions: actions,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(
              sigmaX: kGlassBlurSigma, sigmaY: kGlassBlurSigma),
          child: Container(
            decoration: BoxDecoration(
              color: warm.glassTint,
              border: Border(bottom: BorderSide(color: warm.glassBorder)),
            ),
            child: Column(
              children: [
                // 顶部内发光倒角：状态栏下缘一道高光，向下渐隐。
                Container(
                  height: 1,
                  margin:
                      EdgeInsets.only(top: MediaQuery.of(context).padding.top),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        warm.glassBevel,
                        warm.glassBevel.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 液态玻璃底部悬浮条外衣：给任意底部条（NavigationBar / 工具栏）套上
/// 毛玻璃内衬与高光顶边。
class GlassBottomBar extends StatelessWidget {
  const GlassBottomBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final warm = WarmPalette.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter:
            ImageFilter.blur(sigmaX: kGlassBlurSigma, sigmaY: kGlassBlurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: warm.glassTint,
            border: Border(top: BorderSide(color: warm.glassBorder)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 液态玻璃卡片：毛玻璃底 + 高光边框 + 顶部内发光倒角 + 点击水波。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
    this.radius = 12,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final warm = WarmPalette.of(context);
    final borderRadius = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter:
            ImageFilter.blur(sigmaX: kGlassBlurSigma, sigmaY: kGlassBlurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: warm.glassTint,
            borderRadius: borderRadius,
            border: Border(
              top: BorderSide(color: warm.glassBevel, width: 1.5),
              left: BorderSide(color: warm.glassBorder),
              right: BorderSide(color: warm.glassBorder),
              bottom: BorderSide(color: warm.glassBorder),
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: borderRadius,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
