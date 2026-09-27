// Validation entry point. Launch with `flutter run -t` on a real phone or TV,
// then `adb forward tcp:8798 tcp:8798`. POST /begin with label, cache=cold or
// warm, device, build, and exact visible contentKey/actionKey before navigation.
// For category grids, pass imageKeyPrefix=phone-shelf-image- and
// imageScopeKey=phone-shelf-image-grid. Only cards inside that grid contribute
// decoded-image timings; media item IDs are not exported.
// GET /state is exploratory; POST /end consumes one active run and returns its
// random runId for host-bound, one-time formal capture.
// Repeat each scenario in the same build mode; keep cold/warm samples separate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/main.dart' as production;
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_controller.dart';

final _probe = _PageProbe();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _probe.start();
  await production.main([]);
}

class _PageProbe {
  final MobileFrameTimingCollector _timings = MobileFrameTimingCollector();
  final Random _runRandom = Random.secure();
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _bindPhonePlayer(sample);
        // Category images can finish after text and actions are usable. Keep
        // observing their decoded frames until /end, within the sample limit.
        if (!sample.contentTimedOut &&
            (!sample.complete || sample.imageKeyPrefix?.isNotEmpty == true)) {
          _sample(sample);
        }
      });
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
              (q['actionKey'] ?? '').isEmpty ||
              ((q['imageKeyPrefix'] ?? '').isNotEmpty &&
                  (q['imageScopeKey'] ?? '').isEmpty)) {
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
              imageKeyPrefix: q['imageKeyPrefix'],
              imageScopeKey: q['imageScopeKey'],
              runId: List.generate(
                16,
                (_) =>
                    _runRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
              ).join(),
              frames: _timings.begin(),
            );
            _active = _latest = sample;
            request.response.write(jsonEncode(_record(sample)));
          }
        } else if (request.method == 'GET' && request.uri.path == '/state') {
          request.response.write(jsonEncode(_record(_latest)));
        } else if (request.method == 'POST' && request.uri.path == '/observe') {
          final sample = _active;
          if (sample == null) {
            request.response.statusCode = HttpStatus.conflict;
            request.response.write('No active scenario');
          } else {
            final value = jsonDecode(await utf8.decoder.bind(request).join());
            if (value is! Map<String, dynamic> ||
                !_recordExternalObservation(sample, value)) {
              request.response.statusCode = HttpStatus.badRequest;
              request.response.write('Invalid external observation');
            } else {
              request.response.write(jsonEncode(_record(sample)));
            }
          }
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
            sample.ended = true;
            sample.unbindPlayer();
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
    sample?.samplePlayerStatus();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final refreshRate = view.display.refreshRate;
    final frameBudgetMs = refreshRate > 0 ? 1000 / refreshRate : null;
    return {
      'label': sample?.label,
      'runId': sample?.runId,
      'ended': sample?.ended ?? false,
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
      'playerAttached': sample?.playerEverAttached ?? false,
      'playerItemId': sample?.playerItemId,
      'playerBuffering': sample?.lastBuffering,
      'playerPlaying': sample?.lastPlaying,
      'playerPositionMs': sample?.lastPositionMs,
      'playerPhase': sample?.lastPhase,
      'playerError': sample?.lastError,
      'playerDisconnected': sample?.lastDisconnected,
      'playerLoading': sample?.lastLoading,
      'bufferingEvents': sample?.bufferingEvents ?? const [],
      'contentKey': sample?.contentKey,
      'actionKey': sample?.actionKey,
      'imageKeyPrefix': sample?.imageKeyPrefix,
      'imageScopeKey': sample?.imageScopeKey,
      'firstContentMs': sample?.contentMs,
      'firstRenderedImageMs': sample?.renderedImageMs,
      'visibleImageCount': sample?.visibleImageKeys.length ?? 0,
      'visibleImageCompletionMs':
          (sample?.visibleImageCompletionMs.values.toList() ?? <double>[])
            ..sort(),
      'renderedImageObserved': sample?.renderedImageMs != null,
      'firstDisplayedImageMs': sample?.displayedImageMs,
      'displayedImageEvidenceSha256': sample?.displayedImageEvidenceSha256,
      'displayedImageClockUncertaintyMs':
          sample?.displayedImageClockUncertaintyMs,
      'firstOperableMs': sample?.operableMs,
      'nativeFirstFrameMs': sample?.nativeFirstFrameMs,
      'firstDisplayedFrameMs': sample?.displayedFrameMs,
      'displayedFrameEvidenceSha256': sample?.displayedFrameEvidenceSha256,
      'displayedFrameClockUncertaintyMs':
          sample?.displayedFrameClockUncertaintyMs,
      'elapsedMs': (sample?.clock.elapsedMicroseconds ?? 0) / 1000,
      'complete': sample?.complete ?? false,
    };
  }

  void _bindPhonePlayer(_PageSample sample) {
    if (!identical(_active, sample) || sample.trackedPlayer != null) return;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    void visit(Element element) {
      if (sample.trackedPlayer != null) return;
      if (element is StatefulElement &&
          element.state is MobilePlayerPageState) {
        final controller = (element.state as MobilePlayerPageState).controller;
        if (controller != null) {
          sample.bindPlayer(controller);
          return;
        }
      }
      element.visitChildren(visit);
    }

    visit(root);
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
            if (sample.renderedImageMs == null &&
                key.value == sample.contentKey &&
                hasDecodedImage(element, viewport: viewport)) {
              sample.renderedImageMs = ms;
            }
            final imagePrefix = sample.imageKeyPrefix;
            if (imagePrefix != null &&
                imagePrefix.isNotEmpty &&
                key.value.startsWith(imagePrefix) &&
                imageWithinScope(element, sample.imageScopeKey!)) {
              sample.visibleImageKeys.add(key.value);
              if (!sample.visibleImageCompletionMs.containsKey(key.value) &&
                  hasDecodedImage(element, viewport: viewport)) {
                sample.visibleImageCompletionMs[key.value] = ms;
              }
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
    required this.imageKeyPrefix,
    required this.imageScopeKey,
    required this.runId,
    required this.frames,
  }) {
    clock.start();
  }

  final String label, cacheMode, device, buildId, contentKey, actionKey, runId;
  final String? imageKeyPrefix;
  final String? imageScopeKey;
  final Set<String> visibleImageKeys = {};
  final Map<String, double> visibleImageCompletionMs = {};
  final MobileFrameTimingWindow frames;
  final Stopwatch clock = Stopwatch();
  double? contentMs, renderedImageMs, operableMs, nativeFirstFrameMs;
  double? displayedImageMs, displayedImageClockUncertaintyMs;
  String? displayedImageEvidenceSha256;
  double? displayedFrameMs, displayedFrameClockUncertaintyMs;
  String? displayedFrameEvidenceSha256;
  bool contentTimedOut = false;
  bool ended = false;
  PlayerController? trackedPlayer;
  bool playerEverAttached = false;
  String? playerItemId;
  VoidCallback? _playerListener;
  bool? lastBuffering;
  bool? lastPlaying, lastDisconnected, lastLoading;
  int? lastPositionMs;
  String? lastPhase, lastError;
  final List<Map<String, Object>> bufferingEvents = [];

  void bindPlayer(PlayerController player) {
    if (trackedPlayer != null) return;
    trackedPlayer = player;
    playerEverAttached = true;
    playerItemId = player.itemId;
    lastBuffering = player.isBuffering;
    samplePlayerStatus();
    void observe() {
      final buffering = player.isBuffering;
      if (buffering == lastBuffering) return;
      lastBuffering = buffering;
      samplePlayerStatus();
      bufferingEvents.add({
        'buffering': buffering,
        'elapsedMs': clock.elapsedMicroseconds / 1000,
      });
    }

    _playerListener = observe;
    player.addListener(observe);
  }

  void unbindPlayer() {
    samplePlayerStatus();
    trackedPlayer?.removeListener(_playerListener!);
    trackedPlayer = null;
    _playerListener = null;
  }

  void samplePlayerStatus() {
    final player = trackedPlayer;
    if (player == null) return;
    lastPlaying = player.isPlaying;
    lastPositionMs = player.position.inMilliseconds;
    lastPhase = player.state.phase.name;
    lastError = player.error?.name;
    lastDisconnected = player.disconnected;
    lastLoading = player.loading;
  }

  bool get complete => contentMs != null && operableMs != null;
}

/// Ensures an image measurement belongs to the requested grid, even when
/// another page or home rail uses a similar card key in the same navigator.
bool imageWithinScope(Element element, String scopeKey) {
  var inside = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget.key == ValueKey<String>(scopeKey)) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// A decoded image counts only when its painted bounds survive visible clips.
/// Device screenshot evidence separately confirms actual screen pixels.
bool hasDecodedImage(Element element, {Rect? viewport}) {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final visibleViewport =
      viewport ?? (Offset.zero & (view.physicalSize / view.devicePixelRatio));
  var found = false;
  void visit(Element child) {
    if (found) return;
    if (child is RenderObjectElement &&
        child.renderObject is RenderIndexedStack) {
      final stack = child.renderObject as RenderIndexedStack;
      var index = 0;
      child.visitChildren((candidate) {
        if (index++ == stack.index) visit(candidate);
      });
      return;
    }
    final render = child.findRenderObject();
    if (render is RenderImage &&
        render.image != null &&
        _imageBoundsVisible(child, render, visibleViewport)) {
      found = true;
      return;
    }
    child.visitChildren(visit);
  }

  visit(element);
  return found;
}

bool _imageBoundsVisible(Element element, RenderImage image, Rect viewport) {
  if (!image.attached || !image.hasSize) return false;
  var visible = (image.localToGlobal(Offset.zero) & image.size).intersect(
    viewport,
  );
  if (visible.isEmpty) return false;
  var allowed = true;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Offstage && widget.offstage ||
        widget is Visibility && !widget.visible ||
        widget is Opacity && widget.opacity <= 0 ||
        widget is AnimatedOpacity && widget.opacity <= 0 ||
        widget is FadeTransition && widget.opacity.value <= 0) {
      allowed = false;
      return false;
    }
    if (widget is ClipRect || widget is ClipRRect || widget is ClipOval) {
      final render = ancestor.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        visible = visible.intersect(
          render.localToGlobal(Offset.zero) & render.size,
        );
        if (visible.isEmpty) {
          allowed = false;
          return false;
        }
      }
    }
    // Arbitrary paths can conceal all pixels; require screen evidence instead.
    if (widget is ClipPath) {
      allowed = false;
      return false;
    }
    return true;
  });
  return allowed && !visible.isEmpty;
}

/// Host observations require a screenshot digest and bounded clock alignment.
/// The native callback is retained separately and never fills display timing.
bool _recordExternalObservation(
  _PageSample sample,
  Map<String, dynamic> value,
) {
  final kind = value['kind'];
  final elapsed = value['elapsedMs'];
  final uncertainty = value['clockUncertaintyMs'];
  if (elapsed is! num ||
      elapsed < 0 ||
      uncertainty is! num ||
      uncertainty < 0 ||
      uncertainty > 100 ||
      elapsed > sample.clock.elapsedMicroseconds / 1000 + uncertainty) {
    return false;
  }
  if (kind == 'nativeFirstFrame') {
    sample.nativeFirstFrameMs ??= elapsed.toDouble();
    return true;
  }
  final digest = value['evidenceSha256'];
  if (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    return false;
  }
  if (kind == 'displayedImage') {
    sample.displayedImageMs ??= elapsed.toDouble();
    sample.displayedImageClockUncertaintyMs ??= uncertainty.toDouble();
    sample.displayedImageEvidenceSha256 ??= digest;
    return true;
  }
  if (kind != 'displayedFrame') return false;
  sample.displayedFrameMs ??= elapsed.toDouble();
  sample.displayedFrameClockUncertaintyMs ??= uncertainty.toDouble();
  sample.displayedFrameEvidenceSha256 ??= digest;
  return true;
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
