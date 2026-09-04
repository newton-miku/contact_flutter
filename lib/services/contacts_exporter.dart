import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/models/contact.dart';

const _channel = MethodChannel('com.example.contact_importer_flutter/contacts');

/// 导出联系人到系统通讯录。
///
/// 通过 MethodChannel 调用 Android 原生代码写入通讯录，
/// 不依赖第三方 NDK 插件。
class ContactsExporter {
  /// 请求 WRITE_CONTACTS 权限并导出。
  static Future<ExportResult> export(List<RemoteContact> contacts) async {
    if (contacts.isEmpty) {
      return const ExportResult(success: 0, failure: 0);
    }

    final status = await Permission.contacts.request();
    if (!status.isGranted) {
      return const ExportResult(
        success: 0,
        failure: 0,
        permissionDenied: true,
      );
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
