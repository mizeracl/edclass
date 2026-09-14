import 'package:web/web.dart' as web;

/// Пропорции (w/h) самого крупного <video>-элемента на странице: им всегда
/// является трансляция экрана. `videoWidth/videoHeight` — точные размеры
/// того кадра, который браузер рисует картинкой objectFit contain, поэтому
/// штрихи обеих сторон не разъезжаются.
double? probeVideoElementAspect() {
  try {
    double? best;
    var bestArea = 0.0;
    final nodes = web.document.querySelectorAll('video');
    for (var i = 0; i < nodes.length; i++) {
      final v = nodes.item(i) as web.HTMLVideoElement;
      final w = v.videoWidth.toDouble();
      final h = v.videoHeight.toDouble();
      if (w <= 0 || h <= 0) continue;
      final area = w * h;
      if (area > bestArea) {
        bestArea = area;
        best = w / h;
      }
    }
    return best;
  } catch (_) {
    return null;
  }
}