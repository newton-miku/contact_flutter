import 'dart:async';
import 'dart:io' show Directory, File, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/contact.dart';
import '../../data/providers/contacts_provider.dart';
import '../../services/apk_installer.dart';
import '../../services/app_update.dart';
import '../../services/biometric_auth.dart';
import '../../services/contacts_exporter.dart';
import '../../services/caller_id_sync.dart';
import '../../services/device_auth.dart';
import '../../services/pinyin_search.dart';
import '../../services/update_download.dart';
import '../../services/windows_installer.dart';
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

  // 启动后的自动更新检查定时器（dispose 时必须取消）
  Timer? _updateTimer;

  /// 手机端（Android/iOS）：来电名片、应用锁、生物认证这些都依赖手机能力。
  /// 桌面端（Linux/Windows）没有这些能力，对应入口一律不展示。
  static bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(contactsProvider.notifier).load());
    _openPendingRoute();
    CallerIdSync.setRouteHandler(_gotoRoute);
    _scheduleAutoUpdateCheck();
  }

  /// 启动后延迟自动检查应用更新。
  ///
  /// 特意延迟 3 秒且不阻塞首帧：更新提示是"顺带的服务"，不该影响启动体验。
  /// 检查失败、超时、或用户已跳过该版本时静默（见 autoCheckAppUpdate）。
  void _scheduleAutoUpdateCheck() {
    _updateTimer?.cancel();
    _updateTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted) return;
      final up = await autoCheckAppUpdate();
      if (!mounted || up == null) return;
      await _showAppUpdateDialog(up, auto: true);
    });
  }

  /// 常驻通知被点击时会带路由过来（caller_id_settings）：
  /// 冷启动走 consumePendingRoute，App 已在运行时由原生推 onRoute。
  Future<void> _openPendingRoute() async {
    final route = await CallerIdSync.consumePendingRoute();
    _gotoRoute(route);
  }

  void _gotoRoute(String? route) {
    // 来电显示设置页依赖 Android 的通知/来电能力，桌面端不处理该路由。
    if (!mounted || !_mobile || route != 'caller_id_settings') return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CallerIdSettingsScreen()),
    );
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    CallerIdSync.setRouteHandler(null);
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
                      case _MenuAction.checkAppUpdate:
                        _checkAppUpdate(context);
                      case _MenuAction.checkUpdate:
                        _checkUpdate(context);
                      case _MenuAction.changePassword:
                        _changePassword(context);
                      case _MenuAction.logout:
                        _logout(context);
                    }
                  },
                  itemBuilder: (_) => [
                    // 应用锁（依赖生物认证/密码锁屏，仅手机端提供）
                    if (_mobile) ...[
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
                    // 来电显示（Android 全屏名片 + 来电筛选角色，仅手机端）
                    if (_mobile) ...[
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
                    ],
                    // 导出：进入「导出模式」后才可勾选联系人。
                    // 导出调的是 Android 原生通道（MethodChannel .../contacts），
                    // 桌面端没有该实现，故仅手机端提供此入口。
                    if (_mobile) ...[
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
                    ],
                    // 检查应用更新（安装包版本，走公共更新源）
                    const PopupMenuItem(
                      value: _MenuAction.checkAppUpdate,
                      child: Row(
                        children: [
                          Icon(Icons.system_update_outlined, size: 20),
                          SizedBox(width: 12),
                          Text('检查应用更新'),
                        ],
                      ),
                    ),
                    // 检查通讯录更新（服务端号码库版本，与上面是两件事）
                    const PopupMenuItem(
                      value: _MenuAction.checkUpdate,
                      child: Row(
                        children: [
                          Icon(Icons.sync, size: 20),
                          SizedBox(width: 12),
                          Text('同步通讯录'),
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

  /// 手动检查应用更新（安装包版本）。
  /// 与 [_checkUpdate] 是两件事：那个查服务端通讯录数据版本，这个查安装包。
  Future<void> _checkAppUpdate(BuildContext context) async {
    final res = await checkAppUpdate();
    if (!context.mounted) return;
    if (res.update != null) {
      await _showAppUpdateDialog(res.update!, auto: false);
      return;
    }
    // 已最新，或检查失败：给出明确文案而不是静默
    final msg = res.error == null ? '已是最新版本' : '检查失败：${res.error}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.system_update_alt, color: Colors.green, size: 24),
            SizedBox(width: 8),
            Text('检查应用更新'),
          ],
        ),
        content: Text(msg),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 更新提示弹窗：显示新版本号、更新说明，并可一键下载/跳转。
  ///
  /// [auto] 为 true 表示启动时自动弹出，此时"稍后"会记住该版本不再提示；
  /// 手动检查时不记录，避免用户主动查看却把版本"跳过"了。
  Future<void> _showAppUpdateDialog(AppUpdate up, {required bool auto}) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.new_releases_outlined, color: Colors.green, size: 24),
            const SizedBox(width: 8),
            Expanded(child: Text('发现新版本 ${up.versionName}')),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (up.notes.isNotEmpty)
                  Text(up.notes, style: const TextStyle(height: 1.5))
                else
                  const Text('（该版本未附更新说明）'),
                if (!up.hasDownload) ...[
                  const SizedBox(height: 12),
                  Text(
                    _canInstallInApp
                        ? '该版本暂未附带安装包，可到发布页面下载。'
                        : '本系统暂不支持应用内更新，可到发布页面查看。',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: Text(auto ? '稍后' : '关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'download'),
            child: Text(up.hasDownload ? '去下载' : '打开发布页'),
          ),
        ],
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'later') {
      // 仅自动提示时记住"跳过这一版"，避免每次启动都弹
      if (auto) await skipVersion(up.versionName);
      return;
    }
    // 优先应用内下载并安装；任何环节失败才回退到浏览器。
    if (up.hasDownload && _canInstallInApp) {
      final ok = await _installInApp(up);
      if (ok) return;
    }
    await _openInBrowser(up.hasDownload ? up.downloadUrl! : up.pageUrl);
  }

  /// 本机是否能应用内更新：Android 装 APK，Windows 自替换 zip。
  /// Linux/macOS 只能引导到发布页——发布链路目前不产出这两个平台的包。
  static bool get _canInstallInApp =>
      ApkInstaller.isSupported || WindowsInstaller.isSupported;

  /// 应用内下载 + 安装，带进度弹窗。返回 true 表示不必再跳浏览器。
  ///
  /// 之所以所有异常都吞掉并返回 false：更新是辅助功能，
  /// 失败应该安静地退到浏览器下载，而不是把用户卡在错误弹窗上。
  Future<bool> _installInApp(AppUpdate up) async {
    if (ApkInstaller.isSupported) return _installApk(up);
    if (WindowsInstaller.isSupported) return _installWindows(up);
    return false;
  }

  /// Android：下载 APK 并交给系统安装器。
  Future<bool> _installApk(AppUpdate up) async {
    final progress = ValueNotifier<double?>(0);
    var dialogOpen = true;
    // 进度弹窗不可点掉：下载中途误触关闭会留下半截文件，反而更难排查
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: value),
              const SizedBox(height: 12),
              Text(value == null
                  ? '已开始下载…'
                  : '${(value * 100).clamp(0, 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);

    try {
      final fileName = up.assetName ?? 'contact_flutter_${up.versionName}.apk';
      final file = await ApkInstaller.download(
        up.downloadUrl!,
        fileName: fileName,
        onProgress: (p) => progress.value = p,
      );
      // 装完就不需要旧包了（保留刚下的这个，安装器还要读它）
      unawaited(ApkInstaller.cleanOldFiles(keep: fileName));

      // 下载已成功，后面即使安装失败也不该回退浏览器——那只会把同一个包再下一遍。
      try {
        await ApkInstaller.install(file);
      } on UpdatePermissionException {
        if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
        if (mounted) _promptInstallPermission();
        return true;
      } catch (e) {
        if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
        if (mounted) _promptInstallRetry(file, e);
        return true;
      }
      if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
      return true;
    } on UpdateException catch (e) {
      // 下载阶段的失败才回退浏览器
      if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) _toast('应用内下载失败（$e），改用浏览器下载');
      return false;
    } catch (e) {
      if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) _toast('应用内更新失败，改用浏览器下载');
      return false;
    }
  }

  /// Windows：下载 zip → 解压 → 退出应用，由脚本替换文件并重启。
  ///
  /// 失败同样分两段：下载/解压阶段失败回退浏览器；
  /// 已经解压好了才失败（比如安装目录不可写）就只提示，不重复下载。
  Future<bool> _installWindows(AppUpdate up) async {
    final progress = ValueNotifier<double?>(0);
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: value),
              const SizedBox(height: 12),
              Text(value == null
                  ? '已开始下载…'
                  : '${(value * 100).clamp(0, 100).toStringAsFixed(0)}%'),
              const SizedBox(height: 8),
              const Text(
                '下载完成后需要关闭应用才能替换文件，随后会自动重启。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);

    Directory? extracted;
    try {
      extracted = await WindowsInstaller.prepare(
        up.downloadUrl!,
        versionName: up.versionName,
        onProgress: (p) => progress.value = p,
      );
    } on UpdateException catch (e) {
      if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) _toast('应用内下载失败（$e），改用浏览器下载');
      return false;
    } catch (e) {
      if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) _toast('应用内更新失败，改用浏览器下载');
      return false;
    }

    if (dialogOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return true;
    if (!await _confirmWindowsRestart(up)) return true;

    try {
      await WindowsInstaller.applyAndRestart(extracted, versionName: up.versionName);
    } on UpdateException catch (e) {
      if (mounted) _toast('$e');
      return true;
    } catch (e) {
      if (mounted) _toast('无法应用更新：$e');
      return true;
    }
    // 更新脚本正在等本进程退出，必须真的退出它才会开始替换
    exit(0);
  }

  /// 替换文件必须先关掉应用，所以问一句再动手。
  Future<bool> _confirmWindowsRestart(AppUpdate up) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('更新已就绪'),
        content: Text(
          '新版本 ${up.versionName} 已下载完成。\n\n'
          '完成安装需要先关闭本应用，随后会自动重新打开。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 包已下好但安装器没起来：提示重试（重试只重新拉起安装器，不重新下载）。
  void _promptInstallRetry(File apk, Object error) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('安装未启动'),
        content: Text(
          '安装包已下载完成，但无法唤起系统安装器：\n$error\n\n'
          '可以重试，或到「应用内更新」目录手动安装。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ApkInstaller.install(apk).catchError((e) {
                if (mounted) _toast('仍然无法启动安装器：$e');
              });
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  /// Android 8+ 需按「来源应用」授权安装未知应用。
  void _promptInstallPermission() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('需要授权'),
        content: const Text(
          '系统要求先允许本应用「安装未知应用」，才能完成更新。\n\n'
          '请在接下来的设置页中开启该权限，然后重新点击下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ApkInstaller.openInstallPermissionSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Future<void> _openInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _toast('无法打开下载链接，请到发布页面手动下载');
    }
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

enum _MenuAction {
  callerId,
  appLock,
  export,
  about,
  checkAppUpdate, // 安装包版本（走公共更新源）
  checkUpdate, // 服务端通讯录数据版本
  changePassword,
  logout,
}

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
