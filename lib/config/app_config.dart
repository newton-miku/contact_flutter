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

  /// 请求超时时间。
  static const Duration requestTimeout = Duration(seconds: 6);
}
