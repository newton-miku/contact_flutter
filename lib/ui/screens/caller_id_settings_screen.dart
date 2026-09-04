import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../services/caller_id_sync.dart';

/// 来电显示名片设置：
/// - 主开关：打开时向系统申请 READ_PHONE_STATE / READ_CALL_LOG / POST_NOTIFICATIONS；
/// - 权限状态逐项展示，可跳系统设置补授权；
/// - Android 14+ 的“全屏提醒”需在系统通知设置里单独放行，这里一键直达。
class CallerIdSettingsScreen extends StatefulWidget {
  const CallerIdSettingsScreen({super.key});

  @override
  State<CallerIdSettingsScreen> createState() => _CallerIdSettingsScreenState();
}

class _CallerIdSettingsScreenState extends State<CallerIdSettingsScreen>
    with WidgetsBindingObserver {
  final bool _android = defaultTargetPlatform == TargetPlatform.android;
  bool _loading = true;
  bool _enabled = false;
  Map<String, bool> _perms = const {};
  bool? _fullScreenOk; // false=需在系统设置开启（仅 Android 14+）；null=非安卓

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置/授权框返回时刷新状态。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    if (!_android) {
      if (mounted && _loading) setState(() => _loading = false);
      return;
    }
    final enabled = await CallerIdSync.isEnabled();
    final perms = await CallerIdSync.permissions();
    final fs = await CallerIdSync.canUseFullScreen();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _enabled = enabled;
      _perms = perms;
      _fullScreenOk = fs;
    });
  }

  Future<void> _onToggle(bool on) async {
    if (!on) {
      await CallerIdSync.setEnabled(false);
      await _reload();
      return;
    }

    // 打开：先按系统需要申请权限（native 弹框，授权后立即返回状态）
    _perms = await CallerIdSync.requestPermissions();
    await CallerIdSync.setEnabled(true);
    if (!mounted) return;
    await _reload();

    final notif = _perms['notifications'] ?? false;
    final callLog = _perms['readCallLog'] ?? false;
    if (!notif) {
      _toast(
        '通知权限被拒绝：来电名片将无法弹出。请在系统设置中开启通知。',
        openSettings: true,
      );
    } else if (!callLog) {
      _toast('未授予“电话/通话记录”：Android 10+ 会读不到来电号码，名片可能不显示。',
          openSettings: true);
    }
  }

  Future<void> _grant(String permission) async {
    if (!mounted) return;
    if (permission == 'notifications' &&
        (await ph.Permission.notification.status).isPermanentlyDenied) {
      _toast('通知权限已被系统永久拒绝，请到系统设置中手动开启', openSettings: true);
      return;
    }
    if ((await ph.Permission.phone.status).isPermanentlyDenied) {
      _toast('电话/通话记录权限已被系统永久拒绝，请到系统设置中手动开启', openSettings: true);
      return;
    }
    _perms = await CallerIdSync.requestPermissions();
    if (!mounted) return;
    await _reload();
  }

  void _toast(String msg, {bool openSettings = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        action: openSettings
            ? SnackBarAction(label: '去设置', onPressed: () => ph.openAppSettings())
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        title: Text('来电显示',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_android
              ? const _Unsupported()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    const _TipCard(
                      icon: Icons.phone_in_talk,
                      title: '来电自动显示名片',
                      subtitle: '当通讯录里的人来电时，全屏弹出名片显示姓名、单位与职务；陌生号码不打扰。',
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: SwitchListTile(
                        value: _enabled,
                        onChanged: _onToggle,
                        title: const Text('开启来电显示'),
                        subtitle: const Text('关闭后立即停止弹名片'),
                        secondary: Icon(_enabled ? Icons.toggle_on : Icons.notifications_off,
                            color: _enabled ? colorScheme.primary : colorScheme.outline),
                      ),
                    ),
                    const _SectionHeader('所需权限'),
                    Card(
                      child: Column(
                        children: [
                          _PermTile(
                            title: '电话状态',
                            subtitle: '监听响铃事件（Android 10+ 需与通话记录配合取号）',
                            granted: _perms['readPhoneState'] ?? false,
                            onGrant: () => _grant('phone'),
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          _PermTile(
                            title: '电话/通话记录',
                            subtitle: 'Android 10+ 出于隐私限制，须此权限才能取得来电号码',
                            granted: _perms['readCallLog'] ?? false,
                            onGrant: () => _grant('phone'),
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          _PermTile(
                            title: '通知',
                            subtitle: '展示全屏名片通知（Android 13+ 必需）',
                            granted: _perms['notifications'] ?? false,
                            onGrant: () => _grant('notifications'),
                          ),
                        ],
                      ),
                    ),
                    if (_fullScreenOk != null) ...[
                      const _SectionHeader('全屏提醒'),
                      Card(
                        child: ListTile(
                          leading: Icon(
                            _fullScreenOk! ? Icons.fullscreen : Icons.warning_amber,
                            color: _fullScreenOk!
                                ? Colors.green
                                : colorScheme.error,
                          ),
                          title: Text(_fullScreenOk! ? '全屏提醒已可用' : '需在系统设置开启全屏提醒'),
                          subtitle: Text(
                            _fullScreenOk!
                                ? '来电名片可以直接全屏弹出'
                                : 'Android 14+ 要求应用在系统通知设置里单独授予“全屏提醒”（这是系统限制，需手动开启一次）',
                          ),
                          trailing: _fullScreenOk!
                              ? null
                              : const FilledButton(
                                  onPressed: CallerIdSync.openFullScreenSettings,
                                  child: Text('去开启'),
                                ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const _TipCard(
                      icon: Icons.lightbulb_outline,
                      title: '小贴士',
                      subtitle: '联系人数据每次同步后会自动推送给来电识别使用，无需手动导入。\n'
                          '此功能仅在系统来电界面之上叠加展示，不拦截、不处理通话本身。',
                      dim: true,
                    ),
                  ],
                ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

class _TipCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool dim;
  const _TipCard(
      {required this.icon, required this.title, required this.subtitle, this.dim = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: 22,
              color: dim ? colorScheme.outline : colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontWeight: FontWeight.w600, color: dim
                        ? colorScheme.onSurfaceVariant
                        : null)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: dim ? colorScheme.outline : colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool granted;
  final VoidCallback onGrant;
  const _PermTile({
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        granted ? Icons.check_circle : Icons.radio_button_unchecked,
        color: granted ? Colors.green : colorScheme.outline,
      ),
      title: Text(title),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12, height: 1.4)),
      trailing: granted
          ? const Text('已授权',
              style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600))
          : TextButton(onPressed: onGrant, child: const Text('授权')),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phone_android,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text('来电显示名片仅支持 Android', style: TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }
}
