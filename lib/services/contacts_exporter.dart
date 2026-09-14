import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/models/contact.dart';

const _channel = MethodChannel('com.newtonmiku.contact_flutter/contacts');

/// 是否是需要「运行时权限」的平台。
///
/// 运行时权限是 Android/iOS 的概念；Linux/Windows 桌面端没有这一层，
/// 且 permission_handler 在 Linux 上没有实现（会抛 MissingPluginException），
/// 所以桌面端不能去 request 权限——直接走原生通道，失败由调用方兜底。
///
/// 注意用 final 而非 const：defaultTargetPlatform 是运行时 getter，
/// 不是编译期常量（const 初始化会报 const_initialized_with_non_constant_value）。
final _needsRuntimePermission = defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// 导出联系人到系统通讯录。
///
/// 通过 MethodChannel 调用 Android 原生代码写入通讯录，
/// 不依赖第三方 NDK 插件。桌面端无该原生实现，会走 catch 分支返回全失败。
class ContactsExporter {
  /// 请求 WRITE_CONTACTS 权限并导出。
  static Future<ExportResult> export(List<RemoteContact> contacts) async {
    if (contacts.isEmpty) {
      return const ExportResult(success: 0, failure: 0);
    }

    // 桌面端跳过权限申请（见 _needsRuntimePermission 说明）。
    if (_needsRuntimePermission) {
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        return const ExportResult(
          success: 0,
          failure: 0,
          permissionDenied: true,
        );
      }
    }

    try {
      final result = await _channel.invokeMethod<Map>('insertContacts', {
        'contacts': contacts.map((c) => {
          'displayName': c.displayName,
          'phoneNumber': c.phoneNumber,
          'mobile2': c.mobile2 ?? '',
          'landline': c.landline ?? '',
          'fax': c.fax ?? '',
          'email': c.email ?? '',
          'org': c.unit,
          'jobTitle': c.jobTitle ?? '',
        }).toList(),
      });
      return ExportResult(
        success: (result?['success'] as int?) ?? 0,
        failure: (result?['failure'] as int?) ?? 0,
      );
    } catch (e) {
      return ExportResult(success: 0, failure: contacts.length);
    }
  }
}

class ExportResult {
  final int success;
  final int failure;
  final bool permissionDenied;

  const ExportResult({
    required this.success,
    required this.failure,
    this.permissionDenied = false,
  });
}
