import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// 客户端本地设置（SharedPreferences 持久化）：开发者模式 + 服务器地址覆盖。
///
/// 普通用户没有入口；在「关于」页连点 5 次客户端版本号 / 长按服务端版本号可进入
/// 开发者模式，把服务器临时指到测试环境，便于联调验收——不必为每种环境单独打包。
class AppSettings {
  const AppSettings({this.devMode = false, this.baseOverride = ''});

  /// 开发者模式是否开启。
  final bool devMode;

  /// 运行时服务器地址覆盖（已归一化）；空串 = 用构建期默认地址。
  final String baseOverride;

  /// 当前生效的服务器地址：有覆盖用覆盖值，否则构建期默认。
  String get effectiveBaseUrl =>
      baseOverride.trim().isNotEmpty ? baseOverride.trim() : AppConfig.apiBaseUrl;

  /// 归一化：去首尾空白与末尾斜杠；与构建默认一致则视为“未覆盖”（返回空串）。
  static String normalizeUrl(String input) {
    var v = input.trim();
    while (v.length > 1 && v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v == AppConfig.apiBaseUrl ? '' : v;
  }
}

class AppSettingsNotifier extends StateNotifier<AppSettings> {
  AppSettingsNotifier() : super(const AppSettings()) {
    _hydrate();
  }

  static const _kDevMode = 'settings_dev_mode';
  static const _kBaseOverride = 'settings_base_override';

  Future<void> _hydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      state = AppSettings(
        devMode: p.getBool(_kDevMode) ?? false,
        baseOverride: p.getString(_kBaseOverride) ?? '',
      );
    } catch (_) {
      // 本地存储不可用时保持默认值即可
    }
  }

  Future<void> setDevMode(bool on) async {
    if (state.devMode == on) return;
    state = AppSettings(devMode: on, baseOverride: state.baseOverride);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kDevMode, on);
    } catch (_) {}
  }

  Future<void> setBaseOverride(String url) async {
    final v = AppSettings.normalizeUrl(url);
    if (state.baseOverride == v) return;
    state = AppSettings(devMode: state.devMode, baseOverride: v);
    try {
      final p = await SharedPreferences.getInstance();
      if (v.isEmpty) {
        await p.remove(_kBaseOverride);
      } else {
        await p.setString(_kBaseOverride, v);
      }
    } catch (_) {}
  }
}

/// 当前生效的服务器地址（只随 baseOverride 变化而重建，避免开发者模式开关打断数据流）。
final apiBaseProvider = Provider<String>((ref) {
  final override = ref.watch(appSettingsProvider.select((s) => s.baseOverride));
  return override.isNotEmpty ? override : AppConfig.apiBaseUrl;
});

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettings>(
  (ref) => AppSettingsNotifier(),
);
