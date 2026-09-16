/// 全局运行配置。
///
/// 后端地址通过编译期常量注入，方便不同环境打包：
/// - Android 模拟器默认访问宿主机：`http://10.0.2.2:8080`
/// - 真机/局域网请在构建时指定：
///   `flutter run --dart-define=API_BASE_URL=http://<服务器IP>:8080`
abstract final class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  /// 客户端版本号 / 构建时间，构建时注入（与 phonebook-server 同款做法）：
  ///   flutter build ... --dart-define=APP_VERSION=xxxxx --dart-define=BUILD_TIME='2026-09-05T01:23:45Z'
  /// 未注入时为占位符（本地直接 run 时显示）。
  static const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

  /// ISO-8601 UTC 时间；未注入显示“本地运行（未注入构建时间）”。
  static const String buildTimeRaw =
      String.fromEnvironment('BUILD_TIME', defaultValue: '');

  static String get buildTime {
    final t = DateTime.tryParse(buildTimeRaw)?.toLocal();
    if (t == null) return '本地运行（未注入构建时间）';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// 构建年份（版权信息用）：取构建时注入的 BUILD_TIME 的年份；
  /// 未注入（本地直接 run）时回退当前年份。
  static int get buildYear =>
      DateTime.tryParse(buildTimeRaw)?.year ?? DateTime.now().year;

  /// 请求超时时间。
  static const Duration requestTimeout = Duration(seconds: 6);

  // ---------- 应用内更新源（公开分发仓）----------
  //
  // 默认指向 GitCode 公开仓；换分发站、换仓库名、或别人 fork 后自行发布时，
  // 用编译期注入覆盖即可，不需要改代码：
  //   flutter build apk \
  //     --dart-define=UPDATE_REPO_OWNER=someone \
  //     --dart-define=UPDATE_REPO_NAME=some_repo \
  //     --dart-define=UPDATE_API_BASE=https://api.gitcode.com/api/v5 \
  //     --dart-define=UPDATE_WEB_BASE=https://gitcode.com
  //
  // 注意：这里刻意用「空值即未配置」而不是直接用 String.fromEnvironment 的
  // defaultValue——否则 CI 里变量名写错/漏传会注入空串，把请求拼成
  // `/repos//releases` 这种静默失败（而不是干净地回退默认值）。
  static const String _updateRepoOwner = String.fromEnvironment('UPDATE_REPO_OWNER');
  static const String _updateRepoName = String.fromEnvironment('UPDATE_REPO_NAME');
  static const String _updateApiBase = String.fromEnvironment('UPDATE_API_BASE');
  static const String _updateWebBase = String.fromEnvironment('UPDATE_WEB_BASE');

  /// 公开仓所属用户名/组织。
  static String get updateRepoOwner => _or(_updateRepoOwner, 'newton-miku');

  /// 公开仓仓库名。
  static String get updateRepoName => _or(_updateRepoName, 'contact_shiquan');

  /// Release 列表接口根地址（不含结尾斜杠）。
  static String get updateApiBase =>
      _trimSlash(_or(_updateApiBase, 'https://api.gitcode.com/api/v5'));

  /// Release 网页根地址（不含结尾斜杠），用于「打不开就跳浏览器」。
  static String get updateWebBase => _trimSlash(_or(_updateWebBase, 'https://gitcode.com'));

  /// 空/纯空白视为未配置，回退内置默认值。
  static String _or(String raw, String fallback) {
    final v = raw.trim();
    return v.isEmpty ? fallback : v;
  }

  /// 去掉结尾斜杠：`--dart-define` 手写时很容易多带一个，拼出 `//` 路径。
  static String _trimSlash(String v) =>
      v.endsWith('/') ? v.substring(0, v.length - 1) : v;
}
