import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../data/models/contact.dart';
import '../../data/providers/contacts_provider.dart';
import '../../services/caller_id_sync.dart';
import '../../services/pinyin_search.dart';

/// 来电显示名片设置：
/// - 主开关：打开时向系统申请 READ_PHONE_STATE / READ_CALL_LOG / POST_NOTIFICATIONS；
/// - 权限状态逐项展示，可跳系统设置补授权；
/// - Android 14+ 的“全屏提醒”需在系统通知设置里单独放行，这里一键直达；
/// - 「测试与预览」：从通讯录挑一个人模拟来电（走真实响铃后的匹配+全屏链路）、
///   或直接预览名片界面，用于定位“开了却没反应”卡在哪一步；
/// - 「运行状态」：号码库条数 + 最近一次系统来电广播是否送达本应用（诊断后台限制）。
class CallerIdSettingsScreen extends ConsumerStatefulWidget {
  const CallerIdSettingsScreen({super.key});

  @override
  ConsumerState<CallerIdSettingsScreen> createState() => _CallerIdSettingsScreenState();
}

class _CallerIdSettingsScreenState extends ConsumerState<CallerIdSettingsScreen>
    with WidgetsBindingObserver {
  final bool _android = defaultTargetPlatform == TargetPlatform.android;
  bool _loading = true;
  bool _enabled = false;
  bool _keepAlive = true; // 后台常驻（前台服务保活），默认开
  Map<String, bool> _perms = const {};
  bool? _fullScreenOk; // false=需在系统设置开启（仅 Android 14+）；null=非安卓
  CallerIdStatus? _status;

  // 测试目标：从通讯录挑一个人 + 具体测哪个号码
  RemoteContact? _testContact;
  String? _testNumber;
  bool _schedulingDefault = false;
  bool _busyTest = false;
  String? _testResult;
  _ResultKind _testResultKind = _ResultKind.info;

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

  /// 当前已加载的、有号码可测的联系人。
  List<RemoteContact> get _contactsWithPhones => ref
      .read(contactsProvider)
      .contacts
      .map((s) => s.contact)
      .where((c) => c.dialablePhones.isNotEmpty)
      .toList();

  /// 全部原始联系人（重新推给号码库用）。
  List<RemoteContact> get _allContacts =>
      ref.read(contactsProvider).contacts.map((s) => s.contact).toList();

  Future<void> _reload() async {
    if (!_android) {
      if (mounted && _loading) setState(() => _loading = false);
      return;
    }
    final enabled = await CallerIdSync.isEnabled();
    final keepAlive = await CallerIdSync.isKeepAlive();
    final perms = await CallerIdSync.permissions();
    final st = await CallerIdSync.status();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _enabled = enabled;
      _keepAlive = keepAlive;
      _perms = perms;
      _fullScreenOk = st.fullScreenOk;
      _status = st;
    });
  }

  /// 关键权限缺失项数（电话状态 / 通话记录 / 通知），用于顶部引导卡。
  int get _missingCount {
    if (_loading || !_enabled) return 0;
    var n = 0;
    if (!(_perms['readPhoneState'] ?? false)) n++;
    if (!(_perms['readCallLog'] ?? false)) n++;
    if (!(_perms['notifications'] ?? false)) n++;
    return n;
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
    final phone = _perms['readPhoneState'] ?? false;
    if (!notif) {
      await _askOpenSettings('通知权限未授予：来电名片无法弹出。',
          target: 'notification');
    } else if (!callLog || !phone) {
      await _askOpenSettings('「电话 / 通话记录」权限未授予：Android 10+ 会读不到来电号码，名片无法显示。');
    }
  }

  /// 权限拿不到时的引导：确认后【直接跳转】对应系统设置页，不再只给一个按钮让用户自己找。
  Future<void> _askOpenSettings(String message, {String target = 'app'}) async {
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber, size: 36),
        title: const Text('还需要授权'),
        content: Text('$message\n\n点「去系统设置」直接打开对应页面；开启后返回本页会自动刷新状态。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去系统设置'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await CallerIdSync.openSettings(target);
    if (mounted) _toast('已打开系统设置，开启权限后返回即可');
  }

  Future<void> _onToggleKeepAlive(bool on) async {
    await CallerIdSync.setKeepAlive(on);
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    if (on) {
      final notif = _perms['notifications'] ?? false;
      _toast(
        notif
            ? '已开启后台常驻：会常驻一条静默通知以保活'
            : '已开启后台常驻；但通知权限未授予，保活通知可能不显示，建议一并开启通知。',
        openSettings: !notif,
      );
    } else {
      _toast('已关闭后台常驻：从最近任务划掉后，来电名片可能收不到广播');
    }
  }

  /// 无电脑时给用户抄的命令（可用「另一台手机 + 无线调试」执行）。
  static const String _roleAdbCommand =
      'adb shell cmd role set-bypassing-role-qualification true\n'
      'adb shell cmd role add-role-holder --user 0 '
      'android.app.role.CALL_SCREENING com.newtonmiku.contact_flutter_shiquan';

  Future<void> _copyRoleAdbCommand() async {
    await Clipboard.setData(const ClipboardData(text: _roleAdbCommand));
    if (!mounted) return;
    _toast('已复制授权命令');
  }

  /// 申请「来电筛选」角色（系统弹框）；申请后刷新状态。
  ///
  /// 已知问题：部分荣耀 MagicOS 10 / Android 16 机型上，系统那个角色弹框点「确定」会
  /// 崩在系统进程（permissioncontroller 的 NullPointerException: parameter current），
  /// 弹框直接消失、角色拿不到，而且系统侧不会给应用任何异常。检测到这种情况时，
  /// 不再让用户反复点，直接给可执行的替代方案。
  Future<void> _requestScreeningRole() async {
    final res = await CallerIdSync.requestScreeningRole();
    if (!mounted) return;
    await _reload();
    if (!mounted) return;

    if (res.held) {
      _toast('已取得「来电筛选」角色：来电名片会更快弹出');
      return;
    }
    if (res.dialogCrashed) {
      await _showScreeningRoleUnsupportedByRomDialog();
      return;
    }
    _toast(res.reason == 'unavailable'
        ? '本机不提供「来电筛选」角色（被其它应用占用或被系统限制）'
        : '未取得「来电筛选」角色，仍在用广播+补号方式取号');
  }

  /// 系统角色界面崩溃时的说明与替代路径（本 ROM 上无法通过界面授权）。
  Future<void> _showScreeningRoleUnsupportedByRomDialog() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.report_problem_outlined),
        title: const Text('系统弹框自己崩了'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '点「确定」的瞬间，是系统的「默认应用」界面崩了，不是本应用的问题：\n'
                'com.android.permissioncontroller 抛了 NullPointerException，'
                '所以弹框会突然消失、角色也拿不到。',
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 12),
              const Text('可用以下任一方式：',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text(
                '1. 先不管它：广播 + 补号的取号方式仍然可用，只是名片可能晚几秒。\n'
                '2. 用另一台手机开「无线调试」连过来，执行下面的命令（一次性）：',
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const SelectableText(_roleAdbCommand,
                    style: TextStyle(
                        fontFamily: 'monospace', fontSize: 12, height: 1.5)),
              ),
              const SizedBox(height: 8),
              const Text('授予后回来刷新本页即可看到「已开启」。',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('知道了'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop(false);
              await _copyRoleAdbCommand();
            },
            child: const Text('复制命令'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去开无线调试'),
          ),
        ],
      ),
    );
    if (go == true) {
      await CallerIdSync.openWirelessDebugging();
    }
  }

  Future<void> _grant(String permission) async {
    if (!mounted) return;
    // 已被「永久拒绝」时系统不会再弹授权框，只能去系统设置——直接带用户过去。
    final notifDenied = permission == 'notifications' &&
        (await ph.Permission.notification.status).isPermanentlyDenied;
    final phoneDenied = (await ph.Permission.phone.status).isPermanentlyDenied;
    if (notifDenied || phoneDenied) {
      final target = notifDenied ? 'notification' : 'app';
      _toast(notifDenied ? '通知权限已被拒绝，已为你打开通知设置' : '电话权限已被拒绝，已为你打开应用设置');
      await CallerIdSync.openSettings(target);
      return;
    }

    _perms = await CallerIdSync.requestPermissions();
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    // 申请后仍未授予：多半是被拒绝且不再弹框，直接引导去系统设置。
    if (!(_perms['readPhoneState'] ?? false) || !(_perms['readCallLog'] ?? false)) {
      await _askOpenSettings('「电话 / 通话记录」权限未授予，来电将读不到号码。');
    } else if (!(_perms['readContacts'] ?? false)) {
      await _askOpenSettings('「读取联系人」权限未授予，来电只能拿到号码、匹配不出是谁。');
    } else if (!(_perms['notifications'] ?? false)) {
      await _askOpenSettings('通知权限未授予，来电名片无法弹出。', target: 'notification');
    }
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

  // ---------- 测试 / 预览 ----------

  void _maybePickDefaultTestTarget() {
    // 通讯录加载好之前不打扰；拿到第一个有号码的人作为默认测试对象。
    if (_testContact != null || _schedulingDefault || _contactsWithPhones.isEmpty) return;
    _schedulingDefault = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _schedulingDefault = false;
      if (!mounted || _testContact != null) return;
      final list = _contactsWithPhones;
      if (list.isEmpty) return;
      setState(() {
        _testContact = list.first;
        _testNumber = list.first.dialablePhones.first;
      });
    });
  }

  Future<void> _pickContact() async {
    final list = _contactsWithPhones;
    if (list.isEmpty) {
      _toast('通讯录数据尚未加载。请先返回主界面刷新成功后再来测试。');
      return;
    }
    final picked = await showModalBottomSheet<RemoteContact>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ContactPickerSheet(contacts: list),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _testContact = picked;
      _testNumber = picked.dialablePhones.first;
      _testResult = null;
    });
  }

  /// 测试主按钮：先把手头目录重新推给号码库，再模拟来电 → 走真实“匹配+全屏通知”链路。
  Future<void> _runSimulate(String number, {required bool expectKnown}) async {
    if (_busyTest) return;
    setState(() {
      _busyTest = true;
      _testResult = null;
    });
    try {
      // 与列表保持一致，避免号码库过期导致误判“未命中”。
      await CallerIdSync.resync(_allContacts);
      final res = await CallerIdSync.simulateIncoming(number);
      if (!mounted) return;
      setState(() {
        if (res == null) {
          _testResult = '此功能仅 Android 支持。';
          _testResultKind = _ResultKind.error;
        } else if (!res.matched && res.reason == 'notifications') {
          _testResult = '「通知」未开启，名片无法弹出。\n请先在上方「所需权限 → 通知」授权，再来测试。';
          _testResultKind = _ResultKind.error;
        } else if (!res.matched) {
          _testResult = expectKnown
              ? '该号码未命中号码库，按设计不显示。\n（号码已重新推送却仍未命中，多半是原生写入异常——点「运行状态 → 重新同步号码库」重试；也可直接点「预览名片界面」查看名片 UI。）'
              : '陌生号码测试通过：与真实来电一致，未命中则不显示名片。';
          _testResultKind = expectKnown ? _ResultKind.warn : _ResultKind.success;
        } else {
          final parts = <String>[
            '已模拟来电并触发名片链路：',
            '命中「${res.name ?? ''}」',
            if ((res.org ?? '').isNotEmpty) res.org!,
            '号码 ${res.phone ?? number}',
            '',
            _fullScreenOk == false
                ? '若没有全屏弹出，请在上方开启「全屏提醒」。'
                : '若仍没弹出，请确认「通知」已开启；部分机型对“后台弹通知”有额外限制。',
          ];
          _testResult = parts.join('\n');
          _testResultKind = _ResultKind.success;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResult = '测试调用失败：$e';
          _testResultKind = _ResultKind.error;
        });
      }
    } finally {
      if (mounted) setState(() => _busyTest = false);
    }
  }

  /// 陌生号码样例：本地号码库中不存在的一个 11 位手机号。
  String _strangerNumber() {
    final rand = Random();
    final known = <String>{};
    for (final c in _allContacts) {
      for (final p in c.dialablePhones) {
        known.add(p.replaceAll(RegExp(r'\D'), ''));
      }
    }
    const heads = ['13', '15', '18', '19', '17'];
    for (var i = 0; i < 40; i++) {
      final n = heads[rand.nextInt(heads.length)] +
          List.generate(9, (_) => rand.nextInt(10)).join();
      if (!known.contains(n)) return n;
    }
    return '19900000000'; // 兜底（预留号段，通讯录不会收录）
  }

  Future<void> _resyncNow() async {
    try {
      await CallerIdSync.resync(_allContacts);
      final st = await CallerIdSync.status();
      if (!mounted) return;
      setState(() => _status = st);
      _toast('号码库已与当前目录重新同步。');
    } catch (_) {
      _toast('同步失败（非 Android 或通道不可用）。');
    }
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    _maybePickDefaultTestTarget();

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
                    if (_missingCount > 0) ...[
                      const SizedBox(height: 12),
                      _PermissionBanner(
                        missingCount: _missingCount,
                        onGrantAll: () => _grant('phone'),
                        onOpenSettings: () => CallerIdSync.openSettings('app'),
                      ),
                    ],
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
                    // 后台常驻（前台服务保活）：仅在功能开启时显示，默认开。
                    if (_enabled) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: SwitchListTile(
                          value: _keepAlive,
                          onChanged: _onToggleKeepAlive,
                          title: const Text('后台常驻（划掉也尽量保持运行）'),
                          subtitle: Text(_keepAlive
                              ? '已开启：以前台服务保活，会常驻一条静默通知'
                              : '关闭后，从最近任务划掉可能收不到来电广播'),
                          secondary: Icon(Icons.shield_moon_outlined,
                              color: _keepAlive
                                  ? colorScheme.primary
                                  : colorScheme.outline),
                        ),
                      ),
                      if (_keepAlive)
                        const _TipCard(
                          icon: Icons.battery_alert,
                          title: '会略微增加耗电',
                          subtitle: '保活需要常驻一条“来电名片运行中”的通知（静默、不弹横幅）。'
                              '若不再需要来电名片，直接关闭上面的「开启来电显示」即可。',
                          dim: true,
                        ),
                    ],
                    // 来电筛选：响铃瞬间拿号码（比通话记录早数秒），名片最快的一条路。
                    const _SectionHeader('来电筛选（推荐）'),
                    Card(
                      child: ListTile(
                        leading: Icon(
                          (_status?.screeningRoleHeld ?? false)
                              ? Icons.verified
                              : Icons.hourglass_empty,
                          color: (_status?.screeningRoleHeld ?? false)
                              ? Colors.green
                              : colorScheme.error,
                        ),
                        title: Text((_status?.screeningRoleHeld ?? false)
                            ? '已开启：响铃瞬间即可拿到号码'
                            : (_status?.screeningRoleAvailable ?? true)
                                ? '未开启：来电名片可能要等几秒才弹'
                                : '本机不可用：该角色已被其它应用占用或被系统限制'),
                        subtitle: Text((_status?.screeningRoleHeld ?? false)
                            ? '来电筛选只用于取号展示，不会拦截或静音任何电话'
                            : 'Android 10+ 的响铃广播常不带号码，通话记录又要等系统写库（可能数秒）。'
                                '授予「来电筛选」角色后，系统会在来电建立瞬间把号码交给我们，名片近乎即时。'
                                '（只做展示，绝不拦截电话）'),
                        isThreeLine: !(_status?.screeningRoleHeld ?? false),
                        trailing: (_status?.screeningRoleHeld ?? false)
                            ? null
                            : ((_status?.screeningRoleAvailable ?? true)
                                ? FilledButton(
                                    onPressed: _requestScreeningRole,
                                    child: const Text('去授权'),
                                  )
                                : null),
                      ),
                    ),
                    // 部分荣耀 MagicOS 10 机型：系统角色弹框点「确定」必崩在系统进程，
                    // 界面授权这条路走不通，直接把可用命令摆出来，别让用户反复点。
                    if (_android && !(_status?.screeningRoleHeld ?? false))
                      _TipCard(
                        icon: Icons.info_outline,
                        title: '若点「确定」后弹框突然消失',
                        subtitle: '那是荣耀系统的「默认应用」界面崩了'
                            '（com.android.permissioncontroller 报 NullPointerException），'
                            '不是本应用的问题，且系统不会产生本应用的崩溃记录。\n'
                            '此时用另一台手机开「无线调试」连过来执行下面命令即可（一次性）：\n'
                            '$_roleAdbCommand',
                        trailing: IconButton(
                          tooltip: '复制命令',
                          icon: const Icon(Icons.copy_all),
                          onPressed: _copyRoleAdbCommand,
                        ),
                      ),
                    if (_android &&
                        (_status?.screeningRoleHeld ?? false) &&
                        !(_status?.readContacts ?? true))
                      const _TipCard(
                        icon: Icons.warning_amber_rounded,
                        title: '「读取联系人」未授权',
                        subtitle: '来电筛选已经能拿到号码了，但没有通讯录权限就匹配不出是谁，'
                            '名片不会显示内容。请在下方「所需权限」里补上。',
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
                            title: '读取联系人',
                            subtitle: '拿到来电号码后匹配出是谁；缺它则只能拿到号码、弹不出内容',
                            granted: _status?.readContacts ?? false,
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
                            color: _fullScreenOk! ? Colors.green : colorScheme.error,
                          ),
                          title: Text(_fullScreenOk!
                              ? '全屏提醒已授权'
                              : '未授权「全屏提醒」：来电只会出通知，不弹全屏名片'),
                          subtitle: Text(
                            _fullScreenOk!
                                ? '锁屏或息屏时来电会整屏弹出名片'
                                : 'Android 14+ 把「全屏提醒」列为特殊应用权限，默认不授予。\n'
                                    '开关位置：设置 → 应用 → 特殊应用权限 → 全屏通知 → 本应用。\n'
                                    '（「通知设置」里没有这个开关，必须走上面这个入口）',
                          ),
                          isThreeLine: !_fullScreenOk!,
                          trailing: _fullScreenOk!
                              ? null
                              : const FilledButton(
                                  onPressed: CallerIdSync.openFullScreenSettings,
                                  child: Text('去开启'),
                                ),
                        ),
                      ),
                    ],
                    // 亮屏弹出兜底：系统只在锁屏/息屏时应用全屏意图；授予「显示在其他应用上层」
                    // 后可在来电时直接拉起名片页，亮屏使用中也能整屏弹出。
                    const _SectionHeader('亮屏弹出'),
                    Card(
                      child: ListTile(
                        leading: Icon(
                          (_status?.overlayOk ?? false)
                              ? Icons.picture_in_picture_alt
                              : Icons.warning_amber,
                          color: (_status?.overlayOk ?? false)
                              ? Colors.green
                              : colorScheme.error,
                        ),
                        title: Text((_status?.overlayOk ?? false)
                            ? '亮屏也能弹出（已允许「显示在其他应用上层」）'
                            : '亮屏使用中只出通知：可允许「显示在其他应用上层」'),
                        subtitle: Text((_status?.overlayOk ?? false)
                            ? '来电时直接拉起名片页，不再依赖系统全屏意图'
                            : '系统只在锁屏/息屏时应用全屏意图，亮屏解锁时只给横幅。'
                                '授权后本应用可在后台直接拉起名片页，亮屏也能弹。'
                                '若授权后仍不弹，请再到系统设置允许本应用「后台弹出界面」（厂商限制）。'),
                        isThreeLine: !(_status?.overlayOk ?? false),
                        trailing: (_status?.overlayOk ?? false)
                            ? null
                            : FilledButton(
                                onPressed: () => CallerIdSync.openSettings('overlay'),
                                child: const Text('去授权'),
                              ),
                      ),
                    ),
                    const _SectionHeader('系统设置直达'),
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.settings_applications_outlined),
                            title: const Text('应用详情页'),
                            subtitle: const Text('权限、通知、后台运行等开关都在这页'),
                            trailing: const Icon(Icons.open_in_new, size: 18),
                            onTap: () => CallerIdSync.openSettings('app'),
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          ListTile(
                            leading: const Icon(Icons.battery_saver_outlined),
                            title: const Text('电池优化白名单'),
                            subtitle: const Text('把本应用设为「不优化」，避免后台被系统冻结'),
                            trailing: const Icon(Icons.open_in_new, size: 18),
                            onTap: () => CallerIdSync.openSettings('battery'),
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          ListTile(
                            leading: const Icon(Icons.notifications_active_outlined),
                            title: const Text('通知设置'),
                            subtitle: const Text('开启通知与「全屏提醒」（Android 14+）'),
                            trailing: const Icon(Icons.open_in_new, size: 18),
                            onTap: () => CallerIdSync.openSettings('notification'),
                          ),
                        ],
                      ),
                    ),
                    const _SectionHeader('测试与预览'),
                    const _TipCard(
                      icon: Icons.science_outlined,
                      title: '先在这里测，别急着真打电话',
                      subtitle: '“模拟来电”与真实响铃命中后走的是同一条链路：号码匹配 → 全屏通知。\n'
                          '若模拟能弹、真实来电不弹，问题就出在「系统广播 / 取号」环节——看下面「运行状态」里有没有收到来电广播即可判断。',
                      dim: true,
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.person_search),
                            title: const Text('测试对象（通讯录里的人）'),
                            subtitle: Text(
                              _testContact == null
                                  ? '暂无联系人数据，请先返回主界面刷新'
                                  : '${_testContact!.displayName}'
                                      '${_testContact!.orgLine.isEmpty ? '' : ' · ${_testContact!.orgLine}'}',
                            ),
                            trailing: _testContact == null
                                ? null
                                : const Icon(Icons.chevron_right),
                            enabled: _testContact != null,
                            onTap: _pickContact,
                          ),
                          if (_testContact != null &&
                              _testContact!.dialablePhones.length > 1) ...[
                            const Divider(height: 1, indent: 16, endIndent: 16),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                              child: Text('测哪个号码',
                                  style: theme.textTheme.labelMedium
                                      ?.copyWith(color: colorScheme.onSurfaceVariant)),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final p in _testContact!.dialablePhones)
                                    ChoiceChip(
                                      label: Text(p),
                                      selected: p == _testNumber,
                                      onSelected: (_) =>
                                          setState(() => _testNumber = p),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FilledButton.icon(
                              onPressed: _busyTest || _testNumber == null
                                  ? null
                                  : () => _runSimulate(_testNumber!, expectKnown: true),
                              icon: _busyTest
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.notifications_active_outlined),
                              label: Text(_busyTest ? '模拟中…' : '模拟来电（应弹出名片）'),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _testContact == null
                                        ? null
                                        : () async {
                                            await CallerIdSync.previewIncoming(
                                              name: _testContact!.displayName,
                                              org: _testContact!.orgLine,
                                              phone: _testNumber ?? _testContact!.dialablePhones.first,
                                            );
                                          },
                                    icon: const Icon(Icons.preview_outlined),
                                    label: const Text('预览名片界面'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextButton(
                                    onPressed: _busyTest
                                        ? null
                                        : () => _runSimulate(_strangerNumber(), expectKnown: false),
                                    child: const Text('陌生号码测试'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_testResult != null) ...[
                      const SizedBox(height: 8),
                      _ResultBanner(text: _testResult!, kind: _testResultKind),
                    ],
                    const _SectionHeader('运行状态'),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _statusRow(
                              context,
                              icon: _status == null || _status!.lookupExists
                                  ? Icons.storage
                                  : Icons.error_outline,
                              ok: _status != null && _status!.lookupExists,
                              title: '号码库（供来电匹配）',
                              value: switch (_status) {
                                null => '读取中…',
                                CallerIdStatus s when s.lookupCount < 0 => '文件损坏，请重新同步',
                                CallerIdStatus s when !s.lookupExists => '尚未生成：在主界面成功加载一次通讯录即自动创建',
                                CallerIdStatus s => '已收录 ${s.lookupCount} 条号码',
                              },
                              trailing: _status == null
                                  ? null
                                  : TextButton(onPressed: _resyncNow, child: const Text('重新同步')),
                            ),
                            const Divider(height: 16),
                            _statusRow(
                              context,
                              icon: (_status?.eventRecorded ?? false)
                                  ? Icons.sensors
                                  : Icons.sensors_off,
                              ok: _status?.eventRecorded ?? false,
                              title: '最近一次系统来电广播',
                              value: _eventSummary(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_status != null && !_status!.eventRecorded)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.warning_amber, size: 20),
                                    SizedBox(width: 10),
                                    Expanded(
                                      child: Text('一直收不到广播？多半是系统/厂商后台限制',
                                          style: TextStyle(fontWeight: FontWeight.w600)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '请用另一台手机给本机拨号一次，再回来看这行。若仍显示“无记录”，说明系统没有把来电事件交给本 App：'
                                  '请允许本 App「自启动 / 后台运行」，并把电池策略设为不限制。\n'
                                  '（若开启开关前弹过“允许应用在后台启动活动吗？”，请选择允许。）',
                                  style: TextStyle(fontSize: 13, height: 1.5),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () => CallerIdSync.openSettings('app'),
                                      child: const Text('打开应用设置'),
                                    ),
                                    TextButton(
                                      onPressed: () => CallerIdSync.openSettings('battery'),
                                      child: const Text('电池优化白名单'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    const _TipCard(
                      icon: Icons.lightbulb_outline,
                      title: '小贴士',
                      subtitle: '联系人数据每次同步后会自动推送给来电识别使用，无需手动导入。\n'
                          '此功能仅在系统来电界面之上叠加展示，不拦截、不处理通话本身。\n'
                          '真机来电必须满足：号码库命中 + 通知已开 +（Android 14+）全屏提醒已放行，缺一即静默不弹。\n'
                          '另外：名片只在锁屏/息屏时才会被系统全屏拉起，亮屏解锁时只出横幅；'
                          '允许「显示在其他应用上层」后本应用可直接拉起名片页，亮屏也能弹（见上「亮屏弹出」）。',
                      dim: true,
                    ),
                  ],
                ),
    );
  }

  Widget _statusRow(
    BuildContext context, {
    required IconData icon,
    required bool ok,
    required String title,
    required String value,
    Widget? trailing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: ok ? Colors.green : colorScheme.outline),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: ok ? colorScheme.onSurfaceVariant : colorScheme.error)),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }

  String _eventSummary() {
    final st = _status;
    if (st == null) return '读取中…';
    if (!st.eventRecorded || st.lastEventAt == null) {
      return '无记录：系统还没把响铃广播交给本 App';
    }
    final stateLabel = switch (st.lastEventState) {
      'RINGING' => '响铃',
      'OFFHOOK' => '接通',
      'IDLE' => '挂断',
      _ => st.lastEventState.isEmpty ? '未知' : st.lastEventState,
    };
    String two(int v) => v.toString().padLeft(2, '0');
    final t = st.lastEventAt!;
    final time = '${t.month}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final num = st.lastEventNumber.trim();
    return '$time · $stateLabel\n广播号码：${num.isEmpty ? '（未携带）' : num}\n结果：${st.lastEventDecision.isEmpty ? '—' : st.lastEventDecision}';
  }
}

enum _ResultKind { info, success, warn, error }

class _ResultBanner extends StatelessWidget {
  final String text;
  final _ResultKind kind;
  const _ResultBanner({required this.text, required this.kind});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (kind) {
      _ResultKind.success => (Icons.check_circle, Colors.green),
      _ResultKind.warn => (Icons.info_outline, Colors.orange),
      _ResultKind.error => (Icons.error_outline, colorScheme.error),
      _ResultKind.info => (Icons.info_outline, colorScheme.primary),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, height: 1.5, color: colorScheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

/// 从通讯录挑一个测试对象（支持姓名/拼音/单位/号码搜索）。
class _ContactPickerSheet extends StatefulWidget {
  final List<RemoteContact> contacts;
  const _ContactPickerSheet({required this.contacts});

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  final TextEditingController _query = TextEditingController();
  late final List<RemoteContact> _all = widget.contacts;

  List<RemoteContact> get _filtered {
    final q = _query.text.trim();
    if (q.isEmpty) return _all;
    final lower = q.toLowerCase();
    return _all.where((c) {
      if (c.displayName.toLowerCase().contains(lower)) return true;
      for (final p in c.dialablePhones) {
        if (p.contains(q)) return true;
      }
      if (c.unit.toLowerCase().contains(lower)) return true;
      return PinyinSearch.matches(
        rawContactText: c.unit,
        displayName: c.displayName,
        groupKey: c.unit,
        jobTitle: c.jobTitle,
        query: q,
      );
    }).toList();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final results = _filtered;
    return SafeArea(
      child: Material(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Text('选择测试对象（通讯录共 ${_all.length} 人）',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _query,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '搜姓名 / 单位 / 号码',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('没有匹配的联系人',
                          style: TextStyle(color: colorScheme.onSurfaceVariant)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final c = results[i];
                        final phones = c.dialablePhones;
                        return ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor: colorScheme.primaryContainer,
                            child: Text(c.initials,
                                style: TextStyle(
                                    color: colorScheme.onPrimaryContainer, fontSize: 13)),
                          ),
                          title: Text(c.displayName),
                          subtitle: Text(
                            '${c.orgLine.isEmpty ? c.unit : c.orgLine}\n${phones.join(' / ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: () => Navigator.pop(context, c),
                        );
                      },
                    ),
            ),
          ],
        ),
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
  final Widget? trailing;
  const _TipCard(
      {required this.icon,
      required this.title,
      required this.subtitle,
      this.dim = false,
      this.trailing});

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
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 关键权限缺失时的顶部引导卡：一键授权 + 直达系统设置。
class _PermissionBanner extends StatelessWidget {
  final int missingCount;
  final VoidCallback onGrantAll;
  final VoidCallback onOpenSettings;
  const _PermissionBanner({
    required this.missingCount,
    required this.onGrantAll,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.errorContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 20, color: colorScheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('还缺 $missingCount 项权限，来电名片无法弹出',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '需要「电话状态 / 通话记录」取号、「通知」展示名片。点「一键授权」按系统提示允许即可；'
              '若之前选过“拒绝”，系统不再弹框，请走「去系统设置」。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onOpenSettings, child: const Text('去系统设置')),
                const SizedBox(width: 6),
                FilledButton(onPressed: onGrantAll, child: const Text('一键授权')),
              ],
            ),
          ],
        ),
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
