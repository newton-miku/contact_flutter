import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../data/providers/contacts_provider.dart';
import '../../data/remote/contact_api.dart';
import '../../services/caller_id_sync.dart';
import '../../services/device_auth.dart';
import 'qr_scanner_screen.dart';

/// 设备激活页：输入管理员发放的一次性激活码 + 手机号，换取长期设备令牌。
/// 激活成功后自动拉取可见范围内的联系人并进入主界面。
class ActivationScreen extends ConsumerStatefulWidget {
  const ActivationScreen({super.key});

  @override
  ConsumerState<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends ConsumerState<ActivationScreen> {
  final _code = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  /// 从系统读到的本机号码（双卡时会有多条，供用户选择）。
  List<Map<String, dynamic>> _sims = [];
  bool _autoFilled = false;
  bool _reading = false;

  /// 电话权限被永久拒绝（需去系统设置手动开启）。
  bool _permDenied = false;

  @override
  void initState() {
    super.initState();
    // 进入激活页自动申请一次读号权限（仅用于自动填入本机号码）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadDeviceNumber(requestPermission: true);
    });
  }

  /// 读取本机号码并自动填入（多张卡时由用户点选）；[requestPermission] 为真时先申请权限。
  Future<void> _loadDeviceNumber({bool requestPermission = false}) async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      if (requestPermission) {
        await CallerIdSync.requestNumberPermission();
      }
      final r = await CallerIdSync.line1Number();
      final raw = r['sims'];
      final list = raw is List ? raw : const [];
      final withNumber = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((m) => (m['number'] as String?)?.trim().isNotEmpty == true)
          .toList();
      if (!mounted) return;
      setState(() => _sims = withNumber);
      if (withNumber.length == 1 && _phone.text.trim().isEmpty) {
        _phone.text = (withNumber.first['number'] as String).trim();
        setState(() {
          _autoFilled = true;
          _permDenied = false;
        });
      } else if (withNumber.isEmpty && requestPermission) {
        // 权限被永久拒绝时引导去系统设置；否则只是运营商未写入号码。
        final status = await ph.Permission.phone.status;
        if (!mounted) return;
        final denied = status.isPermanentlyDenied;
        setState(() {
          _permDenied = denied;
          _error = denied
              ? '「电话」权限已被拒绝，无法读取本机号码'
              : '未读取到本机号码（双卡/CDMA/部分运营商不提供），请手动输入';
        });
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// 从扫码结果里提取 10 位激活码（支持纯码、URL 里带 code=、或文本中的码）。
  String? _extractCode(String raw) {
    final up = raw.trim().toUpperCase();
    if (RegExp(r'^[A-Z0-9]{10}$').hasMatch(up)) return up;
    final byParam = RegExp(r'(?:CODE=|/)([A-Z0-9]{10})(?![A-Z0-9])').firstMatch(up);
    if (byParam != null) return byParam.group(1);
    final any = RegExp(r'[A-Z0-9]{10}').firstMatch(up);
    return any?.group(0);
  }

  /// 扫码填入激活码。
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (raw == null || !mounted) return;
    final code = _extractCode(raw);
    if (code == null) {
      setState(() => _error = '二维码里没有识别到激活码，请手动输入');
      return;
    }
    setState(() {
      _code.text = code;
      _error = null;
    });
    _toast('已识别激活码 $code');
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

  void _pickSim(Map<String, dynamic> sim) {
    final n = (sim['number'] as String?)?.trim() ?? '';
    if (n.isEmpty) return;
    setState(() {
      _phone.text = n;
      _autoFilled = true;
      _error = null;
    });
  }

  @override
  void dispose() {
    _code.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    final phone = _phone.text.trim();
    if (code.isEmpty || phone.isEmpty) {
      setState(() => _error = '请输入激活码和手机号');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(contactApiProvider)
          .activate(code: code, phone: phone, label: 'Android');
      await ref.read(deviceAuthProvider.notifier).save(
            token: result.token,
            phone: result.phone.isEmpty ? phone : result.phone,
            displayName: result.displayName,
          );
      // 令牌已写入 → contactApiProvider 会带新令牌重建，这里触发拉取。
      await ref.read(contactsProvider.notifier).load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '激活失败：$e');
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
                  Text('激活通讯录',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    '首次使用需输入单位管理员发放的激活码。\n激活后本机将绑定该手机号；更换手机需用新激活码重新激活。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(10),
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                      TextInputFormatter.withFunction(
                        (oldValue, newValue) =>
                            newValue.copyWith(text: newValue.text.toUpperCase()),
                      ),
                    ],
                    decoration: InputDecoration(
                      labelText: '激活码',
                      hintText: '10 位字母+数字，不区分大小写',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.confirmation_number_outlined),
                      suffixIcon: (defaultTargetPlatform == TargetPlatform.android ||
                              defaultTargetPlatform == TargetPlatform.iOS)
                          ? IconButton(
                              tooltip: '扫码填入',
                              icon: const Icon(Icons.qr_code_scanner),
                              onPressed: _busy ? null : _scan,
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _phone,
                    enabled: !_busy,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: '手机号',
                      hintText: '与该激活码绑定的手机号',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.phone_android),
                    ),
                  ),
                  if (_sims.length > 1) ...[
                    const SizedBox(height: 10),
                    Text('检测到多张卡，请选择用于激活的号码：',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in _sims)
                          ActionChip(
                            label: Text('卡${s['slot']} ${s['number']}'),
                            onPressed: _busy ? null : () => _pickSim(s),
                          ),
                      ],
                    ),
                  ] else if (_sims.isEmpty && !_reading) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _permDenied
                          ? TextButton.icon(
                              onPressed: _busy ? null : ph.openAppSettings,
                              icon: const Icon(Icons.settings, size: 18),
                              label: const Text('去系统设置开启「电话」权限'),
                            )
                          : TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _loadDeviceNumber(requestPermission: true),
                              icon: const Icon(Icons.sim_card_outlined, size: 18),
                              label: const Text('自动填入本机号码'),
                            ),
                    ),
                  ] else if (_autoFilled) ...[
                    const SizedBox(height: 6),
                    Text('已自动填入本机号码，可手动修改',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: colorScheme.outline)),
                  ],
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
                        : const Text('激活'),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '没有激活码？请联系本单位管理员在后台生成。',
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
