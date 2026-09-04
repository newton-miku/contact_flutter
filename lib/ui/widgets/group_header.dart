import 'package:flutter/material.dart';

import '../../data/models/contact.dart';

class GroupHeader extends StatelessWidget {
  final String groupKey;
  final List<SelectableContact> contacts;
  final VoidCallback onToggle;

  const GroupHeader({
    super.key,
    required this.groupKey,
    required this.contacts,
    required this.onToggle,
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
          onTap: onToggle,
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
                        '$selectedCount/${contacts.length} 已选',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                // 勾选指示器
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
            ),
          ),
        ),
      ),
    );
  }
}
