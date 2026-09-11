import 'dart:async';

import 'package:flutter/services.dart';

import '../data/models/contact.dart';

/// 原生来电识别运行状态（诊断用，一次取回）。
class CallerIdStatus {
  final bool enabled;
  final bool readPhoneState;
  final bool readCallLog;
  final bool notifications;
  final bool? fullScreenOk; // null=非 Android
  final bool lookupExists;
  final int lookupCount; // -1 = 文件损坏读取失败
  final bool eventRecorded;
  final DateTime? lastEventAt;
  final String lastEventState;
  final String lastEventNumber;
  final String lastEventDecision;

  const CallerIdStatus({
    required this.enabled,
    required this.readPhoneState,
    required this.readCallLog,
    required this.notifications,
    this.fullScreenOk,
    required this.lookupExists,
    required this.lookupCount,
    required this.eventRecorded,
    this.lastEventAt,
    this.lastEventState = '',
    this.lastEventNumber = '',
    this.lastEventDecision = '',
  });

  static CallerIdStatus fromMap(Object? raw) {
    final m = raw is Map ? raw : const <String, Object?>{};
    bool b(String k, [bool d = false]) => m[k] == true || (m[k] == null ? d : false);
    final at = m['lastEventAt'];
    final ok = m['fullScreenOk'];
    return CallerIdStatus(
      enabled: b('enabled'),
      readPhoneState: b('readPhoneState'),
      readCallLog: b('readCallLog'),
      notifications: b('notifications'),
      fullScreenOk: ok is bool ? ok : null,
      lookupExists: b('lookupExists'),
      lookupCount: m['lookupCount'] is num ? (m['lookupCount'] as num).toInt() : 0,
      eventRecorded: b('eventRecorded'),
      lastEventAt: at is int && at > 0
          ? DateTime.fromMillisecondsSinceEpoch(at)
          : null,
      lastEventState: '${m['lastEventState'] ?? ''}',
      lastEventNumber: '${m['lastEventNumber'] ?? ''}',
      lastEventDecision: '${m['lastEventDecision'] ?? ''}',
    );
  }
}

/// “模拟来电”返回结果。
class SimulatedIncomingResult {
  final bool matched;

  /// 未命中时的原因：'notifications'=通知未开启；null=陌生号码未命中。
  final String? reason;
  final String? name;
  final String? org;
  final String? phone;

  const SimulatedIncomingResult({
    required this.matched,
    this.reason,
    this.name,
    this.org,
    this.phone,
  });
}

/// 来电显示名片 —— Flutter 与原生 [android ... CallerId.kt] 之间的通道。
///
/// 分工：
/// - [replaceContacts]：每次取得联系人快照后，把精简字段推给原生写成本地文件；
///   来电响铃时原生直接读该文件匹配号码，**不拉起 Flutter engine**；
/// - 其余方法用于「来电显示设置」页（开关、权限、Android 14+ 全屏能力、测试）。
///
/// 本通道只存在于 Android 原生端；在测试 / 其它平台调用会抛 MissingPluginException，
/// 这里一律内部吞掉并返回安全默认值，绝不干扰主流程。
class CallerIdSync {
  CallerIdSync._();

  static const MethodChannel _channel =
      MethodChannel('com.newtonmiku.contact_flutter/caller_id');

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

  /// 是否开启后台常驻（前台服务保活，默认开）。
  static Future<bool> isKeepAlive() async =>
      await _invoke('isKeepAlive') == true;

  static Future<void> setKeepAlive(bool on) =>
      _invoke('setKeepAlive', {'enabled': on});

  /// 当前权限状态（readPhoneState / readPhoneNumbers / readCallLog / notifications）。
  static Future<Map<String, bool>> permissions() async {
    final r = await _invoke('permissions');
    if (r is Map) {
      return {
        for (final e in r.entries) '${e.key}': e.value == true,
      };
    }
    return const {
      'readPhoneState': false,
      'readPhoneNumbers': false,
      'readCallLog': false,
      'notifications': false,
    };
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

  /// 直达系统设置页：app=应用详情 / battery=电池优化 / notification=通知设置。
  static Future<void> openSettings(String target) =>
      _invoke('openSettings', {'target': target});

  /// 运行状态（权限 / 号码库 / 最近一次来电广播事件），用于诊断“开了没反应”。
  static Future<CallerIdStatus> status() async =>
      CallerIdStatus.fromMap(await _invoke('status'));

  /// 重新把当前目录推给原生号码库（保持与 App 内列表一致）。
  static Future<void> resync(List<RemoteContact> contacts) => replaceContacts(contacts);

  /// 模拟一通往指定号码的来电：与真实响铃命中后同一套“匹配 + 全屏通知”。
  static Future<SimulatedIncomingResult?> simulateIncoming(String number) async {
    final r = await _invoke('simulateIncoming', {'number': number});
    if (r is Map) {
      return SimulatedIncomingResult(
        matched: r['matched'] == true,
        reason: r['reason'] as String?,
        name: r['name'] as String?,
        org: r['org'] as String?,
        phone: r['phone'] as String?,
      );
    }
    return null;
  }

  /// 纯界面预览：直接拉起名片 Activity，不走通知/全屏系统限制。
  static Future<bool> previewIncoming({
    required String name,
    required String org,
    required String phone,
  }) async =>
      await _invoke('previewIncoming',
              {'name': name, 'org': org, 'phone': phone}) ==
          true;

  /// 申请「读取本机号码」所需权限（电话状态 + 读取本机号码），返回是否已授权。
  static Future<bool> requestNumberPermission() async =>
      await _invoke('requestNumberPermission') == true;

  /// 尝试读取本机号码（逐张 SIM）。
  /// 返回 {granted, number?, note?, sims: [ {slot, name?, number?} ]}；
  /// 双卡/CDMA/部分运营商不写入号码属正常，仅开发者诊断用。
  static Future<Map<String, dynamic>> line1Number() async {
    final r = await _invoke('line1Number');
    if (r is Map) {
      return {
        'granted': (r['granted'] == true).toString(),
        'number': r['number'] as String?,
        'note': (r['note'] as String?) ?? '',
        'sims': r['sims'] is List ? (r['sims'] as List) : const [],
      };
    }
    return const {
      'granted': 'false',
      'number': null,
      'note': '原生通道不可用（仅 Android 支持）',
      'sims': <Map<String, dynamic>>[],
    };
  }

  static Future<dynamic> _invoke(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod(method, args);
    } catch (_) {
      return null;
    }
  }
}
