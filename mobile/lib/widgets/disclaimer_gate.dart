// 合规免责声明确认项：文案与桌面端 web/dist/index.html 的 .disclaimer 同值。
// 勾选状态由调用方经 SettingsController 持久化（AppSettings.disclaimerAccepted），
// 未勾选时上色 / 全自动 / 参考图上色的运行入口保持禁用。
import 'package:flutter/material.dart';

const String kDisclaimerText =
    '我确认对处理内容拥有合法权利；上色结果仅供个人创作与预览，不用于商业发布（模型权重 CC BY-NC-SA 4.0）。';

class DisclaimerCheck extends StatelessWidget {
  const DisclaimerCheck({
    super.key,
    required this.accepted,
    required this.onChanged,
    this.enabled = true,
  });

  final bool accepted;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: enabled ? () => onChanged(!accepted) : null,
      child: Padding(
        padding: const EdgeInsets.only(left: 2, right: 4, top: 2, bottom: 2),
        child: Row(children: [
          Checkbox(
            value: accepted,
            onChanged: enabled ? (v) => onChanged(v ?? false) : null,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Expanded(
            child: Text(
              kDisclaimerText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
            ),
          ),
        ]),
      ),
    );
  }
}
