import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import 'mic_level.dart';
import 'mic_level_stub.dart'
    if (dart.library.js_interop) 'mic_level_web.dart' as mic_impl;
import 'video_aspect_stub.dart'
    if (dart.library.js_interop) 'video_aspect_web.dart' as aspect_impl;

export 'mic_level.dart';

/// Пропорции (w/h) самого крупного <video>-элемента на странице.
/// На web — опрос DOM: это точные размеры кадра, который браузер фактически
/// рисует картинкой objectFit contain. На нативных платформах DOM нет —
/// функция всегда возвращает null.
double? probeVideoElementAspect() => aspect_impl.probeVideoElementAspect();

/// Создаёт измеритель уровня микрофона: на web — на Web Audio, на нативных
/// платформах — упрощённый индикатор наличия звукового трека.
MicLevelController createMicLevelController({MediaStream? stream}) =>
    mic_impl.createMicLevelController(stream: stream);