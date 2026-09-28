class AppConfig {
  static const _mode = String.fromEnvironment('APP_MODE', defaultValue: 'app');

  // JSON metadata applied on boot in central mode. Empty means no factory reset.
  static const factoryJson = String.fromEnvironment('FACTORY', defaultValue: '');

  static bool get isCentral => _mode == 'central';
  static bool get isApp => !isCentral;

  static bool get hasFactory => factoryJson.isNotEmpty;
}
