import 'package:flutter/services.dart';

import '../data/models/contact.dart';

/// 来电显示名片 —— Flutter 与原生 [android ... CallerId.kt] 之间的通道。
///
/// 分工：
/// - [replaceContacts]：每次取得联系人快照后，把精简字段推给原生写成本地文件；
///   来电响铃时原生直接读该文件匹配号码，**不拉起 Flutter engine**；
/// - 其余方法用于「来电显示设置」页（开关、权限、Android 14+ 全屏能力）。
///
/// 本通道只存在于 Android 原生端；在测试 / 其它平台调用会抛 MissingPluginException，
/// 这里一律内部吞掉并返回安全默认值，绝不干扰主流程。
class CallerIdSync {
  CallerIdSync._();

  static const MethodChannel _channel =
      MethodChannel('com.example.contact_importer_flutter/caller_id');

  /// 推送联系人供原生来电匹配（含号码为空时的清空）。
  /// v6：同一个人有 手机/座机/传真 多个号码时，按号码拆成多条下发（号码全量去重），
  /// 原生端对每个号码建立匹配变体，来电命中即可亮名片。
  static Future<void> replaceContacts(List<RemoteContact> contacts) {
    final entries = <Map<String, String>>[];
    final seen = <String>{};
    void addNumber(String? phone, RemoteContact c) {
      final p = phone?.trim() ?? '';
      if (p.isEmpty || seen.contains(p)) return;
      seen.add(p);
      entries.add({
        'name': c.displayName,
        'phone': p,
        'unit': c.unit,
        'jobTitle': c.jobTitle ?? '',
      });
    }

    for (final c in contacts) {
      for (final p in c.dialablePhones) {
        addNumber(p, c);
      }
    }
    return _invoke('replaceContacts', {'contacts': entries});
  }

  static Future<void> setEnabled(bool on) =>
      _invoke('setEnabled', {'enabled': on});

  static Future<bool> isEnabled() async =>
      await _invoke('isEnabled') == true;

  /// 当前权限状态（readPhoneState / readCallLog / notifications）。
  static Future<Map<String, bool>> permissions() async {
    final r = await _invoke('permissions');
    if (r is Map) {
      return {
        for (final e in r.entries) '${e.key}': e.value == true,
      };
    }
    return const {'readPhoneState': false, 'readCallLog': false, 'notifications': false};
  }

  /// 弹系统授权框（READ_PHONE_STATE + READ_CALL_LOG + POST_NOTIFICATIONS），
  /// 返回授权后的最新权限状态。
  static Future<Map<String, bool>> requestPermissions() async {
    final r = await _invoke('requestPermissions');
    if (r is Map) {
      return {
        for (final e in r.entries) '${e.key}': e.value == true,
      };
    }
    return const {'readPhoneState': false, 'readCallLog': false, 'notifications': false};
  }

  /// Android 14+ 才有“全屏提醒需在系统设置手动开启”的限制；更早/非安卓返回 null。
  static Future<bool?> canUseFullScreen() async {
    final r = await _invoke('canUseFullScreen');
    return r is bool ? r : null;
  }

  /// 打开系统通知设置页（含“全屏提醒”开关，Android 14+）。
  static Future<void> openFullScreenSettings() => _invoke('openFullScreenSettings');

  static Future<dynamic> _invoke(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod(method, args);
    } catch (_) {
      return null;
    }
  }
}
