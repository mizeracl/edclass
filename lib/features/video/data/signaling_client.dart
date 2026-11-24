import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/api_config.dart';

/// Клиент сигнального сервера WebRTC.
///
/// Подключается к комнате встречи через WebSocket и передаёт «пакеты
/// договорённостей» (SDP offer/answer, ICE-кандидаты) между участниками.
///
/// Умеет переподключаться: если WebSocket оборвался (пропал интернет, сервер
/// перезапустился), выводятся повторные попытки с нарастающей паузой, а поток
/// входящих сообщений не закрывается. Когда соединение восстановилось, в поток
/// приходит служебное сообщение `{'type': 'reconnected'}` — на него звонок
/// перезапускает медиа-соединение.
class SignalingClient {
  SignalingClient({
    required this.meetingId,
    required this.uid,
    this.name,
    this.isTeacher = false,
    this.getToken,
  });

  final String meetingId;
  final String uid;
  final String? name;
  final bool isTeacher;

  /// Возвращает свежий Firebase ID-токен для аутентификации на сигнальном
  /// сервере. Во-первых, он короткоживущий (час), поэтому его нужно запрашивать
  /// именно перед подключением. Во-вторых — сервер НЕ доверяет uid/name/teacher
  /// из URL: личность он делает только из проверенного токена. Без токена
  /// соединение с рабочим сервером отклоняется.
  final Future<String?> Function()? getToken;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  // События подключения: true — онлайн, false — сигнальный сервер недоступен.
  // Потребитель (звонок) показывает по ним состояние «восстанавливаем».
  final _stateController = StreamController<bool>.broadcast();
  Stream<bool> get connectionChanges => _stateController.stream;

  bool _disposed = false;
  bool _connecting = false;
  bool _connected = false;
  bool _everConnected = false;
  Timer? _reconnectTimer;
  int _attempt = 0;

  /// Поток входящих сообщений сигнализации.
  Stream<Map<String, dynamic>> get messages => _controller.stream;

  /// Есть ли прямо сейчас живое соединение с сервером.
  bool get isConnected => _connected;

  Uri _buildUri({String? token}) {
    final nameParam =
        name == null ? '' : '&name=${Uri.encodeQueryComponent(name!)}';
    final teacherParam = isTeacher ? '&teacher=1' : '';
    final tokenParam = (token != null && token.isNotEmpty)
        ? '&token=${Uri.encodeQueryComponent(token)}'
        : '';
    return Uri.parse(
        '${ApiConfig.signalingUrl}/ws/meetings/$meetingId?uid=$uid$nameParam$teacherParam$tokenParam');
  }

  /// Первое подключение (или повторная попытка из цикла автовосстановления).
  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    try {
      // Сначала отвязываем старое соединение: его «закрытие» (onDone) после
      // cancel() не должно восприниматься как новый обрыв и порождать
      // собственный цикл переподключений.
      final oldSub = _sub;
      _sub = null;
      _channel = null;
      await oldSub?.cancel();

      // Свежий Firebase ID-токен получаем именно в момент подключения: он
      // короткоживущий (~1 час), а запрошенный заранее может истечь до того,
      // как WebSocket реально установится. Если токена нет (dev без Firebase)
      // — сигнальный сервер в упрощённом режиме пустит и так.
      String? token;
      if (getToken != null) {
        try {
          token = await getToken!();
        } catch (_) {
          // Токен не получить — коннектимся без него (dev-сервер пропустит,
          // прод-сервер ответит закрытием, и мы переподключимся с новым).
        }
      }

      final channel = WebSocketChannel.connect(_buildUri(token: token));
      _channel = channel;
      _sub = channel.stream.listen(
        (event) {
          try {
            final data = jsonDecode(event as String) as Map<String, dynamic>;
            _controller.add(data);
          } catch (_) {
            // Не JSON — игнорируем.
          }
        },
        onError: (Object e) => _onSocketClosed(),
        onDone: _onSocketClosed,
      );
      final wasFirst = !_everConnected;
      _connected = true;
      _everConnected = true;
      _attempt = 0;
      _stateController.add(true);
      if (!wasFirst) {
        // Переподключение после обрыва — сообщаем, чтобы перезапустить звонок.
        _controller.add({'type': 'reconnected'});
      }
    } finally {
      _connecting = false;
    }
  }

  void _onSocketClosed() {
    _connected = false;
    if (_disposed) return;
    _stateController.add(false);
    if (_channel == null) return;
    _reconnectTimer?.cancel();
    final delay = Duration(
      milliseconds: (500 * (1 << _attempt.clamp(0, 4))).clamp(500, 5000),
    );
    _attempt++;
    _diag('Сервер сигнализации отключился, следующая попытка через '
        '${delay.inMilliseconds} мс');
    _reconnectTimer = Timer(delay, () {
      unawaited(connect());
    });
  }

  /// Ждёт восстановления соединения (своими попытками или уже идущим циклом),
  /// возвращает, получилось ли стать онлайн в пределах timeout.
  Future<bool> reconnect({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_disposed) return false;
    _reconnectTimer?.cancel();
    if (!_connected) {
      unawaited(connect());
    }
    final deadline = DateTime.now().add(timeout);
    while (!_disposed && !_connected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return _connected;
  }

  void send(String type,
      {Map<String, dynamic>? sdp,
      Map<String, dynamic>? ice,
      Map<String, dynamic>? extra}) {
    if (!_connected) return;
    final data = <String, dynamic>{
      'type': type,
      'sdp': ?sdp,
      'ice': ?ice,
      ...?extra,
    };
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {
      // канал мог закрыться в момент отправки — следующая попытка всё поправит
    }
  }

  void _diag(String message) {
    // dev-вывод; в самой комнате диагностику ведёт CallController.
    try {
      // ignore: avoid_print
      print('[signal] $message');
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _sub?.cancel();
    await _channel?.sink.close();
    await _stateController.close();
    await _controller.close();
  }
}