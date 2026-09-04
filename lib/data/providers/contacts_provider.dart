import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/contacts_cache.dart';
import '../models/contact.dart';
import '../remote/contact_api.dart';
import '../../services/caller_id_sync.dart';
import '../../services/pinyin_search.dart';
import '../../config/app_config.dart';

/// 数据当前来源/可信度，用于界面提示。
enum DataStatus {
  /// 已向服务器确认是最新版本（无论数据来自刚拉取还是本地缓存）。
  server,

  /// 连不上服务器，展示的是本地缓存。
  offline,
}

/// 通讯录列表状态。
class ContactsState {
  /// 全屏加载中（还没有任何可展示的数据时）。
  final bool loading;

  /// 后台核对/拉取中（已有数据可看，只是静默更新）。
  final bool syncing;

  final List<SelectableContact> contacts;
  final int? version;
  final String? updatedAt;
  final DataStatus status;
  final String? message;

  const ContactsState({
    this.loading = true,
    this.syncing = false,
    this.contacts = const [],
    this.version,
    this.updatedAt,
    this.status = DataStatus.server,
    this.message,
  });

  int get selectedCount => contacts.where((c) => c.isSelected).length;

  // 用于区分“不修改”与“置 null”的哨兵。
  static const Object _noChange = Object();

  ContactsState copyWith({
    bool? loading,
    bool? syncing,
    List<SelectableContact>? contacts,
    int? version,
    String? updatedAt,
    DataStatus? status,
    Object? message = _noChange,
  }) =>
      ContactsState(
        loading: loading ?? this.loading,
        syncing: syncing ?? this.syncing,
        contacts: contacts ?? this.contacts,
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
        status: status ?? this.status,
        message: identical(message, _noChange) ? this.message : message as String?,
      );

  Map<String, List<SelectableContact>> get groupedContacts {
    final map = <String, List<SelectableContact>>{};
    for (final contact in contacts) {
      map.putIfAbsent(contact.groupKey, () => []).add(contact);
    }
    // 每个分组内部按名字排序
    for (final key in map.keys) {
      map[key]!.sort((a, b) => a.contact.displayName.compareTo(b.contact.displayName));
    }
    // 分组按键排序
    return Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }
}

/// 联系人状态管理：缓存优先 + 版本号判断是否需要重新拉取。
///
/// 流程：
/// 1. 先读本地缓存立刻展示（省流量、快）；
/// 2. 请求轻量接口 `GET /api/version`；
/// 3. 版本一致 → 直接用缓存，不拉全量；版本不一致/无缓存 → 拉 `GET /api/contacts` 并写缓存；
/// 4. 网络失败 → 回退缓存并标记离线。
class ContactsNotifier extends StateNotifier<ContactsState> {
  ContactsNotifier(this._api, this._cache) : super(const ContactsState());

  final ContactApi _api;
  final ContactsCache _cache;

  bool _busy = false;

  /// 启动/下拉刷新入口。
  Future<void> load() => _sync(force: false);

  /// “检查更新”：只问版本号，返回供弹窗展示的状态文案。
  Future<String> checkForUpdates() async {
    try {
      final sv = await _api.fetchVersion();
      if (state.contacts.isNotEmpty && state.version == sv.version) {
        state = state.copyWith(
          status: DataStatus.server,
          updatedAt: sv.updatedAt,
          message: null,
        );
        return '当前已是最新版本 ${state.version}';
      }
      await _sync(force: false);
      return '已更新到版本 ${state.version ?? 0}';
    } catch (e) {
      return '无法连接服务器：$e';
    }
  }

  /// 核心同步逻辑。
  Future<void> _sync({required bool force}) async {
    if (_busy) return;
    _busy = true;
    try {
      // 1) 读缓存
      ContactSnapshot? cached;
      try {
        cached = await _cache.load();
      } catch (_) {
        cached = null;
      }

      if (cached != null) {
        // 已有缓存：先展示，再后台核对版本
        _show(cached, status: DataStatus.server, syncing: true);
      } else {
        state = state.copyWith(
          loading: true,
          syncing: false,
          message: null,
        );
      }

      // 2) 版本判断
      try {
        final sv = await _api.fetchVersion();
        if (!force && cached != null && cached.version == sv.version) {
          // 版本一致 → 直接用缓存，不拉全量
          _show(cached, status: DataStatus.server, syncing: false);
          return;
        }

        // 3) 版本不一致或没有缓存 → 拉全量
        final snapshot = await _api.fetchContacts();
        await _cache.save(snapshot);
        PinyinSearch.clearCache();
        _show(snapshot, status: DataStatus.server, syncing: false);
      } catch (e) {
        final msg = e is NetworkException ? e.message : '加载失败：$e';
        if (cached != null) {
          _show(cached, status: DataStatus.offline, syncing: false, message: msg);
        } else {
          state = state.copyWith(loading: false, syncing: false, message: msg);
        }
      }
    } finally {
      _busy = false;
    }
  }

  void _show(
    ContactSnapshot snapshot, {
    required DataStatus status,
    bool syncing = false,
    String? message,
  }) {
    // 来电显示：把最新联系人推给原生写本地查找文件（空列表即清空）。
    unawaited(CallerIdSync.replaceContacts(snapshot.contacts));

    final selectable = snapshot.contacts
        .map((c) =>
            SelectableContact(contact: c, groupKey: c.unit.isEmpty ? '未分组' : c.unit))
        .toList();
    state = ContactsState(
      loading: false,
      syncing: syncing,
      contacts: selectable,
      version: snapshot.version,
      updatedAt: snapshot.updatedAt,
      status: status,
      message: message,
    );
  }

  // ---------- 选中交互（沿用原逻辑） ----------

  void toggle(String id) {
    _update(
      (list) => list.map((c) {
        if (c.contact.id == id) return c.copyWith(isSelected: !c.isSelected);
        return c;
      }).toList(),
    );
  }

  void toggleGroup(String groupKey) {
    final group = state.groupedContacts[groupKey];
    if (group == null || group.isEmpty) return;
    final allSelected = group.every((c) => c.isSelected);
    _update(
      (list) => list.map((c) {
        if (c.groupKey == groupKey) {
          return c.copyWith(isSelected: !allSelected);
        }
        return c;
      }).toList(),
    );
  }

  void selectAll(bool selected) {
    _update(
      (list) => list.map((c) => c.copyWith(isSelected: selected)).toList(),
    );
  }

  void clearMessage() => state = state.copyWith(message: null);

  void setMessage(String message) => state = state.copyWith(message: message);

  void _update(List<SelectableContact> Function(List<SelectableContact>) transform) {
    state = state.copyWith(contacts: transform(state.contacts));
  }
}

// ---------- Riverpod 提供 ----------

/// HTTP 客户端（测试可 override 为假实现）。
final contactApiProvider = Provider<ContactApi>(
  (ref) => ContactApi(AppConfig.apiBaseUrl),
);

/// 本地缓存（测试可 override 为内存实现）。
final contactsCacheProvider = Provider<ContactsCache>(
  (_) => ContactsCache(),
);

/// 通讯录状态。
final contactsProvider = StateNotifierProvider<ContactsNotifier, ContactsState>(
  (ref) => ContactsNotifier(
    ref.watch(contactApiProvider),
    ref.watch(contactsCacheProvider),
  ),
);
