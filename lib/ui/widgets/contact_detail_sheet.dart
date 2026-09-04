import 'package:flutter/material.dart';

import '../../data/models/contact.dart';
import '../../services/contact_actions.dart';
import 'avatar.dart';

/// 该联系人的「号码 → 展示」清单：(类型标注, 号码, 是否允许发短信)。
/// 主叫号带类型标注（手机/座机/传真兜底），再追加与主叫号不同的 手机2、座机、传真。
List<(String, String, bool)> _phoneNumberRows(RemoteContact contact) {
  bool looksMobile(String n) {
    final d = n.replaceAll(RegExp(r'[^0-9]'), '');
    return d.length == 11 && d.startsWith('1');
  }

  final out = <(String, String, bool)>[];
  final primary = contact.phoneNumber;
  final faxOnly = contact.fax != null && contact.fax == primary;
  final primaryLabel = faxOnly ? '传真' : (looksMobile(primary) ? '手机' : '座机');
  out.add((primaryLabel, primary, primaryLabel != '传真'));

  final mob2 = contact.mobile2;
  if (mob2 != null && mob2.isNotEmpty && mob2 != primary) {
    out.add(('手机2', mob2, true));
  }
  final land = contact.landline;
  if (land != null && land.isNotEmpty && land != primary) {
    out.add(('座机', land, true));
  }
  final fax = contact.fax;
  if (fax != null && fax.isNotEmpty && fax != primary) {
    out.add(('传真', fax, false));
  }
  return out;
}

class ContactDetailSheet extends StatelessWidget {
  final RemoteContact contact;

  const ContactDetailSheet({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    Future<void> copyNumber(String text) async {
      await ContactActions.copyPhone(text);
      if (!context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: const Text('号码已复制'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖拽指示条
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 头像 + 姓名
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                Avatar(
                  initials: contact.initials,
                  size: 72,
                ),
                const SizedBox(height: 16),
                Text(
                  contact.displayName,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (contact.orgLine.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      contact.orgLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 电话号码：一个联系人可有 手机/座机/传真 多个号码，逐号提供 呼叫/短信/复制
          for (final (label, number, smsEnabled) in _phoneNumberRows(contact)) ...[
            const Divider(height: 1, thickness: 0.5),
            _NumberTile(
              label: label,
              number: number,
              smsEnabled: smsEnabled,
              onCall: () async {
                Navigator.pop(context);
                await ContactActions.call(number);
              },
              onSms: smsEnabled
                  ? () async {
                      Navigator.pop(context);
                      await ContactActions.sendSms(number);
                    }
                  : null,
              onCopy: () => copyNumber(number),
            ),
          ],
          if (contact.email != null) ...[
            const Divider(height: 1, thickness: 0.5),
            // 邮箱
            _ActionTile(
              icon: Icons.email_outlined,
              label: contact.email!,
              subtitle: '复制邮箱',
              onTap: () async {
                await ContactActions.copyPhone(contact.email!);
                if (!context.mounted) return;
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                messenger.showSnackBar(
                  SnackBar(
                    content: const Text('邮箱已复制'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// 单条号码行：类型标注 + 号码，右侧提供 呼叫/短信/复制 快捷按钮。
class _NumberTile extends StatelessWidget {
  final String label;
  final String number;
  final bool smsEnabled;
  final VoidCallback onCall;
  final VoidCallback? onSms;
  final VoidCallback onCopy;

  const _NumberTile({
    required this.label,
    required this.number,
    required this.smsEnabled,
    required this.onCall,
    this.onSms,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isFax = label == '传真';
    return ListTile(
      dense: true,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          isFax ? Icons.print_outlined : Icons.phone_in_talk_outlined,
          color: colorScheme.primary,
          size: 20,
        ),
      ),
      title: Text(
        number,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        label,
        style: TextStyle(color: colorScheme.outline, fontSize: 12),
      ),
      onTap: onCall,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '呼叫',
            icon: Icon(Icons.call_outlined, color: colorScheme.primary, size: 20),
            onPressed: onCall,
          ),
          if (onSms != null)
            IconButton(
              tooltip: '发短信',
              icon: Icon(Icons.message_outlined, color: colorScheme.primary, size: 20),
              onPressed: onSms,
            ),
          IconButton(
            tooltip: '复制号码',
            icon: const Icon(Icons.content_copy_outlined, size: 18),
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: colorScheme.primary, size: 22),
      ),
      title: Text(
        label,
        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: colorScheme.outline, fontSize: 12),
      ),
      trailing: Icon(Icons.chevron_right, color: colorScheme.outline, size: 20),
      onTap: onTap,
    );
  }
}
