import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/contacts_provider.dart';
import '../../data/remote/contact_api.dart';
import '../../services/device_auth.dart';

/// 修改密码页（桌面端账号密码通道）。
///
/// 两种用法：
/// - [forced] = true：首次登录 / 被管理员重置密码后的强制改密。由 `AppRoot`
///   作为根 widget 直接返回，**不是 push 出来的路由**，所以没有任何返回或关闭
///   路径；另外留一个「退出登录」逃生口，免得不知道当前密码的用户被彻底卡死。
/// - [forced] = false：首页 ⋮ 菜单里的自愿改密，正常可返回，改完 `pop(true)`。
///
/// 服务端在改密成功时会清零 `must_change_password`、并让其它设备的会话失效
/// （保留当前会话，所以本机令牌继续可用）。
class PasswordChangeScreen extends ConsumerStatefulWidget {
  const PasswordChangeScreen({super.key, this.forced = false});

  /// 是否处于「首次登录强制改密」状态。
  final bool forced;

  @override
  ConsumerState<PasswordChangeScreen> createState() =>
      _PasswordChangeScreenState();
}

class _PasswordChangeScreenState extends ConsumerState<PasswordChangeScreen> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // 本地只拦"格式"；口令对不对由服务端判定（原密码不正确会带 message 回来）。
    if (_old.text.isEmpty) {
      setState(() => _error = '请输入当前密码');
      return;
    }
    if (_new.text.length < 6) {
      setState(() => _error = '新密码至少 6 位');
      return;
    }
    if (_new.text != _again.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(contactApiProvider).changePassword(
            oldPassword: _old.text,
            newPassword: _new.text,
          );
      // 服务端已清零标记，本地同步一份：桌面端冷启动那条拦截才会解除。
      await ref.read(deviceAuthProvider.notifier).setMustChangePassword(false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码已修改'), behavior: SnackBarBehavior.floating),
      );
      // 强制模式下本页是根 widget：标记一变，AppRoot 自己就换成主界面了。
      if (widget.forced) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '修改失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 强制模式下的逃生口：不知道当前密码时，至少能退出登录去问管理员。
  Future<void> _logout() async {
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
    if (yes != true || !mounted) return;
    await ref.read(deviceAuthProvider.notifier).clear();
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    bool autofocus = false,
    ValueChanged<String>? onSubmitted,
  }) =>
      TextField(
        controller: controller,
        enabled: !_busy,
        obscureText: true,
        autofocus: autofocus,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.lock_outline),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('修改密码'),
        // 强制模式下不给返回箭头：这一页是没法"退出去"的。
        automaticallyImplyLeading: !widget.forced,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.forced) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.lock_reset, color: scheme.onErrorContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '首次登录，请先修改初始密码',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: scheme.onErrorContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '当前账号仍在使用初始密码，修改后才能使用其它功能。',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onErrorContainer,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                  ] else ...[
                    Text(
                      '修改后其它设备需要重新登录，本机继续有效。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                  ],
                  _field(
                    controller: _old,
                    label: '当前密码',
                    autofocus: widget.forced,
                  ),
                  const SizedBox(height: 14),
                  _field(controller: _new, label: '新密码（至少 6 位）'),
                  const SizedBox(height: 14),
                  _field(
                    controller: _again,
                    label: '再次输入新密码',
                    onSubmitted: (_) => _busy ? null : _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!,
                        style: TextStyle(color: scheme.error, fontSize: 13)),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('保存'),
                  ),
                  if (widget.forced) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _busy ? null : _logout,
                      child: const Text('退出登录'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
