import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用锁状态。
///
/// 规则（按用户确认）：仅冷启动锁（切后台再回前台不锁）；生物识别为主、4~6 位数字
/// 密码为备用；首次启动弹一次「设置应用锁」引导，可跳过；设置后默认开启，可在
/// 「应用锁」页关闭/改密码/关生物快捷。
class AppLockState {
  const AppLockState({
    this.ready = false,
    this.configured = false,
    this.enabled = false,
    this.bioEnabled = true,
    this.askedOnce = false,
    this.unlocked = false,
    this.shuffle = false,
  });

  /// 本地设置是否已读取完成（读取前不渲染主界面，避免闪一下内容再上锁）。
  final bool ready;

  /// 是否已设置过解锁密码（无论当前是否启用）。
  final bool configured;

  /// 应用锁是否启用。
  final bool enabled;

  /// 冷启动时是否优先走生物识别（指纹/面部）快捷解锁。
  final bool bioEnabled;

  /// 首次启动的“设置应用锁”引导是否已处理（设置或跳过）。
  final bool askedOnce;

  /// 本次进程内是否已解锁。冷启动进程刚起为 false；验证通过后置 true，
  /// 之后切后台再回来不再要求（不实现回前台重锁）。
  final bool unlocked;

  /// 密码键盘是否打乱数字顺序（防旁人偷看）。
  final bool shuffle;

  /// 当前是否应上锁：设置了密码且开启、且本进程还没解过锁。
  bool get shouldLock => configured && enabled && !unlocked;

  AppLockState copyWith({
    bool? ready,
    bool? configured,
    bool? enabled,
    bool? bioEnabled,
    bool? askedOnce,
    bool? unlocked,
    bool? shuffle,
  }) =>
      AppLockState(
        ready: ready ?? this.ready,
        configured: configured ?? this.configured,
        enabled: enabled ?? this.enabled,
        bioEnabled: bioEnabled ?? this.bioEnabled,
        askedOnce: askedOnce ?? this.askedOnce,
        unlocked: unlocked ?? this.unlocked,
        shuffle: shuffle ?? this.shuffle,
      );
}

/// 应用锁逻辑：密码只以「盐 + SHA-256 哈希」存本地 SharedPreferences
/// （不存明文；纯 Dart，无原生依赖）。
class AppLockNotifier extends StateNotifier<AppLockState> {
  /// [loadPersistence] 为 false 时跳过本地读取（测试 override 用，直接以
  /// “已就绪、未设置密码”起步，避免依赖平台插件）。
  AppLockNotifier({bool loadPersistence = true})
      : super(const AppLockState()) {
    if (loadPersistence) {
      _init();
    } else {
      state = const AppLockState(ready: true);
    }
  }

  static const _kHash = 'applock_pin_hash';
  static const _kSalt = 'applock_salt';
  static const _kLen = 'applock_len';
  static const _kEnabled = 'applock_enabled';
  static const _kBio = 'applock_bio';
  static const _kAsked = 'applock_asked_once';
  static const _kShuffle = 'applock_shuffle';

  final Random _rng = Random.secure();

  String? _hash;
  String? _salt;
  int _len = 0;

  static String _digest(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _hash = p.getString(_kHash);
      _salt = p.getString(_kSalt);
      _len = p.getInt(_kLen) ?? 0;
      final enabled = p.getBool(_kEnabled) ?? false;
      final bio = p.getBool(_kBio) ?? true;
      final asked = p.getBool(_kAsked) ?? false;
      final shuffle = p.getBool(_kShuffle) ?? false;
      state = AppLockState(
        ready: true,
        configured: (_hash?.isNotEmpty ?? false) && _len >= 4,
        enabled: enabled,
        bioEnabled: bio,
        askedOnce: asked,
        shuffle: shuffle,
      );
    } catch (_) {
      // 本地存储不可用：按未设置处理。
      state = const AppLockState(ready: true);
    }
  }

  /// 已存密码长度（备用解锁面板据此判断何时自动提交）。
  int get pinLength => _len;

  Future<void> _persistPin(String pin, {required int len}) async {
    _salt = _rng.nextInt(1 << 31).toRadixString(16) +
        _rng.nextInt(1 << 31).toRadixString(16);
    _hash = _digest(_salt!, pin);
    _len = len;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSalt, _salt!);
      await p.setString(_kHash, _hash!);
      await p.setInt(_kLen, len);
    } catch (_) {}
  }

  /// 首次设置密码：写入加盐哈希，默认开启，标记引导已处理，并视为本进程已解锁。
  Future<void> setUp(String pin) async {
    await _persistPin(pin, len: pin.length);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, true);
      await p.setBool(_kAsked, true);
    } catch (_) {}
    state = state.copyWith(configured: true, enabled: true, askedOnce: true, unlocked: true);
  }

  /// 修改密码（保持原开启状态，重新加盐）。
  Future<void> changePin(String newPin) async {
    await _persistPin(newPin, len: newPin.length);
    state = state.copyWith();
  }

  /// 校验备用密码；正确则本进程解锁。
  Future<bool> verify(String candidate) async {
    final ok = _hash != null && _salt != null && _len == candidate.length &&
        _digest(_salt!, candidate) == _hash;
    if (ok) state = state.copyWith(unlocked: true);
    return ok;
  }

  /// 生物识别成功后调用（无需密码）。
  Future<void> unlockSession() async {
    state = state.copyWith(unlocked: true);
  }

  /// 关闭应用锁（须先完成身份验证再调用）：清除已存密码，回到“未设置”态。
  Future<void> turnOff() async {
    _hash = null;
    _salt = null;
    _len = 0;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kHash);
      await p.remove(_kSalt);
      await p.remove(_kLen);
      await p.setBool(_kEnabled, false);
    } catch (_) {}
    state = state.copyWith(configured: false, enabled: false);
  }

  Future<void> setEnabled(bool on) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, on);
    } catch (_) {}
    state = state.copyWith(enabled: on);
  }

  Future<void> setBioEnabled(bool on) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kBio, on);
    } catch (_) {}
    state = state.copyWith(bioEnabled: on);
  }

  Future<void> setShuffle(bool on) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShuffle, on);
    } catch (_) {}
    state = state.copyWith(shuffle: on);
  }

  /// 首次引导点“跳过”时调用（不再打扰）。
  Future<void> markAskedOnce() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAsked, true);
    } catch (_) {}
    state = state.copyWith(askedOnce: true);
  }
}

final appLockProvider = StateNotifierProvider<AppLockNotifier, AppLockState>(
  (ref) => AppLockNotifier(),
);
