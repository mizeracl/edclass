import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Настройки подключения к бэкенду.
class ApiConfig {
  ApiConfig._();

  /// Адрес сигнального сервера (Go-бэкенд), ws:// или wss://.
  ///
  /// Можно переопределить при сборке: `--dart-define=API_URL=ws://192.168.0.10:8080`.
  /// Дефолты:
  ///  * web и нативный десктоп — локальный сервер разработки;
  ///  * Android-эмулятор — host через 10.0.2.2;
  ///  * реальный телефон/десктоп — укажите IP компьютера через --dart-define.
  static const String signalingBaseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: '',
  );

  static String get signalingUrl {
    if (signalingBaseUrl.isNotEmpty) return signalingBaseUrl;
    if (kIsWeb) return 'ws://localhost:8080';
    // Android-эмулятор видит хост-машину как 10.0.2.2; iOS-симулятор и
    // десктоп используют loopback хост-машины.
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'ws://10.0.2.2:8080';
    }
    return 'ws://localhost:8080';
  }
}