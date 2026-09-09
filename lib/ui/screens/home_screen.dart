import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/models/contact.dart';
import '../../data/providers/contacts_provider.dart';
import '../../services/biometric_auth.dart';
import '../../services/contacts_exporter.dart';
import '../../services/device_auth.dart';
import '../../services/pinyin_search.dart';
import '../widgets/avatar.dart';
import '../widgets/contact_detail_sheet.dart';
import '../widgets/group_header.dart';
import '../widgets/search_bar.dart';
import 'about_screen.dart';
import 'app_lock_settings_screen.dart';
import 'caller_id_settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  // 导出模式：仅在此模式下才可勾选联系人并导出。默认浏览态 = 点击查看详情/复制/拨打。
  bool _exportMode = false;

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
    final allSelected =
        state.contacts.isNotEmpty && state.selectedCount == state.contacts.length;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        // 导出模式下用返回箭头退出（若已有勾选会先确认），其余时间无 leading。
        leading: _exportMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: '退出选择',
                onPressed: _exitExportMode,
              )
            : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _exportMode ? '选择要导出的联系人' : '通讯录',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              _exportMode
                  ? '点选联系人，点分组标题可整组选择'
                  : _statusSubtitle(state),
              style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: _exportMode
            ? []
            : [
                // ---------- 高级功能菜单 ----------
                PopupMenuButton<_MenuAction>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '高级功能',
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  onSelected: (action) {
                    switch (action) {
                      case _MenuAction.export:
                        _enterExportMode();
                      case _MenuAction.appLock:
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AppLockSettingsScreen()),
                        );
                      case _MenuAction.callerId:
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const CallerIdSettingsScreen()),
                        );
                      case _MenuAction.about:
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const AboutScreen()),
                        );
                      case _MenuAction.checkUpdate:
                        _checkUpdate(context);
                      case _MenuAction.changePassword:
                        _changePassword(context);
                      case _MenuAction.logout:
                        _logout(context);
                    }
                  },
                  itemBuilder: (_) => [
                    // 应用锁（Windows 桌面版不提供解锁要求，不显示）
                    if (defaultTargetPlatform != TargetPlatform.windows) ...[
                      const PopupMenuItem(
                        value: _MenuAction.appLock,
                        child: Row(
                          children: [
                            Icon(Icons.lock_outline, size: 20),
                            SizedBox(width: 12),
                            Text('应用锁'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                    ],
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
                    // 导出：进入「导出模式」后才可勾选联系人
                    PopupMenuItem(
                      value: _MenuAction.export,
                      child: Row(
                        children: [
                          const Icon(Icons.person_add_outlined, size: 20),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('导出到系统通讯录…'),
                              Text(
                                '进入选择模式 · 需生物认证',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: colorScheme.outline),
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
                    // 桌面端：账号密码登录相关
                    if (defaultTargetPlatform != TargetPlatform.android &&
                        defaultTargetPlatform != TargetPlatform.iOS) ...[
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _MenuAction.changePassword,
                        child: Row(
                          children: [
                            Icon(Icons.password, size: 20),
                            SizedBox(width: 12),
                            Text('修改密码'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: _MenuAction.logout,
                        child: Row(
                          children: [
                            Icon(Icons.logout, size: 20),
                            SizedBox(width: 12),
                            Text('退出登录'),
                          ],
                        ),
                      ),
                    ],
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
                        selectionMode: _exportMode,
                        onContactTap: (contact) => _showDetail(context, contact),
                        onToggle: (id) => ref.read(contactsProvider.notifier).toggle(id),
                        onGroupToggle: (key) =>
                            ref.read(contactsProvider.notifier).toggleGroup(key),
                      ),
          ),
        ],
      ),
      // ---------- 导出模式底部操作条（浏览态不显示） ----------
      bottomNavigationBar: _exportMode
          ? _ExportModeBar(
              count: state.selectedCount,
              total: state.contacts.length,
              allSelected: allSelected,
              onToggleAll: () =>
                  ref.read(contactsProvider.notifier).selectAll(!allSelected),
              onExport: _confirmAndExport,
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

  // ---------- 导出模式进出 ----------

  /// 进入导出模式：清空上次选择，展示勾选与导出条。
  void _enterExportMode() {
    ref.read(contactsProvider.notifier).clearSelection();
    setState(() => _exportMode = true);
  }

  /// 退出导出模式：已有勾选时先确认（避免误触丢选择）。
  Future<void> _exitExportMode() async {
    final selectedCount = ref.read(contactsProvider).selectedCount;
    if (selectedCount > 0) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('退出选择'),
          content: Text('已勾选 $selectedCount 位联系人，退出后将清空选择。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续选择'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出并清空'),
            ),
          ],
        ),
      );
      if (leave != true) return;
    }
    _leaveExportMode();
  }

  /// 无条件退出选择模式并清空勾选（导出结束 / 无勾选退出时用）。
  void _leaveExportMode() {
    ref.read(contactsProvider.notifier).clearSelection();
    if (!mounted) return;
    setState(() => _exportMode = false);
  }

  // ---------- 导出执行 ----------

  Future<void> _confirmAndExport() async {
    final selected = ref
        .read(contactsProvider)
        .contacts
        .where((c) => c.isSelected)
        .map((c) => c.contact)
        .toList();

    if (selected.isEmpty) {
      ref.read(contactsProvider.notifier).setMessage('请先点选要导出的联系人');
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
      // 认证失败：留在导出模式，可重试。
      ref.read(contactsProvider.notifier).setMessage(authResult.error ?? '认证失败，无法导出');
      return;
    }

    final result = await ContactsExporter.export(selected);
    if (result.permissionDenied) {
      ref.read(contactsProvider.notifier).setMessage('缺少通讯录权限，无法导出');
    } else {
      ref.read(contactsProvider.notifier).setMessage('成功导出 ${result.success} 个，失败 ${result.failure} 个');
    }
    // 导出动作结束后退出选择模式，回到普通浏览界面。
    _leaveExportMode();
  }

  /// 桌面端：修改当前账号密码。
  Future<void> _changePassword(BuildContext context) async {
    final oldCtl = TextEditingController();
    final newCtl = TextEditingController();
    final againCtl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('修改密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldCtl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '当前密码'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: newCtl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: againCtl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '再次输入新密码'),
              ),
              if (err != null) ...[
                const SizedBox(height: 10),
                Text(err!,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (newCtl.text.length < 6) {
                  setD(() => err = '新密码至少 6 位');
                  return;
                }
                if (newCtl.text != againCtl.text) {
                  setD(() => err = '两次输入不一致');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(contactApiProvider).changePassword(
            oldPassword: oldCtl.text,
            newPassword: newCtl.text,
          );
      if (mounted) _toast('密码已修改');
    } catch (e) {
      if (mounted) _toast('修改失败：$e');
    }
  }

  /// 桌面端：退出登录（清除本地令牌，回到登录页）。
  Future<void> _logout(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('退出后需要重新输入账号密码。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(deviceAuthProvider.notifier).clear();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
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

enum _MenuAction { callerId, appLock, export, about, checkUpdate, changePassword, logout }

// ==================== 导出模式底部操作条 ====================

class _ExportModeBar extends StatelessWidget {
  final int count;
  final int total;
  final bool allSelected;
  final VoidCallback onToggleAll;
  final VoidCallback onExport;

  const _ExportModeBar({
    required this.count,
    required this.total,
    required this.allSelected,
    required this.onToggleAll,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // 全选 / 取消全选
            OutlinedButton.icon(
              onPressed: onToggleAll,
              icon: Icon(
                allSelected ? Icons.deselect : Icons.select_all,
                size: 18,
              ),
              label: Text(allSelected ? '取消全选' : '全选'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(width: 12),
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
                  const SizedBox(height: 6),
                  Text(
                    count == 0 ? '点击联系人勾选，或点分组标题整组选择' : '已选 $count 个',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: count > 0 ? FontWeight.w600 : FontWeight.w400,
                      color: count == 0 ? colorScheme.outline : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: count > 0 ? onExport : null,
              icon: const Icon(Icons.person_add, size: 20),
              label: const Text('导出'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ),
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
  // 是否为导出模式（可勾选）；浏览态 = 点击看详情。
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
            selectMode: selectionMode,
            onToggle: selectionMode ? () => onGroupToggle(entry.key) : null,
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
  // 导出模式（可勾选）：浏览态下点击看详情，不产生任何选中动作。
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
          // 浏览态：点击查看详情；导出模式：点击勾选/取消勾选。
          onTap: selectionMode ? onToggle : onTap,
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
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                // 导出模式下显示 Checkbox
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
