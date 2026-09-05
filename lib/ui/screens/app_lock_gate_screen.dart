import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_lock.dart';
import '../../services/biometric_auth.dart';
import '../widgets/pin_code_widgets.dart';

/// 冷启动锁屏：默认优先弹生物识别；不可用/失败时用数字密码。
/// 解锁成功后 provider 置 unlocked，本页自动被顶层路由替换为主界面。
class AppLockGateScreen extends ConsumerStatefulWidget {
  const AppLockGateScreen({super.key});

  @override
  ConsumerState<AppLockGateScreen> createState() => _AppLockGateScreenState();
}

class _AppLockGateScreenState extends ConsumerState<AppLockGateScreen> {
  final BiometricAuth _bio = BiometricAuth();

  String _pin = '';
  bool _error = false;
  bool _bioBusy = false;
  bool _bioSupported = true; // 探测后若不可用则隐藏指纹入口
  String? _bioMsg; // 生物识别失败/取消的提示

  /// 数字键盘顺序：开启“乱序”时本次会话随机一份（固定，避免按键跳动）。
  late final List<int> _padOrder;

  int get _pinLength {
    final n = ref.read(appLockProvider.notifier);
    final len = n.pinLength;
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
      // 稍微延迟再尝试生物识别：App 刚冷启动时立刻弹认证框容易被系统吞掉。
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      _probeAndAutoBio();
    });
  }

  Future<void> _probeAndAutoBio() async {
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
    // 冷启动自动弹一次生物识别（银行 App 体验）
    await _tryBio();
  }

  Future<void> _tryBio() async {
    if (_bioBusy) return;
    setState(() => _bioBusy = true);
    final result = await _bio.tryAuthenticate(
      reason: '解锁「通讯录」',
      skipIfNotAvailable: false,
    );
    if (!mounted) return;
    setState(() => _bioBusy = false);
    if (result.granted) {
      await ref.read(appLockProvider.notifier).unlockSession();
    } else if (_bioSupported) {
      // 未通过：给一句提示，停留在密码面板。
      setState(() => _bioMsg = '生物识别未通过或已取消，请用下方密码');
    }
  }

  void _onDigit(String d) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _error = false;
      _bioMsg = null;
      _pin += d;
    });
    if (_pin.length == _pinLength) {
      _submit();
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _error = false;
      _bioMsg = null;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _submit() async {
    final ok = await ref.read(appLockProvider.notifier).verify(_pin);
    if (ok) return; // 由 provider 状态变化移除本页
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
    final state = ref.watch(appLockProvider);
    final showBio = state.bioEnabled && _bioSupported;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 24),
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(Icons.contact_phone,
                        size: 46, color: colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 16),
                  Text('通讯录已锁定',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    showBio ? '请验证指纹/面部，或输入密码' : '请输入解锁密码',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  PinDots(total: _pinLength, filled: _pin.length, error: _error),
                  if (_bioMsg != null) ...[
                    const SizedBox(height: 14),
                    Text(_bioMsg!,
                        style: TextStyle(color: colorScheme.error, fontSize: 13)),
                  ],
                  const SizedBox(height: 24),
                  if (showBio) ...[
                    _FingerprintButton(
                      busy: _bioBusy,
                      onTap: _tryBio,
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

class _FingerprintButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;

  const _FingerprintButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.primaryContainer,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? null : onTap,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(
            busy ? Icons.hourglass_top : Icons.fingerprint,
            size: 34,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
