import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/contacts_provider.dart';
import '../../data/remote/contact_api.dart';
import '../../services/device_auth.dart';

/// 桌面端账号密码登录页。
/// 手机端暂不提供账号密码登录（走一次性激活码），仅桌面端使用本页。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _user.text.trim();
    final password = _pwd.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入账号和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(contactApiProvider)
          .login(username: username, password: password);
      await ref.read(deviceAuthProvider.notifier).save(
            token: result.token,
            username: result.username,
            displayName: result.displayName,
            // 首次登录 / 被重置密码：AppRoot 据此把人拦在改密页，不放行主界面。
            mustChangePassword: result.mustChangePassword,
          );
      await ref.read(contactsProvider.notifier).load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
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
                  Container(
                    width: 84,
                    height: 84,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(Icons.contact_phone,
                        size: 46, color: colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 18),
                  Text('登录通讯录',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    '桌面端使用管理员发放的账号密码登录。\n手机端请使用激活码（本页不适用于手机）。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _user,
                    enabled: !_busy,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      hintText: '管理员发放的用户名 / 座机号',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _pwd,
                    enabled: !_busy,
                    obscureText: true,
                    onSubmitted: (_) => _busy ? null : _submit(),
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!,
                        style: TextStyle(color: colorScheme.error, fontSize: 13)),
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
                        : const Text('登录'),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '没有账号？请联系管理员在后台创建（或从通讯录导入）。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
