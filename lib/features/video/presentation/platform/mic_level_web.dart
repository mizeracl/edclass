import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:web/web.dart' as web;

import 'mic_level.dart';

MicLevelController createMicLevelController({MediaStream? stream}) =>
    _WebMicLevelController(stream);

/// Web-анализатор микрофона на Web Audio API. В некоторых браузерах нужно
/// нажать на тест один раз, чтобы разрешить звук (см. [resume]).
class _WebMicLevelController implements MicLevelController {
  _WebMicLevelController(MediaStream? stream) {
    _bind(stream);
  }

  web.AudioContext? _ctx;
  web.AnalyserNode? _analyser;
  JSUint8Array? _jsTime;
  Uint8List? _time;
  double _level = 0;
  bool _flowing = false;
  String? _error;

  void _bind(MediaStream? stream) {
    if (stream is! MediaStreamWeb) {
      _error = 'Микрофон не запущен';
      return;
    }
    final jsTracks = stream.jsStream.getAudioTracks().toDart;
    if (jsTracks.isEmpty) {
      _error = 'Нет звукового потока микрофона';
      return;
    }
    try {
      final ctx = web.AudioContext();
      final src = ctx.createMediaStreamSource(
          web.MediaStream([jsTracks.first].toJS));
      final analyser = ctx.createAnalyser();
      analyser.fftSize = 1024;
      src.connect(analyser);
      final time = Uint8List(analyser.fftSize);
      _ctx = ctx;
      _analyser = analyser;
      _time = time;
      _jsTime = time.toJS;
      unawaited(_attemptResume(ctx));
    } catch (e) {
      _error = 'Ошибка теста звука: $e';
    }
  }

  Future<void> _attemptResume(web.AudioContext ctx) async {
    try {
      await ctx.resume().toDart;
      if (_ctx == ctx) _flowing = true;
    } catch (_) {}
  }

  @override
  double get level {
    final analyser = _analyser;
    final jsTime = _jsTime;
    final time = _time;
    if (analyser == null || jsTime == null || time == null) return 0;
    try {
      analyser.getByteTimeDomainData(jsTime);
    } catch (_) {
      return 0;
    }
    double sum = 0;
    for (var i = 0; i < time.length; i++) {
      final v = (time[i] - 128) / 128.0;
      sum += v * v;
    }
    final rms = time.isEmpty ? 0.0 : math.sqrt(sum / time.length);
    _level = math.max((rms * 5).clamp(0.0, 1.0), _level * 0.85);
    return _level;
  }

  @override
  bool get flowing => _flowing;

  @override
  String? get error => _error;

  @override
  void resume() {
    final ctx = _ctx;
    if (ctx != null) unawaited(_attemptResume(ctx));
  }

  @override
  void dispose() {
    final ctx = _ctx;
    if (ctx != null) unawaited(ctx.close().toDart);
    _ctx = null;
    _analyser = null;
    _jsTime = null;
    _time = null;
  }
}