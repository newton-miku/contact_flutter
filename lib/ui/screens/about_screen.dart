import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../config/app_config.dart';
import '../../config/app_settings.dart';
import '../../data/providers/contacts_provider.dart';
import '../../data/remote/contact_api.dart';
import 'dev_options_screen.dart';

/// 客户端「关于」页：客户端版本/构建时间 + 服务端版本信息 + 隐藏的开发者模式入口。
///
/// 说明：
/// - 接口地址普通模式不展示（避免暴露服务器），开发者模式在「开发者选项」子页里改；
/// - 信息行都可点击（仅水波纹反馈，无副作用）；
/// - 隐藏入口（两步，需都做）：先长按服务端「版本号」静默解锁，再连点 5 次客户端
///   「版本号」开启开发者模式；只在“还差 2 次 / 还差 1 次”时各提示一次，其余静默防误触。
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  ServerVersion? _server;
  String? _error;

  // 真实安装版本（versionName / versionCode，来自 pubspec 的 version 字段）。
  String _pkgVersion = '—';
  String _pkgBuild = '';

  // 两步隐藏手势状态：
  // 第 1 步长按服务端版本号 → _armed = true（解锁，10 秒内有效）；
  // 第 2 步连点 5 次客户端版本号 → 开启。单做一步均不生效，防止误触。
  bool _armed = false;
  Timer? _armTimer;
  int _versionTaps = 0;
  Timer? _tapTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPkg();
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    _armTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPkg() async {
    try {
      final p = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _pkgVersion = p.version;
        _pkgBuild = p.buildNumber;
      });
    } catch (_) {
      // 读取失败保持占位符即可
    }
  }

  Future<void> _load() async {
    try {
      final sv = await ref.read(contactApiProvider).fetchVersion();
      if (!mounted) return;
      setState(() {
        _server = sv;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  String _fmtTime(String? iso) {
    final t = DateTime.tryParse(iso ?? '')?.toLocal();
    if (t == null) return '—';
    return DateFormat('yyyy-MM-dd HH:mm').format(t);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  // ---------- 开发者模式入口（两步隐藏手势，需都做才生效） ----------

  /// 第 1 步：长按服务端「版本号」→ 静默解锁（无提示，10 秒内有效，超时静默作废）。
  void _armDevMode() {
    if (ref.read(appSettingsProvider).devMode) return; // 已在开发者模式
    _armed = true;
    _versionTaps = 0;
    _tapTimer?.cancel();
    _armTimer?.cancel();
    _armTimer = Timer(const Duration(seconds: 10), () => _armed = false);
  }

  /// 第 2 步：连点 5 次客户端「版本号」→ 开启开发者模式。
  /// 未先长按解锁时连点一律静默不生效；直到只差 2 次时才提示一次，避免误触暴露入口。
  void _tapClientVersion() {
    if (!_armed) return; // 未先长按解锁：连点不生效（防误触，无提示）
    _versionTaps++;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(seconds: 2), () => _versionTaps = 0);
    if (_versionTaps >= 5) {
      _activateDevMode();
    } else if (_versionTaps == 3) {
      // 剩 2 次：开始提示引导（前面都静默）。
      _toast('再连点 2 次客户端「版本号」进入开发者模式');
    } else if (_versionTaps == 4) {
      // 剩 1 次。
      _toast('再连点 1 次客户端「版本号」进入开发者模式');
    }
  }

  Future<void> _activateDevMode() async {
    _armed = false;
    _armTimer?.cancel();
    _versionTaps = 0;
    _tapTimer?.cancel();
    await ref.read(appSettingsProvider.notifier).setDevMode(true);
    if (!mounted) return;
    _toast('开发者模式已开启');
    // 开启且当前指向自定义服务器时，顺手用新地址重新取一次服务端信息。
    if (ref.read(appSettingsProvider).effectiveBaseUrl != AppConfig.apiBaseUrl) {
      setState(() {
        _server = null;
        _error = null;
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        title: Text('关于',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // ---------- 头图 ----------
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(Icons.contact_phone,
                        size: 40, color: colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 12),
                  Text('通讯录',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('县域单位通讯录客户端',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const _SectionTitle('客户端'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _InfoRow(
                  label: '版本号',
                  value: _pkgVersion,
                  mono: true,
                  onTap: _tapClientVersion,
                ),
                // 构建时注入的 git 短哈希：仅作运维“构建标识”，不是产品版本号。
                if (AppConfig.appVersion.isNotEmpty && AppConfig.appVersion != 'dev')
                  const _InfoRow(
                    label: '构建标识（提交）',
                    value: AppConfig.appVersion,
                    mono: true,
                  ),
                if (_pkgBuild.isNotEmpty)
                  _InfoRow(
                    label: '构建号（versionCode）',
                    value: _pkgBuild,
                    mono: true,
                  ),
                _InfoRow(
                  label: '构建时间',
                  value: AppConfig.buildTime,
                  last: true,
                ),
              ],
            ),
          ),
          const _SectionTitle('服务端'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: _server == null
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: _error == null
                          ? const CircularProgressIndicator()
                          : Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Column(
                                children: [
                                  Text('无法获取服务端版本信息',
                                      style: TextStyle(color: colorScheme.error)),
                                  const SizedBox(height: 4),
                                  Text(_error!,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
                    ),
                  )
                : Column(
                    children: [
                      _InfoRow(label: '数据版本', value: '${_server!.version}'),
                      _InfoRow(
                          label: '数据更新于', value: _fmtTime(_server!.updatedAt)),
                      // 长按解锁开发者模式入口（解锁后再连点客户端版本号才开启）。
                      _InfoRow(
                        label: '版本号',
                        value: (_server!.appVersion?.isNotEmpty ?? false)
                            ? _server!.appVersion!
                            : '—',
                        mono: true,
                        onLongPress: _armDevMode,
                      ),
                      _InfoRow(
                          label: '服务端构建时间', value: _fmtTime(_server!.buildTime)),
                      _InfoRow(
                        label: '数据库结构版本',
                        value: _server!.schemaVersion == null
                            ? '—'
                            : 'v${_server!.schemaVersion}',
                        last: true,
                      ),
                    ],
                  ),
          ),

          // ---------- 开发者选项入口（仅开发者模式显示；功能在子页，仿安卓设置） ----------
          if (settings.devMode)
            Card(
              child: ListTile(
                leading: const Icon(Icons.developer_mode),
                title: const Text('开发者选项'),
                subtitle: const Text('服务器地址 / 连接测试 / 获取本机号码等诊断'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevOptionsScreen()),
                ),
              ),
            ),

          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('说明',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    '联系人数据由通讯录服务器下发，客户端缓存最近一次数据，'
                    '并在服务器数据版本变化时自动更新，减少重复拉取。\n\n'
                    '功能：\n'
                    '• 按单位分组浏览（单位顺序与后台一致，组内按姓名拼音、办公室/值班室置顶）\n'
                    '• 拼音 / 首字母搜索\n'
                    '• 点击查看详情 / 一键呼叫 / 发短信 / 复制号码\n'
                    '• 导出到系统通讯录（菜单进入选择模式后勾选，需生物认证）\n'
                    '• 来电显示名片（Android：通讯录内的人来电时全屏显示单位职务）',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

/// 一条「标签 + 值」信息行：整行可点（默认无副作用，仅水波纹）。
/// [onTap] / [onLongPress] 用于客户端版本号连点、服务端版本号长按等隐藏手势。
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final bool last;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _InfoRow({
    required this.label,
    required this.value,
    this.mono = false,
    this.last = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap ?? () {},
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: colorScheme.onSurfaceVariant, fontSize: 14)),
                const Spacer(),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      fontFamily: mono ? 'monospace' : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!last)
            Divider(height: 1,
                indent: 16,
                endIndent: 16,
                color: colorScheme.outlineVariant),
        ],
      ),
    );
  }
}
