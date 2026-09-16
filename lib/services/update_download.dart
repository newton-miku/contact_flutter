import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 应用内更新的失败（下载或安装阶段）。
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => message;
}

/// 需要用户先授予权限（Android 的「安装未知应用」、或安装目录不可写）才能继续。
class UpdatePermissionException extends UpdateException {
  const UpdatePermissionException(super.message);
}

/// 更新包下载，Android 与 Windows 共用。
///
/// 两个平台的更新包都是 zip（APK 本身就是 zip），所以校验逻辑完全一致。
abstract final class UpdateDownload {
  /// 从 [url] 下载到 [target]，边下边用 [onProgress] 回报 0.0~1.0。
  ///
  /// 总长度未知时回报 null（调用方显示不确定进度条）。
  ///
  /// 校验三层，缺一不可：GitCode 的下载代理出错时会返回一段 **HTML**，
  /// 那种响应若直接落盘再交给安装器，用户只会看到一句语焉不详的「解析失败」。
  ///   1. 状态码必须是 200
  ///   2. 已知总长度时不能小得离谱（< 64KB）
  ///   3. 落盘后文件头必须是 zip 魔数 `PK\x03\x04`
  static Future<File> download(
    String url,
    File target, {
    void Function(double? progress)? onProgress,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final dir = target.parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 先删同名旧文件，避免上次的断点残留被当成完整包
    if (target.existsSync()) target.deleteSync();
    final tmp = File('${target.path}.part');
    if (tmp.existsSync()) tmp.deleteSync();

    final client = http.Client();
    try {
      final resp =
          await client.send(http.Request('GET', Uri.parse(url))).timeout(timeout);
      if (resp.statusCode != 200) {
        throw UpdateException('下载失败：HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      if (total != null && total < 64 * 1024) {
        throw UpdateException('下载内容异常（仅 $total 字节），可能不是更新包');
      }

      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(total != null && total > 0 ? received / total : null);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      final head = await tmp.openRead(0, 4).first;
      if (head.length < 4 || head[0] != 0x50 || head[1] != 0x4B) {
        await tmp.delete();
        throw const UpdateException('下载内容不是有效的更新包');
      }

      await tmp.rename(target.path);
      onProgress?.call(1.0);
      return target;
    } on UpdateException {
      rethrow;
    } catch (e) {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
      throw UpdateException('下载失败：$e');
    } finally {
      client.close();
    }
  }
}
