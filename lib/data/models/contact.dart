/// 服务器通讯录数据结构与本地快照。
library;

/// 服务器返回的联系人。可选字段可能为 null。
class RemoteContact {
  /// 服务端整数 id，这里统一转成字符串便于 UI 按 id 操作。
  final String id;
  final String displayName;

  /// 主叫号（服务端约定：手机优先，无手机则座机，仍无则传真）。
  final String phoneNumber;

  /// 第二个手机号（同一人登记了两个手机时才有值）。
  final String? mobile2;

  /// 另有座机（区别于主叫号时才有值）。
  final String? landline;

  /// 传真（单位「办公室」联系人常携带）。
  final String? fax;
  final String? email;

  /// 所属单位名称（服务器按单位分组；旧缓存无该字段时回退到原 department）。
  final String unit;
  final String? jobTitle;

  const RemoteContact({
    required this.id,
    required this.displayName,
    required this.phoneNumber,
    this.mobile2,
    this.landline,
    this.fax,
    this.email,
    this.unit = '',
    this.jobTitle,
  });

  /// 头像缩写：取姓名第一个字符。
  String get initials {
    final name = displayName.trim();
    if (name.isEmpty) return '?';
    return String.fromCharCode(name.runes.first);
  }

  /// 「单位 · 职务」展示行（两者都空则返回空串）。
  String get orgLine => [
        if (unit.trim().isNotEmpty) unit.trim(),
        if (jobTitle != null && jobTitle!.trim().isNotEmpty) jobTitle!.trim(),
      ].join(' · ');

  /// 全部可拨叫号码（主叫号优先：主叫/手机2/座机/传真），去空、去重保序。
  List<String> get dialablePhones {
    final out = <String>[];
    void add(String? n) {
      final s = n?.trim() ?? '';
      if (s.isEmpty || out.contains(s)) return;
      out.add(s);
    }

    add(phoneNumber);
    add(mobile2);
    add(landline);
    add(fax);
    return out;
  }

  factory RemoteContact.fromJson(Map<String, dynamic> json) {
    final unit = (json['unit'] as String?)?.trim() ?? '';
    return RemoteContact(
      id: (json['id'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      phoneNumber: (json['phoneNumber'] ?? '').toString(),
      mobile2: json['mobile2'] as String?,
      landline: json['landline'] as String?,
      fax: json['fax'] as String?,
      email: json['email'] as String?,
      // 兼容旧缓存：新字段 unit 为空时回退到已废弃的 department。
      unit: unit.isEmpty ? ((json['department'] as String?) ?? '') : unit,
      jobTitle: json['jobTitle'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'phoneNumber': phoneNumber,
        'mobile2': mobile2,
        'landline': landline,
        'fax': fax,
        'email': email,
        'unit': unit,
        'jobTitle': jobTitle,
      };
}

/// 可选中的联系人（展示层状态）。
class SelectableContact {
  final RemoteContact contact;
  final String groupKey;
  final bool isSelected;

  const SelectableContact({
    required this.contact,
    required this.groupKey,
    this.isSelected = false,
  });

  SelectableContact copyWith({bool? isSelected}) => SelectableContact(
        contact: contact,
        groupKey: groupKey,
        isSelected: isSelected ?? this.isSelected,
      );
}

/// 一次完整的数据快照：版本号 + 更新时间 + 联系人列表。
/// 客户端把它缓存到本地，凭 version 判断是否已是最新。
class ContactSnapshot {
  final int version;
  final String? updatedAt;
  final List<RemoteContact> contacts;

  const ContactSnapshot({
    required this.version,
    this.updatedAt,
    this.contacts = const [],
  });

  factory ContactSnapshot.fromJson(Map<String, dynamic> json) {
    final list = json['contacts'];
    return ContactSnapshot(
      version: (json['version'] as num?)?.toInt() ?? 0,
      updatedAt: json['updatedAt'] as String?,
      contacts: list is List
          ? list
              .whereType<Map<String, dynamic>>()
              .map(RemoteContact.fromJson)
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'updatedAt': updatedAt,
        'contacts': contacts.map((c) => c.toJson()).toList(),
      };
}
