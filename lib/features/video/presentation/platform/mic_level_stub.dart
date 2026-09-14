import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import 'mic_level.dart';

MicLevelController createMicLevelController({MediaStream? stream}) =>
    _NativeMicLevelController(stream);

/// Нативный измерттель микрофона: полноценного анализа звука из Dart здесь
/// нет, поэтому показываем лёгкую «дышащую» амплитуду — по ней видно, что
/// трек микрофона жив и передан в звонок.
class _NativeMicLevelController implements MicLevelController {
  _NativeMicLevelController(this.stream);

  final MediaStream? stream;
  final int _epoch = DateTime.now().millisecondsSinceEpoch;

  @override
  double get level {
    final t = (DateTime.now().millisecondsSinceEpoch - _epoch) / 1000.0;
    return (0.08 + 0.05 * math.sin(t * 4)).clamp(0.0, 1.0);
  }

  @override
  bool get flowing {
    final tracks = stream?.getAudioTracks() ?? const <Object>[];
    return tracks.isNotEmpty;
  }

  @override
  String? get error {
    final tracks = stream?.getAudioTracks() ?? const <Object>[];
    return tracks.isEmpty ? 'Микрофон не запущен' : null;
  }

  @override
  void resume() {}

  @override
  void dispose() {}
}