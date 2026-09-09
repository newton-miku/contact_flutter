import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/app_config.dart';
import '../models/contact.dart';

/// 服务端版本信息（轻量接口 /api/version）。
class ServerVersion {
  /// 数据版本（每次写入 +1，客户端缓存同步用）。
  final int version;
  final String? updatedAt;

  /// 服务端程序版本 / 构建时刻 / 库结构版本（管理页运维展示用，可能为空）。
  final String? appVersion;
  final String? buildTime;
  final int? schemaVersion;

  const ServerVersion({
    required this.version,
    this.updatedAt,
    this.appVersion,
    this.buildTime,
    this.schemaVersion,
  });

  factory ServerVersion.fromJson(Map<String, dynamic> json) => ServerVersion(
        version: (json['version'] as num?)?.toInt() ?? 0,
        updatedAt: json['updatedAt'] as String?,
        appVersion: json['appVersion'] as String?,
        buildTime: json['buildTime'] as String?,
        schemaVersion: (json['schemaVersion'] as num?)?.toInt(),
      );
}

/// 服务器返回错误（HTTP 4xx/5xx）。
class ApiException implements Exception {
  final String message;
  final int statusCode;

  ApiException(this.message, {this.statusCode = 0});

  @override
  String toString() => message;
}

/// 令牌无效/过期（HTTP 401）：需重新激活。
class UnauthorizedException extends ApiException {
  UnauthorizedException()
      : super('设备未激活或令牌已失效，请重新激活', statusCode: 401);
}

/// 网络不可达 / 超时。
class NetworkException implements Exception {
  final String message;

  NetworkException([this.message = '无法连接服务器，请检查网络']);
  NetworkException.withCause(Object e)
      : message = '无法连接服务器：$e';

  @override
  String toString() => message;
}

/// 激活结果（一次性激活码换取长期设备令牌）。
class ActivationResult {
  final String token;
  final String? expiresAt;
  final String phone;
  final String? displayName;

  const ActivationResult({
    required this.token,
    this.expiresAt,
    required this.phone,
    this.displayName,
  });

  factory ActivationResult.fromJson(Map<String, dynamic> json) {
    final u = json['user'];
    final user = u is Map ? u : const {};
    return ActivationResult(
      token: json['token'] as String? ?? '',
      expiresAt: json['expiresAt'] as String?,
      phone: (user['phone'] as String?) ?? '',
      displayName: user['displayName'] as String?,
    );
  }
}

/// 账号密码登录结果（桌面端）。
class LoginResult {
  final String token;
  final String username;
  final String? displayName;
  final String role;
  final bool mustChangePassword;

  const LoginResult({
    required this.token,
    required this.username,
    this.displayName,
    this.role = '',
    this.mustChangePassword = false,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    final u = json['user'];
    final user = u is Map ? u : const {};
    return LoginResult(
      token: json['token'] as String? ?? '',
      username: (user['username'] as String?) ?? '',
      displayName: user['displayName'] as String?,
      role: (user['role'] as String?) ?? '',
      mustChangePassword: user['mustChangePassword'] == true,
    );
  }
}

/// 通讯录 HTTP 客户端：只读接口（版本查询 + 全量拉取）+ 设备激活 + 账号登录。
class ContactApi {
  ContactApi(this.baseUrl, {http.Client? client, this.token})
      : _client = client ?? http.Client();

  final String baseUrl;

  /// 设备令牌（激活后获得）；为空表示未激活。
  final String? token;

  final http.Client _client;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> get _headers {
    final t = token?.trim() ?? '';
    return t.isEmpty ? const {} : {'Authorization': 'Bearer $t'};
  }

  void _ensureOk(http.Response res) {
    if (res.statusCode == 401) {
      throw UnauthorizedException();
    }
    if (res.statusCode != 200) {
      throw ApiException('服务器返回错误（HTTP ${res.statusCode}）',
          statusCode: res.statusCode);
    }
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    http.Response res;
    try {
      res = await _client
          .get(_uri(path), headers: _headers)
          .timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw NetworkException('连接服务器超时');
    } on http.ClientException {
      throw NetworkException();
    } catch (e) {
      throw NetworkException.withCause(e);
    }

    _ensureOk(res);
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('服务器响应格式不正确');
    }
    return decoded;
  }

  /// POST JSON（可选带令牌）：统一错误信息处理。
  Future<Map<String, dynamic>> _postJson(String path, Map<String, Object?> body) async {
    http.Response res;
    try {
      res = await _client
          .post(
            _uri(path),
            headers: {'Content-Type': 'application/json', ..._headers},
            body: jsonEncode(body),
          )
          .timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw NetworkException('连接服务器超时');
    } on http.ClientException {
      throw NetworkException();
    } catch (e) {
      throw NetworkException.withCause(e);
    }

    Map<String, dynamic>? decoded;
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map<String, dynamic>) decoded = d;
    } catch (_) {}
    if (res.statusCode != 200) {
      final msg = decoded?['error'];
      throw ApiException(
        msg is String ? msg : '请求失败（HTTP ${res.statusCode}）',
        statusCode: res.statusCode,
      );
    }
    if (decoded == null) throw ApiException('服务器响应格式不正确');
    return decoded;
  }

  /// 用一次性激活码 + 手机号换取长期设备令牌。
  Future<ActivationResult> activate({
    required String code,
    required String phone,
    String label = '',
  }) async {
    return ActivationResult.fromJson(
      await _postJson('/api/device/activate', {'code': code, 'phone': phone, 'label': label}),
    );
  }

  /// 账号密码登录（桌面端；client=app 返回 Bearer 令牌）。
  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    return LoginResult.fromJson(
      await _postJson('/api/auth/login', {
        'username': username,
        'password': password,
        'client': 'app',
      }),
    );
  }

  /// 修改当前账号密码（需已登录）。
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    await _postJson('/api/auth/password', {
      'oldPassword': oldPassword,
      'newPassword': newPassword,
    });
  }

  /// 查询当前数据版本（超小负载，客户端据此决定是否拉全量）。
  Future<ServerVersion> fetchVersion() async {
    return ServerVersion.fromJson(await _getJson('/api/version'));
  }

  /// 拉取完整联系人快照（含版本号）。
  Future<ContactSnapshot> fetchContacts() async {
    return ContactSnapshot.fromJson(await _getJson('/api/contacts'));
  }
}
