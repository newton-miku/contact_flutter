import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 密码圆点指示：深色圆点=已输入。
class PinDots extends StatelessWidget {
  final int total;
  final int filled;
  final bool error;

  const PinDots({
    super.key,
    required this.total,
    required this.filled,
    this.error = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final active = i < filled;
        final Color color;
        if (error) {
          color = colorScheme.error;
        } else if (active) {
          color = colorScheme.primary;
        } else {
          color = colorScheme.outlineVariant;
        }
        return Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        );
      }),
    );
  }
}

/// 数字密码键盘（0~9 + 退格）。
///
/// [digitOrder] 决定 10 个数字键的摆放：默认顺序 1~9、0 在底部中间；给乱序可传入
/// 打乱后的序列，防止旁观者偷看。布局固定（1~9 三行 + 底部 0/退格），仅数字位置变。
class NumPad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  /// 打乱的数字序列（防偷看），每次会话固定一份、勿逐次重建，避免按键跳动。
  final List<int> digitOrder;

  const NumPad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.enabled = true,
    this.digitOrder = const [1, 2, 3, 4, 5, 6, 7, 8, 9, 0],
  });

  /// 数字键默认顺序（不乱序时使用）。
  static const List<int> normalOrder = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0];

  /// 生成一份随机打乱的数字顺序。
  static List<int> randomOrder([Random? rng]) {
    final r = rng ?? Random.secure();
    final list = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0];
    list.shuffle(r);
    return list;
  }

  /// 把数字顺序切成 4 行（前 3 行各 3 键 + 底部 [空, 最后一个, 退格]）。
  static List<List<String>> _rowsOf(List<int> order) {
    final labels = order.map((d) => '$d').toList();
    return [
      [labels[0], labels[1], labels[2]],
      [labels[3], labels[4], labels[5]],
      [labels[6], labels[7], labels[8]],
      ['', labels[9], 'back'],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final rows = _rowsOf(digitOrder);
    return LayoutBuilder(
      builder: (context, constraints) {
        final diameter =
            ((constraints.maxWidth - 48) / 3).clamp(48.0, 84.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: rows.map((row) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final key in row) ...[
                    if (key.isEmpty)
                      SizedBox(width: diameter)
                    else
                      _PadKey(
                        label: key == 'back' ? null : key,
                        icon: key == 'back' ? Icons.backspace_outlined : null,
                        diameter: diameter,
                        enabled: enabled,
                        color: colorScheme,
                        onTap: key == 'back'
                            ? onBackspace
                            : () => onDigit(key),
                      ),
                    const SizedBox(width: 16),
                  ],
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _PadKey extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final double diameter;
  final bool enabled;
  final ColorScheme color;
  final VoidCallback onTap;

  const _PadKey({
    required this.label,
    required this.icon,
    required this.diameter,
    required this.enabled,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.titleLarge?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: enabled ? color.onSurface : color.onSurface.withValues(alpha: 0.35),
        );
    return Material(
      color: enabled
          ? (Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.08)
              : color.surfaceContainerHighest.withValues(alpha: 0.6))
          : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                onTap();
              }
            : null,
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Center(
            child: label != null
                ? Text(label!, style: text)
                : Icon(icon, size: 26, color: text?.color),
          ),
        ),
      ),
    );
  }
}
