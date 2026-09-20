import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设备激活状态：激活后保存长期令牌与手机号，之后所有请求带 Bearer 令牌。
///
/// 说明：令牌目前存 shared_preferences（明文）；后续可迁移到 Keystore 加密
/// （见 docs/device-identity-auth-design.md 的 P2/P3）。
class DeviceAuthState {
  const DeviceAuthState({
    this.ready = false,
    this.token,
    this.phone,
    this.username,
    this.displayName,
    this.mustChangePassword = false,
  });

  /// 本地是否已读取完成（读取前不渲染主界面）。
  final bool ready;

  final String? token;

  /// 激活时的手机号（激活通道）。
  final String? phone;

  /// 账号密码登录的用户名（桌面端通道）。
  final String? username;

  final String? displayName;

  /// 账号还在用初始/被重置的密码（服务端 `must_change_password`）：
  /// 桌面端未改密前不放行主界面，与 Web 管理页行为一致。
  final bool mustChangePassword;

  bool get activated => (token ?? '').isNotEmpty;

  DeviceAuthState copyWith({
    bool? ready,
    String? token,
    String? phone,
    String? username,
    String? displayName,
    bool? mustChangePassword,
  }) =>
      DeviceAuthState(
        ready: ready ?? this.ready,
        token: token ?? this.token,
        phone: phone ?? this.phone,
        username: username ?? this.username,
        displayName: displayName ?? this.displayName,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      );
}

class DeviceAuthNotifier extends StateNotifier<DeviceAuthState> {
  /// [loadPersistence] 为 false 时跳过本地读取（测试 override 用）；
  /// 可用 [initialToken]/[initialPhone]/[initialMustChangePassword] 直接构造状态。
  DeviceAuthNotifier({
    bool loadPersistence = true,
    String? initialToken,
    String? initialPhone,
    bool initialMustChangePassword = false,
  }) : super(const DeviceAuthState()) {
    if (loadPersistence) {
      _hydrate();
    } else {
      state = DeviceAuthState(
        ready: true,
        token: initialToken,
        phone: initialPhone,
        mustChangePassword: initialMustChangePassword,
      );
    }
  }

  static const _kToken = 'device_token';
  static const _kPhone = 'device_phone';
  static const _kUsername = 'device_username';
  static const _kName = 'device_name';
  static const _kMustChange = 'device_must_change_password';

  Future<void> _hydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      state = DeviceAuthState(
        ready: true,
        token: p.getString(_kToken),
        phone: p.getString(_kPhone),
        username: p.getString(_kUsername),
        displayName: p.getString(_kName),
        mustChangePassword: p.getBool(_kMustChange) ?? false,
      );
    } catch (_) {
      state = const DeviceAuthState(ready: true);
    }
  }

  /// 激活/登录成功：保存令牌（激活带手机号，密码登录带用户名）。
  Future<void> save({
    required String token,
    String? phone,
    String? username,
    String? displayName,
    bool mustChangePassword = false,
  }) async {
    state = DeviceAuthState(
      ready: true,
      token: token,
      phone: phone,
      username: username,
      displayName: displayName,
      mustChangePassword: mustChangePassword,
    );
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kToken, token);
      if ((phone ?? '').isNotEmpty) {
        await p.setString(_kPhone, phone!);
      } else {
        await p.remove(_kPhone);
      }
      if ((username ?? '').isNotEmpty) {
        await p.setString(_kUsername, username!);
      } else {
        await p.remove(_kUsername);
      }
      if ((displayName ?? '').isNotEmpty) {
        await p.setString(_kName, displayName!);
      } else {
        await p.remove(_kName);
      }
      await p.setBool(_kMustChange, mustChangePassword);
    } catch (_) {}
  }

  /// 更新「首次登录强制改密」标记：改密成功后置 false；
  /// 桌面端冷启动按服务端 `/api/auth/me` 复检时也用这个对齐。
  ///
  /// 必须落盘：桌面端冷启动是用本地令牌直接进主界面的，不重新登录，
  /// 只存在内存里的话重启一次就把拦截绕过去了。
  Future<void> setMustChangePassword(bool value) async {
    if (state.mustChangePassword == value) return;
    state = state.copyWith(mustChangePassword: value);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kMustChange, value);
    } catch (_) {}
  }

  /// 清除激活（令牌失效 / 换设备）。
  Future<void> clear() async {
    state = const DeviceAuthState(ready: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kToken);
      await p.remove(_kPhone);
      await p.remove(_kUsername);
      await p.remove(_kName);
      await p.remove(_kMustChange);
    } catch (_) {}
  }
}

final deviceAuthProvider =
    StateNotifierProvider<DeviceAuthNotifier, DeviceAuthState>(
  (ref) => DeviceAuthNotifier(),
);
