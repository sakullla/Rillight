// Validation entry point. Launch with `flutter run -t` on a real phone or TV,
// then `adb forward tcp:8798 tcp:8798`. POST /begin with label, cache=cold or
// warm, device, build, and exact visible contentKey/actionKey before navigation.
// Poll GET /state and append POST /end JSON to a baseline or candidate JSONL.
// Repeat each scenario in the same build mode; keep cold/warm samples separate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/main.dart' as production;

final _probe = _PageProbe();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _probe.start();
  await production.main([]);
}

class _PageProbe {
  final MobileFrameTimingCollector _timings = MobileFrameTimingCollector();
  _PageSample? _active, _latest;

  Future<void> start() async {
    WidgetsBinding.instance.addTimingsCallback(_timings.receive);
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      final sample = _active;
      if (sample == null) return;
      // This is the engine's raw onBeginFrame timestamp. FrameTiming.buildStart
      // uses exactly the same value, even if the timing batch arrives later.
      _timings.frameStarted(
        sample.frames,
        WidgetsBinding.instance.currentSystemFrameTimeStamp.inMicroseconds,
      );
      if (!sample.contentTimedOut && !sample.complete) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sample(sample));
      }
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8798);
    server.listen((request) async {
      try {
        if (request.method == 'POST' && request.uri.path == '/begin') {
          final q = request.uri.queryParameters;
          if (!{'cold', 'warm'}.contains(q['cache']) ||
              (q['label'] ?? '').isEmpty ||
              (q['device'] ?? '').isEmpty ||
              (q['build'] ?? '').isEmpty ||
              (q['contentKey'] ?? '').isEmpty ||
              (q['actionKey'] ?? '').isEmpty) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write(
              'label, cache, device, build, contentKey and actionKey required',
            );
          } else if (_active != null) {
            request.response.statusCode = HttpStatus.conflict;
            request.response.write(
              'End the active scenario before beginning another',
            );
          } else {
            final sample = _PageSample(
              label: q['label']!,
              cacheMode: q['cache']!,
              device: q['device']!,
              buildId: q['build']!,
              contentKey: q['contentKey']!,
              actionKey: q['actionKey']!,
              frames: _timings.begin(),
            );
            _active = _latest = sample;
            request.response.write(jsonEncode(_record(sample)));
          }
        } else if (request.method == 'GET' && request.uri.path == '/state') {
          request.response.write(jsonEncode(_record(_latest)));
        } else if (request.method == 'POST' && request.uri.path == '/end') {
          final sample = _active;
          if (sample == null) {
            request.response.statusCode = HttpStatus.conflict;
            request.response.write('No active scenario');
          } else {
            _active = null;
            sample.clock.stop();
            // Release/profile timing batches can arrive up to a second after
            // their frames. Keep this window alive while a new one begins.
            await _timings.end(sample.frames);
            request.response.write(jsonEncode(_record(sample)));
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
      } catch (error) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(error.toString());
      }
      await request.response.close();
    });
  }

  Map<String, Object?> _record(_PageSample? sample) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final refreshRate = view.display.refreshRate;
    final frameBudgetMs = refreshRate > 0 ? 1000 / refreshRate : null;
    return {
      'label': sample?.label,
      'cache': sample?.cacheMode,
      'device': sample?.device,
      'build': sample?.buildId,
      'platform': Platform.operatingSystem,
      'buildMode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'physicalSize': [view.physicalSize.width, view.physicalSize.height],
      'pixelRatio': view.devicePixelRatio,
      'refreshRateHz': refreshRate,
      'frameBudgetMs': frameBudgetMs,
      'uiFrameMs': List<double>.of(sample?.frames.uiFrameMs ?? const []),
      'rasterFrameMs': List<double>.of(
        sample?.frames.rasterFrameMs ?? const [],
      ),
      'expectedFrames': sample?.frames.expectedFrames ?? 0,
      'pendingFrameTimings': sample?.frames.pendingFrameTimings ?? 0,
      'missingFrameTimings': sample?.frames.missingFrameTimings ?? 0,
      'frameTimingsComplete': sample?.frames.frameTimingsComplete ?? false,
      'contentKey': sample?.contentKey,
      'actionKey': sample?.actionKey,
      'firstContentMs': sample?.contentMs,
      'firstOperableMs': sample?.operableMs,
      'elapsedMs': (sample?.clock.elapsedMicroseconds ?? 0) / 1000,
      'complete': sample?.complete ?? false,
    };
  }

  void _sample(_PageSample sample) {
    if (!identical(_active, sample)) return;
    if (sample.clock.elapsed > const Duration(seconds: 20)) {
      sample.contentTimedOut = true;
      return;
    }
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final viewport = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      final key = widget.key;
      if (key is ValueKey<String>) {
        final render = element.findRenderObject();
        if (render is RenderBox && render.attached && render.hasSize) {
          final rect = render.localToGlobal(Offset.zero) & render.size;
          if (rect.overlaps(viewport)) {
            final ms = sample.clock.elapsedMicroseconds / 1000;
            if (sample.contentMs == null && key.value == sample.contentKey) {
              sample.contentMs = ms;
            }
            if (sample.operableMs == null &&
                key.value == sample.actionKey &&
                _enabled(widget)) {
              sample.operableMs = ms;
            }
          }
        }
      }
      if (element is RenderObjectElement &&
          element.renderObject is RenderIndexedStack) {
        final stack = element.renderObject as RenderIndexedStack;
        var index = 0;
        element.visitChildren((child) {
          if (index++ == stack.index) visit(child);
        });
      } else {
        element.visitChildren(visit);
      }
    }

    visit(root);
  }

  bool _enabled(Widget widget) => switch (widget) {
    ButtonStyleButton(:final onPressed) => onPressed != null,
    IconButton(:final onPressed) => onPressed != null,
    TvAction(:final onPressed) => onPressed != null,
    InkWell(:final onTap) => onTap != null,
    GestureDetector(:final onTap) => onTap != null,
    _ => true,
  };
}

class _PageSample {
  _PageSample({
    required this.label,
    required this.cacheMode,
    required this.device,
    required this.buildId,
    required this.contentKey,
    required this.actionKey,
    required this.frames,
  }) {
    clock.start();
  }

  final String label, cacheMode, device, buildId, contentKey, actionKey;
  final MobileFrameTimingWindow frames;
  final Stopwatch clock = Stopwatch();
  double? contentMs, operableMs;
  bool contentTimedOut = false;
  bool get complete => contentMs != null && operableMs != null;
}

/// Matches delayed engine timing batches to the frame window where UI work ran.
/// `buildStart` is the raw timestamp supplied to onBeginFrame, so callback
/// delivery time and a later scenario's active state do not affect ownership.
class MobileFrameTimingCollector {
  final Map<int, MobileFrameTimingWindow> _owners = {};

  MobileFrameTimingWindow begin() => MobileFrameTimingWindow._();

  void frameStarted(MobileFrameTimingWindow window, int buildStartUs) {
    if (window._finished || !window._pending.add(buildStartUs)) return;
    window.expectedFrames++;
    _owners[buildStartUs] = window;
  }

  void receive(List<FrameTiming> timings) {
    for (final timing in timings) {
      final timestamp = timing.timestampInMicroseconds(FramePhase.buildStart);
      final window = _owners.remove(timestamp);
      if (window == null || !window._pending.remove(timestamp)) continue;
      window.uiFrameMs.add(timing.buildDuration.inMicroseconds / 1000);
      window.rasterFrameMs.add(timing.rasterDuration.inMicroseconds / 1000);
      if (window._pending.isEmpty) {
        final drained = window._drained;
        if (drained != null && !drained.isCompleted) drained.complete();
      }
    }
  }

  /// Waits for the final batch. A lost engine timing remains explicit in JSON.
  Future<void> end(
    MobileFrameTimingWindow window, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (window._finished) return;
    if (window._pending.isNotEmpty) {
      final drained = window._drained ??= Completer<void>();
      try {
        await drained.future.timeout(timeout);
      } on TimeoutException {
        // Do not silently turn an incomplete timing sample into a passing one.
      }
    }
    window.missingFrameTimings = window._pending.length;
    for (final timestamp in window._pending) {
      _owners.remove(timestamp);
    }
    window._pending.clear();
    window._finished = true;
  }
}

class MobileFrameTimingWindow {
  MobileFrameTimingWindow._();

  final List<double> uiFrameMs = [], rasterFrameMs = [];
  final Set<int> _pending = {};
  Completer<void>? _drained;
  bool _finished = false;
  int expectedFrames = 0;
  int missingFrameTimings = 0;

  int get pendingFrameTimings => _pending.length;
  bool get frameTimingsComplete => _finished && missingFrameTimings == 0;
}
