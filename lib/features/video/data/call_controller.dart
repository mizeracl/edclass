import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_client.dart';

/// Управляет видеозвонком: захват микрофона/камеры (можно отдельно, можно
/// без камеры), peer-соединение с обменом SDP/ICE через сигнальный сервер,
/// проброс экрана, индикатор «говорит» по статистике RTP.
class CallController extends ChangeNotifier {
  CallController({
    required this.meetingId,
    required this.uid,
    this.isTeacher = false,
  });

  final String meetingId;
  final String uid;
  final bool isTeacher;

  // --- UI-состояние (желаемое состояние устройств) ---
  bool micEnabled = true;
  bool cameraEnabled = true;
  bool joined = false;
  bool screenSharing = false;
  // Пропорции (w/h) картинки экрана, который сейчас в главной области: своя
  // трансляция или экран собеседника. Нужно для рисования — чтобы штрихи
  // привязывались к самой картинке, а не ко всей области (там есть поля
  // «письма» из-за objectFit contain).
  double? screenAspect;
  // Собеседник ведёт трансляцию экрана: признак + id его видео-потока,
  // по которому мы отличаем его экран от его камеры.
  bool peerScreenSharing = false;
  String? _peerScreenStreamId;
  // id видеопотоков, которые собеседник объявлял трансляцией экрана: по ним
  // распознаём его экран, даже если сигнал «screen» пришёл раньше или позже
  // самого потока (при восстановлении соединения порядок не гарантирован).
  final Set<String> _screenStreamIds = {};
  MediaStream? _peerScreenStream;
  // Состояние устройств Собеседника (пришло по сигналу «device»); true, пока
  // не узнали обратное.
  bool remoteMicEnabled = true;
  bool remoteCameraEnabled = true;
  // Политика учителя: могут ли ученики показывать экран (по умолчанию — да).
  bool studentsCanShare = true;
  // Временное уведомление (например, «учитель запретил показ экрана»).
  String? notice;
  bool hasPeer = false;
  bool capturingMedia = false;
  bool remoteSpeaking = false;
  bool micBusy = false;
  bool cameraBusy = false;
  String? remoteName; // имя собеседника (для галереи участников)
  String? role; // offerer | answerer
  String? errorMessage;
  String? micIssue;
  String? cameraIssue;

  // --- Диагностика (текст для пользователя и для логов) ---
  final List<String> _diagnostics = [];
  List<String> get diagnostics => List.unmodifiable(_diagnostics);

  // События рисования на трансляции: свои штрихи страница шлёт через
  // sendStroke/sendWhiteboardClear, чужие приходят сюда после ретрансляции.
  final StreamController<Map<String, dynamic>> _drawEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get drawEvents => _drawEvents.stream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  // На экран отдельного рендерера выводится трансляция экрана: либо наша
  // копия, либо экран собеседника. Работает на всех платформах.
  final RTCVideoRenderer? screenRenderer = RTCVideoRenderer();

  MediaStream? _micStream;
  MediaStream? _camStream;
  MediaStream? _localStream; // общий поток (собирается из _micStream/_camStream)
  MediaStream? _screenStream;
  RTCPeerConnection? _pc;
  SignalingClient? _client;
  StreamSubscription<Map<String, dynamic>>? _signalSub;
  StreamSubscription<bool>? _connSub;
  Timer? _voiceTimer;
  bool _pcReady = false;
  bool _disposed = false;
  bool _hangupDone = false;
  final Set<String> _seenTrackIds = {};
  Map<String, dynamic>? _pendingOffer;
  // Наш offer уже в пути — не шлём второй, пока не придёт answer или встречный
  // offer (защита от «шторма» переговоров при повторном соединении).
  bool _offerInFlight = false;
  // Идёт полный перезапуск соединения (автовосстановление после обрыва) —
  // чтобы несколько причин сразу не запустили его несколько раз.
  bool _restartInProgress = false;
  // Пользователю показываем «восстанавливаем соединение».
  bool reconnecting = false;
  // Сторож медиа-соединения: по disconnected/failed ждём 3 с (вдруг само
  // восстановится) и перезапускаем звонок. Не чаще одного раза в 15 с.
  Timer? _healthTimer;
  DateTime? _nextRestartAllowed;
  // Сторож «не доехали до connected»: если после отправки offer/answer медиа
  // так и не потекло, соединение зависает в new/connecting, а штатный сторож
  // (_healthTimer) реагирует только на disconnected/failed. Тогда сами
  // перезапускаем звонок — иначе картинка появится лишь после следующей
  // пересылки offer (например, когда собеседник включит экран).
  Timer? _connectWatchdog;
  // Последнее состояние соединения из callback'ов. Геттеры
  // iceConnectionState/connectionState на нативе отдают null, поэтому
  // полагаемся только на события.
  RTCIceConnectionState? _lastIceState;
  RTCPeerConnectionState? _lastConnState;
  // Цепочка последовательной обработки сигналов (см. listen в _ensureSignaling).
  Future<void> _signalQueue = Future<void>.value();
  // Кандидаты, пришедшие до установки remote description: копим и применяем,
  // как только описание появится.
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescSet = false;
  // Текущие запросы захвата: по ним можно отменить зависший браузер.
  final Map<String, Completer<MediaStream>> _captureCompleters = {};
  final Map<String, MediaStream?> _capturePending = {};

  bool get hasMicTrack => _micStream?.getAudioTracks().isNotEmpty == true;
  bool get hasCameraTrack => _camStream?.getVideoTracks().isNotEmpty == true;

  /// Поток микрофона (для теста уровня звука на экране подготовки).
  MediaStream? get micStream => _micStream;

  /// Поток камеры (для превью на экране подготовки).
  MediaStream? get camStream => _camStream;

  void _diag(String message) {
    debugPrint('[call] $message');
    _diagnostics.add(message);
  }

  /// Подготовка перед звонком: захватываем выбранные устройства СРАЗУ, чтобы
  /// на экране подготовки была живая картинка с камеры и работал тест
  /// микрофона. Камера может не отвечать — она запрашивается в фоне,
  /// а звонок всё равно сможет начаться.
  Future<void> visitPreview({
    required bool mic,
    required bool camera,
  }) async {
    micEnabled = mic;
    cameraEnabled = camera;
    try {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      await screenRenderer?.initialize();
    } catch (e) {
      errorMessage = 'Ошибка инициализации видео: $e';
      notifyListeners();
      rethrow;
    }
    if (mic) await _acquireMic();
    if (!_disposed && camera) {
      // Камеру запускаем в фоне: если браузер не ответит (занятая камера и
      // т.п.), таймаут покажет ошибку, но не заставит ждать перед входом.
      unawaited(_acquireCamera());
    }
    await _rebuildLocalStream();
    notifyListeners();
  }

  /// Вход в звонок. Устройства обычно уже захвачены в `visitPreview`; сюда
  /// лишь до-захватываемь то, чего не хватает по флагу, собираем общий поток
  /// и поднимаем соединение. Если камера недоступна — звонок идёт без видео.
  Future<void> start({
    String? name,
    bool initializeRenderers = false,
  }) async {
    try {
      if (initializeRenderers) {
        await localRenderer.initialize();
        await remoteRenderer.initialize();
        await screenRenderer?.initialize();
      }
    } catch (e) {
      errorMessage = 'Ошибка инициализации видео: $e';
      notifyListeners();
      rethrow;
    }

    capturingMedia = true;
    notifyListeners();
    await _acquireMicIfWanted();
    if (!_disposed && cameraEnabled && !hasCameraTrack) {
      await _acquireCamera();
    }
    capturingMedia = false;

    final combined = await _rebuildLocalStream();
    if (_disposed) {
      await combined?.dispose();
      return;
    }
    if (combined != null) {
      _localStream = combined;
      localRenderer.srcObject = combined;
    }
    notifyListeners(); // своё превью появляется сразу

    // 2. Соединение с сигнальным сервером.
    try {
      _diag('Подключаемся к серверу сигнализации...');
      final client = SignalingClient(
          meetingId: meetingId,
          uid: uid,
          name: name,
          isTeacher: isTeacher,
        );
      _client = client;
      await client.connect();
      if (_disposed) return;
      // Обрабатываем сигналы СТРОГО по очереди. Поток Dart не ждёт завершения
      // async-обработчика, поэтому без очереди «ice» успевает прийти раньше,
      // чем применится offer: кандидат добавляется без remote description и
      // теряется, пары не складываются и ICE не стартует вовсе.
      _signalSub = client.messages.listen((data) {
        _signalQueue = _signalQueue
            .then((_) => _handleSignal(data))
            .catchError((Object e) => _diag('Ошибка обработки сигнала: $e'));
      });
      // Как только сигнальный сервер стал недоступен — сразу показываем
      // «восстанавливаем соединение» (а не только в момент перезапуска звонка,
      // когда сервер уже снова ответил). Выключим баннер в конце _restartCall.
      await _connSub?.cancel();
      _connSub = client.connectionChanges.listen((online) {
        if (online) return;
        if (_disposed || _hangupDone) return;
        reconnecting = true;
        notifyListeners();
      });
      _diag('Сервер: подключено.');
      notifyListeners();
    } catch (e) {
      errorMessage = 'Не удалось соединиться с сервером звонка: $e';
      _diag('Ошибка сигнального сервера: $e');
      notifyListeners();
      return;
    }

    // 3. Peer-соединение.
    try {
      await _setupPeerConnection();
      if (_disposed) return;
      joined = true;
      _diag('Peer-соединение готово.');
      _startVoiceMonitor();
      notifyListeners();
    } catch (e) {
      errorMessage = 'Ошибка соединения: $e';
      _diag('Ошибка peer-соединения: $e');
      notifyListeners();
    }
  }

  // --- Динамическое включение/выключение устройств ---
  // До звонка переключатели реально стартуют/останавливают захват (превью и
  // тест микрофона), во время звонка — заглушают/возобновляют передачу.

  Future<void> setMicEnabled(bool value) async {
    if (micEnabled == value) return;
    micEnabled = value;
    notifyListeners();

    if (value) {
      await _acquireMic();
      if (!micEnabled || _disposed) return; // могло не получиться
      if (joined) {
        await _wireTrackToPeer('audio');
        await _renegotiate();
      } else {
        await _rebuildLocalStream();
      }
      notifyListeners();
      if (joined) _sendDeviceState();
    } else {
      if (joined) {
        for (final t
            in _micStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
          t.enabled = false;
        }
      } else {
        _abortCapture('Микрофон');
        await _releaseMic();
        await _rebuildLocalStream();
      }
      _diag('Микрофон выключен.');
      notifyListeners();
      if (joined) _sendDeviceState();
    }
  }

  Future<void> setCameraEnabled(bool value) async {
    if (cameraEnabled == value && (value ? hasCameraTrack : true)) return;
    cameraEnabled = value;
    notifyListeners();

    if (value) {
      await _acquireCamera();
      if (!cameraEnabled || _disposed) return; // могло не получиться
      if (joined) {
        await _wireTrackToPeer('video');
        await _renegotiate();
      } else {
        await _rebuildLocalStream();
      }
      notifyListeners();
      if (joined) _sendDeviceState();
    } else {
      if (joined) {
        for (final t
            in _camStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
          t.enabled = false;
        }
      } else {
        _abortCapture('Камера');
        await _releaseCamera();
        await _rebuildLocalStream();
      }
      _diag('Камера выключена.');
      notifyListeners();
      if (joined) _sendDeviceState();
    }
  }

  Future<void> toggleMic() => setMicEnabled(!micEnabled);
  Future<void> toggleCamera() => setCameraEnabled(!cameraEnabled);

  // --- Захват устройств (переиспользуется и до, и во время звонка) ---

  Future<void> _acquireMicIfWanted() async {
    if (micEnabled && !hasMicTrack) await _acquireMic();
  }

  Future<void> _acquireMic() async {
    if (hasMicTrack) {
      for (final t in _micStream!.getAudioTracks()) {
        t.enabled = true;
      }
      return;
    }
    if (micBusy) return;
    micBusy = true;
    micIssue = null;
    notifyListeners();
    try {
      final mic = await _captureKind({'audio': true}, 'Микрофон');
      if (_disposed || !micEnabled) {
        await mic.dispose();
        return;
      }
      _micStream = mic;
      _diag('Микрофон: включён (${_micStream!.getAudioTracks().firstOrNull?.label ?? 'без названия'})');
      notifyListeners();
    } catch (e) {
      if (micEnabled) {
        micEnabled = false;
        micIssue = 'Микрофон не запущен: $e';
        _diag(micIssue!);
      } else {
        _diag('Микрофон: захват отменён.');
      }
      notifyListeners();
    } finally {
      micBusy = false;
      notifyListeners();
    }
  }

  Future<void> _acquireCamera() async {
    if (hasCameraTrack) {
      for (final t in _camStream!.getVideoTracks()) {
        t.enabled = true;
      }
      return;
    }
    if (cameraBusy) return;
    cameraBusy = true;
    cameraIssue = null;
    notifyListeners();
    try {
      final cam = await _captureKind(
        {'video': {'facingMode': 'user', 'width': 1280, 'height': 720}},
        'Камера',
      );
      if (_disposed || !cameraEnabled) {
        await cam.dispose();
        return;
      }
      _camStream = cam;
      _diag('Камера: включена (${_camStream!.getVideoTracks().firstOrNull?.label ?? 'без названия'})');
      notifyListeners();
    } catch (e) {
      if (cameraEnabled) {
        cameraEnabled = false;
        cameraIssue = 'Камера не запущена: $e';
        _diag(cameraIssue!);
      } else {
        _diag('Камера: захват отменён пользователем.');
      }
      notifyListeners();
    } finally {
      cameraBusy = false;
      if (joined) {
        // Камера могла быть запрошена в фоне и «прийти» уже во время звонка:
        // добавляем её трек в соединение.
        unawaited(_wireTrackToPeer('video').then((_) => _renegotiate()));
      }
      notifyListeners();
    }
  }

  Future<void> _releaseMic() async {
    for (final t in _micStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    _micStream = null;
  }

  Future<void> _releaseCamera() async {
    for (final t in _camStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    _camStream = null;
    if (localRenderer.srcObject != null && !joined) {
      localRenderer.srcObject = null;
    }
  }

  /// Собирает общий поток из текущих микрофона/камеры и показывает его в
  /// превью. Если поток уже есть и ничего не изменилось — просто возвращает.
  Future<MediaStream?> _rebuildLocalStream() async {
    if (_micStream == null && _camStream == null) {
      _localStream = null;
      localRenderer.srcObject = null;
      return null;
    }
    final combined = await createLocalMediaStream('edclass-local');
    for (final track in _micStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await combined.addTrack(track);
    }
    for (final track in _camStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await combined.addTrack(track);
    }
    if (_disposed) {
      await combined.dispose();
      return null;
    }
    _localStream = combined;
    localRenderer.srcObject = combined;
    return combined;
  }

  /// Добавляет все треки источника в peer-соединение (после захвата
  /// во время уже установленного звонка).
  Future<void> _wireTrackToPeer(String kind) async {
    final source = kind == 'audio' ? _micStream : _camStream;
    if (source == null || _pc == null) return;
    _localStream ??= await createLocalMediaStream('edclass-local');
    for (final t in source.getTracks()) {
      await _localStream!.addTrack(t);
      await _pc?.addTrack(t, _localStream!);
    }
    localRenderer.srcObject = _localStream;
    notifyListeners();
  }

  // --- Захват с таймаутом ---

  /// Запрашивает один источник (микрофон или камеру) с таймаутом: браузер
  /// иногда не возвращает доступ (занятая камера, зависший запрос), и вызов
  /// повисает навсегда — поэтому 15 секунд и понятная ошибка. Запрос можно
  /// отменить через [_abortCapture], пока он выполняется.
  Future<MediaStream> _captureKind(
      Map<String, dynamic> constraints, String label) {
    const timeout = Duration(seconds: 15);
    final completer = Completer<MediaStream>();
    _captureCompleters[label] = completer;
    _capturePending[label] = null;

    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      unawaited(_capturePending[label]?.dispose());
      completer.completeError(
        Exception(
            '$label: браузер не ответил за ${timeout.inSeconds} с. '
            'Проверьте, что вкладка активна и устройство не занято другим '
            'приложением'),
      );
    });

    unawaited(() async {
      try {
        final stream = await navigator.mediaDevices.getUserMedia(constraints);
        _capturePending[label] = stream;
        if (completer.isCompleted) {
          await stream.dispose();
        } else {
          completer.complete(stream);
        }
      } catch (e) {
        if (completer.isCompleted) return;
        completer.completeError(e);
      } finally {
        timer.cancel();
      }
    }());

    return completer.future.whenComplete(() {
      _captureCompleters.remove(label);
      _capturePending.remove(label);
    });
  }

  /// Отменяет зависший запрос захвата (например, пользователь выключил
  /// тумблер камеры, пока браузер «думал»). Если запрос уже завершился —
  /// ничего не делает.
  void _abortCapture(String label) {
    final completer = _captureCompleters[label];
    if (completer == null || completer.isCompleted) return;
    unawaited(_capturePending[label]?.dispose());
    completer.completeError(Exception('$label: захват отменён'));
  }

  /// Повторно запускает звонок после ошибки или зависания в режиме звонка.
  Future<void> retry() async {
    errorMessage = null;
    micIssue = null;
    cameraIssue = null;
    _disposed = false;
    _restartInProgress = false;
    reconnecting = false;
    capturingMedia = false;
    _diagnostics.clear();

    await _releaseMic();
    await _releaseCamera();
    _localStream = null;
    localRenderer.srcObject = null;
    notifyListeners();
    await start(initializeRenderers: false);
  }

  // --- Индикатор «собеседник говорит» ---

  void _startVoiceMonitor() {
    _voiceTimer?.cancel();
    const interval = Duration(milliseconds: 500);
    Timer.periodic(interval, (timer) async {
      final pc = _pc;
      if (pc == null || _disposed) {
        _voiceTimer?.cancel();
        return;
      }
      final level = await _probeRemoteAudioLevel();
      final talking = level > 0.03;
      if (talking != remoteSpeaking) {
        remoteSpeaking = talking;
        notifyListeners();
      }
    });
  }

  Future<double> _probeRemoteAudioLevel() async {
    final pc = _pc;
    if (pc == null) return 0;
    double maxLevel = 0;
    try {
      final stats = await pc.getStats();
      for (final s in stats) {
        if (s.type != 'inbound-rtp') continue;
        if (s.values['kind'] != 'audio') continue;
        final level = s.values['audioLevel'];
        if (level is num) maxLevel = max(maxLevel, level.toDouble());
      }
    } catch (_) {
      // статистика может быть недоступна — просто возвращаем 0
    }
    return maxLevel;
  }

  void _stopVoiceMonitor() {
    _voiceTimer?.cancel();
    _voiceTimer = null;
    if (remoteSpeaking) {
      remoteSpeaking = false;
      notifyListeners();
    }
  }

  Future<void> _setupPeerConnection() async {
    // STUN — для звонков в одной сети. TURN (openrelay.metered.ca) — реле
    // для разных сетей/NAT: его видно как общедоступный и бесплатный, без
    // регистрации. Для продакшена лучше заменить на свой coturn или
    // провайдера — достаточно поменять этот список.
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ],
    };

    _pc = await createPeerConnection(configuration);
    if (_disposed) return;

    _pc!.onTrack = (event) {
      final stream = event.streams.isEmpty ? null : event.streams.first;
      if (stream == null) return;
      final videoTrack = stream.getVideoTracks().isNotEmpty
          ? stream.getVideoTracks().first
          : null;
      if (videoTrack == null) return; // только звук — видео-рендерерам не нужно
      final trackId = videoTrack.id ?? stream.id;
      // Дедупликация по id ТРЕКА, а не потока: два разных видеотрека
      // (камера и экран) могут прийти в потоках с одинаковым id, и раньше
      // экран молча отбрасывался — поэтому у собеседника оставалась галерея.
      if (!_seenTrackIds.add(trackId)) {
        _diag('Повторное событие видеотрека $trackId — пропуск.');
        return;
      }

      // Экран собеседника отличаем от его камеры по id потока: ведущий
      // присылает id своей трансляции в сигнале «screen» (а на входе в
      // комнату его передаёт сервер). Имя трека — только запасной вариант,
      // оно зависит от языка ОС.
      final label = videoTrack.label?.toLowerCase() ?? '';
      final isScreen = _screenStreamIds.contains(stream.id) ||
          label.contains('screen');

      // Когда трек заканчивается (отключили трансляцию, кто-то вышел) —
      // очищаем рендерер, чтобы не оставалась застывшая картинка.
      void clearOnEnd(RTCVideoRenderer? renderer) {
        videoTrack.onEnded = () {
          if (renderer?.srcObject == stream) {
            renderer?.srcObject = null;
            if (isScreen) _peerScreenStream = null;
            _diag('Видеопоток ${isScreen ? 'экрана' : 'камеры'} завершён.');
            notifyListeners();
          }
        };
      }

      if (isScreen) {
        // Одиночная трансляция: свой экран показываем локально сразу при
        // старте, поэтому чужой сюда приходит только когда мы не транслируем.
        if (screenSharing) {
          _diag('Чужой экран пропущен (мы сами транслируем).');
          return;
        }
        screenRenderer?.srcObject = stream;
        _peerScreenStream = stream;
        _watchScreenAspect(videoTrack);
        clearOnEnd(screenRenderer);
        _diag('Трансляция экрана собеседника: ${stream.id}');
      } else {
        remoteRenderer.srcObject = stream;
        clearOnEnd(remoteRenderer);
        _diag('Камера собеседника: ${stream.id}');
      }
      notifyListeners();
    };

    _pc!.onIceCandidate = (candidate) {
      _client?.send('ice', ice: candidate.toMap());
    };

    _pc!.onConnectionState = (state) {
      debugPrint('CONNECTION STATE: $state');
      _lastConnState = state;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectWatchdog?.cancel();
        _connectWatchdog = null;
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _diag('Хост: соединение потеряно ($state). Пытаюсь восстановить...');
        _onPeerHealth(false);
      } else {
        _onPeerHealth(true);
      }
    };

    _pc!.onIceConnectionState = (state) {
      debugPrint('ICE STATE: $state');
      _lastIceState = state;
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _connectWatchdog?.cancel();
        _connectWatchdog = null;
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _onPeerHealth(false);
      } else {
        _onPeerHealth(true);
      }
    };

    // Добавляем в соединение все имеющиеся треки (может быть и 0).
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await _pc!.addTrack(track, _localStream!);
    }
    // Если транслируем экран — возвращаем в новое соединение и его трек.
    if (screenSharing && _screenStream != null) {
      for (final t in _screenStream!.getTracks()) {
        await _pc!.addTrack(t, _screenStream!);
      }
    }
    if (_disposed) return;

    _pcReady = true;

    // Если к моменту готовности уже пришёл offer — отвечаем на него.
    if (_pendingOffer != null) {
      await _onOfferReceived(_pendingOffer!);
      _pendingOffer = null;
    }

    _maybeSendOffer();
    notifyListeners();
  }

  void _maybeSendOffer() {
    if (_pcReady && role == 'offerer' && hasPeer) {
      _sendOffer();
    }
  }

  Future<void> _sendOffer() async {
    if (_offerInFlight) return;
    _offerInFlight = true;
    try {
      // Ответчик может добавить свой видео-трек (например, экран после
      // восстановления соединения) только если в offer есть приёмная m-секция
      // видео — иначе новый трек останется без канала и не дойдёт.
      await _ensureRecvTransceiver('video');
      final offer = await _pc!.createOffer(_offerConstraints);
      await _pc!.setLocalDescription(offer);
      _client?.send('offer', sdp: offer.toMap());
      _diag('Offer отправлен.');
      _armConnectWatchdog('после offer');
    } catch (e) {
      _diag('Ошибка формирования offer: $e');
      _offerInFlight = false;
    }
  }

  /// Если у нас нет ни одного видео-трансивера (нет камеры/экрана), добавляет
  /// в соединение приёмный (recvonly) видео-трансивер. Тогда offer всегда
  /// содержит видео m-секцию, и собеседник сможет присоединить к ней свою
  /// трансляцию экрана или камеру.
  Future<void> _ensureRecvTransceiver(String kind) async {
    final pc = _pc;
    if (pc == null || _disposed) return;
    final localKinds = <String>{
      for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[])
        if (t.kind != null) t.kind!,
    };
    if (localKinds.contains(kind)) return; // свой трек уже даёт m-секцию
    final transceivers = await pc.getTransceivers();
    for (final tr in transceivers) {
      if (tr.sender.track?.kind == kind ||
          tr.receiver.track?.kind == kind) {
        return;
      }
    }
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    _diag('В offer добавлена приёмная видео-m-секция.');
  }

  /// Добавляет ICE-кандидата, а если remote description ещё не установлен —
  /// откладывает его в буфер (иначе кандидат теряется и ICE не стартует).
  Future<void> _addCandidateSafely(RTCIceCandidate candidate) async {
    final pc = _pc;
    if (pc == null) return;
    if (!_remoteDescSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    try {
      await pc.addCandidate(candidate);
    } catch (e) {
      _diag('Не удалось добавить ICE-кандидата: $e');
    }
  }

  /// Применяет кандидатов, накопленных до появления remote description.
  Future<void> _flushPendingCandidates() async {
    if (_pendingCandidates.isEmpty) return;
    final batch = List<RTCIceCandidate>.of(_pendingCandidates);
    _pendingCandidates.clear();
    _diag('Применяю отложенных ICE-кандидатов: ${batch.length}.');
    for (final c in batch) {
      await _addCandidateSafely(c);
    }
  }

  Future<void> _sendAnswer(RTCSessionDescription offer) async {
    final answer = await _pc!.createAnswer(_offerConstraints);
    await _pc!.setLocalDescription(answer);
    _client?.send('answer', sdp: answer.toMap());
    _diag('Answer отправлен.');
    _armConnectWatchdog('после answer');
  }

  Map<String, dynamic> get _offerConstraints => {
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': true,
        },
      };

  Future<void> _handleSignal(Map<String, dynamic> data) async {
    switch (data['type']) {
      case 'reconnected':
        _diag('Сервер сигнализации восстановлен.');
        await _restartCall();
        break;
      case 'joined':
        role = data['role'] as String?;
        _diag('Роль на сервере: $role');
        // Показываем собеседнику состояние наших устройств.
        _sendDeviceState();
        notifyListeners();
        break;
      case 'peer-joined':
        hasPeer = true;
        final joinedName = data['name'] as String?;
        if (joinedName != null && joinedName.isNotEmpty) {
          remoteName = joinedName;
        }
        _diag('Второй участник вошёл в комнату.');
        _sendDeviceState();
        _maybeSendOffer();
        notifyListeners();
        break;
      case 'peers':
        final names = data['names'];
        hasPeer = names is List && names.isNotEmpty;
        if (hasPeer) {
          remoteName = names.first.toString();
          _diag('Участники в комнате: ${names.join(', ')}');
        } else {
          _diag('В комнате пока никого кроме нас.');
        }
        // Если мы offerer и собеседник уже в комнате — начинаем звонок.
        // Список мог прийти раньше, чем поднялось peer-соединение (например,
        // после перезагрузки страницы во время встречи) — справится
        // _maybeSendOffer: он ничего не шлёт, пока соединение не готово.
        _sendDeviceState();
        _maybeSendOffer();
        notifyListeners();
        break;
      case 'screen':
        final active = data['active'] == true;
        final forced = data['forced'] == true;
        if (forced && screenSharing) {
          // Сервер снял нашу трансляцию (перехватили / запретил учитель) —
          // останавливаем её у себя.
          _forceStopScreenShare();
          break;
        }
        peerScreenSharing = active;
        if (active) {
          // Запоминаем id трансляции собеседника: приходящий видеопоток с
          // этим id — его экран, остальные — камера.
          _peerScreenStreamId = data['streamId'] as String?;
          if (_peerScreenStreamId != null) {
            _screenStreamIds.add(_peerScreenStreamId!);
          }
          // Пропорции берём из сигнала ведущего — они всегда согласованы у
          // обоих, в отличие от getSettings() у удалённого трека.
          final aspect = data['aspect'];
          if (aspect is num && aspect.toDouble() > 0) {
            screenAspect = aspect.toDouble();
            _aspectTimer?.cancel();
            _aspectTimer = null;
          }
          // Поток мог прийти раньше сигнала (например, при восстановлении) —
          // тогда он уже лежит в remoteRenderer как «камера»; переносим.
          _rerouteScreenStream();
        } else {
          if (_peerScreenStreamId != null) {
            _screenStreamIds.remove(_peerScreenStreamId!);
          }
          _peerScreenStreamId = null;
          // Собеседник закончил трансляцию — убираем его экран (он лежит в
          // screenRenderer, т.к. мы не транслируем). Свою трансляцию при
          // этом не трогаем.
          if (!screenSharing &&
              screenRenderer?.srcObject == _peerScreenStream) {
            screenRenderer?.srcObject = null;
          }
          _peerScreenStream = null;
        }
        _diag('Трансляция экрана собеседника: '
            '${active ? 'включена' : 'выключена'}'
            '${active && _peerScreenStreamId != null ? ' (поток $_peerScreenStreamId)' : ''}');
        notifyListeners();
        break;
      case 'device':
        remoteMicEnabled = data['mic'] == true;
        remoteCameraEnabled = data['camera'] == true;
        _diag('Устройства собеседника: микрофон '
            '${remoteMicEnabled ? 'вкл' : 'выкл'}, камера '
            '${remoteCameraEnabled ? 'вкл' : 'выкл'}');
        notifyListeners();
        break;
      case 'share-policy':
        final allow = data['allow'] == true;
        studentsCanShare = allow;
        if (!isTeacher) {
          _diag('Учитель ${allow ? 'разрешил' : 'запретил'} ученикам '
              'показывать экран.');
        }
        notifyListeners();
        break;
      case 'share-denied':
        // Учитель запретил показ экрана. Трек, который мы уже успели
        // добавить в peer-соединение до ответа сервера, нужно убрать.
        await _forceStopScreenShare();
        _showNotice(data['allow'] == true
            ? 'Трансляция перехвачена собеседником'
            : 'Учитель запретил показ экрана');
        break;
      case 'renegotiate':
        // Собеседник (answerer) изменил состав своих треков и просит нас
        // (offerer'а) переотправить offer. Так избегаем «glare» — когда оба
        // участника одновременно шлют offer.
        if (role == 'offerer') {
          await _sendOffer();
        }
        break;
      case 'draw':
        _drawEvents.add(data);
        break;
      case 'offer':
        // Встречный offer перебивает наш незавершённый — отвечаем на него.
        _offerInFlight = false;
        hasPeer = true;
        final sdp = data['sdp'] as Map<String, dynamic>?;
        if (sdp == null) return;
        if (_pcReady) {
          await _onOfferReceived(sdp);
        } else {
          _pendingOffer = sdp;
        }
        break;
      case 'answer':
        _offerInFlight = false;
        final sdp = data['sdp'] as Map<String, dynamic>?;
        if (sdp == null) return;
        final answerPc = _pc;
        if (answerPc == null) return;
        // Answer применяем всегда: отбрасывание «по состоянию» на практике
        // оставляет offerer без удалённого описания, ICE не стартует и медиа
        // не течёт до следующей пересылки offer. Ошибку просто логируем —
        // дальше соединение доводит до ума watchdog (_armConnectWatchdog).
        final state = answerPc.signalingState;
        try {
          await answerPc.setRemoteDescription(
            RTCSessionDescription(
              sdp['sdp'],
              sdp['type'] as String? ?? 'answer',
            ),
          );
            _diag('Получен answer (состояние было $state).');
            _remoteDescSet = true;
            await _flushPendingCandidates();
        } catch (e) {
          _diag('Ошибка установки answer ($state): $e');
        }
        break;
      case 'ice':
        final ice = data['ice'] as Map<String, dynamic>?;
        if (ice == null) return;
        final candidate = RTCIceCandidate(
          ice['candidate'],
          ice['sdpMid'] as String?,
          (ice['sdpMLineIndex'] as num?)?.toInt(),
        );
        await _addCandidateSafely(candidate);
        break;
      case 'peer-leave':
        _offerInFlight = false;
        hasPeer = false;
        remoteName = null;
        remoteMicEnabled = true;
        remoteCameraEnabled = true;
        remoteRenderer.srcObject = null;
        // Если мы сами транслируем, в screenRenderer лежит НАША копия экрана —
        // её не трогаем. Иначе это экран ушедшего собеседника — убираем.
        if (!screenSharing) {
          screenRenderer?.srcObject = null;
        }
        peerScreenSharing = false;
        _peerScreenStreamId = null;
        _screenStreamIds.clear();
        _peerScreenStream = null;
        // Сбрасываем кэш треков: когда собеседник вернётся (перезагрузил
        // страницу), его видео придёт заново — без этого новый трек мог бы
        // «заблокироваться» старым id.
        _seenTrackIds.clear();
        _diag('Собеседник покинул комнату: состояние сброшено.');
        notifyListeners();
        break;
    }
  }

  Future<void> _onOfferReceived(Map<String, dynamic> sdp) async {
    final pc = _pc;
    if (pc == null) return;
    final state = pc.signalingState;
    // Гонка: пока мы сами слали offer, пришёл встречный. Старый SDP в
    // состоянии have-local-offer может «разложить» переговоры; игнорируем
    // входящий offer до завершения наших — это решается повторным offer.
    if (state == RTCSignalingState.RTCSignalingStateHaveLocalOffer ||
        state == RTCSignalingState.RTCSignalingStateHaveLocalPrAnswer) {
      _diag('Встречный offer проигнорирован (состояние $state).');
      return;
    }
    // Новый раунд переговоров — сбрасываем кэш треков, чтобы трек, который
    // собеседник переслал заново (например, после перезахвата экрана), не
    // был молча отброшен как «повторный».
    _seenTrackIds.clear();
    final offer = RTCSessionDescription(
      sdp['sdp'],
      sdp['type'] as String? ?? 'offer',
    );
    try {
      await pc.setRemoteDescription(offer);
      _remoteDescSet = true;
      await _flushPendingCandidates();
      await _sendAnswer(offer);
    } catch (e) {
      _diag('Ошибка обработки offer ($state): $e');
    }
  }

  // --- Проброс экрана ---

  /// Может ли этот участник показывать экран (учитель — всегда, ученик —
  /// только пока учитель не запретил).
  bool get canShareScreen => isTeacher || studentsCanShare;

  /// Учитель включает/выключает для учеников возможность показывать экран.
  Future<void> setStudentSharingAllow(bool allow) async {
    if (!isTeacher) return;
    studentsCanShare = allow;
    _diag(allow
        ? 'Ученикам разрешён показ экрана.'
        : 'Показ экрана ученикам запрещён.');
    notifyListeners();
    _client?.send('share-policy', extra: {'allow': allow});
  }

  Future<void> toggleScreenShare() async {
    if (screenSharing) {
      final senders = _pc == null
          ? const <RTCRtpSender?>[]
          : await _pc!.getSenders();
      for (final s in senders) {
        final label = s?.track?.label ?? '';
        if (s?.track?.kind == 'video' && label.contains('screen')) {
          final sender = s;
          if (sender == null) continue;
          await _pc?.removeTrack(sender);
        }
      }
      for (final t in _screenStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      _screenStream = null;
      screenRenderer?.srcObject = null;
      screenSharing = false;
      // Сообщаем собеседнику ДО переговоров: его экран должен пропасть, а
      // наша трансляция определяется сигналом, а не именем трека.
      _client?.send('screen', extra: {'active': false, 'streamId': null});
      _diag('Проброс экрана выключен.');
      notifyListeners();
      await _renegotiate();
      return;
    }

    if (!canShareScreen) {
      _showNotice('Учитель запретил показ экрана');
      return;
    }

    try {
      final display = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
      });
      final videoTrack = display.getVideoTracks().firstOrNull;
      if (videoTrack == null) {
        await display.dispose();
        return;
      }
      _screenStream = display;
      await _pc?.addTrack(videoTrack, display);
      screenSharing = true;
      _watchScreenAspect(videoTrack);
      // Мы ведущий трансляции — чужого экрана не показываем.
      peerScreenSharing = false;
      _peerScreenStreamId = null;
      _peerScreenStream = null;
      // Сначала сигнал о трансляции (собеседник по id потока распознает
      // экран), только потом offer с новым треком. Пропорции передаём, чтобы
      // рисование у обоих было в одном и том же пространстве картинки.
      _client?.send('screen', extra: {
        'active': true,
        'streamId': display.id,
        'aspect': screenAspect,
      });
      // Сразу показываем свою трансляцию (копию экрана) на своей стороне.
      screenRenderer?.srcObject = display;
      _diag('Проброс экрана включён (поток ${display.id}).');
      notifyListeners();
      await _renegotiate();
    } catch (e) {
      errorMessage = 'Не удалось открыть экран: $e';
      _diag('Ошибка проброса экрана: $e');
      notifyListeners();
    }
  }

  Future<void> _renegotiate() async {
    if (!_pcReady) return;
    if (role == 'offerer') {
      // Offerer сам отправляет offer.
      await _sendOffer();
    } else {
      // Ответчик просит offerer'а пересоздать offer (иначе оба будут слать
      // offer одновременно и переговоры развалятся).
      _client?.send('renegotiate');
    }
  }

  // --- Автовосстановление соединения ---

  /// Полностью перезапускает медиа-соединение после обрыва: заново собирает
  /// peer-соединение, возвращает наши треки (микрофон, камера, экран),
  /// при необходимости переподключает сигнальный сервер и заново
  /// «договаривается» о звонке. Захваченные устройства при этом НЕ трогаются —
  /// человеку не нужно заново разрешать доступ к камере и микрофону.
  Future<void> _restartCall() async {
    if (_disposed || _hangupDone || _restartInProgress || !joined) return;
    final wsWasDown = _client?.isConnected != true;
    if (!wsWasDown && !hasPeer) {
      _diag('Собеседника нет в комнате — перезапуск соединения не нужен.');
      return;
    }
    _restartInProgress = true;
    reconnecting = true;
    final hadPeer = hasPeer;
    _diag('Соединение потеряно — восстанавливаю звонок...');

    try {
      // Медиа-уровень: закрываем старое соединение и сбрасываем состояние.
      await _closePeerConnection();
      _offerInFlight = false;
      _pendingOffer = null;
      _seenTrackIds.clear();
      hasPeer = false;
      remoteRenderer.srcObject = null;
      if (!screenSharing) {
        screenRenderer?.srcObject = null;
      }
      // При обрыве сигнального канала сбрасываем и состояние собеседника:
      // сервер заново передаст актуальную трансляцию после переподключения.
      // Если сломался только медиа-канал, экран собеседника по-прежнему с ним,
      // его id пригодится для распознавания — его не трогаем.
      if (wsWasDown) {
        peerScreenSharing = false;
        _peerScreenStreamId = null;
        _screenStreamIds.clear();
      }
      notifyListeners();

      // Сигнальный сервер: если он был оборван — ждём восстановления.
      if (_client != null && wsWasDown) {
        await _ensureSignaling();
      }

      // Заново поднимаем peer-соединение и возвращаем наши треки.
      await _setupPeerConnection();
      if (_disposed) return;

      // Если мы транслируем экран — второй раз пережить разрыв он не может:
      // при закрытии старого peer-соединения Chrome «гасит» трек захвата
      // экрана (своя копия замирает), и слать мёртвый трек бесполезно.
      // Поэтому перезахватываем экран заново.
      if (screenSharing && _screenStream != null) {
        await _reacquireScreenShare();
      }

      // Возвращаем признак собеседника, если сервер не переподключался
      // (при переподключении его вернёт сообщение «peers»).
      if (!wsWasDown && hadPeer) {
        hasPeer = true;
      }

      _maybeSendOffer();
      _diag('Восстановление соединения завершено.');
    } catch (e) {
      _diag('Ошибка восстановления звонка: $e');
    } finally {
      _restartInProgress = false;
      reconnecting = false;
      notifyListeners();
    }
  }

  /// Следит за «здоровьем» медиа-соединения: если состояние ушло в
  /// disconnected/failed и не вернулось за 3 секунды — запускает полный
  /// перезапуск (не чаще раза в 15 секунд, чтобы не устраивать «шторм»).
  void _onPeerHealth(bool healthy) {
    if (healthy) {
      _healthTimer?.cancel();
      _healthTimer = null;
      return;
    }
    if (_disposed || _hangupDone || _restartInProgress) return;
    final now = DateTime.now();
    if (_nextRestartAllowed != null && now.isBefore(_nextRestartAllowed!)) {
      return;
    }
    _healthTimer?.cancel();
    _healthTimer = Timer(const Duration(seconds: 3), () {
      _healthTimer = null;
      if (_disposed || _hangupDone || _restartInProgress || !joined) return;
      _nextRestartAllowed = DateTime.now().add(const Duration(seconds: 15));
      unawaited(_restartCall());
    });
  }

  /// Сколько ждём перехода в connected после отправки offer/answer.
  static const _connectTimeout = Duration(seconds: 6);

  /// Ставит сторожа на «медиа не потекло»: штатный сторож реагирует только на
  /// disconnected/failed, а зависшее в new/connecting соединение он не видит.
  void _armConnectWatchdog(String reason) {
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
    if (_disposed || _hangupDone || !joined || !hasPeer) return;
    _connectWatchdog = Timer(_connectTimeout, () {
      _connectWatchdog = null;
      if (_disposed || _hangupDone || _restartInProgress || !joined) return;
      final ice = _lastIceState;
      final conn = _lastConnState;
      if (ice == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          ice == RTCIceConnectionState.RTCIceConnectionStateCompleted ||
          conn == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        return;
      }
      final now = DateTime.now();
      if (_nextRestartAllowed != null && now.isBefore(_nextRestartAllowed!)) {
        return;
      }
      _diag('Медиа не потекло за ${_connectTimeout.inSeconds} с '
          '($reason, ice=$ice, conn=$conn) — перезапускаю звонок.');
      _nextRestartAllowed = DateTime.now().add(const Duration(seconds: 15));
      unawaited(_restartCall());
    });
  }

  /// Перезахватывает экран для трансляции после восстановления соединения.
  /// Старый трек захвата Chrome гасит при закрытии peer-соединения (своя
  /// копия экрана замирает), поэтому берём свежий захват: браузер один раз
  /// спросит, чем поделиться. Если захват отменён — трансляция гасится
  /// аккуратно, с подсказкой пользователю.
  Future<void> _reacquireScreenShare() async {
    // Убираем из (нового) peer-соединения старый трек экрана, чтобы не
    // осталась мёртвая m-строка в offer.
    if (_screenStream != null) {
      for (final t in _screenStream!.getTracks()) {
        await t.stop();
      }
      _screenStream = null;
    }
    final senders =
        _pc == null ? const <RTCRtpSender?>[] : await _pc!.getSenders();
    for (final s in senders) {
      if (s?.track?.kind == 'video' &&
          (s?.track?.label ?? '').contains('screen')) {
        final sender = s;
        if (sender == null) continue;
        await _pc?.removeTrack(sender);
      }
    }
    screenRenderer?.srcObject = null;
    try {
      final display = await navigator.mediaDevices.getDisplayMedia(
        {'video': true},
      );
      final videoTrack = display.getVideoTracks().firstOrNull;
      if (videoTrack == null) {
        await display.dispose();
        throw Exception('В захвате экрана не оказалось видео');
      }
      _screenStream = display;
      await _pc?.addTrack(videoTrack, display);
      _watchScreenAspect(videoTrack);
      // Сразу показываем свежую копию экрана у себя и говорим собеседнику,
      // что это трансляция с новым id потока.
      screenRenderer?.srcObject = display;
      _client?.send('screen', extra: {
        'active': true,
        'streamId': display.id,
        'aspect': screenAspect,
      });
      _diag('Экран перезахвачен (поток ${display.id}).');
    } catch (e) {
      // Пользователь отменил выбор экрана — завершаем трансляцию.
      _screenStream = null;
      if (screenSharing) {
        screenSharing = false;
        _client?.send('screen', extra: {'active': false, 'streamId': null});
        _showNotice('Соединение восстановлено — включите показ экрана снова');
      }
      _diag('Перезахват экрана не удался: $e');
    }
    await _renegotiate();
  }

  /// Ждёт восстановления сигнального соединения (клиент уже делает повторные
  /// попытки в фоне) либо завершает её с понятной пометкой.
  Future<void> _ensureSignaling() async {
    final client = _client;
    if (client == null || client.isConnected) return;
    _diag('Переподключаюсь к серверу сигнализации...');
    final ok = await client.reconnect();
    if (ok) {
      _diag('Сервер сигнализации снова на связи.');
    } else {
      _diag('Сервер сигнализации пока недоступен — повторю позднее.');
    }
  }

  /// Закрывает текущее peer-соединение и его сторож.
  Future<void> _closePeerConnection() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
    _lastIceState = null;
    _lastConnState = null;
    _remoteDescSet = false;
    _pendingCandidates.clear();
    final pc = _pc;
    _pc = null;
    _pcReady = false;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
    }
  }

  /// Если экран собеседника уже пришёл (лежит в remoteRenderer как «камера»),
  /// а сигнал «screen» пришёл позже — переносим поток в экранный рендерер.
  void _rerouteScreenStream() {
    if (screenSharing) return; // транслируем сами, чужих экранов не показываем
    final cur = remoteRenderer.srcObject;
    if (cur == null || !_screenStreamIds.contains(cur.id)) return;
    _peerScreenStream = cur;
    screenRenderer?.srcObject = cur;
    remoteRenderer.srcObject = null;
    _watchScreenAspect(cur.getVideoTracks().firstOrNull);
    _diag('Трансляция переведена из камеры на экран: ${cur.id}');
    notifyListeners();
  }

  // --- Состояние устройств и уведомления ---

  /// Пропорции (w/h) видеотрека из его настроек; null, если не узнать.
  double? _videoAspect(MediaStreamTrack? track) {
    if (track == null) return null;
    try {
      final s = track.getSettings();
      final w = s['width'];
      final h = s['height'];
      if (w is num && h is num && h.toDouble() > 0) {
        return w.toDouble() / h.toDouble();
      }
    } catch (_) {
      // настройки могут быть недоступны до фактического старта видеопотока
    }
    return null;
  }

  Timer? _aspectTimer;

  /// Запоминает пропорции экрана. У удалённого трека они нередко становятся
  /// доступны только после прихода первых кадров, поэтому при пустом значении
  /// перечитываем каждые 250 мс (до ~5 с), а после — перерисовываем канвас.
  void _watchScreenAspect(MediaStreamTrack? track) {
    _aspectTimer?.cancel();
    _aspectTimer = null;
    if (track == null || _disposed) return;
    final now = _videoAspect(track);
    if (now != null) {
      screenAspect = now;
      return;
    }
    var tries = 0;
    _aspectTimer = Timer.periodic(const Duration(milliseconds: 250), (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      tries++;
      final a = _videoAspect(track);
      if (a != null) {
        screenAspect = a;
        _diag('Пропорции экрана: $a');
        notifyListeners();
        t.cancel();
      } else if (tries >= 20) {
        t.cancel();
      }
    });
  }

  /// Отправляет собеседнику состояние наших микрофона/камеры (для индикации
  /// выключенных устройств на его экране).
  void _sendDeviceState() {
    if (!joined) return;
    _client?.send('device', extra: {
      'mic': micEnabled,
      'camera': cameraEnabled,
    });
  }

  Timer? _noticeTimer;

  /// Показывает временное уведомление (например, про запрет показа экрана).
  void _showNotice(String message) {
    notice = message;
    _diag('Уведомление: $message');
    notifyListeners();
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (notice == message && !_disposed) {
        notice = null;
        notifyListeners();
      }
    });
  }

  /// Останавливает СВОЮ трансляцию по принудительному сигналу сервера
  /// (трансляцию перехватил другой участник или её запретил учитель).
  Future<void> _forceStopScreenShare() async {
    if (!screenSharing) return;
    final senders =
        _pc == null ? const <RTCRtpSender?>[] : await _pc!.getSenders();
    for (final s in senders) {
      final label = s?.track?.label ?? '';
      if (s?.track?.kind == 'video' && label.contains('screen')) {
        final sender = s;
        if (sender == null) continue;
        await _pc?.removeTrack(sender);
      }
    }
    for (final t in _screenStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    _screenStream = null;
    screenRenderer?.srcObject = null;
    screenSharing = false;
    _diag('Трансляция остановлена сервером.');
    notifyListeners();
    await _renegotiate();
  }

  void _stopNoticeTimer() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
  }

  // --- Рисование на трансляции ---

  /// Отправляет собеседнику один законченный штрих. Координаты уже
  /// нормализованы (0..1) по размеру области рисования каждого устройства.
  void sendStroke({
    required List<double> points,
    required String color,
    required double width,
  }) {
    _client?.send('draw', extra: {
      'points': points,
      'color': color,
      'width': width,
    });
  }

  /// Стирает все пометки рисунка у всех участников.
  void sendWhiteboardClear() {
    _client?.send('draw', extra: {'clear': true});
  }

  // --- Диагностика устройств (диалог «Проверить оборудование») ---
  Future<List<String>> deviceReport() async {
    final lines = <String>[];
    if (hasMicTrack) {
      lines.add('Микрофон: включён.');
    } else {
      lines.add('Микрофон: НЕ запущен.');
      if (micIssue != null) lines.add('Причина: $micIssue');
    }
    if (hasCameraTrack) {
      lines.add('Камера: включена.');
    } else {
      lines.add('Камера: НЕ запущена.');
      if (cameraIssue != null) lines.add('Причина: $cameraIssue');
    }
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      for (final d in devices) {
        final label = d.label.isNotEmpty ? d.label : '(без названия)';
        lines.add('  ${d.kind}: $label');
      }
    } catch (e) {
      lines.add('Не удалось перечислить устройства: $e');
    }
    return lines;
  }

  /// Завершает звонок, освобождает камеру и соединение.
  Future<void> hangup() async {
    if (_hangupDone) return;
    _hangupDone = true;
    _disposed = true;
    _stopVoiceMonitor();
    _stopNoticeTimer();
    _aspectTimer?.cancel();
    _aspectTimer = null;

    try {
      _client?.send('leave');
    } catch (_) {}
    await _closePeerConnection();
    reconnecting = false;
    _restartInProgress = false;

    for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    _micStream = null;
    _camStream = null;

    for (final t in _screenStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    _screenStream = null;

    await _signalSub?.cancel();
    await _connSub?.cancel();
    await _drawEvents.close();
    await _client?.dispose();
    _client = null;

    remoteRenderer.srcObject = null;
    screenRenderer?.srcObject = null;
    await remoteRenderer.dispose();
    await screenRenderer?.dispose();
    await localRenderer.dispose();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}