import 'package:flutter/material.dart';

class ExportBottomBar extends StatelessWidget {
  final int selectedCount;
  final int totalCount;
  final VoidCallback onExport;

  const ExportBottomBar({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Row(
        children: [
          // 线性进度指示
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  // 3.10 的 LinearProgressIndicator 还没有 borderRadius 参数
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: totalCount > 0 ? selectedCount / totalCount : 0,
                    backgroundColor: colorScheme.surfaceVariant,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '已选 $selectedCount 个',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '共 $totalCount 位联系人',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            onPressed: selectedCount > 0 ? onExport : null,
            icon: const Icon(Icons.person_add, size: 20),
            label: const Text('导出到通讯录'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
