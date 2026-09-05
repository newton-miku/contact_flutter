import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_lock.dart';
import '../../services/biometric_auth.dart';
import '../widgets/pin_code_widgets.dart';

/// 一次性身份验证页（用于“关闭应用锁”等敏感操作前确认）。
/// 验证通过后 pop(true)；生物识别为主、数字密码备用。
class AppLockVerifyScreen extends ConsumerStatefulWidget {
  final String title;
  final String message;
  const AppLockVerifyScreen({
    super.key,
    this.title = '验证身份',
    this.message = '请验证指纹/面部，或输入当前密码',
  });

  @override
  ConsumerState<AppLockVerifyScreen> createState() =>
      _AppLockVerifyScreenState();
}

class _AppLockVerifyScreenState extends ConsumerState<AppLockVerifyScreen> {
  final BiometricAuth _bio = BiometricAuth();

  String _pin = '';
  bool _error = false;
  bool _bioBusy = false;
  bool _bioSupported = true;
  late final List<int> _padOrder;

  int get _pinLength {
    final len = ref.read(appLockProvider.notifier).pinLength;
    return len > 0 ? len : 6;
  }

  @override
  void initState() {
    super.initState();
    _padOrder = ref.read(appLockProvider).shuffle
        ? NumPad.randomOrder()
        : NumPad.normalOrder;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final state = ref.read(appLockProvider);
      if (!state.bioEnabled) {
        setState(() => _bioSupported = false);
        return;
      }
      final cap = await _bio.checkCapability();
      if (!mounted) return;
      if (cap != BiometricCapability.available) {
        setState(() => _bioSupported = false);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      await _tryBio();
    });
  }

  Future<void> _tryBio() async {
    if (_bioBusy) return;
    setState(() => _bioBusy = true);
    final result = await _bio.tryAuthenticate(
      reason: widget.title,
      skipIfNotAvailable: false,
    );
    if (!mounted) return;
    setState(() => _bioBusy = false);
    if (result.granted) Navigator.of(context).pop(true);
  }

  void _onDigit(String d) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _error = false;
      _pin += d;
    });
    if (_pin.length == _pinLength) _submit();
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _error = false;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _submit() async {
    final ok = await ref.read(appLockProvider.notifier).verify(_pin);
    if (ok) {
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    if (!mounted) return;
    HapticFeedback.vibrate();
    setState(() => _error = true);
    await Future.delayed(const Duration(milliseconds: 350));
    if (mounted) {
      setState(() {
        _pin = '';
        _error = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final showBio = _bioSupported;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 24),
                  PinDots(total: _pinLength, filled: _pin.length, error: _error),
                  const SizedBox(height: 24),
                  if (showBio) ...[
                    Material(
                      color: colorScheme.primaryContainer,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _bioBusy ? null : _tryBio,
                        child: SizedBox(
                          width: 60,
                          height: 60,
                          child: Icon(
                            _bioBusy ? Icons.hourglass_top : Icons.fingerprint,
                            size: 32,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('指纹 / 面部识别',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 24),
                  ],
                  NumPad(
                    onDigit: _onDigit,
                    onBackspace: _onBackspace,
                    digitOrder: _padOrder,
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
