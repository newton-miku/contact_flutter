import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/contacts_provider.dart';
import '../../services/app_lock.dart';
import '../../services/caller_id_guide.dart';
import '../../services/caller_id_sync.dart';
import '../../services/device_auth.dart';
import 'activation_screen.dart';
import 'login_screen.dart';
import 'app_lock_gate_screen.dart';
import 'app_lock_setup_screen.dart';
import 'caller_id_settings_screen.dart';
import 'home_screen.dart';
import 'password_change_screen.dart';

/// App 根路由：设备激活门禁 + 冷启动应用锁 + 首次启动引导（应用锁 → 来电显示）。
///
/// 规则（自上而下）：
/// 1. 未激活（无设备令牌）→ 激活页；令牌失效（401）→ 清令牌回激活页；
/// 2. 桌面版：账号还在用初始/被重置的密码（`mustChangePassword`）→ 强制改密页，
///    改完才进主界面；否则直接进主界面（不做应用锁）；
/// 3. 手机端冷启动若已设置并开启应用锁 → 先解锁；切后台再回来不重复锁；
/// 4. 首次启动引导**一次只弹一件**，按顺序排队：
///    ① 应用锁（未设置过密码且未处理过引导）→ 弹一次，可跳过；
///    ② 来电显示（仅 Android，且号码库已有数据、功能还关着）→ 弹一次，可跳过。
///    两条各有独立的持久化标记，互不叠加；每条都只负责"讲价值 + 带路"，
///    真正的权限申请留在各自的设置页由用户点击触发。
class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  /// 有引导弹窗/页面正在进行：期间不再排下一条，绝不叠两个框。
  bool _guideBusy = false;

  /// 本会话内 ① 应用锁引导是否已走完（设置完或跳过），走完才轮到 ②。
  bool _appLockGuideDone = false;

  /// ② 来电显示引导本会话是否已排过（防重）。
  bool _callerIdGuideScheduled = false;

  /// ② 是否还需要弹：null = 本地标记 / 原生开关尚未读出。
  bool? _callerIdGuidePending;

  /// 桌面端冷启动的「强制改密」复检是否已排过（每进程一次）。
  bool _mustChangeRecheckScheduled = false;

  static bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// 来电显示是原生 Android 能力：`CallerIdSync` 通道只有 Android 实现。
  static bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (_android) _resolveCallerIdGuide();
  }

  /// 读本地标记 + 原生开关，决定还要不要弹「来电显示」引导。
  ///
  /// 已经开启过该功能的设备（例如标记丢了但开关还开着）不再打扰：
  /// 引导的目的只是"让人用上"，已经在用的人不需要再被教育一遍。
  Future<void> _resolveCallerIdGuide() async {
    final asked = await CallerIdGuide.askedOnce();
    final alreadyOn = asked ? true : await CallerIdSync.isEnabled();
    if (!mounted) return;
    setState(() => _callerIdGuidePending = !(asked || alreadyOn));
  }

  /// 桌面端冷启动复检「首次登录强制改密」标记，以服务端为准对齐一次。
  ///
  /// 本地那份只是登录时的快照：用户可能在网页端改过密码（服务端已清零），
  /// 也可能刚被管理员重置（服务端又置 1），而桌面端冷启动是用本地令牌直接进
  /// 主界面的、不会重走登录接口，所以必须补这一问。
  ///
  /// 请求失败（离线 / 服务端异常）时保留本地值：宁可维持上次已知状态，也不要
  /// 因为一次网络抖动就把还在用初始密码的账号放进主界面。
  Future<void> _refreshMustChangePassword() async {
    bool must;
    try {
      must = await ref.read(contactApiProvider).fetchMustChangePassword();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (must != ref.read(deviceAuthProvider).mustChangePassword) {
      await ref.read(deviceAuthProvider.notifier).setMustChangePassword(must);
    }
  }

  Widget _blank() => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    body: const SizedBox.expand(),
  );

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(deviceAuthProvider);
    final lock = ref.watch(appLockProvider);
    final contacts = ref.watch(contactsProvider);

    if (!auth.ready) return _blank();

    // 令牌失效（HTTP 401）：清掉本地令牌，回到激活页。
    if (contacts.unauthorized && auth.activated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(deviceAuthProvider.notifier).clear();
      });
    }
    if (!auth.activated || contacts.unauthorized) {
      // 手机端：激活码；桌面端：账号密码登录。
      return _mobile ? const ActivationScreen() : const LoginScreen();
    }

    // 桌面/网页版：不做应用锁。
    if (!_mobile) {
      // 首次登录 / 被管理员重置密码：未改密前不放行主界面（与 Web 管理页一致）。
      // 先按本地标记决策，再后台向服务端对齐一次，避免"先闪一下主界面再拦回来"。
      if (!_mustChangeRecheckScheduled && auth.activated) {
        _mustChangeRecheckScheduled = true;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _refreshMustChangePassword());
      }
      return auth.mustChangePassword
          ? const PasswordChangeScreen(forced: true)
          : const HomeScreen();
    }

    // 应用锁设置尚未读取完成：先空白页，避免“闪一下主界面再上锁”。
    if (!lock.ready) return _blank();

    // 需要解锁（冷启动）：显示解锁页。
    if (lock.shouldLock) {
      return const AppLockGateScreen();
    }

    _maybeScheduleGuide(lock, contacts);

    return const HomeScreen();
  }

  /// 首次启动引导的排队逻辑：一次只弹一件，且必须满足“弹了有用”的前提。
  ///
  /// ① 应用锁：未设置过密码、也没处理过引导 → 先弹；
  /// ② 来电显示：① 走完之后，仅 Android、本地标记未处理、功能还关着，
  ///    并且**号码库已有数据**（联系人还没同步就打开开关，用户第一次接电话
  ///    只会看到“陌生号码”，等于亲手告诉他这功能没用）→ 再弹。
  void _maybeScheduleGuide(AppLockState lock, ContactsState contacts) {
    if (_guideBusy) return;

    if (!lock.askedOnce && !lock.configured && !_appLockGuideDone) {
      _guideBusy = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _runAppLockGuide());
      return;
    }

    final callerIdReady =
        _callerIdGuidePending == true &&
        !_callerIdGuideScheduled &&
        !contacts.loading &&
        contacts.contacts.isNotEmpty;
    if (callerIdReady) {
      _guideBusy = true;
      _callerIdGuideScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _runCallerIdGuide());
    }
  }

  /// 一次性引导弹窗的统一外观：图标 + 标题 + 说明 + 大号主按钮 + 不显眼的「跳过」。
  ///
  /// 返回 true = 点了主按钮，false = 明确跳过，null = 被系统返回键关掉（未做选择）。
  Future<bool?> _askOnce({
    required IconData icon,
    required String title,
    required String content,
    required String primaryLabel,
    required String skipLabel,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(icon, size: 40, color: Theme.of(ctx).colorScheme.primary),
        title: Text(title),
        content: Text(content),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(primaryLabel),
              ),
              const SizedBox(height: 6),
              _skipAction(ctx, skipLabel, () => Navigator.of(ctx).pop(false)),
            ],
          ),
        ],
      ),
    );
  }

  /// 「跳过」按钮：小号、低对比，刻意不显眼（允许跳过，但不鼓励）。
  Widget _skipAction(BuildContext ctx, String label, VoidCallback onTap) {
    final scheme = Theme.of(ctx).colorScheme;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: scheme.outline,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
      ),
      child: Text(label),
    );
  }

  /// ① 应用锁引导：先解释，再让用户选「设置密码 / 暂时跳过」。
  ///
  /// 语义与原实现一致：只有明确点「暂时跳过」才标记已处理（下次不再打扰）；
  /// 被返回键关掉不算表态，下次冷启动会再问一次。
  Future<void> _runAppLockGuide() async {
    final choice = await _askOnce(
      icon: Icons.lock_outline,
      title: '为通讯录加把锁？',
      content:
          '可设置一个 4~6 位解锁密码：以后每次打开 App 时，用指纹/面部或密码验证身份，'
          '避免单位通讯录被他人翻阅。\n\n也可以先跳过，之后在首页 ⋮ 菜单「应用锁」中随时开启。',
      primaryLabel: '设置解锁密码',
      skipLabel: '暂时跳过',
    );
    if (!mounted) return;

    if (choice == true) {
      await Navigator.of(context).push(
        MaterialPageRoute<bool>(builder: (_) => const AppLockSetupScreen()),
      );
    } else if (choice == false) {
      await ref.read(appLockProvider.notifier).markAskedOnce();
    }
    if (!mounted) return;

    // 无论结果如何，本会话的 ① 到此为止：放行 ②，且不再重弹 ①。
    // （用户进了密码页又退出来、没设成密码时，也是这个分支——
    //   此时 configured/askedOnce 都没变，靠 _appLockGuideDone 兜住。）
    setState(() {
      _appLockGuideDone = true;
      _guideBusy = false;
    });
  }

  /// ② 来电显示引导（仅 Android）：只负责“讲价值 + 带路”。
  ///
  /// 真正的权限申请、角色申请、跳系统设置全部交给 [CallerIdSettingsScreen]，
  /// 由用户在那一页逐项点击触发：Android 11+ 连续两次拒绝即永久拒绝，
  /// 首次启动一次性甩完三五个系统弹框，拒绝率最高且很难挽回。
  Future<void> _runCallerIdGuide() async {
    final choice = await _askOnce(
      icon: Icons.phone_in_talk_outlined,
      title: '来电时自动显示名片？',
      content:
          '开启后，通讯录里的人打来电话，会弹出对方的姓名、单位和职务，'
          '不必先接起来问是谁。\n\n'
          '首次开启需要授予「电话 / 通话记录 / 通知」等系统权限，进去后按提示逐项授权即可。\n\n'
          '也可以先跳过，之后在首页 ⋮ 菜单「来电显示」中随时开启。',
      primaryLabel: '去开启',
      skipLabel: '以后再说',
    );

    // 明确表态（开启 / 跳过）才算处理过，之后不再打扰；
    // 被返回键关掉不算表态，下次启动最多再问一次。
    if (choice != null) await CallerIdGuide.markAsked();
    if (!mounted) return;

    setState(() {
      _callerIdGuidePending = false;
      _guideBusy = false;
    });

    if (choice == true) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const CallerIdSettingsScreen()));
    }
  }
}
