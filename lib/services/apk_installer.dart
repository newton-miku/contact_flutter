import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'update_download.dart';

/// 应用内更新安装（Android）。
///
/// 流程：把新版 APK 下到应用私有目录（无需存储权限，卸载随应用清理），
/// 再通过 FileProvider 以 content:// 交给系统安装器。
/// 下载或安装失败时由调用方回退到浏览器下载，保证"总能装上"。
///
/// Windows 的自替换在 [WindowsInstaller]，两者共用 [UpdateDownload] 的下载与校验。
class ApkInstaller {
  static const _channel = MethodChannel('com.newtonmiku.contact_flutter/apk_installer');

  /// 是否支持应用内安装（只有 Android 有这套原生实现）。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 下载 APK 到应用私有目录，返回本地文件。
  ///
  /// [onProgress] 会收到 0.0~1.0；总长度未知时收到 null（调用方显示不确定进度）。
  /// 校验见 [UpdateDownload.download]。
  static Future<File> download(
    String url, {
    required String fileName,
    void Function(double? progress)? onProgress,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (!isSupported) {
      throw const UpdateException('当前平台不支持应用内安装');
    }
    final dirPath = await _channel.invokeMethod<String>('downloadDir');
    if (dirPath == null || dirPath.isEmpty) {
      throw const UpdateException('无法创建下载目录');
    }
    return UpdateDownload.download(
      url,
      File('$dirPath/$fileName'),
      onProgress: onProgress,
      timeout: timeout,
    );
  }

  /// 设备的 ABI 列表（如 `[arm64-v8a, armeabi-v7a]`）。
  ///
  /// 用来在默认包（arm+arm64）与 x86_64 包之间挑对的那个：
  /// 给 x86 模拟器下发 arm 包会直接装不上。
  static Future<List<String>> supportedAbis() async {
    if (!isSupported) return const [];
    try {
      final abis = await _channel.invokeMethod<List<Object?>>('supportedAbis');
      return (abis ?? const [])
          .map((e) => '$e'.toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      // 拿不到就按"没有 x86"处理：默认包覆盖面更广
      return const [];
    }
  }

  /// 拉起系统安装器。
  ///
  /// Android 8+ 需要「安装未知应用」授权；未授权时抛
  /// [UpdatePermissionException]，调用方可引导用户去开。
  static Future<void> install(File apk) async {
    if (!isSupported) {
      throw const UpdateException('当前平台不支持应用内安装');
    }
    final allowed = await _channel.invokeMethod<bool>('canRequestInstall') ?? true;
    if (!allowed) {
      throw const UpdatePermissionException('需要允许「安装未知应用」才能完成更新');
    }
    try {
      await _channel.invokeMethod<bool>('install', {'path': apk.path});
    } on PlatformException catch (e) {
      throw UpdateException(e.message ?? '无法拉起安装器');
    }
  }

  /// 跳到「安装未知应用」授权页。
  static Future<void> openInstallPermissionSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<bool>('openInstallPermissionSettings');
  }

  /// 应用私有下载目录（用于清理旧包）。
  static Future<Directory?> downloadDirectory() async {
    if (!isSupported) return null;
    final p = await _channel.invokeMethod<String>('downloadDir');
    return p == null ? null : Directory(p);
  }

  /// 删除除 [keep] 之外的历史安装包，避免反复更新堆积。
  static Future<void> cleanOldFiles({String? keep}) async {
    try {
      final dir = await downloadDirectory();
      if (dir == null || !dir.existsSync()) return;
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (keep != null && f.path.endsWith(keep)) continue;
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {
      // 清理是尽力而为，失败不影响更新
    }
  }
}
