import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/contacts_cache.dart';
import '../models/contact.dart';
import '../remote/contact_api.dart';
import '../../services/caller_id_sync.dart';
import '../../services/pinyin_search.dart';
import '../../config/app_settings.dart';
import '../../services/device_auth.dart';

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

  /// 令牌失效（HTTP 401）：需要重新激活。AppRoot 据此切到激活页。
  final bool unauthorized;

  const ContactsState({
    this.loading = true,
    this.syncing = false,
    this.contacts = const [],
    this.version,
    this.updatedAt,
    this.status = DataStatus.server,
    this.message,
    this.unauthorized = false,
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
    bool? unauthorized,
  }) =>
      ContactsState(
        loading: loading ?? this.loading,
        syncing: syncing ?? this.syncing,
        contacts: contacts ?? this.contacts,
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
        status: status ?? this.status,
        message: identical(message, _noChange) ? this.message : message as String?,
        unauthorized: unauthorized ?? this.unauthorized,
      );

  /// 联系人的“办公室/值班室”电话条目标记等级（该单位组内置顶）：
  /// 含“办公室”=1、含“值班室”=2（办公室在值班室前），普通人员=3。
  static int _entryRank(String displayName) {
    final n = displayName.trim();
    if (n.contains('办公室')) return 1;
    if (n.contains('值班室')) return 2;
    return 3;
  }

  /// 稳定排序（Dart List.sort 不保证稳定：同键项按原顺序）。
  static List<SelectableContact> _stableSort(
    List<SelectableContact> items,
    int Function(SelectableContact, SelectableContact) compare,
  ) {
    final indexed = <(int, SelectableContact)>[
      for (var i = 0; i < items.length; i++) (i, items[i]),
    ];
    indexed.sort((x, y) {
      final c = compare(x.$2, y.$2);
      return c != 0 ? c : x.$1.compareTo(y.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// 组内排序：办公室/值班室条目置顶（办公室→值班室），其余按姓名拼音，
  /// 同名/同类型保持服务器原顺序。
  static int _compareWithinGroup(SelectableContact a, SelectableContact b) {
    final ga = _entryRank(a.contact.displayName);
    final gb = _entryRank(b.contact.displayName);
    if (ga != gb) return ga - gb;
    if (ga < 3) return 0; // 办公室/值班室条目：保留原先后顺序
    final c = PinyinSearch.sortKey(a.contact.displayName)
        .compareTo(PinyinSearch.sortKey(b.contact.displayName));
    return c; // 人名按拼音；同拼音交给稳定排序兜底保持原序
  }

  Map<String, List<SelectableContact>> get groupedContacts {
    final map = <String, List<SelectableContact>>{};
    for (final contact in contacts) {
      map.putIfAbsent(contact.groupKey, () => []).add(contact);
    }
    // 组序 = 后端单位排序（服务器已按 units.sort_order 返回，这里保持首次出现顺序），
    // 组内 = 办公室/值班室置顶 + 姓名拼音。
    return map.map(
      (key, members) => MapEntry(key, _stableSort(members, _compareWithinGroup)),
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
        if (e is UnauthorizedException) {
          // 令牌失效：清空数据并标记未授权，由 AppRoot 切到激活页。
          state = const ContactsState(loading: false, unauthorized: true);
          return;
        }
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

  /// 清空全部选中（退出导出模式 / 重新开始时调用）。
  void clearSelection() {
    if (state.contacts.every((c) => !c.isSelected)) return;
    _update(
      (list) => list.map((c) => c.copyWith(isSelected: false)).toList(),
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
/// 地址走 [apiBaseProvider]；令牌走 [deviceAuthProvider]（激活后自动带上，变化时重建）。
final contactApiProvider = Provider<ContactApi>((ref) {
  final base = ref.watch(apiBaseProvider);
  final token = ref.watch(deviceAuthProvider.select((s) => s.token));
  return ContactApi(base, token: token);
});

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
