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

  /// 请求超时时间。
  static const Duration requestTimeout = Duration(seconds: 6);
}
