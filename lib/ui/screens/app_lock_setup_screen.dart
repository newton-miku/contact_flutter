import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_lock.dart';
import '../../services/biometric_auth.dart';
import '../widgets/pin_code_widgets.dart';

/// 设置 / 修改解锁密码流程。
/// - [requireCurrent] 为 true（修改场景）：先验证旧密码，再输入两次新密码。
/// - 首次设置（enabled 场景）：直接输入两次新密码，完成后默认开启。
/// 数字长度允许 4~6 位；点「下一步/完成」推进，长度不足按钮置灰。
class AppLockSetupScreen extends ConsumerStatefulWidget {
  final bool requireCurrent;
  const AppLockSetupScreen({super.key, this.requireCurrent = false});

  @override
  ConsumerState<AppLockSetupScreen> createState() =>
      _AppLockSetupScreenState();
}

class _AppLockSetupScreenState extends ConsumerState<AppLockSetupScreen> {
  late bool _checkOld = widget.requireCurrent;
  bool _confirming = false;
  String _old = '';
  String _first = '';
  String _newPin = '';
  bool _error = false;
  String? _errorText;

  /// 数字键盘顺序：开启“乱序”时本页随机一份（两遍输入用同一份，避免按键跳动）。
  late final List<int> _padOrder;

  @override
  void initState() {
    super.initState();
    _padOrder = ref.read(appLockProvider).shuffle
        ? NumPad.randomOrder()
        : NumPad.normalOrder;
  }

  String get _buffer => _checkOld ? _old : _newPin;

  set _buffer(String v) {
    if (_checkOld) {
      _old = v;
    } else {
      _newPin = v;
    }
  }

  String get _title {
    if (_checkOld) return '输入当前密码';
    return _confirming ? '再次输入新密码确认' : '设置解锁密码';
  }

  String get _hint {
    if (_checkOld) return '验证旧密码后即可修改';
    return _confirming ? '请再输一次，两次需一致' : '4~6 位数字（用于生物识别不可用时的备用解锁）';
  }

  String get _actionText {
    if (_checkOld) return '验证';
    return _confirming ? '完成' : '下一步';
  }

  bool get _canContinue {
    if (_checkOld) return _old.length >= 4;
    return _newPin.length >= 4;
  }

  void _onDigit(String d) {
    if (_buffer.length >= 6) return;
    setState(() {
      _error = false;
      _errorText = null;
      _buffer = _buffer + d;
    });
  }

  void _onBackspace() {
    if (_buffer.isEmpty) return;
    setState(() {
      _error = false;
      _errorText = null;
      _buffer = _buffer.substring(0, _buffer.length - 1);
    });
  }

  Future<void> _next() async {
    final notifier = ref.read(appLockProvider.notifier);
    if (_checkOld) {
      final ok = await notifier.verify(_old);
      if (!ok) return _fail('旧密码不正确');
      if (!mounted) return;
      setState(() {
        _checkOld = false;
        _old = '';
      });
      return;
    }
    if (!_confirming) {
      // 第一步：记住新密码，进入确认。
      setState(() {
        _first = _newPin;
        _confirming = true;
        _newPin = '';
      });
      return;
    }
    // 确认步：两次须一致。
    if (_newPin != _first) {
      return _fail('两次输入不一致，请重新确认');
    }
    // 完成：已配置过密码（或走了验证旧密码流程）= 改密码；否则 = 首次设置。
    final isChange =
        widget.requireCurrent || ref.read(appLockProvider).configured;
    if (isChange) {
      await notifier.changePin(_first);
    } else {
      await notifier.setUp(_first);
      // 首次设置完成：顺手测一次生物识别，确认冷启动能正常唤起（支持才弹）。
      if (mounted) await _bioTestOnEnable();
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  /// 设备支持生物识别且已开启时，测一次认证；结果以系统弹窗反馈，不阻断流程。
  Future<void> _bioTestOnEnable() async {
    if (!ref.read(appLockProvider).bioEnabled) return;
    final bio = BiometricAuth();
    final cap = await bio.checkCapability();
    if (cap != BiometricCapability.available) return;
    await bio.tryAuthenticate(
      reason: '解锁密码已设置，测试指纹 / 面部识别',
      skipIfNotAvailable: false,
    );
  }

  void _fail(String msg) {
    HapticFeedback.vibrate();
    if (!mounted) return;
    setState(() {
      _error = true;
      _errorText = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_checkOld || !_confirming ? '设置应用锁' : '确认新密码')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_title,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(_hint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 20),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _error ? 1 : 0.2,
                    child: PinDots(
                      total: 6,
                      filled: _buffer.length,
                      error: _error,
                    ),
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(_errorText!,
                        style: TextStyle(color: colorScheme.error, fontSize: 13)),
                  ],
                  const SizedBox(height: 24),
                  NumPad(
                    onDigit: _onDigit,
                    onBackspace: _onBackspace,
                    digitOrder: _padOrder,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _canContinue ? _next : null,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: Text(_actionText),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                    ),
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
