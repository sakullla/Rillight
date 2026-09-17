import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Linux unregister only queues work on Flutter's raster runner. A completed
/// asynchronous picture snapshot, requested after the detach reply, fences
/// that earlier work without needing a mounted view, vsync, or a visible window.
/// See README's engine ordering contract before updating the Flutter engine.
Future<void> waitForRasterRetirement() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0x00000000), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(1, 1);
    image.dispose();
  } finally {
    picture.dispose();
  }
}

Future<void> retireSurface({
  required MethodChannel channel,
  required int handle,
  required bool needsRasterBarrier,
  Future<void> Function() rasterBarrier = waitForRasterRetirement,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  Duration remaining() => deadline.difference(DateTime.now());
  final arguments = {'handle': handle};
  if (needsRasterBarrier) {
    final detached = await channel
        .invokeMethod<bool>('detach', arguments)
        .timeout(remaining());
    if (detached == null) {
      throw StateError('Missing texture detach acknowledgement');
    }
    if (detached) await rasterBarrier().timeout(remaining());
  }
  // Failure or timeout before this point deliberately leaves native resources
  // alive. The process host can terminate the child; guessing completion risks
  // a raster use-after-free and must never be a cleanup fallback.
  await channel.invokeMethod<void>('dispose', arguments).timeout(remaining());
}
