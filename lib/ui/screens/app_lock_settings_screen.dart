import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_lock.dart';
import '../../services/biometric_auth.dart';
import 'app_lock_setup_screen.dart';
import 'app_lock_verify_screen.dart';

/// 应用锁设置页：开启/关闭（关闭需验证并清除密码）、生物识别（支持才显示，可测试）、
/// 修改密码、密码键盘乱序。
/// 入口：首页右上 ⋮ 菜单「应用锁」（Windows 桌面版不提供）。
class AppLockSettingsScreen extends ConsumerStatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  ConsumerState<AppLockSettingsScreen> createState() =>
      _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState
    extends ConsumerState<AppLockSettingsScreen> {
  final BiometricAuth _bio = BiometricAuth();
  bool _bioSupported = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cap = await _bio.checkCapability();
      if (mounted) {
        setState(() {
          _bioSupported = cap == BiometricCapability.available;
        });
      }
    });
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

  /// 测试生物识别是否可用（手动）。
  Future<void> _testBio() async {
    if (_bioBusy) return;
    setState(() => _bioBusy = true);
    final r = await _bio.tryAuthenticate(
      reason: '测试指纹 / 面部识别',
      skipIfNotAvailable: false,
    );
    if (!mounted) return;
    setState(() => _bioBusy = false);
    _toast(r.granted ? '生物识别验证成功' : (r.error ?? '已取消'));
  }

  bool _bioBusy = false;

  /// 首次开启成功后：由设置密码流程里自动测一次生物识别（见 AppLockSetupScreen）。

  Future<void> _openSetup({required bool requireCurrent}) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AppLockSetupScreen(requireCurrent: requireCurrent),
      ),
    );
  }

  /// 关闭应用锁：先确认，再验证身份，通过后清除密码。
  Future<void> _disable() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭应用锁？'),
        content: const Text('关闭后将清除已设置的解锁密码，下次开启需重新设置。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('验证并关闭')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const AppLockVerifyScreen(
          title: '关闭应用锁',
          message: '请验证指纹/面部，或输入当前密码',
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(appLockProvider.notifier).turnOff();
    if (mounted) _toast('应用锁已关闭，密码已清除');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final state = ref.watch(appLockProvider);

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        title: Text('应用锁',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (!state.configured)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(Icons.lock_outline,
                        size: 44, color: colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('设置解锁密码后，每次冷启动打开 App 都需验证',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _openSetup(requireCurrent: false),
                      icon: const Icon(Icons.lock_open, size: 18),
                      label: const Text('开启应用锁'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 14),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            const _SectionHeader('通用'),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('启用应用锁'),
                    subtitle: const Text('关闭需验证身份，并清除已设置的密码'),
                    value: state.enabled,
                    onChanged: state.enabled ? (_) => _disable() : (v) {
                      ref.read(appLockProvider.notifier).setEnabled(true);
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.password),
                    title: const Text('修改解锁密码'),
                    subtitle: const Text('需先验证当前密码'),
                    onTap: () => _openSetup(requireCurrent: true),
                  ),
                ],
              ),
            ),
            const _SectionHeader('解锁方式'),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: _bioSupported
                    ? [
                        SwitchListTile(
                          title: const Text('指纹 / 面部识别'),
                          subtitle: const Text('冷启动时优先弹出生物识别，失败可改用密码'),
                          value: state.bioEnabled,
                          onChanged: (v) => ref.read(appLockProvider.notifier)
                              .setBioEnabled(v),
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        ListTile(
                          leading: const Icon(Icons.fingerprint),
                          title: const Text('测试生物识别'),
                          subtitle: const Text('确认设备可正常唤起指纹 / 面部'),
                          trailing: _bioBusy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check_circle_outline, size: 20),
                          onTap: _bioBusy ? null : _testBio,
                        ),
                      ]
                    : [
                        const ListTile(
                          leading: Icon(Icons.fingerprint),
                          title: Text('指纹 / 面部识别'),
                          subtitle: Text('当前设备不支持生物识别，将始终使用密码解锁'),
                          enabled: false,
                        ),
                      ],
              ),
            ),
            const _SectionHeader('安全'),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('密码键盘乱序'),
                    subtitle: const Text('数字键顺序随机打乱，防止旁人偷看'),
                    value: state.shuffle,
                    onChanged: (v) =>
                        ref.read(appLockProvider.notifier).setShuffle(v),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('说明'),
                    subtitle: Text('仅在本机冷启动进入时验证；切到后台再返回不需要重复解锁。'),
                    isThreeLine: true,
                  ),
                ],
              ),
            ),
          ],
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
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}
