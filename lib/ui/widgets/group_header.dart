import 'package:flutter/material.dart';

import '../../data/models/contact.dart';

class GroupHeader extends StatelessWidget {
  final String groupKey;
  final List<SelectableContact> contacts;
  /// 是否处于导出模式（可勾选）。浏览态下仅展示组名与人数，点击不产生任何选择动作。
  final bool selectMode;
  final VoidCallback? onToggle;

  const GroupHeader({
    super.key,
    required this.groupKey,
    required this.contacts,
    this.selectMode = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selectedCount = contacts.where((c) => c.isSelected).length;
    final allSelected = selectedCount == contacts.length;
    final someSelected = selectedCount > 0 && !allSelected;

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Material(
        color: colorScheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          // 仅导出模式下点击 = 整组勾选/取消，浏览态不响应。
          onTap: selectMode ? onToggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colorScheme.onPrimaryContainer.withValues(alpha: 0.1),
                  ),
                  child: Icon(
                    Icons.groups,
                    size: 20,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        groupKey,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                      Text(
                        selectMode
                            ? '$selectedCount/${contacts.length} 已选'
                            : '${contacts.length} 人',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                // 导出模式下的勾选指示器（浏览态不显示）
                if (selectMode) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: allSelected
                          ? colorScheme.primary
                          : someSelected
                              ? colorScheme.tertiary
                              : colorScheme.onPrimaryContainer.withValues(alpha: 0.08),
                    ),
                    child: allSelected
                        ? Icon(Icons.check, size: 16, color: colorScheme.onPrimary)
                        : someSelected
                            ? Icon(Icons.remove, size: 16, color: colorScheme.onPrimary)
                            : null,
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
