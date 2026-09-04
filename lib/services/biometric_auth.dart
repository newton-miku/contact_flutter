import 'package:local_auth/local_auth.dart';

/// 生物认证服务的返回结果。
class AuthResult {
  final bool granted;
  final String? error;

  const AuthResult({required this.granted, this.error});
}

/// 设备生物认证能力状态。
enum BiometricCapability {
  /// 设备支持且已录入生物特征（指纹/面部）。
  available,

  /// 设备不支持生物认证硬件（没有指纹/面部识别模块）。
  notSupported,

  /// 设备有硬件，但用户未录入生物特征。
  notEnrolled,
}

/// 模块化生物认证服务。
///
/// 使用方式：
/// ```dart
/// final auth = BiometricAuth();
/// final result = await auth.tryAuthenticate(reason: '导出需要验证身份');
/// if (result.granted) { /* 执行操作 */ }
/// ```
class BiometricAuth {
  final LocalAuthentication _auth = LocalAuthentication();

  /// 检测当前设备的生物认证能力。
  ///
  /// 返回 [BiometricCapability] 枚举，调用方可根据结果决定：
  /// - [BiometricCapability.available]：直接弹窗认证
  /// - [BiometricCapability.notSupported]：跳过认证，允许继续
  /// - [BiometricCapability.notEnrolled]：提示用户去设置中录入
  Future<BiometricCapability> checkCapability() async {
    try {
      // 1) 设备是否支持生物认证硬件
      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) return BiometricCapability.notSupported;

      // 2) 设备是否支持该功能（Android 上检查 API 级别）
      final supported = await _auth.isDeviceSupported();
      if (!supported) return BiometricCapability.notSupported;

      // 3) 用户是否已录入生物特征
      // local_auth 没有直接暴露「是否已录入」的跨平台 API；
      // 尝试 authenticate 会弹出系统对话框，取消会抛异常，
      // 所以这里先检查 canCheckBiometrics 和 isDeviceSupported 就够了。
      // 实际弹窗失败时通过 catch 判断。
      return BiometricCapability.available;
    } catch (_) {
      return BiometricCapability.notSupported;
    }
  }

  /// 尝试进行生物认证。
  ///
  /// 这个方法封装了完整的「检查 → 弹窗 → 结果」逻辑。
  /// 调用方不需要关心底层细节。
  ///
  /// [reason] 显示在系统认证对话框中的说明文字。
  /// [skipIfNotAvailable] 当设备不支持认证时是否直接视为通过（默认为 true）。
  Future<AuthResult> tryAuthenticate({
    String reason = '验证身份以继续',
    bool skipIfNotAvailable = true,
  }) async {
    // 先检查设备能力
    final capability = await checkCapability();

    // 设备不支持 → 按策略决定
    if (capability == BiometricCapability.notSupported) {
      return AuthResult(
        granted: skipIfNotAvailable,
        error: skipIfNotAvailable ? null : '设备不支持生物认证',
      );
    }

    // 设备有硬件但用户未录入 → 仍尝试弹窗
    // （部分 ROM 在未录入时弹窗会直接返回错误）

    // 弹出系统认证对话框
    return _authenticateDialog(reason: reason);
  }

  /// 内部弹窗认证逻辑。
  Future<AuthResult> _authenticateDialog({required String reason}) async {
    try {
      final success = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
      return AuthResult(granted: success);
    } catch (e) {
      final msg = e.toString().toLowerCase();

      // Android / iOS 未录入生物特征
      if (msg.contains('notenrolled') || msg.contains('not enrolled')) {
        return const AuthResult(
          granted: false,
          error: '未录入指纹或面部识别，请先在系统设置中添加',
        );
      }

      // 用户取消
      if (msg.contains('canceled') || msg.contains('cancelled')) {
        return const AuthResult(granted: false, error: '已取消认证');
      }

      // 锁屏密码未设置（极少见）
      if (msg.contains('passcode')) {
        return const AuthResult(granted: false, error: '请先设置锁屏密码');
      }

      return AuthResult(granted: false, error: '认证失败：${e.toString()}');
    }
  }
}
