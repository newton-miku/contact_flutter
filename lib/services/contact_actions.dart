import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class ContactActions {
  /// 调用系统拨号界面。
  static Future<void> call(String phoneNumber) async {
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw '无法拨打电话：$phoneNumber';
    }
  }

  /// 调用系统短信界面。
  static Future<void> sendSms(String phoneNumber, {String? body}) async {
    final uri = Uri(
      scheme: 'sms',
      path: phoneNumber,
      queryParameters: body != null ? {'body': body} : null,
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw '无法发送短信：$phoneNumber';
    }
  }

  /// 复制号码到剪贴板。
  static Future<void> copyPhone(String phoneNumber) async {
    await Clipboard.setData(ClipboardData(text: phoneNumber));
  }
}
