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

/// 网络不可达 / 超时。
class NetworkException implements Exception {
  final String message;

  NetworkException([this.message = '无法连接服务器，请检查网络']);
  NetworkException.withCause(Object e)
      : message = '无法连接服务器：$e';

  @override
  String toString() => message;
}

/// 通讯录 HTTP 客户端：只读接口（版本查询 + 全量拉取）。
class ContactApi {
  ContactApi(this.baseUrl, {http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> _getJson(String path) async {
    http.Response res;
    try {
      res = await _client.get(_uri(path)).timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw NetworkException('连接服务器超时');
    } on http.ClientException {
      throw NetworkException();
    } on ApiException {
      rethrow;
    } catch (e) {
      throw NetworkException.withCause(e);
    }

    if (res.statusCode != 200) {
      throw ApiException('服务器返回错误（HTTP ${res.statusCode}）',
          statusCode: res.statusCode);
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('服务器响应格式不正确');
    }
    return decoded;
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
