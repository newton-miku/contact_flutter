// 通讯录客户端冒烟测试：用内存假实现覆盖 API 与缓存，
// 不触网、不依赖平台插件，只验证主界面能加载并渲染联系人。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:contact_flutter/data/cache/contacts_cache.dart';
import 'package:contact_flutter/data/models/contact.dart';
import 'package:contact_flutter/data/providers/contacts_provider.dart';
import 'package:contact_flutter/data/remote/contact_api.dart';
import 'package:contact_flutter/main.dart';
import 'package:contact_flutter/services/app_lock.dart';
import 'package:contact_flutter/services/device_auth.dart';

const _sample = RemoteContact(
  id: '1',
  displayName: '张三',
  phoneNumber: '13800138000',
  unit: '研发部',
  jobTitle: '工程师',
);

/// 假后端：不联网，直接返回固定快照。
class _FakeApi implements ContactApi {
  _FakeApi({this.mustChangePassword = false});

  /// `GET /api/auth/me` 复检结果（桌面端「首次登录强制改密」用）。
  final bool mustChangePassword;

  /// 改密请求记录（oldPassword, newPassword）。
  final List<(String, String)> changePasswordCalls = [];

  @override
  String get baseUrl => 'http://fake.local';

  @override
  String? get token => null;

  @override
  Future<ActivationResult> activate({
    required String code,
    required String phone,
    String label = '',
  }) async =>
      throw UnimplementedError();

  @override
  Future<LoginResult> login({required String username, required String password}) async =>
      throw UnimplementedError();

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    changePasswordCalls.add((oldPassword, newPassword));
  }

  @override
  Future<bool> fetchMustChangePassword() async => mustChangePassword;

  @override
  Future<ServerVersion> fetchVersion() async =>
      const ServerVersion(version: 1, updatedAt: '2026-09-04T00:00:00Z');

  @override
  Future<ContactSnapshot> fetchContacts() async => const ContactSnapshot(
        version: 1,
        updatedAt: '2026-09-04T00:00:00Z',
        contacts: [_sample],
      );
}

/// 内存缓存：模拟本地持久化。
class _FakeCache implements ContactsCache {
  ContactSnapshot? stored;

  @override
  Future<void> clear() async => stored = null;

  @override
  Future<ContactSnapshot?> load() async => stored;

  @override
  Future<void> save(ContactSnapshot snapshot) async => stored = snapshot;
}

void main() {
  testWidgets('主界面加载并展示服务器联系人', (WidgetTester tester) async {
    final cache = _FakeCache();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactApiProvider.overrideWithValue(_FakeApi()),
          contactsCacheProvider.overrideWithValue(cache),
          // 应用锁在单测环境不读本地插件：以“就绪、未设置”状态起步。
          appLockProvider
              .overrideWith((ref) => AppLockNotifier(loadPersistence: false)),
          // 已激活（避免测试环境落到激活页）
          deviceAuthProvider.overrideWith((ref) => DeviceAuthNotifier(
              loadPersistence: false, initialToken: 'test-token', initialPhone: '13800000000')),
        ],
        child: const ContactsApp(),
      ),
    );

    // 等待本地设置(应用锁)就绪 + 数据加载完成
    await tester.pumpAndSettle();

    // 标题出现即说明首页已挂载
    expect(find.text('通讯录'), findsOneWidget);

    // 假后端下发的联系人与单位分组可见
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('研发部'), findsOneWidget);

    // 同步完成后应写入缓存（版本 1）
    expect(cache.stored?.version, 1);
  });

  testWidgets('无本地缓存且后端为空时显示空态', (WidgetTester tester) async {
    final emptyApi = _EmptyApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactApiProvider.overrideWithValue(emptyApi),
          contactsCacheProvider.overrideWithValue(_FakeCache()),
          appLockProvider
              .overrideWith((ref) => AppLockNotifier(loadPersistence: false)),
          // 已激活（避免测试环境落到激活页）
          deviceAuthProvider.overrideWith((ref) => DeviceAuthNotifier(
              loadPersistence: false, initialToken: 'test-token', initialPhone: '13800000000')),
        ],
        child: const ContactsApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无联系人'), findsOneWidget);
  });

  // ---------- 桌面端：首次登录强制改密 ----------

  testWidgets('桌面端首登强制改密：未改密前进不了主界面', (WidgetTester tester) async {
    // 测试环境默认是 android；跑桌面分支必须显式覆盖平台。
    // 复位只能放在用例体内（finally）：binding 的
    // "foundation debug variable changed" 校验跑在 tearDown 之前。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _pumpDesktopForcedClient(tester, _FakeApi(mustChangePassword: true));

      // 停在改密页：服务端复检也是 true，因此不会被放行。
      expect(find.text('首次登录，请先修改初始密码'), findsOneWidget);
      expect(find.text('通讯录'), findsNothing);
      expect(find.text('张三'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('桌面端改密成功后进入主界面', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final api = _FakeApi(mustChangePassword: true);
      await _pumpDesktopForcedClient(tester, api);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Pb@123456');
      await tester.enterText(fields.at(1), 'newpass123');
      await tester.enterText(fields.at(2), 'newpass123');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      // 真的提交到了服务端，且标记解除后主界面才出现。
      expect(api.changePasswordCalls, [('Pb@123456', 'newpass123')]);
      expect(find.text('通讯录'), findsOneWidget);
      expect(find.text('张三'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 以“桌面端 + 仍在用初始密码”的状态启动客户端（平台覆盖由调用方设置）。
Future<void> _pumpDesktopForcedClient(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        contactApiProvider.overrideWithValue(api),
        contactsCacheProvider.overrideWithValue(_FakeCache()),
        // 登录返回 mustChangePassword=true：账号还在用初始密码。
        deviceAuthProvider.overrideWith((ref) => DeviceAuthNotifier(
              loadPersistence: false,
              initialToken: 'test-token',
              initialMustChangePassword: true,
            )),
      ],
      child: const ContactsApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// 返回空列表的假后端。
class _EmptyApi implements ContactApi {
  @override
  String get baseUrl => 'http://fake.local';

  @override
  String? get token => null;

  @override
  Future<ActivationResult> activate({
    required String code,
    required String phone,
    String label = '',
  }) async =>
      throw UnimplementedError();

  @override
  Future<LoginResult> login({required String username, required String password}) async =>
      throw UnimplementedError();

  @override
  Future<void> changePassword({required String oldPassword, required String newPassword}) async =>
      throw UnimplementedError();

  @override
  Future<bool> fetchMustChangePassword() async => false;

  @override
  Future<ServerVersion> fetchVersion() async =>
      const ServerVersion(version: 0, updatedAt: '2026-09-04T00:00:00Z');

  @override
  Future<ContactSnapshot> fetchContacts() async => const ContactSnapshot(
        version: 0,
        updatedAt: '2026-09-04T00:00:00Z',
        contacts: [],
      );
}
