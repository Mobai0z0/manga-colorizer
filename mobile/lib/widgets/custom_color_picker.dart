// 自定义提示点取色器（上色页）：HSV 色相条 + 饱和度/明度二维面板 +
// hex 直输 + 最近自定义色。纯 Material 手搓（不引第三方取色库，与本仓
// 「内置组件优先」纪律一致）；触达面 ≥48dp、拖动实时回显，符合端侧交互。
//
// 持久化约定（colorize_screen 负责）：选定的不透明色经 SettingsController
// 落 settings.json 的 customHintColors（ARGB int，最近在前，上限 8）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Color → 不透明 ARGB int（持久化键）。
/// 8bit 通道（0..1 double → int），与 colorize_screen 的 `_channel` 同式。
int argbOfColor(Color c) {
  int ch(double v) => (v * 255.0).round().clamp(0, 255).toInt();
  return 0xFF000000 | ch(c.r) << 16 | ch(c.g) << 8 | ch(c.b);
}

/// ARGB int → 不透明 Color（历史/脏数据强制不透明，防半透明刷）。
Color colorFromArgb(int v) => Color(0xFF000000 | (v & 0xFFFFFF));

/// 打开自定义取色对话框；返回选定颜色（取消为 null）。点最近自定义色即返回。
Future<Color?> showCustomColorPicker(
  BuildContext context, {
  required Color initial,
  required List<Color> recents,
}) {
  return showDialog<Color>(
    context: context,
    builder: (ctx) => _PickerDialog(initial: initial, recents: recents),
  );
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({required this.initial, required this.recents});

  final Color initial;
  final List<Color> recents;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hex =
      TextEditingController(text: _hexOf(widget.initial));
  late final FocusNode _hexFocus = FocusNode()
    // 失焦统一吃一次输入（键盘「完成」与点击别处两条路径都会经过这里）。
    ..addListener(() {
      if (!_hexFocus.hasFocus) _applyHex(_hex.text);
    });

  static String _hexOf(Color c) {
    final v = argbOfColor(c) & 0xFFFFFF;
    return v.toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  Color get _color => _hsv.toColor();

  void _setColor(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      // hex 框不在编辑焦点时随动（编辑中抢值会打断输入）。
      if (!_hexFocus.hasFocus) _hex.text = _hexOf(_color);
    });
  }

  /// 解析 '#RRGGBB' / 'RRGGBB'：6 位 hex 才接受（8 位带 alpha 一律拒绝，
  /// 与「提示点恒不透明」的持久化约定一致）。
  void _applyHex(String raw) {
    final v = int.tryParse(raw.trim().replaceFirst('#', ''), radix: 16);
    if (v == null || v < 0 || v > 0xFFFFFF) return;
    _setColor(HSVColor.fromColor(Color(0xFF000000 | v)));
  }

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('自定义颜色'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            // 当前色预览 + hex 直输。
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _color,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant, width: 1),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _hex,
                focusNode: _hexFocus,
                decoration: const InputDecoration(
                  labelText: 'Hex（#RRGGBB）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')),
                ],
                onSubmitted: _applyHex,
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _HsvPlane(hsv: _hsv, onChanged: _setColor),
          const SizedBox(height: 12),
          _HueBar(hue: _hsv.hue, onChanged: (h) => _setColor(_hsv.withHue(h))),
          if (widget.recents.isNotEmpty) ...[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('最近自定义',
                  style: Theme.of(context).textTheme.labelSmall),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in widget.recents)
                  _SwatchDot(
                    color: c,
                    selected: argbOfColor(c) == argbOfColor(_color),
                    onTap: () => _setColor(HSVColor.fromColor(c)),
                  ),
              ],
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 饱和度/明度二维面板：底色为当前色相的纯色，左→右白（降饱和）、
/// 上→下黑（降明度），两次线性渐变叠加即标准 SV 方块（不需着色器）。
/// 宽高比固定 1:0.62（AspectRatio 承载；AlertDialog 的 actions 溢出条会算
/// intrinsic 尺寸，LayoutBuilder 在对话框内容里不可用）。
class _HsvPlane extends StatelessWidget {
  const _HsvPlane({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _apply(BuildContext context, Offset local) {
    final size = (context.findRenderObject()! as RenderBox).size;
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.0 / 0.62,
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('sv-plane'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _apply(context, d.localPosition),
            onPanStart: (d) => _apply(context, d.localPosition),
            onPanUpdate: (d) => _apply(context, d.localPosition),
            child: CustomPaint(
              size: Size.infinite,
              painter: _SvPlanePainter(hue: hsv.hue),
            ),
          ),
        ),
        // 拾取点：白圈黑边双描边，任何底色上都可辨。分数定位经 Align
        // （sat/val ∈ [0,1] 映射到 Alignment ±1），免读像素尺寸。
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              alignment: Alignment(
                  hsv.saturation * 2 - 1, (1 - hsv.value) * 2 - 1),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hsv.toColor(),
                  border: Border.all(color: Colors.white, width: 2.5),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 2),
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _SvPlanePainter extends CustomPainter {
  const _SvPlanePainter({this.hue = 0});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..color = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor(),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );
    // 圆角裁切观感：外圈描边。
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x33000000),
    );
  }

  @override
  bool shouldRepaint(_SvPlanePainter old) => old.hue != hue;
}

/// 色相条：全谱渐变（红→黄→绿→青→蓝→品红→红），横向拖动改 hue。
class _HueBar extends StatelessWidget {
  const _HueBar({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  static const _spectrum = <Color>[
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('hue-bar'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => onChanged(
                (d.localPosition.dx /
                        (context.findRenderObject()! as RenderBox)
                            .size
                            .width)
                    .clamp(0.0, 1.0) *
                    360.0),
            onPanStart: (d) => onChanged(
                (d.localPosition.dx /
                        (context.findRenderObject()! as RenderBox)
                            .size
                            .width)
                    .clamp(0.0, 1.0) *
                    360.0),
            onPanUpdate: (d) => onChanged(
                (d.localPosition.dx /
                        (context.findRenderObject()! as RenderBox)
                            .size
                            .width)
                    .clamp(0.0, 1.0) *
                    360.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(colors: _spectrum),
              ),
            ),
          ),
        ),
        // 色相指示点：Align 分数定位，免读像素尺寸。
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              alignment: Alignment(hue / 360.0 * 2 - 1, 0),
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor(),
                  border: Border.all(color: Colors.white, width: 2.5),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 2),
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// 最近自定义色小圆点（对话框内）。
class _SwatchDot extends StatelessWidget {
  const _SwatchDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}
