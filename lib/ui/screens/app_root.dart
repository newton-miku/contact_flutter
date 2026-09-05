import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_lock.dart';
import 'app_lock_gate_screen.dart';
import 'app_lock_setup_screen.dart';
import 'home_screen.dart';

/// App 根路由：冷启动门禁 + 首次启动“设置应用锁”引导。
///
/// 规则：
/// - Windows/桌面版不做解锁要求，直接进主界面；
/// - 手机端：冷启动时若已设置并开启应用锁 → 先显示解锁页，验证后才进入主界面；
///   切后台再回来不重复锁；
/// - 首次启动（未设置过密码且未处理过引导）→ 弹一次“设置应用锁”，可跳过
///   （跳过按钮做小、低对比）。
class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  bool _prompted = false;

  static bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(appLockProvider);

    // 桌面/网页版：不启用应用锁。
    if (!_mobile) return const HomeScreen();

    // 本地设置尚未读取完成：先显示空白页，避免“闪一下主界面再上锁”。
    if (!state.ready) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: const SizedBox.expand(),
      );
    }

    // 需要解锁（冷启动）：显示解锁页。
    if (state.shouldLock) {
      return const AppLockGateScreen();
    }

    // 首次启动引导：处理过一次（设置或跳过）后不再打扰。
    if (!_prompted && !state.askedOnce && !state.configured) {
      _prompted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showOnboarding());
    }

    return const HomeScreen();
  }

  Future<void> _showOnboarding() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.lock_outline, size: 40, color: scheme.primary),
          title: const Text('为通讯录加把锁？'),
          content: const Text(
            '可设置一个 4~6 位解锁密码：以后每次打开 App 时，用指纹/面部或密码验证身份，'
            '避免单位通讯录被他人翻阅。\n\n也可以先跳过，之后在首页 ⋮ 菜单「应用锁」中随时开启。',
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: () => _chooseSetup(ctx),
                  child: const Text('设置解锁密码'),
                ),
                const SizedBox(height: 6),
                // 跳过：小号、低对比，刻意不显眼。
                TextButton(
                  onPressed: () {
                    ref.read(appLockProvider.notifier).markAskedOnce();
                    Navigator.of(ctx).pop();
                  },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: scheme.outline,
                    textStyle:
                        const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
                  ),
                  child: const Text('暂时跳过'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _chooseSetup(BuildContext ctx) async {
    Navigator.of(ctx).pop(); // 先关引导弹窗
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => const AppLockSetupScreen(),
      ),
    );
  }
}
