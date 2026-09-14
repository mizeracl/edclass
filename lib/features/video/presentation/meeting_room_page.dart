import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../data/call_controller.dart';
import 'platform/platform.dart';

/// Экран видеовстречи: окно подготовки (микрофон/камера), видео
/// собеседника, своё превью, проброс экрана, индикатор «говорит».
class MeetingRoomPage extends StatefulWidget {
  const MeetingRoomPage({
    super.key,
    required this.meetingId,
    required this.uid,
    this.name,
    this.isTeacher = false,
    this.onHangup,
  });

  final String meetingId;
  final String uid;
  final String? name;
  final bool isTeacher;
  final VoidCallback? onHangup;

  @override
  State<MeetingRoomPage> createState() => _MeetingRoomPageState();
}

class _MeetingRoomPageState extends State<MeetingRoomPage> {
  late final CallController _controller = CallController(
    meetingId: widget.meetingId,
    uid: widget.uid,
    isTeacher: widget.isTeacher,
  );

  bool _joining = false;
  // Показывать ли камеры в колонке справа во время трансляции экрана.
  bool _camerasVisible = true;
  // Показывать трансляцию экрана во весь экран (с обрезкой краёв) или
  // по ширине (обычный режим с полосами сверху/снизу) на телефоне.
  bool _screenFullView = false;

  // --- Рисование на трансляции ---
  // Включён ли режим рисования, все штрихи (свои и собеседника) и текущий.
  bool _drawingEnabled = false;
  final List<_Stroke> _strokes = <_Stroke>[];
  _Stroke? _activeStroke;
  Color _brushColor = const Color(0xFFFFEE00);
  StreamSubscription<Map<String, dynamic>>? _drawSub;
  // Опрос пропорций реального <video>-элемента страницы: это то, что браузер
  // фактически показывает, поэтому штрихи каждой из сторон не разъезжаются.
  Timer? _aspectPollTimer;
  double? _lastShownAspect;

  // Журнал диагностики рисования — показывается в диалоге «Диагностика».
  final List<String> _drawDebug = <String>[];

  void _dlog(String message) {
    debugPrint('[draw] $message');
    _drawDebug.add(message);
    if (_drawDebug.length > 40) _drawDebug.removeAt(0);
  }

  void _startAspectPoll() {
    _aspectPollTimer?.cancel();
    _aspectPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final a = probeVideoElementAspect();
      if (a != _lastShownAspect) {
        _lastShownAspect = a;
        _dlog(
            'видео-аспект: ${a != null ? a.toStringAsFixed(4) : 'null'}, контроллер: ${_controller.screenAspect?.toStringAsFixed(4) ?? 'null'}');
        setState(() {});
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // Сразу захватываем микрофон и камеру: на экране подготовки появится
    // живое превью и заработает тест микрофона.
    unawaited(_controller.visitPreview(mic: true, camera: true).onError(
          (Object e, StackTrace st) => debugPrint('[call] Ошибка превью: $e'),
        ));
    _drawSub = _controller.drawEvents.listen(_onDrawEvent);
    _startAspectPoll();
  }

  @override
  void dispose() {
    _aspectPollTimer?.cancel();
    _drawSub?.cancel();
    _controller.hangup();
    super.dispose();
  }

  /// Принимает штрихи и команду «стереть всё» от собеседника. Если собеседник
  /// начал рисовать, а у нас доска выключена — включаем её автоматически.
  void _onDrawEvent(Map<String, dynamic> data) {
    if (!mounted) return;
    if (data['clear'] == true) {
      setState(() => _strokes.clear());
      return;
    }
    final points = data['points'];
    if (points is! List) return;
    if (points.length < 4 || points.length.isOdd) return;
    final colorHex = data['color'] as String?;
    final color = colorHex != null
        ? _colorFromHex(colorHex)
        : const Color(0xFFFFEE00);
    final width = (data['width'] as num?)?.toDouble() ?? 0.006;
    final stroke = _Stroke(
      color: color,
      width: width,
      points: <Offset>[
        for (var i = 0; i + 1 < points.length; i += 2)
          Offset(
            (points[i] as num).toDouble(),
            (points[i + 1] as num).toDouble(),
          ),
      ],
    );
    if (stroke.points.length < 2) return;
    _dlog(
        'получен: ${stroke.points.length} тчк, первый ${stroke.points.first}, аспект экрана=${probeVideoElementAspect()?.toStringAsFixed(4) ?? 'null'}');
    setState(() => _strokes.add(stroke));
  }

  static Color _colorFromHex(String hex) {
    var value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0;
    if (value > 0xFFFFFF) value &= 0xFFFFFF;
    return Color(0xFF000000 | value);
  }

  /// Завершённый штрих отправляем собеседнику в нормализованных координатах.
  void _commitStroke() {
    final stroke = _activeStroke;
    if (stroke == null || stroke.points.length < 2) {
      _activeStroke = null;
      return;
    }
    setState(() => _strokes.add(stroke));
    _dlog(
        'отправка: ${stroke.points.length} тчк, первый ${stroke.points.first}, последний ${stroke.points.last}');
    _controller.sendStroke(
      points: [
        for (final p in stroke.points) ...[p.dx, p.dy],
      ],
      color:
          '#${stroke.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      width: stroke.width,
    );
    _activeStroke = null;
  }

  /// Начали новый штрих (нормализованные координаты 0..1). Запоминаем
  /// пропорции картинки, в которых идёт рисование.
  void _onStrokeDown(Offset normalized, double? aspect, Rect rect, Size box) {
    _dlog(
        'старт: norm=$normalized аспект=${aspect?.toStringAsFixed(4) ?? 'null'} область=${box.width.toStringAsFixed(0)}x${box.height.toStringAsFixed(0)} картинка=[${rect.left.toStringAsFixed(0)},${rect.top.toStringAsFixed(0)},${rect.width.toStringAsFixed(0)},${rect.height.toStringAsFixed(0)}]');
    setState(() {
      _activeStroke = _Stroke(
        color: _brushColor,
        width: 0.006,
        aspect: aspect,
        points: <Offset>[normalized],
      );
    });
  }

  /// Продолжаем штрих, не создавая слишком много лишних точек.
  void _onStrokeMove(Offset normalized) {
    final stroke = _activeStroke;
    if (stroke == null) return;
    final last = stroke.points.last;
    if ((normalized - last).distance < 0.003) return;
    setState(() => stroke.points.add(normalized));
  }

  /// Отпустили указатель — штрих готов, отправляем собеседнику.
  void _onStrokeUp() => _commitStroke();

  Future<void> _join() async {
    setState(() => _joining = true);
    await _controller.start(name: widget.name);
    if (mounted) setState(() => _joining = false);
  }

  Future<void> _showDiagnostics(BuildContext context) async {
    final lines = await _controller.deviceReport();
    final diagLines = _controller.diagnostics;
    if (!context.mounted) return;
    final copyText = StringBuffer()
      ..writeln('--- Устройства ---')
      ..writeAll(lines, '\n')
      ..writeln()
      ..writeln('--- Звонок ---')
      ..writeAll(diagLines, '\n');
    if (_drawDebug.isNotEmpty) {
      copyText
        ..writeln()
        ..writeln('--- Рисование (последние) ---')
        ..writeAll(_drawDebug.reversed, '\n');
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Диагностика звонка'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines)
                Text(line, style: const TextStyle(fontSize: 13)),
              const Divider(height: 20),
              for (final line in diagLines)
                Text(line, style: const TextStyle(fontSize: 12)),
              if (_drawDebug.isNotEmpty) ...[
                const Divider(height: 20),
                const Text('Рисование (последние события):',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                for (final line in _drawDebug.reversed)
                  Text(line, style: const TextStyle(fontSize: 11)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: copyText.toString()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Скопировано'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Text('Копировать'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final joined = _controller.joined;
            final hasRemote =
                _controller.remoteRenderer.srcObject != null;
            final hasScreen =
                _controller.screenRenderer?.srcObject != null;
            final waking = _controller.role == null;
            final screenSharing = _controller.screenSharing;
            // Когда трансляции экрана нет — галерея участников (окна всех,
            // кто в звонке). При трансляции — экран на весь экран у обоих,
            // а камеры — отдельной колонкой сбоку (их можно скрыть).
            final galleryMode = joined && !hasScreen;
            final hasRemoteCam = hasRemote;
            final canShowCameras =
                _controller.hasCameraTrack || hasRemoteCam;

            return Stack(
              fit: StackFit.expand,
              children: [
                if (galleryMode)
                  Padding(
                    padding: const EdgeInsets.only(top: 56),
                    child: _GalleryView(
                      controller: _controller,
                      selfName: widget.name,
                      hasPeer: _controller.hasPeer,
                    ),
                  )
                else ...[
                  // Трансляция экрана — на весь экран. Сервер гарантирует
                  // одну трансляцию на комнату: или наша (копия экрана), или
                  // экран собеседника.
                  if (hasScreen)
                    // Панорамирование трансляции: в режиме «весь экран» когда
                    // картинка шире/выше экрана и кроится по центру, можно
                    // двигать её, чтобы увидеть обрезанные края. Видео и доска
                    // рисования движутся вместе, поэтому штрихи не разъезжаются.
                    _PanScreen(
                      cover: _screenFullView,
                      aspect: probeVideoElementAspect() ??
                          _controller.screenAspect,
                      enabled: !_drawingEnabled,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          RTCVideoView(
                            _controller.screenRenderer!,
                            // Ключ зависит от режима: на Android смена
                            // objectFit на лету замораживает картинку
                            // (стоп-кадр старого масштаба), поэтому при
                            // переключении пересоздаём вью с чистой текстурой.
                            key: ValueKey(
                                'screen-view-${_screenFullView ? 'cover' : 'contain'}'),
                            objectFit: _screenFullView
                                ? RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitCover
                                : RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitContain,
                          ),
                          // Доска для рисования поверх трансляции. Штрихи
                          // собеседника видно всегда; свой режим рисования
                          // включается кнопкой «Рисовать».
                          _WhiteboardCanvas(
                            enabled: _drawingEnabled,
                            strokes: _strokes,
                            activeStroke: _activeStroke,
                            cover: _screenFullView,
                            screenAspect: probeVideoElementAspect() ??
                                _controller.screenAspect,
                            onStrokeDown: _onStrokeDown,
                            onStrokeMove: _onStrokeMove,
                            onStrokeUp: _onStrokeUp,
                          ),
                        ],
                      ),
                    )
                  else
                    _WaitingPlaceholder(
                      error: _controller.errorMessage,
                      waking: waking,
                      hasPeer: _controller.hasPeer,
                      capturingMedia: _controller.capturingMedia,
                    ),

                  // Камеры участников — справа, пока не скрыты кнопкой «Камеры»
                  if (hasScreen && _camerasVisible && canShowCameras)
                    Positioned(
                      right: 12,
                      top: 80,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (_controller.hasCameraTrack)
                            _CamTile(
                              label: (widget.name?.isNotEmpty ?? false)
                                  ? widget.name!
                                  : 'Вы',
                              renderer: _controller.localRenderer,
                              isSelf: true,
                              micEnabled: _controller.micEnabled,
                            ),
                          if (hasRemoteCam)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _CamTile(
                                label:
                                    (_controller.remoteName?.isNotEmpty ??
                                            false)
                                        ? _controller.remoteName!
                                        : 'Участник',
                                renderer: _controller.remoteRenderer,
                                isSelf: false,
                                micEnabled: _controller.remoteMicEnabled,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],

                // Своё видео (превью) больше не нужно: при трансляции камера
                // показывается в колонке справа, в галерее — крупным окном.
                if (joined) ...[
                  // Верхний статус встречи + имя ведущего трансляцию
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _controller.hasPeer
                                      ? Colors.greenAccent
                                      : Colors.amber,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _controller.hasPeer
                                    ? 'В эфире'
                                    : 'Ожидание...',
                                style:
                                    const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        // Имена — в основной части экрана, наверху, чтобы их
                        // не перекрывала панель с кнопками внизу.
                        SizedBox(width: 8),
                        if (hasScreen)
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    screenSharing
                                        ? Icons.screen_share
                                        : Icons.airplay,
                                    color: Colors.white70,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      screenSharing
                                          ? 'Вы показываете экран'
                                          : (_controller.remoteName
                                                      ?.isNotEmpty ??
                                                  false)
                                              ? '${_controller.remoteName} '
                                                  'показывает экран'
                                              : 'Трансляция экрана',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Подсказка про камеру, если она не запустилась
                  if (_controller.cameraIssue != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 96,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_controller.cameraIssue}\n\nЧтобы включить камеру '
                          'сейчас — нажмите «Камера» на панели ниже.',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13),
                        ),
                      ),
                    ),

                  // Временное уведомление (запрет показа экрана и т.п.)
                  if (_controller.notice != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 124,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3A2B00),
                            border: Border.all(color: Colors.amber),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.info_outline,
                                  color: Colors.amber, size: 18),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _controller.notice!,
                                  style: const TextStyle(
                                      color: Colors.amber, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Соединение обрывалось и восстанавливается.
                  if (_controller.reconnecting)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 96,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E3A5F),
                            border: Border.all(color: Colors.lightBlueAccent),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.lightBlueAccent,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Flexible(
                                child: Text(
                                  'Соединение оборвалось, восстанавливаем…',
                                  style: TextStyle(
                                      color: Colors.lightBlueAccent,
                                      fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Палитра рисования (поверх трансляции, сверху по центру)
                  if (hasScreen && _drawingEnabled)
                    Positioned(
                      top: 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: _DrawingPalette(
                          selected: _brushColor,
                          onColorSelected: (c) =>
                              setState(() => _brushColor = c),
                          onClear: () {
                            setState(() => _strokes.clear());
                            _controller.sendWhiteboardClear();
                          },
                        ),
                      ),
                    ),

                  // Меню диагностики в углу (рядом с именем, не мешает)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert,
                          color: Colors.white70, size: 20),
                      color: const Color(0xFF1E1E1E),
                      tooltip: 'Настройки звонка',
                      onSelected: (value) {
                        if (value == 'diag') {
                          _showDiagnostics(context);
                        } else if (value == 'retry') {
                          _controller.retry();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'diag',
                          child: Text('Проверить оборудование'),
                        ),
                        PopupMenuItem(
                          value: 'retry',
                          child: Text('Повторить запуск'),
                        ),
                      ],
                    ),
                  ),

                  // Панель управления
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 20, horizontal: 8),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      // Кнопки вписываются в ширину экрана: на узких экранах
                      // (телефон в портрете) панель пропорционально
                      // уменьшается, а не уезжает в горизонтальный скролл.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                          _MicButton(
                            icon: _controller.micEnabled
                                ? Icons.mic
                                : Icons.mic_off,
                            label: 'Микрофон',
                            active: _controller.micEnabled,
                            speaking: _controller.remoteSpeaking,
                            onTap: _controller.toggleMic,
                          ),
                          _ControlButton(
                            icon: _controller.cameraEnabled
                                ? Icons.videocam
                                : Icons.videocam_off,
                            label: 'Камера',
                            active: _controller.cameraEnabled,
                            onTap: _controller.toggleCamera,
                          ),
                          if (_controller.screenRenderer != null)
                            _ControlButton(
                              icon: _controller.screenSharing
                                  ? Icons.stop_screen_share
                                  : (_controller.canShareScreen
                                      ? Icons.screen_share
                                      : Icons.block),
                              label: 'Экран',
                              active: _controller.screenSharing,
                              enabled: _controller.canShareScreen,
                              onTap: _controller.toggleScreenShare,
                            ),
                          if (hasScreen)
                            _ControlButton(
                              icon: _camerasVisible
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              label: 'Камеры',
                              active: _camerasVisible,
                              onTap: () => setState(
                                  () => _camerasVisible = !_camerasVisible),
                            ),
                          if (hasScreen)
                            _ControlButton(
                              icon: _screenFullView
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                              label: _screenFullView ? 'По ширине' : 'Весь экран',
                              active: _screenFullView,
                              onTap: () => setState(
                                  () => _screenFullView = !_screenFullView),
                            ),
                          if (hasScreen)
                            _ControlButton(
                              icon: _drawingEnabled
                                  ? Icons.close
                                  : Icons.brush,
                              label: 'Рисовать',
                              active: _drawingEnabled,
                              onTap: () => setState(() {
                                _drawingEnabled = !_drawingEnabled;
                                // Рисование ложится на видео только в
                                // режиме «весь экран» — включаем его
                                // автоматически вместе с рисованием.
                                if (_drawingEnabled) _screenFullView = true;
                              }),
                            ),
                          if (widget.isTeacher)
                            _ControlButton(
                              icon: _controller.studentsCanShare
                                  ? Icons.present_to_all
                                  : Icons.block,
                              label: _controller.studentsCanShare
                                  ? 'Показ ученикам'
                                  : 'Показ: запрещён',
                              active: _controller.studentsCanShare,
                              onTap: () => _controller
                                  .setStudentSharingAllow(
                                      !_controller.studentsCanShare),
                            ),
                          _EndCallButton(
                            onTap: () async {
                              await _controller.hangup();
                              widget.onHangup?.call();
                              if (context.mounted) {
                                Navigator.of(context).maybePop();
                              }
                            },
                          ),
                        ],
                        ),
                      ),
                    ),
                  ),
                ],

                // Окно подготовки к звонку: превью камеры + тест микрофона
                if (!joined)
                  _JoinSettings(
                    controller: _controller,
                    busy: _joining,
                    onJoin: _join,
                    onCancel: () {
                      Navigator.of(context).maybePop();
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Галерея участников: когда трансляции экрана нет, каждому, кто в звонке,
/// показывается своё окно с видео и именем. До прихода второго участника —
/// второе окно с надписью «Ожидание».
class _GalleryView extends StatelessWidget {
  const _GalleryView({
    required this.controller,
    required this.selfName,
    required this.hasPeer,
  });

  final CallController controller;
  final String? selfName;
  final bool hasPeer;

  @override
  Widget build(BuildContext context) {
    final remoteName =
        (controller.remoteName?.isNotEmpty ?? false) && controller.remoteName != null
            ? controller.remoteName!
            : 'Участник';
    return LayoutBuilder(
      builder: (context, constraints) {
        final tiles = <Widget>[
          Expanded(
            child: _ParticipantTile(
              label: (selfName?.isNotEmpty ?? false)
                  ? selfName!
                  : 'Вы',
              renderer: controller.localRenderer,
              hasVideo: controller.localRenderer.srcObject != null,
              isSelf: true,
              micEnabled: controller.micEnabled,
              cameraEnabled: controller.cameraEnabled,
            ),
          ),
          Expanded(
            child: _ParticipantTile(
              label: hasPeer ? remoteName : 'Ожидание...',
              renderer: controller.remoteRenderer,
              hasVideo: controller.remoteRenderer.srcObject != null,
              isSelf: false,
              speaking: controller.remoteSpeaking,
              waiting: !hasPeer,
              micEnabled: controller.remoteMicEnabled,
              cameraEnabled: controller.remoteCameraEnabled,
            ),
          ),
        ];
        if (constraints.maxWidth >= 640) {
          // Широкий экран — участники рядом друг с другом.
          return Row(children: tiles);
        }
        // Узкий экран — друг под другом.
        final vertical = <Widget>[];
        for (final t in tiles) {
          vertical.add(Expanded(child: t));
        }
        return Column(children: vertical);
      },
    );
  }
}

/// Окно одного участника в галерее: видео, имя, индикатор «говорит».
/// Если видео нет — заглушка с понятным статусом.
class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.label,
    required this.renderer,
    required this.hasVideo,
    required this.isSelf,
    this.speaking = false,
    this.waiting = false,
    this.micEnabled,
    this.cameraEnabled,
  });

  final String label;
  final RTCVideoRenderer renderer;
  final bool hasVideo;
  final bool isSelf;
  final bool speaking;
  final bool waiting;
  final bool? micEnabled;
  final bool? cameraEnabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: const Color(0xFF161616),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasVideo)
                RTCVideoView(
                  renderer,
                  mirror: isSelf,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              else
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        waiting
                            ? Icons.hourglass_top
                            : Icons.videocam_off,
                        color: Colors.white24,
                        size: 44,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        waiting
                            ? 'Ждём второго участника'
                            : 'Камера выключена',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.75),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSelf ? Icons.person : Icons.person_outline,
                        color: Colors.white70,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (micEnabled == false) ...[
                        const SizedBox(width: 6),
                        const Tooltip(
                          message: 'Микрофон выключен',
                          child: Icon(Icons.mic_off,
                              color: Colors.redAccent, size: 16),
                        ),
                      ],
                      if (cameraEnabled == false) ...[
                        const SizedBox(width: 6),
                        const Tooltip(
                          message: 'Камера выключена',
                          child: Icon(Icons.videocam_off,
                              color: Colors.redAccent, size: 16),
                        ),
                      ],
                      if (speaking)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.greenAccent,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'говорит',
                              style: TextStyle(
                                  color: Colors.greenAccent, fontSize: 12),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Окно камеры участника в колонке справа во время трансляции экрана:
/// видео + имя, маленький размер.
class _CamTile extends StatelessWidget {
  const _CamTile({
    required this.label,
    required this.renderer,
    required this.isSelf,
    this.micEnabled,
  });

  final String label;
  final RTCVideoRenderer renderer;
  final bool isSelf;
  final bool? micEnabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 90,
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RTCVideoView(
            renderer,
            mirror: isSelf,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
          if (micEnabled == false)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.mic_off,
                    color: Colors.white, size: 12),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.7),
                  ],
                ),
              ),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Окно подготовки: живое превью камеры, тест микрофона и переключатели.
/// Переключатели сразу захватывают/останавливают устройства, поэтому вход в
/// звонок возможен даже если камера не ответила (звонок пойдёт без видео).
class _JoinSettings extends StatelessWidget {
  const _JoinSettings({
    required this.controller,
    required this.busy,
    required this.onJoin,
    required this.onCancel,
  });

  final CallController controller;
  final bool busy;
  final VoidCallback onJoin;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: const Color(0xE6111111),
      alignment: Alignment.bottomCenter,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            color: const Color(0xFF1E1E1E),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.videocam, color: Colors.white),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Подготовка к звонку',
                            style: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Проверьте себя перед подключением: картинка с камеры '
                      'и уровень микрофона. Если камера не запустится — '
                      'звонок всё равно начнётся, только без видео.',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    _PreviewBox(
                      renderer: controller.localRenderer,
                      hasVideo: controller.hasCameraTrack,
                      busy: controller.cameraBusy,
                      issue: controller.cameraIssue,
                    ),
                    const SizedBox(height: 12),
                    _MicLevelMeter(
                      stream: controller.micStream,
                      issue: controller.micIssue,
                      busy: controller.micBusy,
                    ),
                    const SizedBox(height: 4),
                    _DeviceSwitch(
                      icon: Icons.mic,
                      title: 'Микрофон',
                      enabled: controller.micEnabled,
                      busy: controller.micBusy,
                      onChanged: (v) =>
                          unawaited(controller.setMicEnabled(v)),
                    ),
                    const SizedBox(height: 8),
                    _DeviceSwitch(
                      icon: Icons.videocam,
                      title: 'Камера',
                      enabled: controller.cameraEnabled,
                      busy: controller.cameraBusy,
                      onChanged: (v) =>
                          unawaited(controller.setCameraEnabled(v)),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: busy ? null : onJoin,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.login),
                      label: Text(busy ? 'Подключаемся...' : 'Подключиться'),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: busy ? null : onCancel,
                      child: const Text('Выйти без звонка',
                          style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Переключатель устройства с понятной раскраской: зелёный фон/иконка —
/// включено, красный — выключено. Рядом статус «Включен»/«Выключен».
/// Тумблер работает даже пока идёт захват — можно отменить зависший запрос.
class _DeviceSwitch extends StatelessWidget {
  const _DeviceSwitch({
    required this.icon,
    required this.title,
    required this.enabled,
    required this.busy,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final bool enabled;
  final bool busy;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = enabled ? Colors.greenAccent : Colors.redAccent;
    return Container(
      decoration: BoxDecoration(
        color: enabled
            ? Colors.green.withValues(alpha: 0.12)
            : Colors.red.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: enabled
              ? Colors.green.withValues(alpha: 0.6)
              : Colors.red.withValues(alpha: 0.35),
        ),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        secondary: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: accent),
              )
            : Icon(icon, color: accent, size: 26),
        title: Text(
          title,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          busy
              ? (enabled ? 'Включаем...' : 'Выключаем...')
              : (enabled ? 'Включен' : 'Выключен'),
          style: TextStyle(
            color: busy ? Colors.white54 : accent,
            fontSize: 12,
          ),
        ),
        value: enabled,
        dense: true,
        activeThumbColor: Colors.white,
        activeTrackColor: Colors.green.shade600,
        inactiveThumbColor: Colors.grey.shade500,
        inactiveTrackColor: Colors.white12,
        onChanged: onChanged,
      ),
    );
  }
}

/// Превью своей камеры на экране подготовки: видео с камеры, или заглушка
/// с понятным статусом (камера выключена / камера не ответила).
class _PreviewBox extends StatelessWidget {
  const _PreviewBox({
    required this.renderer,
    required this.hasVideo,
    required this.busy,
    this.issue,
  });

  final RTCVideoRenderer renderer;
  final bool hasVideo;
  final bool busy;
  final String? issue;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: const Color(0xFF101010),
          child: hasVideo
              ? RTCVideoView(
                  renderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy) ...[
                        const CircularProgressIndicator(
                            color: Colors.white38, strokeWidth: 2),
                        const SizedBox(height: 10),
                        const Text('Подключаем камеру...',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 13)),
                      ] else ...[
                        const Icon(Icons.videocam_off,
                            color: Colors.white24, size: 44),
                        const SizedBox(height: 8),
                        Text(
                          issue ?? 'Камера выключена',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Тест микрофона: рисует живые столбики уровня звука. На web анализатор —
/// Web Audio API, на нативных платформах — упрощённый индикатор работы
/// трека (реального анализа звука там нет).
class _MicLevelMeter extends StatefulWidget {
  const _MicLevelMeter({this.stream, this.issue, this.busy = false});

  final MediaStream? stream;
  final String? issue;
  final bool busy;

  @override
  State<_MicLevelMeter> createState() => _MicLevelMeterState();
}

class _MicLevelMeterState extends State<_MicLevelMeter> {
  static const int _bars = 26;

  MicLevelController? _controller;
  Timer? _timer;
  double _level = 0;
  bool _flowing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant _MicLevelMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream != widget.stream) {
      _teardown();
      _bind();
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _teardown() {
    _timer?.cancel();
    _timer = null;
    _controller?.dispose();
    _controller = null;
    _level = 0;
    _flowing = false;
    _error = null;
  }

  void _bind() {
    final c = createMicLevelController(stream: widget.stream);
    _controller = c;
    _flowing = c.flowing;
    _error = c.error ?? widget.issue;
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _tick());
  }

  void _tick() {
    final c = _controller;
    if (!mounted || c == null) return;
    _flowing = c.flowing;
    _error = c.error ?? widget.issue;
    final level = c.level;
    _level = math.max(level, _level * 0.85);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null || widget.busy) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF151515),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (widget.busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white38),
              )
            else
              const Icon(Icons.mic_off, color: Colors.white38, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.busy ? 'Подключаем микрофон...' : (_error ?? ''),
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    final talking = _level > 0.02;
    return GestureDetector(
      onTap: () {
        _controller?.resume();
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF151515),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(talking ? Icons.mic : Icons.mic_none,
                color: talking ? Colors.greenAccent : Colors.white70,
                size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < _bars; i++) ...[
                        Container(
                          width: 5,
                          height: 6 + (i / _bars) * 18,
                          margin: const EdgeInsets.only(right: 3),
                          decoration: BoxDecoration(
                            color: _level * _bars > i
                                ? Colors.greenAccent
                                : Colors.white12,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _flowing
                        ? (talking
                            ? 'Микрофон работает — говорите!'
                            : 'Микрофон готов — говорите для проверки')
                        : 'Нажмите здесь, чтобы включить тест микрофона',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaitingPlaceholder extends StatelessWidget {
  const _WaitingPlaceholder({
    required this.waking,
    required this.hasPeer,
    this.error,
    this.capturingMedia = false,
  });

  final bool waking;
  final bool hasPeer;
  final String? error;
  final bool capturingMedia;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error != null) ...[
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ] else ...[
            if (capturingMedia || waking || !hasPeer)
              const CircularProgressIndicator(color: Colors.white54)
            else
              const Icon(Icons.videocam_off,
                  color: Colors.white38, size: 44),
            const SizedBox(height: 16),
            Text(
              capturingMedia
                  ? 'Запрашиваем доступ к микрофону/камере.\n'
                      'Разрешите доступ во всплывающем окне браузера.'
                  : waking
                      ? 'Подключаемся к комнате...'
                      : hasPeer
                          ? 'Собеседник в звонке.\n'
                              'Видео не поступает — возможно, у него '
                              'выключена камера.'
                          : 'Встреча начата\nОжидаем второго участника',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = active ? Colors.white : Colors.redAccent;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: active ? Colors.white24 : Colors.white12,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Кнопка микрофона с анимацией «говорит»: когда собеседник говорит,
/// вокруг кнопки пульсирует зелёное кольцо.
class _MicButton extends StatefulWidget {
  const _MicButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.speaking,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool speaking;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void didUpdateWidget(covariant _MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.speaking && !oldWidget.speaking) {
      _pulse.repeat(reverse: true);
    } else if (!widget.speaking && oldWidget.speaking) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? Colors.white : Colors.redAccent;
    final hasPulse = widget.active && widget.speaking;

    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final t = hasPulse ? _pulse.value : 0.0;
                return Transform.scale(
                  scale: 1 + 0.08 * t,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.greenAccent
                            .withValues(alpha: hasPulse ? 0.4 + 0.6 * t : 0),
                        width: 3,
                      ),
                    ),
                    child: child,
                  ),
                );
              },
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: hasPulse ? Colors.green.withValues(alpha: 0.8) : Colors.white24,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(widget.icon, color: hasPulse ? Colors.black : color),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.speaking ? '${widget.label} ⋅ говорит' : widget.label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EndCallButton extends StatelessWidget {
  const _EndCallButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.call_end, color: Colors.white),
            ),
            const SizedBox(height: 4),
            const Text(
              'Выйти',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Один штрих рисунка. Координаты нормированы 0..1 по размеру области
/// рисования, чтобы штрих корректно выглядел на экранах разных размеров.
/// `aspect` фиксирует пропорции картинки, в которых штрих был нарисован:
/// штрих всегда рисуется в этих пропорциях, даже если текущие изменились.
class _Stroke {
  _Stroke({
    required this.color,
    required this.width,
    required this.points,
    this.aspect,
  });

  final Color color;
  final double width;
  final List<Offset> points;
  final double? aspect;
}

/// Прозрачное полотно для рисования поверх трансляции. Штрихи привязаны к
/// самой видеокартинке: рисуем в прямоугольнике, который видеопоток реально
/// занимает внутри области (режим objectFit contain), с полями «письма» по
/// краям. Поэтому у учителя и ученика с разными размерами окон штрихи стоят
/// в одних и тех же местах картинки.
/// Линейное преобразование между координатами слайда (0..1) и пикселями
/// канваса: canvas = slide * scale + offset.
class _Stretch {
  const _Stretch({
    required this.scaleX,
    required this.offsetX,
    required this.scaleY,
    required this.offsetY,
  });

  final double scaleX;
  final double offsetX;
  final double scaleY;
  final double offsetY;

  Offset slideToCanvas(Offset s) =>
      Offset(s.dx * scaleX + offsetX, s.dy * scaleY + offsetY);

  Offset canvasToSlide(Offset c) =>
      Offset((c.dx - offsetX) / scaleX, (c.dy - offsetY) / scaleY);

  double get shortestSide => scaleX < scaleY ? scaleX : scaleY;
}

class _PanScreen extends StatefulWidget {
  const _PanScreen({
    required this.cover,
    required this.aspect,
    required this.enabled,
    required this.child,
  });

  /// Режим «весь экран»: картинка кроится по центру, нужен пан.
  final bool cover;

  /// Пропорция видео (ширина/высота).
  final double? aspect;

  /// Разрешить пан (выключено во время рисования).
  final bool enabled;

  final Widget child;

  @override
  State<_PanScreen> createState() => _PanScreenState();
}

class _PanScreenState extends State<_PanScreen> {
  /// Смещение видео относительно центра экрана.
  Offset _offset = Offset.zero;

  /// Максимальное смещение, при котором края видео ещё видны.
  Offset _maxOffsets(Size size, double? aspect) {
    if (!widget.cover || aspect == null || aspect <= 0 || size.isEmpty) {
      return Offset.zero;
    }
    // Видео в cover размере: его ширина/высота.
    final containerAspect = size.width / size.height;
    late final double videoW;
    late final double videoH;
    if (containerAspect > aspect) {
      videoW = size.width;
      videoH = size.width / aspect;
    } else {
      videoH = size.height;
      videoW = size.height * aspect;
    }
    return Offset(
      math.max(0, (videoW - size.width) / 2),
      math.max(0, (videoH - size.height) / 2),
    );
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (!widget.enabled || !widget.cover) return;
    setState(() {
      final maxOffsets = _maxOffsets(size, widget.aspect);
      _offset = Offset(
        (_offset.dx + d.delta.dx).clamp(-maxOffsets.dx, maxOffsets.dx),
        (_offset.dy + d.delta.dy).clamp(-maxOffsets.dy, maxOffsets.dy),
      );
    });
  }

  void _reset() {
    if (_offset == Offset.zero) return;
    setState(() => _offset = Offset.zero);
  }

  @override
  void didUpdateWidget(_PanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Сбрасываем сдвиг только при смене режима показа. Включение рисования
    // позицию не трогает: штрихи должны остаться на том же месте картинки.
    if (oldWidget.cover != widget.cover) {
      _offset = Offset.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final maxOffsets = _maxOffsets(size, widget.aspect);
        final canPan = maxOffsets != Offset.zero;
        final aspect = widget.aspect;
        // «Коробка» с видео: в cover-режиме она повторяет пропорции видео и
        // накрывает экран целиком, поэтому её края можно дотянуть жестом.
        // Двигаем именно раскладкой (Positioned), а не Transform: видео на web
        // рисуется платформенным элементом, который трансформации не переносит
        // (даёт чёрный экран).
        final boxW =
            canPan ? math.max(size.width, size.height * aspect!) : size.width;
        final boxH = canPan ? boxW / aspect! : size.height;
        final dx = canPan ? _offset.dx.clamp(-maxOffsets.dx, maxOffsets.dx) : 0.0;
        final dy = canPan ? _offset.dy.clamp(-maxOffsets.dy, maxOffsets.dy) : 0.0;
        final gestures = widget.enabled && canPan;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: gestures ? (d) => _onPanUpdate(d, size) : null,
          onDoubleTap: gestures ? _reset : null,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: (size.width - boxW) / 2 + dx,
                  top: (size.height - boxH) / 2 + dy,
                  width: boxW,
                  height: boxH,
                  child: widget.child,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WhiteboardCanvas extends StatefulWidget {
  const _WhiteboardCanvas({
    required this.enabled,
    required this.strokes,
    required this.activeStroke,
    required this.screenAspect,
    required this.cover,
    required this.onStrokeDown,
    required this.onStrokeMove,
    required this.onStrokeUp,
  });

  final bool enabled;
  final List<_Stroke> strokes;
  final _Stroke? activeStroke;
  final double? screenAspect;
  final bool cover;
  final void Function(Offset normalized, double? aspect, Rect rect, Size box)
      onStrokeDown;
  final ValueChanged<Offset> onStrokeMove;
  final VoidCallback onStrokeUp;

  @override
  State<_WhiteboardCanvas> createState() => _WhiteboardCanvasState();
}

class _WhiteboardCanvasState extends State<_WhiteboardCanvas> {
  bool _capturing = false;

  /// Прямоугольник видеокартинки внутри области (contain-fit).
  static Rect pictureRect(Size size, double? aspect) {
    if (aspect == null || aspect <= 0 || size.isEmpty) {
      return Offset.zero & size;
    }
    final boxAspect = size.width / size.height;
    if (boxAspect > aspect) {
      final w = size.height * aspect;
      return Rect.fromLTWH((size.width - w) / 2, 0, w, size.height);
    }
    final h = size.width / aspect;
    return Rect.fromLTWH(0, (size.height - h) / 2, size.width, h);
  }

  /// Маппинг «координаты слайда (0..1) ↔ пиксели канваса» в текущем режиме
  /// показа: по ширине (contain, полосы сверху/снизу) или весь экран
  /// (cover, картинка целиком покрывает экран по вертикали, поля слайда по
  /// бокам обрезаются). Нужно, чтобы штрихи ложились ровно на видео, а не
  /// на мнимую «полосу».
  static _Stretch viewStretch(Size size, double? aspect, bool cover) {
    if (cover && aspect != null && aspect > 0 && !size.isEmpty) {
      final containerAspect = size.width / size.height;
      final wv = math.min(1, containerAspect / aspect);
      final hv = math.min(1, aspect / containerAspect);
      final ox = (1 - wv) / 2;
      final oy = (1 - hv) / 2;
      return _Stretch(
        scaleX: size.width / wv,
        offsetX: -ox * size.width / wv,
        scaleY: size.height / hv,
        offsetY: -oy * size.height / hv,
      );
    }
    final rect = pictureRect(size, aspect);
    return _Stretch(
      scaleX: rect.width,
      offsetX: rect.left,
      scaleY: rect.height,
      offsetY: rect.top,
    );
  }

  void _down(Offset local, Size size) {
    // Рисуем сами только когда включён режим рисования; иначе канвас лишь
    // показывает чужие штрихи и ни на что не реагирует.
    if (!widget.enabled) return;
    final stretch = viewStretch(size, widget.screenAspect, widget.cover);
    final slide = stretch.canvasToSlide(local);
    if (slide.dx < 0 || slide.dx > 1 || slide.dy < 0 || slide.dy > 1) {
      _capturing = false;
      return;
    }
    _capturing = true;
    widget.onStrokeDown(
      Offset(slide.dx.clamp(0.0, 1.0), slide.dy.clamp(0.0, 1.0)),
      widget.screenAspect,
      pictureRect(size, widget.screenAspect),
      size,
    );
  }

  void _move(Offset local, Size size) {
    if (!_capturing) return;
    final stretch = viewStretch(size, widget.screenAspect, widget.cover);
    final slide = stretch.canvasToSlide(local);
    if (slide.dx < 0 || slide.dx > 1 || slide.dy < 0 || slide.dy > 1) return;
    widget.onStrokeMove(
        Offset(slide.dx.clamp(0.0, 1.0), slide.dy.clamp(0.0, 1.0)));
  }

  void _up() {
    if (!_capturing) return;
    _capturing = false;
    widget.onStrokeUp();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Listener(
          behavior: widget.enabled
              ? HitTestBehavior.opaque
              : HitTestBehavior.deferToChild,
          onPointerDown: (event) => _down(event.localPosition, size),
          onPointerMove: (event) => _move(event.localPosition, size),
          onPointerUp: (_) => _up(),
          onPointerCancel: (_) => _up(),
          child: CustomPaint(
            size: Size.infinite,
            painter: _WhiteboardPainter(
              strokes: widget.strokes,
              activeStroke: widget.activeStroke,
              screenAspect: widget.screenAspect,
              cover: widget.cover,
            ),
          ),
        );
      },
    );
  }
}

class _WhiteboardPainter extends CustomPainter {
  _WhiteboardPainter({
    required this.strokes,
    required this.activeStroke,
    required this.screenAspect,
    required this.cover,
  });

  final List<_Stroke> strokes;
  final _Stroke? activeStroke;
  final double? screenAspect;
  final bool cover;

  void _drawStroke(Canvas canvas, Size size, _Stroke stroke) {
    if (stroke.points.length < 2) return;
    // Каждый штрих рисуем в тех же пропорциях картинки, в которых он был
    // нарисован, — иначе «поехали» бы прямые линии.
    final stretch = _WhiteboardCanvasState.viewStretch(
        size, stroke.aspect ?? screenAspect, cover);
    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.stroke
      ..strokeWidth =
          (stroke.width * stretch.shortestSide).clamp(2.0, 30.0)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final first = stretch.slideToCanvas(stroke.points.first);
    final path = Path()..moveTo(first.dx, first.dy);
    for (final p in stroke.points.skip(1)) {
      final c = stretch.slideToCanvas(p);
      path.lineTo(c.dx, c.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _drawStroke(canvas, size, stroke);
    }
    final active = activeStroke;
    if (active != null) {
      _drawStroke(canvas, size, active);
    }
  }

  @override
  bool shouldRepaint(_WhiteboardPainter oldDelegate) =>
      oldDelegate.strokes != strokes ||
      oldDelegate.activeStroke != activeStroke ||
      oldDelegate.screenAspect != screenAspect ||
      oldDelegate.cover != cover;
}

/// Палитра рисования: цвета + «стереть всё».
class _DrawingPalette extends StatelessWidget {
  const _DrawingPalette({
    required this.selected,
    required this.onColorSelected,
    required this.onClear,
  });

  final Color selected;
  final ValueChanged<Color> onColorSelected;
  final VoidCallback onClear;

  static const _colors = <Color>[
    Color(0xFFFFEE00), // жёлтый
    Color(0xFFFF3B30), // красный
    Color(0xFF30D158), // зелёный
    Color(0xFF0A84FF), // синий
    Color(0xFFFFFFFF), // белый
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC1E1E1E),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in _colors)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: InkWell(
                onTap: () => onColorSelected(c),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected == c ? Colors.white : Colors.white24,
                      width: selected == c ? 2 : 1,
                    ),
                  ),
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(width: 1, height: 20, child: VerticalDivider(color: Colors.white24)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: InkWell(
              onTap: onClear,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(
                  color: Colors.white12,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.layers_clear, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}