import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/models/contact.dart';
import '../../data/providers/contacts_provider.dart';
import '../../services/biometric_auth.dart';
import '../../services/contacts_exporter.dart';
import '../../services/pinyin_search.dart';
import '../widgets/avatar.dart';
import '../widgets/contact_detail_sheet.dart';
import '../widgets/group_header.dart';
import '../widgets/search_bar.dart';
import 'caller_id_settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(contactsProvider.notifier).load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final state = ref.watch(contactsProvider);

    ref.listen(contactsProvider, (previous, next) {
      if (next.message != null && next.message != previous?.message) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.message!),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            action: next.message!.contains('权限')
                ? const SnackBarAction(
                    label: '去设置',
                    onPressed: openAppSettings,
                  )
                : null,
          ),
        );
        ref.read(contactsProvider.notifier).clearMessage();
      }
    });

    final filteredGroups = _filterGroups(state.groupedContacts, _query);

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '通讯录',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              _statusSubtitle(state),
              style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          // ---------- 高级功能菜单 ----------
          PopupMenuButton<_MenuAction>(
            icon: const Icon(Icons.more_vert),
            tooltip: '高级功能',
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            onSelected: (action) {
              switch (action) {
                case _MenuAction.selectAll:
                  final allSelected = state.selectedCount == state.contacts.length;
                  ref.read(contactsProvider.notifier).selectAll(!allSelected);
                case _MenuAction.export:
                  _exportSelected(context);
                case _MenuAction.callerId:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CallerIdSettingsScreen()),
                  );
                case _MenuAction.about:
                  _showAbout(context);
                case _MenuAction.checkUpdate:
                  _checkUpdate(context);
              }
            },
            itemBuilder: (_) => [
              // 来电显示（Android 全屏名片）
              const PopupMenuItem(
                value: _MenuAction.callerId,
                child: Row(
                  children: [
                    Icon(Icons.phone_in_talk, size: 20),
                    SizedBox(width: 12),
                    Text('来电显示'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              // 全选 / 取消全选
              PopupMenuItem(
                value: _MenuAction.selectAll,
                child: Row(
                  children: [
                    Icon(
                      state.selectedCount == state.contacts.length
                          ? Icons.deselect
                          : Icons.select_all,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(state.selectedCount == state.contacts.length ? '取消全选' : '全选'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              // 导出到系统通讯录（需生物认证）
              PopupMenuItem(
                value: _MenuAction.export,
                enabled: state.selectedCount > 0,
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 20,
                      color: state.selectedCount > 0 ? null : colorScheme.outline,
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('导出到系统通讯录'),
                        Text(
                          '需生物认证 · 已选 ${state.selectedCount} 个',
                          style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              // 检查更新
              const PopupMenuItem(
                value: _MenuAction.checkUpdate,
                child: Row(
                  children: [
                    Icon(Icons.system_update_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('检查更新'),
                  ],
                ),
              ),
              // 关于
              const PopupMenuItem(
                value: _MenuAction.about,
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 20),
                    SizedBox(width: 12),
                    Text('关于'),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => ref.read(contactsProvider.notifier).load(),
          ),
        ],
      ),
      body: Column(
        children: [
          ContactSearchBar(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
          Expanded(
            child: state.loading
                ? const _LoadingView()
                : filteredGroups.isEmpty
                    ? const _EmptyView()
                    : _ContactList(
                        groups: filteredGroups,
                        selectionMode: state.selectedCount > 0,
                        onContactTap: (contact) => _showDetail(context, contact),
                        onToggle: (id) => ref.read(contactsProvider.notifier).toggle(id),
                        onGroupToggle: (key) =>
                            ref.read(contactsProvider.notifier).toggleGroup(key),
                      ),
          ),
        ],
      ),
      // ---------- 底部选中计数条 ----------
      bottomNavigationBar: state.selectedCount > 0
          ? _SelectedBar(
              count: state.selectedCount,
              total: state.contacts.length,
              onExport: () => _exportSelected(context),
            )
          : null,
    );
  }

  /// AppBar 副标题：反映数据版本 / 来源 / 同步状态。
  String _statusSubtitle(ContactsState state) {
    if (state.status == DataStatus.offline) {
      return state.contacts.isEmpty ? '离线，暂无本地数据' : '离线 · 使用本地缓存';
    }
    if (state.contacts.isEmpty && state.loading) return '正在加载…';

    final parts = <String>[];
    if (state.version != null) {
      parts.add('版本 ${state.version}');
      final updatedAt = state.updatedAt;
      if (updatedAt != null) {
        final t = DateTime.tryParse(updatedAt)?.toLocal();
        if (t != null) parts.add('更新于 ${DateFormat('M月d日 HH:mm').format(t)}');
      }
    } else if (!state.loading) {
      parts.add('暂无数据');
    }
    if (state.syncing) parts.add('同步中…');
    return parts.isEmpty ? '' : parts.join(' · ');
  }

  Map<String, List<SelectableContact>> _filterGroups(
    Map<String, List<SelectableContact>> groups,
    String query,
  ) {
    if (query.isEmpty) return groups;
    final result = <String, List<SelectableContact>>{};
    for (final entry in groups.entries) {
      final filtered = entry.value.where((c) {
        final contact = c.contact;
        final contactText =
            '${contact.displayName}${contact.phoneNumber}${contact.mobile2 ?? ''}'
            '${contact.landline ?? ''}${contact.fax ?? ''}${contact.unit}${contact.jobTitle}';
        return PinyinSearch.matches(
          rawContactText: contactText,
          displayName: contact.displayName,
          groupKey: c.groupKey,
          jobTitle: contact.jobTitle,
          query: query,
        );
      }).toList();
      if (filtered.isNotEmpty) result[entry.key] = filtered;
    }
    return result;
  }

  void _showDetail(BuildContext context, RemoteContact contact) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContactDetailSheet(contact: contact),
    );
  }

  Future<void> _exportSelected(BuildContext context) async {
    final selected = ref
        .read(contactsProvider)
        .contacts
        .where((c) => c.isSelected)
        .map((c) => c.contact)
        .toList();

    if (selected.isEmpty) {
      ref.read(contactsProvider.notifier).setMessage('请先选择要导出的联系人');
      return;
    }

    // 确认弹窗
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('导出到系统通讯录'),
        content: Text('即将把选中的 ${selected.length} 位联系人导出到系统通讯录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // 生物认证
    final auth = BiometricAuth();
    final authResult = await auth.tryAuthenticate(
      reason: '验证身份以导出联系人到系统通讯录',
      skipIfNotAvailable: true,
    );

    if (!authResult.granted) {
      ref.read(contactsProvider.notifier).setMessage(authResult.error ?? '认证失败，无法导出');
      return;
    }

    final result = await ContactsExporter.export(selected);
    if (result.permissionDenied) {
      ref.read(contactsProvider.notifier).setMessage('缺少通讯录权限，无法导出');
      return;
    }
    ref.read(contactsProvider.notifier).setMessage('成功导出 ${result.success} 个，失败 ${result.failure} 个');
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: '通讯录',
      applicationVersion: '1.0.0',
      applicationIcon: const Icon(Icons.contact_phone, size: 48, color: Colors.blue),
      children: [
        const SizedBox(height: 16),
        Text(
          '公司通讯录客户端。联系人数据由通讯录服务器下发，'
          '客户端会缓存最近一次数据，并在版本号变化时自动更新，减少重复拉取。\n\n'
          '功能：\n'
          '• 按部门分组浏览\n'
          '• 拼音 / 首字母搜索\n'
          '• 一键呼叫 / 发短信\n'
          '• 生物认证导出到系统通讯录\n'
          '• 来电显示名片（Android：通讯录内的人来电时全屏显示单位职务）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final text = await ref.read(contactsProvider.notifier).checkForUpdates();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.system_update_alt, color: Colors.green, size: 24),
            SizedBox(width: 8),
            Text('检查更新'),
          ],
        ),
        content: Text(text),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

// ==================== 菜单动作枚举 ====================

enum _MenuAction { callerId, selectAll, export, about, checkUpdate }

// ==================== 底部选中计数条 ====================

class _SelectedBar extends StatelessWidget {
  final int count;
  final int total;
  final VoidCallback onExport;

  const _SelectedBar({
    required this.count,
    required this.total,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: total > 0 ? count / total : 0,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(3),
                  minHeight: 5,
                ),
                const SizedBox(height: 8),
                Text(
                  '已选 $count 个',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: onExport,
            icon: const Icon(Icons.person_add, size: 20),
            label: const Text('导出'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 联系人列表 ====================

class _ContactList extends StatelessWidget {
  final Map<String, List<SelectableContact>> groups;
  final ValueChanged<RemoteContact> onContactTap;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onGroupToggle;
  final bool selectionMode;

  const _ContactList({
    required this.groups,
    required this.onContactTap,
    required this.onToggle,
    required this.onGroupToggle,
    required this.selectionMode,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: groups.length * 2,
      itemBuilder: (context, index) {
        final groupIndex = index ~/ 2;
        final isHeader = index % 2 == 0;
        final entry = groups.entries.elementAt(groupIndex);

        if (isHeader) {
          return GroupHeader(
            groupKey: entry.key,
            contacts: entry.value,
            onToggle: () => onGroupToggle(entry.key),
          );
        }

        return Column(
          children: entry.value.map((selectable) {
            return _ContactTile(
              selectable: selectable,
              onTap: () => onContactTap(selectable.contact),
              onToggle: () => onToggle(selectable.contact.id),
              selectionMode: selectionMode,
            );
          }).toList(),
        );
      },
    );
  }
}

// ==================== 联系人条目 ====================

class _ContactTile extends StatelessWidget {
  final SelectableContact selectable;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  // 当前是否处于选择模式（有任一人被选中）
  final bool selectionMode;

  const _ContactTile({
    required this.selectable,
    required this.onTap,
    required this.onToggle,
    required this.selectionMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final contact = selectable.contact;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // 点击 → 查看详情（默认行为，不会选中）
          onTap: selectionMode ? onToggle : onTap,
          // 长按 → 选中 / 取消选中
          onLongPress: onToggle,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Avatar(
                  initials: contact.initials,
                  isSelected: selectable.isSelected,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        contact.displayName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: selectable.isSelected ? FontWeight.bold : FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          contact.phoneNumber,
                          if (contact.mobile2 != null && contact.mobile2 != contact.phoneNumber)
                            '手机2 ${contact.mobile2}',
                          if (contact.landline != null && contact.landline != contact.phoneNumber)
                            '座机 ${contact.landline}',
                          if (contact.fax != null && contact.fax != contact.phoneNumber)
                            '传真 ${contact.fax}',
                        ].join(' · '),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (contact.orgLine.isNotEmpty)
                        Text(
                          contact.orgLine,
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                // 选择模式下显示 Checkbox
                if (selectionMode)
                  Checkbox(
                    value: selectable.isSelected,
                    onChanged: (_) => onToggle(),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 加载 / 空状态 ====================

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            '正在加载联系人…',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people_outline, size: 80, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('暂无联系人', style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}
