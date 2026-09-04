import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';

/// 联系人本地缓存：把最近一次完整快照（版本号 + 数据）存到本地。
///
/// 读取失败一律按“无缓存”处理，保证缓存异常不会阻塞或崩溃主流程。
class ContactsCache {
  static const String _key = 'pb_contacts_cache';

  /// 读取缓存的快照；无缓存或损坏时返回 null。
  Future<ContactSnapshot?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      return ContactSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 保存快照（原子写单条 key）。
  Future<void> save(ContactSnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(snapshot.toJson()));
    } catch (_) {
      // 缓存写失败不影响本次使用，仅下次重新拉取。
    }
  }

  /// 清除缓存（用户显式要求重拉时可调用）。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
