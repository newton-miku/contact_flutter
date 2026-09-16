import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'apk_installer.dart';

/// App 自身版本更新检查（走 GitCode 公开仓库的 Release）。
///
/// 为什么用 GitCode 而不是自建服务器：
///   更新分发必须公开可读，而开发仓库是私有的（含服务器地址等信息）。
///   所以约定"公私两仓"：私有仓 = 开发主干；公开仓只放 CHANGELOG 与 Release 附件。
///   App 查询的是【免鉴权】接口（已实测匿名可读）：
///     GET {UPDATE_API_BASE}/repos/{owner}/{repo}/releases
///
/// 仓库坐标与接口地址【不是写死的】，见 [AppConfig.updateRepoOwner] 等：
/// 默认值指向 GitCode 公开仓，可用 `--dart-define=UPDATE_REPO_OWNER=...`
/// 在编译期覆盖（CI 里由 GITCODE_OWNER/GITCODE_REPO 注入，与发布目标同源）。
///
/// 与联系人数据的版本检查（`/api/version`）是两件事：
///   那个管的是"号码库/通讯录数据"的新旧，这个管的是"App 安装包"的新旧。
///
/// 版本号约定（tag 即唯一入口）：
///   发布时只推一个 tag，如 `v1.0.0`；版本名与 versionCode 都由它决定，
///   pubspec 不用改。App 解析 tag 得到版本名，再换算 versionCode：
///     MAJOR×10000 + MINOR×100 + PATCH
///   与服务端 tool/release_gitcode.py 的换算规则必须保持一致。
///
/// 实测到的接口细节（2026-09-15 验证）：
///   - **html_url 实际返回 null**（文档写成 required 但不可靠），
///     所以 Release 页面地址自己按约定拼
///   - assets 里会有平台自动附带的源码包，`type` 为 `source`
///     （含一个与 tag 同名的 `v1.0.0.zip`！）；真实上传的附件 `type` 为 `attach`。
///     只按后缀挑 zip 会把源码包当成 Windows 安装包下发给用户，
///     所以挑之前必须先把 `source` 排除掉。
///
/// 产物命名约定（与 GitHub Release 上完全一致，发布脚本照此命名上传）：
///   `contact_flutter_<tag>.apk`                 默认包：arm + arm64
///   `contact_flutter_<tag>_x86_64.apk`          x86_64，模拟器用
///   `contact_flutter_windows_x64_<tag>.zip`     Windows 免安装包
/// Linux/macOS 暂无产物，只引导到 Release 页面。
class AppUpdate {
  /// 远端版本名，如 1.0.0
  final String versionName;

  /// 远端构建号，如 10000
  final int versionCode;

  /// Release 里带的更新说明（发布时写入的 CHANGELOG 内容）
  final String notes;

  /// 与本机平台匹配的更新包下载地址；该版本未附对应产物时为 null。
  final String? downloadUrl;

  /// 更新包文件名（进度弹窗与落盘用）；无产物时为 null。
  final String? assetName;

  /// Release 页面地址（自己按约定拼，不依赖接口的 html_url）
  final String pageUrl;

  const AppUpdate({
    required this.versionName,
    required this.versionCode,
    required this.notes,
    required this.pageUrl,
    this.downloadUrl,
    this.assetName,
  });

  /// 是否已附带本机可用的更新包。未附带时 UI 应引导去 Release 页面手动下载。
  bool get hasDownload => downloadUrl != null && downloadUrl!.isNotEmpty;

  @override
  String toString() =>
      'AppUpdate($versionName, notes=${notes.length}字, asset=${assetName ?? '无'})';
}

/// 检查结果：可更新 / 已最新 / 失败（失败不抛异常，交给 UI 显示原因）
class AppUpdateResult {
  final AppUpdate? update;
  final String? error;
  const AppUpdateResult({this.update, this.error});

  bool get hasUpdate => update != null;
}

/// 用户点过"稍后"的版本记录在本地，避免每次启动都弹同一个提示。
///
/// 存的是版本名（如 `1.0.1`），不是 `1.0.1+10001` 那种拼出来的标识。
const _kSkippedVersionKey = 'app_update_skipped_version';

/// 该版本是否已被用户跳过。
Future<bool> isVersionSkipped(String versionName) async {
  final p = await SharedPreferences.getInstance();
  return p.getString(_kSkippedVersionKey) == versionName;
}

/// 记住用户跳过的版本（下次启动不再自动提示该版本，直到出现更新的一版）。
Future<void> skipVersion(String versionName) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_kSkippedVersionKey, versionName);
}

/// 启动时的自动检查：只在"确有更新且用户没跳过这一版"时返回可更新的结果。
///
/// 设计取向：宁可少弹也不要烦人，也不能拖慢启动——
///   - 网络失败/超时/CORS 一律静默返回 null（不打扰用户）
///   - 用户点过"稍后"的版本不再提示
///   - 调用方应放在启动之后延迟执行，不要挡在首帧前面
Future<AppUpdate?> autoCheckAppUpdate({
  String? owner,
  String? repo,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final res = await checkAppUpdate(owner: owner, repo: repo, timeout: timeout);
  final up = res.update;
  if (up == null) return null;            // 已最新或失败：静默
  if (await isVersionSkipped(up.versionName)) return null;
  return up;
}

/// 检查 App 更新。
///
/// [owner]/[repo] 指向公开仓，省略时取 [AppConfig] 里的编译期注入值
/// （默认 GitCode 公开仓）；[timeout] 默认 12 秒，超时/网络错误都返回带 error 的
/// 结果，不抛异常——"检查更新"是辅助功能，不该让主流程崩。
Future<AppUpdateResult> checkAppUpdate({
  String? owner,
  String? repo,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final o = owner ?? AppConfig.updateRepoOwner;
  final r = repo ?? AppConfig.updateRepoName;
  final uri = Uri.parse('${AppConfig.updateApiBase}/repos/$o/$r/releases');
  try {
    final resp = await http.get(uri, headers: const {
      'Accept': 'application/json',
      // 明确要 JSON，部分网关会按 Accept 返回 HTML
      'User-Agent': 'contact_flutter-update-check',
    }).timeout(timeout);

    if (resp.statusCode != 200) {
      return AppUpdateResult(error: '更新服务返回 ${resp.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! List) {
      return const AppUpdateResult(error: '更新服务返回格式异常');
    }

    // 已安装版本
    final pkg = await PackageInfo.fromPlatform();
    final currentName = _splitName(pkg.version);
    final currentCode = int.tryParse(pkg.buildNumber) ?? 0;

    // 本机该拿哪种产物（Linux/macOS 为 null：公开仓暂无对应包）
    final artifact = await _currentArtifact();

    // 找出版本号最大的正式版（跳过预发布）
    AppUpdate? best;
    for (final item in decoded) {
      if (item is! Map) continue;
      if (item['prerelease'] == true) continue;
      // tag 形如 v1.0.0；版本名解析出来后，versionCode 由它换算
      final versionName = _parseVersionName('${item['tag_name'] ?? ''}');
      if (versionName == null) continue;
      final rawBody = '${item['body'] ?? ''}';
      final asset = pickUpdateAsset(item['assets'], artifact);
      final candidate = AppUpdate(
        versionName: versionName,
        versionCode: _versionCodeOf(versionName),
        // 说明里保留 Version-Code 行也无妨；这里把版本信息行去掉，只留更新内容
        notes: _stripVersionHeader(rawBody),
        // 不用接口的 html_url：实测返回 null。按公开仓的固定约定自己拼。
        pageUrl: '${AppConfig.updateWebBase}/$o/$r/releases',
        downloadUrl: asset?.url,
        assetName: asset?.name,
      );
      if (best == null ||
          _compare(candidate.versionName, candidate.versionCode,
                  best.versionName, best.versionCode) > 0) {
        best = candidate;
      }
    }

    if (best == null) {
      return const AppUpdateResult(error: '远端还没有正式版本记录');
    }
    if (_compare(best.versionName, best.versionCode, currentName, currentCode) <= 0) {
      return const AppUpdateResult(); // 已是最新
    }
    return AppUpdateResult(update: best);
  } catch (e) {
    return AppUpdateResult(error: '检查更新失败：$e');
  }
}

/// 从 tag 取版本名：形如 `v1.0.0` 或 `1.0.0`。
///
/// 也容忍历史上出现过的 `1.0.0+10000` 形式：`+` 之后的部分一律忽略——
/// versionCode 永远由版本名重新换算，不信任远端写的东西。
String? _parseVersionName(String tag) {
  final t = tag.trim().replaceFirst(RegExp(r'^[vV]'), '');
  final m = RegExp(r'^(\d+(?:\.\d+)*)').firstMatch(t);
  return m?.group(1);
}

/// 版本名 → versionCode（与服务端 tool/release_gitcode.py 的换算规则必须一致）。
///
/// 规则：MAJOR×10000 + MINOR×100 + PATCH
///   1.0.0 → 10000    1.0.1 → 10001    1.1.0 → 10100    2.0.0 → 20000
///
/// 这样 versionCode 完全由 tag 决定，不需要在发布说明里额外携带：
/// 发布时只推一个 v1.0.0 的 tag，App 解析 tag 即可算出该版本的 versionCode。
/// 约束：MINOR / PATCH 需 < 100（各占两位），否则会进位串位。
int _versionCodeOf(String versionName) {
  final parts = versionName.split('.').map((s) {
    final digits = s.replaceAll(RegExp(r'\D'), '');
    return int.tryParse(digits) ?? 0;
  }).toList();
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts[0] * 10000 + parts[1] * 100 + parts[2];
}

/// 去掉正文开头的 `Version:` / `Version-Code:` 两行，只留更新说明给用户看。
String _stripVersionHeader(String body) {
  return body
      .replaceFirst(RegExp(r'^\s*Version:\s*[^\n]*\n', multiLine: true), '')
      .replaceFirst(RegExp(r'^\s*Version-Code:\s*\d+\s*\n?', multiLine: true), '')
      .trim();
}

String _splitName(String v) => v.trim().replaceFirst(RegExp(r'^[vV]'), '');

/// 版本比较：先比版本名（按数字段），再比构建号。返回 >0 表示 a 更新。
int _compare(String an, int ac, String bn, int bc) {
  final ap = an.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final bp = bn.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final n = ap.length > bp.length ? ap.length : bp.length;
  for (var i = 0; i < n; i++) {
    final x = i < ap.length ? ap[i] : 0;
    final y = i < bp.length ? bp[i] : 0;
    if (x != y) return x - y;
  }
  return ac - bc;
}

/// 本机该取哪种产物。
enum UpdateArtifact {
  /// Android 默认包（arm + arm64），覆盖绝大多数真机。
  androidArm,

  /// Android x86_64 包，给不带 arm 翻译的模拟器用。
  androidX86,

  /// Windows 免安装压缩包（解压即用）。
  windowsZip;

  /// 文件名是否属于本类型。
  ///
  /// 判定只依赖发布脚本的命名约定（与 GitHub Release 一致），大小写不敏感。
  bool matches(String name) {
    final n = name.toLowerCase();
    switch (this) {
      case UpdateArtifact.androidArm:
        return n.endsWith('.apk') && !n.contains('x86_64');
      case UpdateArtifact.androidX86:
        return n.endsWith('.apk') && n.contains('x86_64');
      case UpdateArtifact.windowsZip:
        return n.endsWith('.zip') && n.contains('windows');
    }
  }
}

/// 当前平台该取哪种产物；公开仓里没有对应包时返回 null（只引导去发布页）。
Future<UpdateArtifact?> _currentArtifact() async {
  if (kIsWeb) return null;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      // 只有"支持 x86_64 且不支持 arm64"才用模拟器专用包：
      // 现在不少模拟器带 arm 翻译，那种情况下默认包更保险。
      final abis = await ApkInstaller.supportedAbis();
      final needX86 = abis.contains('x86_64') && !abis.contains('arm64-v8a');
      return needX86 ? UpdateArtifact.androidX86 : UpdateArtifact.androidArm;
    case TargetPlatform.windows:
      return UpdateArtifact.windowsZip;
    default:
      // Linux / macOS：发布链路目前不产出这两个平台的包
      return null;
  }
}

/// 从 assets 里挑出与本机匹配的产物。
///
/// 两条铁律：
///   1. **必须排除 `type == "source"`**：GitCode 会给每个 Release 自动附上源码归档，
///      里面有一个与 tag 同名的 `v1.0.0.zip`。只按后缀挑 zip 会把它当成
///      Windows 安装包下发给用户。
///   2. **绝不退回"第一个附件"**：挑不到就返回 null，UI 改为引导去 Release 页面。
///
/// 公开是为了能被测试直接覆盖（跨 CI 与客户端的命名契约，错了很难发现）。
({String url, String name})? pickUpdateAsset(Object? assets, UpdateArtifact? want) {
  if (want == null || assets is! List) return null;

  // x86 模拟器优先 x86_64 包，缺了就退回默认包（旧版本可能只传了一个包）；
  // 真机则【只用默认包】——把 x86_64 包发给 arm 手机是装不上的。
  final order = want == UpdateArtifact.androidX86
      ? const [UpdateArtifact.androidX86, UpdateArtifact.androidArm]
      : [want];

  for (final kind in order) {
    for (final a in assets) {
      if (a is! Map) continue;
      if ('${a['type']}' == 'source') continue;
      final name = '${a['name'] ?? ''}';
      if (!kind.matches(name)) continue;
      final url = a['browser_download_url'];
      if (url is String && url.isNotEmpty) return (url: url, name: name);
    }
  }
  return null;
}
