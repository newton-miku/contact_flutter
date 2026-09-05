import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/app_config.dart';
import '../../config/app_settings.dart';
import '../../data/providers/contacts_provider.dart';
import '../../data/remote/contact_api.dart';
import '../../services/caller_id_sync.dart';

/// 开发者选项（子页面，仿安卓“开发者选项”列表式布局）。
/// 入口：关于页开启开发者模式后点「开发者选项」。包含：开关、服务器地址、连接测试、
/// 重新同步、以及“尝试获取本机号码”等诊断项。
class DevOptionsScreen extends ConsumerStatefulWidget {
  const DevOptionsScreen({super.key});

  @override
  ConsumerState<DevOptionsScreen> createState() => _DevOptionsScreenState();
}

class _DevOptionsScreenState extends ConsumerState<DevOptionsScreen> {
  String? _line1Number;
  String? _line1Note;
  bool _line1Busy = false;

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

  // ---------- 服务器 ----------

  Future<void> _editServerUrl() async {
    final settings = ref.read(appSettingsProvider);
    final controller = TextEditingController(text: settings.baseOverride);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '联调/测试用，可指向测试环境。留空 = 恢复构建期默认地址（${AppConfig.apiBaseUrl}）。',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://example.com',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存并同步'),
          ),
        ],
      ),
    );
    if (saved == null || !mounted) return;

    final normalized = AppSettings.normalizeUrl(saved);
    final old = ref.read(appSettingsProvider);
    await ref.read(appSettingsProvider.notifier).setBaseOverride(saved);
    if (!mounted) return;
    if (normalized != old.baseOverride) {
      _toast('服务器地址已更新，正在用新地址重新同步');
      ref.read(contactsProvider.notifier).load();
    }
  }

  Future<void> _clearOverride() async {
    await ref.read(appSettingsProvider.notifier).setBaseOverride('');
    if (!mounted) return;
    _toast('已恢复构建期默认地址');
    ref.read(contactsProvider.notifier).load();
  }

  Future<void> _testConnection() async {
    try {
      final sv = await ref.read(contactApiProvider).fetchVersion();
      _toast('连接成功：数据版本 ${sv.version}');
    } catch (e) {
      _toast(e is ApiException ? e.message : '连接失败：$e');
    }
  }

  Future<void> _reloadData() async {
    await ref.read(contactsProvider.notifier).load();
    if (mounted) _toast('已按当前地址重新同步');
  }

  Future<void> _turnOff() async {
    await ref.read(appSettingsProvider.notifier).setDevMode(false);
    if (mounted) Navigator.of(context).pop();
  }

  // ---------- 本机号码诊断 ----------

  Future<void> _tryLine1() async {
    if (_line1Busy) return;
    setState(() => _line1Busy = true);
    final perms = await CallerIdSync.permissions();
    if (!(perms['readPhoneState'] ?? false)) {
      await CallerIdSync.requestPermissions();
    }
    final r = await CallerIdSync.line1Number();
    if (!mounted) return;
    setState(() {
      _line1Busy = false;
      _line1Number = r['number'];
      _line1Note = r['note'];
    });
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('尝试获取本机号码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _line1Number == null ? '未取得号码' : _line1Number!,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _line1Number == null ? scheme.error : scheme.primary,
              ),
            ),
            if ((_line1Note ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_line1Note!,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final effective = ref.watch(apiBaseProvider);

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        title: Text('开发者选项',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const _SectionTitle('开发者模式'),
          Card(
            child: SwitchListTile(
              title: const Text('开发者模式'),
              subtitle: const Text('关闭后返回关于页，隐藏本菜单'),
              value: settings.devMode,
              onChanged: (v) {
                if (!v) _turnOff();
              },
            ),
          ),
          const _SectionTitle('服务器'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('服务器地址'),
                  subtitle: Text(effective,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: _editServerUrl,
                ),
                if (settings.baseOverride.isNotEmpty) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.settings_backup_restore),
                    title: const Text('恢复构建期默认地址'),
                    subtitle: const Text(AppConfig.apiBaseUrl,
                        style: TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                    trailing: const Icon(Icons.restore, size: 20),
                    onTap: _clearOverride,
                  ),
                ],
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.wifi_tethering),
                  title: const Text('接口连通性测试'),
                  subtitle: const Text('请求当前服务器的 /api/version'),
                  trailing: const Icon(Icons.network_check, size: 20),
                  onTap: _testConnection,
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('立即重新同步'),
                  subtitle: const Text('用当前服务器地址重新拉取通讯录'),
                  trailing: const Icon(Icons.refresh, size: 20),
                  onTap: _reloadData,
                ),
              ],
            ),
          ),
          const _SectionTitle('测试与诊断'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.phone_iphone),
              title: const Text('尝试获取本机号码'),
              subtitle: Text(
                _line1Note ??
                    '读取 SIM/电话线路号码（双卡/CDMA 常为空，供排查）',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: _line1Busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline, size: 20),
              onTap: _line1Busy ? null : _tryLine1,
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
