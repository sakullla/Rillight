import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'core_bindings.dart';
import 'surface_retirement.dart';

/// Loads the desktop core once and reports which decoder names it has.
Map<String, bool> probeDesktopDecoders(Iterable<String> names) {
  final bindings = CoreBindings();
  return {for (final name in names) name: bindings.decoderAvailable(name)};
}

class CorePlayerEvent {
  const CorePlayerEvent(this.session, this.kind, this.value);
  final String session;
  final String kind;
  final Object value;
}

class CoreVideoCompatibilityException implements Exception {
  const CoreVideoCompatibilityException();
  static const errorCode = -20001;
  @override
  String toString() => 'Unsupported Dolby Vision color pipeline';
}

class CoreTrackSelectionException implements Exception {
  const CoreTrackSelectionException(this.track, this.errorCode);
  final String track;
  final int errorCode;

  @override
  String toString() => 'Core rejected $track track ($errorCode)';
}

/// A native seek changes the timeline before cancelling its owned media IO.
/// The transport must not close that IO independently before the native call.
abstract interface class CoreNativeSeekCancellation {}

class CorePlayerTrack {
  const CorePlayerTrack({
    required this.index,
    required this.type,
    required this.language,
    required this.isExternal,
  });
  final int index;
  final String type;
  final String? language;
  final bool isExternal;

  Map<String, Object?> toChannel() => {
    'index': index,
    'type': type,
    'language': language,
    'external': isExternal,
  };
}

enum CoreHardware {
  auto(-1),
  software(0),
  d3d11(1),
  videotoolbox(2),
  vaapi(4),
  mediacodec(8);

  const CoreHardware(this.nativeValue);
  final int nativeValue;

  CoreHardware get resolved {
    if (this != CoreHardware.auto) return this;
    if (Platform.isWindows) return CoreHardware.d3d11;
    if (Platform.isMacOS) return CoreHardware.videotoolbox;
    if (Platform.isLinux) return CoreHardware.vaapi;
    if (Platform.isAndroid) return CoreHardware.mediacodec;
    return CoreHardware.software;
  }
}

class CorePlayerOpen {
  const CorePlayerOpen({
    required this.url,
    required this.session,
    this.start = Duration.zero,
    this.paused = false,
    this.streams = const [],
    this.hardware = CoreHardware.auto,
  });
  final Uri url;
  final String session;
  final Duration start;
  final bool paused;
  final List<CorePlayerTrack> streams;
  final CoreHardware hardware;
}

class _CoreSnapshot {
  const _CoreSnapshot(
    this.state,
    this.ffmpegError,
    this.videoStreamIndex,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.durationUs,
    this.positionUs,
    this.firstVideoFrameReady,
    this.firstAudioFrameReady,
    this.playbackSpeed,
    this.externalSubtitlePending,
    this.timelineVersion,
    this.sessionId, {
    this.dolbyVisionProfile = -1,
    this.videoOutputKind = 0,
    this.audioDelivery = 0,
    this.audioChannels = 0,
    this.audioLayout = 0,
    this.audioAtmos = 0,
    this.audioCodecId = 0,
    this.requestedInterpolation = 0,
    this.effectiveInterpolation = 0,
    this.requestedAnime4k = 0,
    this.effectiveAnime4k = 0,
    this.requestedSuperResolution = 0,
    this.effectiveSuperResolution = 0,
    this.requestedDenoise = 0,
    this.effectiveDenoise = 0,
    this.requestedSharpen = 0,
    this.effectiveSharpen = 0,
    this.doviReconstruction = 0,
    this.dolbyVisionCompatibility = -1,
  });
  final int state;
  final int ffmpegError;
  final int videoStreamIndex;
  final int audioStreamIndex;
  final int subtitleStreamIndex;
  final int durationUs;
  final int positionUs;
  final int firstVideoFrameReady;
  final int firstAudioFrameReady;
  final double playbackSpeed;
  final int externalSubtitlePending;
  final int timelineVersion;
  final int sessionId;
  final int dolbyVisionProfile;
  final int videoOutputKind;
  final int audioDelivery;
  final int audioChannels;
  final int audioLayout;
  final int audioAtmos;
  final int audioCodecId;
  final int requestedInterpolation;
  final int effectiveInterpolation;
  final int requestedAnime4k;
  final int effectiveAnime4k;
  final int requestedSuperResolution;
  final int effectiveSuperResolution;
  final int requestedDenoise;
  final int effectiveDenoise;
  final int requestedSharpen;
  final int effectiveSharpen;
  final int doviReconstruction;
  final int dolbyVisionCompatibility;
}

/// One desktop snapshot plus the enhancement reasons read beside it.
/// Position and playback state are not part of equality.
class CoreOutputSample {
  const CoreOutputSample({
    required this.dolbyVisionProfile,
    required this.dolbyVisionCompatibility,
    required this.videoOutputKind,
    required this.doviReconstruction,
    required this.audioDelivery,
    required this.audioChannels,
    required this.audioLayout,
    required this.audioAtmos,
    required this.audioCodecId,
    required this.requestedInterpolation,
    required this.effectiveInterpolation,
    required this.requestedAnime4k,
    required this.effectiveAnime4k,
    required this.requestedSuperResolution,
    required this.effectiveSuperResolution,
    required this.requestedDenoise,
    required this.effectiveDenoise,
    required this.requestedSharpen,
    required this.effectiveSharpen,
    required this.reasonInterpolation,
    required this.reasonAnime4k,
    required this.reasonSuperResolution,
    required this.reasonDenoise,
    required this.reasonSharpen,
    required this.outputFrameRate,
  });

  factory CoreOutputSample.fromSnapshot({
    required int dolbyVisionProfile,
    required int dolbyVisionCompatibility,
    required int videoOutputKind,
    required int doviReconstruction,
    required int audioDelivery,
    required int audioChannels,
    required int audioLayout,
    required int audioAtmos,
    required int audioCodecId,
    required int requestedInterpolation,
    required int effectiveInterpolation,
    required int requestedAnime4k,
    required int effectiveAnime4k,
    required int requestedSuperResolution,
    required int effectiveSuperResolution,
    required int requestedDenoise,
    required int effectiveDenoise,
    required int requestedSharpen,
    required int effectiveSharpen,
    Map<String, Object> enhancement = const {},
  }) {
    int picked(String key, int fallback) {
      final value = enhancement[key];
      return value is num ? value.toInt() : fallback;
    }

    final reportedRate = enhancement['outputFrameRate'];
    final outputFrameRate = reportedRate is num ? reportedRate.toDouble() : 0.0;

    return CoreOutputSample(
      dolbyVisionProfile: dolbyVisionProfile,
      dolbyVisionCompatibility: dolbyVisionCompatibility,
      videoOutputKind: videoOutputKind,
      doviReconstruction: doviReconstruction,
      audioDelivery: audioDelivery,
      audioChannels: audioChannels,
      audioLayout: audioLayout,
      audioAtmos: audioAtmos,
      audioCodecId: audioCodecId,
      requestedInterpolation: picked(
        'requestedInterpolation',
        requestedInterpolation,
      ),
      effectiveInterpolation: picked(
        'effectiveInterpolation',
        effectiveInterpolation,
      ),
      requestedAnime4k: picked('requestedAnime4k', requestedAnime4k),
      effectiveAnime4k: picked('effectiveAnime4k', effectiveAnime4k),
      requestedSuperResolution: picked(
        'requestedSuperResolution',
        requestedSuperResolution,
      ),
      effectiveSuperResolution: picked(
        'effectiveSuperResolution',
        effectiveSuperResolution,
      ),
      requestedDenoise: picked('requestedDenoise', requestedDenoise),
      effectiveDenoise: picked('effectiveDenoise', effectiveDenoise),
      requestedSharpen: picked('requestedSharpen', requestedSharpen),
      effectiveSharpen: picked('effectiveSharpen', effectiveSharpen),
      reasonInterpolation: picked('reasonInterpolation', 0),
      reasonAnime4k: picked('reasonAnime4k', 0),
      reasonSuperResolution: picked('reasonSuperResolution', 0),
      reasonDenoise: picked('reasonDenoise', 0),
      reasonSharpen: picked('reasonSharpen', 0),
      outputFrameRate: outputFrameRate.isFinite && outputFrameRate > 0
          ? outputFrameRate
          : 0,
    );
  }

  final int dolbyVisionProfile;
  final int dolbyVisionCompatibility;
  final int videoOutputKind;
  final int doviReconstruction;
  final int audioDelivery;
  final int audioChannels;
  final int audioLayout;
  final int audioAtmos;
  final int audioCodecId;
  final int requestedInterpolation;
  final int effectiveInterpolation;
  final int requestedAnime4k;
  final int effectiveAnime4k;
  final int requestedSuperResolution;
  final int effectiveSuperResolution;
  final int requestedDenoise;
  final int effectiveDenoise;
  final int requestedSharpen;
  final int effectiveSharpen;
  final int reasonInterpolation;
  final int reasonAnime4k;
  final int reasonSuperResolution;
  final int reasonDenoise;
  final int reasonSharpen;
  final double outputFrameRate;

  Map<String, Object> toMap() => {
    'dolbyVisionProfile': dolbyVisionProfile,
    'dolbyVisionCompatibility': dolbyVisionCompatibility,
    'videoOutputKind': videoOutputKind,
    'doviReconstruction': doviReconstruction,
    'audioDelivery': audioDelivery,
    'audioChannels': audioChannels,
    'audioLayout': audioLayout,
    'audioAtmos': audioAtmos,
    'audioCodecId': audioCodecId,
    'requestedInterpolation': requestedInterpolation,
    'effectiveInterpolation': effectiveInterpolation,
    'requestedAnime4k': requestedAnime4k,
    'effectiveAnime4k': effectiveAnime4k,
    'requestedSuperResolution': requestedSuperResolution,
    'effectiveSuperResolution': effectiveSuperResolution,
    'requestedDenoise': requestedDenoise,
    'effectiveDenoise': effectiveDenoise,
    'requestedSharpen': requestedSharpen,
    'effectiveSharpen': effectiveSharpen,
    'reasonInterpolation': reasonInterpolation,
    'reasonAnime4k': reasonAnime4k,
    'reasonSuperResolution': reasonSuperResolution,
    'reasonDenoise': reasonDenoise,
    'reasonSharpen': reasonSharpen,
    'outputFrameRate': outputFrameRate,
  };

  @override
  bool operator ==(Object other) {
    return other is CoreOutputSample &&
        other.dolbyVisionProfile == dolbyVisionProfile &&
        other.dolbyVisionCompatibility == dolbyVisionCompatibility &&
        other.videoOutputKind == videoOutputKind &&
        other.doviReconstruction == doviReconstruction &&
        other.audioDelivery == audioDelivery &&
        other.audioChannels == audioChannels &&
        other.audioLayout == audioLayout &&
        other.audioAtmos == audioAtmos &&
        other.audioCodecId == audioCodecId &&
        other.requestedInterpolation == requestedInterpolation &&
        other.effectiveInterpolation == effectiveInterpolation &&
        other.requestedAnime4k == requestedAnime4k &&
        other.effectiveAnime4k == effectiveAnime4k &&
        other.requestedSuperResolution == requestedSuperResolution &&
        other.effectiveSuperResolution == effectiveSuperResolution &&
        other.requestedDenoise == requestedDenoise &&
        other.effectiveDenoise == effectiveDenoise &&
        other.requestedSharpen == requestedSharpen &&
        other.effectiveSharpen == effectiveSharpen &&
        other.reasonInterpolation == reasonInterpolation &&
        other.reasonAnime4k == reasonAnime4k &&
        other.reasonSuperResolution == reasonSuperResolution &&
        other.reasonDenoise == reasonDenoise &&
        other.reasonSharpen == reasonSharpen &&
        other.outputFrameRate == outputFrameRate;
  }

  @override
  int get hashCode => Object.hashAll([
    dolbyVisionProfile,
    dolbyVisionCompatibility,
    videoOutputKind,
    doviReconstruction,
    audioDelivery,
    audioChannels,
    audioLayout,
    audioAtmos,
    audioCodecId,
    requestedInterpolation,
    effectiveInterpolation,
    requestedAnime4k,
    effectiveAnime4k,
    requestedSuperResolution,
    effectiveSuperResolution,
    requestedDenoise,
    effectiveDenoise,
    requestedSharpen,
    effectiveSharpen,
    reasonInterpolation,
    reasonAnime4k,
    reasonSuperResolution,
    reasonDenoise,
    reasonSharpen,
    outputFrameRate,
  ]);
}

abstract class CorePlayer {
  Stream<CorePlayerEvent> get events;
  Future<Map<String, dynamic>> open(CorePlayerOpen request);
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]);
  Future<void> stop();
  Future<void> dispose();
  Widget buildView({Key? key});

  /// Plugin frame timing. Empty when this player has no native surface.
  Future<Map<String, dynamic>> surfaceStatus() async => const {};

  static Future<CorePlayer> create({String? libraryPath}) async {
    if (Platform.isAndroid) return AndroidCorePlayer();
    return DesktopCorePlayer.create(libraryPath: libraryPath);
  }
}

/// One Android owner keeps its native SurfaceView mounted while media opens.
class AndroidCorePlayer implements CorePlayer {
  AndroidCorePlayer()
    : owner = 'core-${++_nextOwner}-${DateTime.now().microsecondsSinceEpoch}' {
    _subscription = _nativeEvents.listen((dynamic raw) {
      if (raw is! Map ||
          raw['owner'] != owner ||
          raw['sessionId'] != _session) {
        return;
      }
      final kind = raw['kind'];
      final value = raw['value'];
      if (kind is String && value is Object) {
        _events.add(CorePlayerEvent(_session, kind, value));
      }
    });
  }

  static int _nextOwner = 0;
  static const _channel = MethodChannel('rillight/android_core');
  static const _eventChannel = EventChannel('rillight/android_core/events');
  static final Stream<dynamic> _nativeEvents = _eventChannel
      .receiveBroadcastStream()
      .asBroadcastStream();
  final String owner;
  String _session = '';
  bool _disposed = false;
  final _events = StreamController<CorePlayerEvent>.broadcast();
  late final StreamSubscription<dynamic> _subscription;

  @override
  Stream<CorePlayerEvent> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen request) async {
    _session = request.session;
    final result = await _channel.invokeMapMethod<String, dynamic>('open', {
      'owner': owner,
      'sessionId': _session,
      'url': request.url.toString(),
      'start': request.start.inMilliseconds,
      'paused': request.paused,
      'streams': [for (final track in request.streams) track.toChannel()],
      'preferredHardware': request.hardware.resolved.nativeValue,
    });
    if (_session != request.session) throw StateError('Superseded core open');
    return result ?? const {};
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final session = _session;
    final result = await _channel.invokeMapMethod<String, dynamic>(method, {
      'owner': owner,
      'sessionId': session,
      ...args,
    });
    if (_session != session) throw StateError('Superseded core command');
    return result ?? const {};
  }

  Future<Map<String, dynamic>> capabilities() async =>
      await _channel.invokeMapMethod<String, dynamic>('capabilities') ??
      const {};

  @override
  Future<void> stop() async {
    if (_disposed) return;
    await command('stop');
  }

  @override
  Future<Map<String, dynamic>> surfaceStatus() async => const {};

  /// The native pump remembers an output sample only after this epoch is the
  /// one the backend kept. A lost event is published again until then.
  Future<void> acceptOutputSample(int epoch) async {
    if (_disposed || epoch <= 0) return;
    try {
      await _channel.invokeMethod<void>('acceptOutput', {
        'owner': owner,
        'sessionId': _session,
        'epoch': epoch,
      });
    } catch (_) {
      // The next output sample is published again until it is accepted.
    }
  }

  @override
  Widget buildView({Key? key}) => PlatformViewLink(
    key: key,
    viewType: 'rillight/android_core/view',
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    ),
    onCreatePlatformView: (params) =>
        PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: params.viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: {'owner': owner},
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create(),
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod<void>('dispose', {
        'owner': owner,
        'sessionId': _session,
      });
    } finally {
      await _subscription.cancel();
      await _events.close();
    }
  }
}

abstract interface class CoreNativeOverlay {
  ValueListenable<bool> get nativeOverlay;
  Future<Map<String, dynamic>> presentationStatus();
}

class DesktopCorePlayer
    implements CorePlayer, CoreNativeOverlay, CoreNativeSeekCancellation {
  DesktopCorePlayer._(this._bindings, this._handle, this._textureId);

  static const _channel = MethodChannel('rillight_player');
  final CoreBindings _bindings;
  final Pointer<Void> _handle;
  final int _textureId;
  final _nativeOverlay = ValueNotifier(false);
  bool _overlayActivated = false;
  @override
  ValueListenable<bool> get nativeOverlay => _nativeOverlay;
  @override
  Future<Map<String, dynamic>> presentationStatus() async =>
      await _channel.invokeMapMethod<String, dynamic>('status', {
        'handle': _handle.address,
      }) ??
      const {};

  Future<void> _activateOverlay() async {
    if (!_nativeOverlay.value || _overlayActivated || _disposed) return;
    _overlayActivated = true;
    try {
      await _channel.invokeMethod<void>('activateOverlay', {
        'handle': _handle.address,
      });
    } catch (_) {
      if (!_disposed) {
        _events.add(
          CorePlayerEvent(
            _session,
            'error',
            'Native HDR overlay could not be activated',
          ),
        );
      }
    }
  }

  final _events = StreamController<CorePlayerEvent>.broadcast();
  String _session = '';
  int _operation = 0;
  bool _disposed = false;
  Timer? _poll;
  int _previousPosition = -1;
  int _previousDuration = -1;
  int _previousState = -1;
  int _previousTimeline = -1;
  int _outputEpoch = 0;
  CoreOutputSample? _outputCurrent;
  CoreOutputSample? _acceptedOutput;

  static Future<DesktopCorePlayer> create({String? libraryPath}) async {
    final bindings = CoreBindings(libraryPath: libraryPath);
    final handle = bindings.createLoopback();
    if (handle == nullptr) throw StateError('Could not create Rillight core');
    try {
      final texture = await _channel.invokeMethod<int>('create', {
        'handle': handle.address,
      });
      if (texture == null) throw StateError('Core texture was not created');
      final player = DesktopCorePlayer._(bindings, handle, texture);
      if (Platform.isWindows || Platform.isMacOS) {
        final status = await player.presentationStatus();
        player._nativeOverlay.value = status['nativeOverlay'] == true;
      }
      return player;
    } catch (_) {
      // A renderer may have been registered before create reported failure.
      // Keep its core alive if retirement cannot be acknowledged.
      await retireSurface(
        channel: _channel,
        handle: handle.address,
        needsRasterBarrier: Platform.isLinux || Platform.isMacOS,
      );
      await _destroyCore((handle.address, bindings.libraryPath));
      rethrow;
    }
  }

  @override
  Stream<CorePlayerEvent> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen request) async {
    if (_disposed) throw StateError('Core is disposed');
    _session = request.session;
    _serverStreams = request.streams;
    _rejectedAudioStreams.clear();
    _poll?.cancel();
    _previousPosition = _previousDuration = _previousState = _previousTimeline =
        -1;
    _outputEpoch = 0;
    _outputCurrent = null;
    _acceptedOutput = null;
    _check(
      _bindings.configureHardware(
        _handle,
        request.hardware.resolved.nativeValue,
        1,
      ),
      'configure hardware',
    );
    final url = request.url.toString().toNativeUtf8();
    try {
      // The first published picture must already belong to the resume point.
      // Opening at zero and seeking after first-frame readiness briefly shows
      // the opening logo behind the loading UI before clearing it again.
      _check(
        _bindings.openAt(
          _handle,
          url,
          request.start.inMicroseconds.clamp(0, 1 << 62),
          ++_operation,
        ),
        'open',
      );
    } finally {
      calloc.free(url);
    }
    if (request.paused) {
      _check(_bindings.setPlaying(_handle, 0, ++_operation), 'pause');
    }
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed || _session != request.session) {
        throw StateError('Superseded core open');
      }
      final snapshot = _readSnapshot();
      if (snapshot.state == 8) {
        if (snapshot.ffmpegError == CoreVideoCompatibilityException.errorCode) {
          throw const CoreVideoCompatibilityException();
        }
        throw StateError('Core media open failed (${snapshot.ffmpegError})');
      }
      final videoReady =
          snapshot.videoStreamIndex >= 0 && snapshot.firstVideoFrameReady != 0;
      final audioReady =
          snapshot.videoStreamIndex < 0 &&
          snapshot.audioStreamIndex >= 0 &&
          snapshot.firstAudioFrameReady != 0;
      if (snapshot.state >= 2 &&
          snapshot.state <= 6 &&
          (videoReady || audioReady)) {
        if (videoReady) {
          final status = await _channel.invokeMapMethod<String, dynamic>(
            'status',
            {'handle': _handle.address},
          );
          final frames = status?['frames'];
          final renderedTimeline = status?['timeline'];
          if (Platform.isMacOS) {
            _nativeOverlay.value = status?['nativeOverlay'] == true;
          }
          if (frames is! num ||
              frames.toInt() <= 0 ||
              (renderedTimeline is num &&
                  renderedTimeline.toInt() != snapshot.timelineVersion)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue;
          }
        }
        return _finishOutput(_trackResult(snapshot, request.streams), snapshot);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Core did not render the first frame');
  }

  void _tick() {
    if (_disposed || _session.isEmpty) return;
    final snapshot = _readSnapshot();
    if (snapshot.timelineVersion != _previousTimeline) {
      _previousTimeline = snapshot.timelineVersion;
      _previousPosition = -1;
    }
    final position = snapshot.positionUs ~/ 1000;
    final duration = snapshot.durationUs ~/ 1000;
    if (position != _previousPosition) {
      _previousPosition = position;
      _events.add(CorePlayerEvent(_session, 'position', position));
    }
    if (duration != _previousDuration) {
      _previousDuration = duration;
      _events.add(CorePlayerEvent(_session, 'duration', duration));
    }
    if (snapshot.state != _previousState) {
      _previousState = snapshot.state;
      _events.add(
        CorePlayerEvent(
          _session,
          'buffering',
          snapshot.state == 5 || snapshot.state == 6,
        ),
      );
      _events.add(CorePlayerEvent(_session, 'playing', snapshot.state == 3));
      if (snapshot.state == 7) {
        _events.add(CorePlayerEvent(_session, 'completed', true));
      }
      if (snapshot.state == 8) {
        _events.add(
          CorePlayerEvent(
            _session,
            'error',
            'Core playback failed (${snapshot.ffmpegError})',
          ),
        );
      }
    }
    _publishOutput(snapshot);
  }

  // Kind, delivery and enhancement tiers are rewritten on later frames.
  // Remember the sample only after the backend accepts it, so a stale command
  // snapshot cannot suppress the next publish of the same tier.
  void _publishOutput(_CoreSnapshot snapshot) {
    if (_disposed || _session.isEmpty) return;
    final next = _outputSample(snapshot);
    if (next == _acceptedOutput) return;
    final epoch = _observeOutput(next);
    _events.add(
      CorePlayerEvent(
        _session,
        'outputStatus',
        next.toMap()..['outputEpoch'] = epoch,
      ),
    );
  }

  /// Backend kept this epoch. Older command maps must not replace it.
  void acceptOutputSample(int epoch) {
    if (epoch != _outputEpoch || _outputCurrent == null) return;
    _acceptedOutput = _outputCurrent;
  }

  Map<String, Object> _enhancementOrEmpty() {
    try {
      return _readEnhancementStatus();
    } catch (_) {
      // Snapshot fields still carry video kind and audio delivery.
      return const {};
    }
  }

  CoreOutputSample _outputSample(
    _CoreSnapshot snapshot, [
    Map<String, Object>? enhancement,
  ]) {
    final resolved = enhancement ?? _enhancementOrEmpty();
    return CoreOutputSample.fromSnapshot(
      dolbyVisionProfile: snapshot.dolbyVisionProfile,
      dolbyVisionCompatibility: snapshot.dolbyVisionCompatibility,
      videoOutputKind: snapshot.videoOutputKind,
      doviReconstruction: snapshot.doviReconstruction,
      audioDelivery: snapshot.audioDelivery,
      audioChannels: snapshot.audioChannels,
      audioLayout: snapshot.audioLayout,
      audioAtmos: snapshot.audioAtmos,
      audioCodecId: snapshot.audioCodecId,
      requestedInterpolation: snapshot.requestedInterpolation,
      effectiveInterpolation: snapshot.effectiveInterpolation,
      requestedAnime4k: snapshot.requestedAnime4k,
      effectiveAnime4k: snapshot.effectiveAnime4k,
      requestedSuperResolution: snapshot.requestedSuperResolution,
      effectiveSuperResolution: snapshot.effectiveSuperResolution,
      requestedDenoise: snapshot.requestedDenoise,
      effectiveDenoise: snapshot.effectiveDenoise,
      requestedSharpen: snapshot.requestedSharpen,
      effectiveSharpen: snapshot.effectiveSharpen,
      enhancement: resolved,
    );
  }

  int _observeOutput(CoreOutputSample next) {
    if (next == _outputCurrent && _outputEpoch > 0) return _outputEpoch;
    _outputEpoch++;
    _outputCurrent = next;
    return _outputEpoch;
  }

  Map<String, dynamic> _finishOutput(
    Map<String, dynamic> mapped,
    _CoreSnapshot snapshot,
  ) {
    final enhancement = _enhancementOrEmpty();
    // Backend ids stay on the command result. The tick sample also carries
    // outputFrameRate so a later frame does not drop the target rate.
    mapped.addAll(enhancement);
    final sample = _outputSample(snapshot, enhancement);
    mapped['outputEpoch'] = _observeOutput(sample);
    return mapped;
  }

  _CoreSnapshot _readSnapshot() {
    final pointer = calloc<NativeCoreSnapshot>();
    pointer.ref.structSize = sizeOf<NativeCoreSnapshot>();
    try {
      _check(_bindings.snapshot(_handle, pointer), 'snapshot');
      final value = pointer.ref;
      return _CoreSnapshot(
        value.state,
        value.ffmpegError,
        value.videoStreamIndex,
        value.audioStreamIndex,
        value.subtitleStreamIndex,
        value.durationUs,
        value.positionUs,
        value.firstVideoFrameReady,
        value.firstAudioFrameReady,
        value.playbackSpeed,
        value.externalSubtitlePending,
        value.timelineVersion,
        value.sessionId,
        dolbyVisionProfile: value.dolbyVisionProfile,
        videoOutputKind: value.videoOutputKind,
        audioDelivery: value.audioDelivery,
        audioChannels: value.audioChannels,
        audioLayout: value.audioLayout,
        audioAtmos: value.audioAtmos,
        audioCodecId: value.audioCodecId,
        requestedInterpolation: value.requestedInterpolation,
        effectiveInterpolation: value.effectiveInterpolation,
        requestedAnime4k: value.requestedAnime4k,
        effectiveAnime4k: value.effectiveAnime4k,
        requestedSuperResolution: value.requestedSuperResolution,
        effectiveSuperResolution: value.effectiveSuperResolution,
        requestedDenoise: value.requestedDenoise,
        effectiveDenoise: value.effectiveDenoise,
        requestedSharpen: value.requestedSharpen,
        effectiveSharpen: value.effectiveSharpen,
        doviReconstruction: value.doviReconstruction,
        dolbyVisionCompatibility: value.dolbyVisionCompatibility,
      );
    } finally {
      calloc.free(pointer);
    }
  }

  List<CorePlayerTrack> _serverStreams = const [];
  final _rejectedAudioStreams = <int>{};
  Map<String, dynamic> _trackResult(
    _CoreSnapshot snapshot,
    List<CorePlayerTrack> server,
  ) {
    final native = <int, (int, String?)>{};
    final unsupportedAudio = {..._rejectedAudioStreams};
    var actualHardware = 0;
    int? videoTrackId;
    int? audioTrackId;
    final nativeIds = calloc<Int32>(2);
    try {
      if (_bindings.containerTrackIds?.call(
            _handle,
            nativeIds,
            nativeIds + 1,
          ) ==
          0) {
        videoTrackId = nativeIds[0] > 0 ? nativeIds[0] : null;
        audioTrackId = nativeIds[1] > 0 ? nativeIds[1] : null;
      }
    } finally {
      calloc.free(nativeIds);
    }
    final track = calloc<NativeCoreTrack>();
    try {
      for (
        var ordinal = 0;
        ordinal < _bindings.trackCount(_handle);
        ordinal++
      ) {
        track.ref.structSize = sizeOf<NativeCoreTrack>();
        if (_bindings.getTrack(_handle, ordinal, track) != 0) continue;
        if (track.ref.type == 1 &&
            track.ref.streamIndex == snapshot.videoStreamIndex) {
          actualHardware = track.ref.actualHardware;
        }
        native[track.ref.streamIndex] = (
          track.ref.type,
          _cstring(track.ref.language),
        );
        if (track.ref.type == 2 &&
            !_bindings.decoderAvailable(_cstring(track.ref.codecName) ?? '')) {
          unsupportedAudio.add(track.ref.streamIndex);
        }
      }
    } finally {
      calloc.free(track);
    }
    final mapped = <int, int>{};
    final used = <int>{};
    for (final item in server.where((item) => !item.isExternal)) {
      final type = switch (item.type) {
        'Video' => 1,
        'Audio' => 2,
        'Subtitle' => 3,
        _ => 0,
      };
      final candidates = native.entries.where(
        (entry) => entry.value.$1 == type && !used.contains(entry.key),
      );
      final exact = candidates
          .where((entry) => entry.key == item.index)
          .firstOrNull;
      final byLanguage = candidates
          .where(
            (entry) => item.language != null && entry.value.$2 == item.language,
          )
          .toList();
      final chosen =
          exact ??
          (byLanguage.length == 1
              ? byLanguage.single
              : candidates.length == 1
              ? candidates.first
              : null);
      if (chosen != null) {
        mapped[item.index] = chosen.key;
        used.add(chosen.key);
      }
    }
    _trackMap = mapped;
    return {
      // The decoded hardware of the selected video track, not the preference.
      'actualHardware': actualHardware,
      'videoTrackId': videoTrackId,
      'audioTrackId': audioTrackId,
      'audioIndex': mapped.entries
          .where((entry) => entry.value == snapshot.audioStreamIndex)
          .firstOrNull
          ?.key,
      'subtitleIndex': mapped.entries
          .where((entry) => entry.value == snapshot.subtitleStreamIndex)
          .firstOrNull
          ?.key,
      'playableAudio': [
        for (final item in server.where((item) => item.type == 'Audio'))
          if (mapped.containsKey(item.index) &&
              !unsupportedAudio.contains(mapped[item.index]))
            item.index,
      ],
      'rejectedAudio': [
        for (final item in server.where((item) => item.type == 'Audio'))
          if (!mapped.containsKey(item.index) ||
              unsupportedAudio.contains(mapped[item.index]))
            item.index,
      ],
      'playableSubtitle': [
        for (final item in server.where((item) => item.type == 'Subtitle'))
          if (mapped.containsKey(item.index)) item.index,
      ],
      'rejectedSubtitle': [
        for (final item in server.where(
          (item) => item.type == 'Subtitle' && !item.isExternal,
        ))
          if (!mapped.containsKey(item.index)) item.index,
      ],
      'dolbyVisionProfile': snapshot.dolbyVisionProfile,
      'videoOutputKind': snapshot.videoOutputKind,
      'audioDelivery': snapshot.audioDelivery,
      'audioChannels': snapshot.audioChannels,
      'audioLayout': snapshot.audioLayout,
      'audioAtmos': snapshot.audioAtmos,
      'audioCodecId': snapshot.audioCodecId,
      'requestedInterpolation': snapshot.requestedInterpolation,
      'effectiveInterpolation': snapshot.effectiveInterpolation,
      'requestedAnime4k': snapshot.requestedAnime4k,
      'effectiveAnime4k': snapshot.effectiveAnime4k,
      'requestedSuperResolution': snapshot.requestedSuperResolution,
      'effectiveSuperResolution': snapshot.effectiveSuperResolution,
      'requestedDenoise': snapshot.requestedDenoise,
      'effectiveDenoise': snapshot.effectiveDenoise,
      'requestedSharpen': snapshot.requestedSharpen,
      'effectiveSharpen': snapshot.effectiveSharpen,
      'doviReconstruction': snapshot.doviReconstruction,
      'dolbyVisionCompatibility': snapshot.dolbyVisionCompatibility,
    };
  }

  Map<int, int> _trackMap = const {};
  static String? _cstring(Array<Uint8> bytes) {
    final values = <int>[];
    for (var index = 0; index < 32; index++) {
      if (bytes[index] == 0) break;
      values.add(bytes[index]);
    }
    return values.isEmpty ? null : String.fromCharCodes(values).toLowerCase();
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_disposed) throw StateError('Core is disposed');
    var result = 0;
    final selectedStream = method == 'audio' || method == 'subtitle'
        ? _mapped(args['index'])
        : method == 'subtitleOff'
        ? -1
        : null;
    final timelineBefore = method == 'seek'
        ? _readSnapshot().timelineVersion
        : 0;
    switch (method) {
      case 'play':
        result = _bindings.setPlaying(_handle, 1, ++_operation);
      case 'pause':
        result = _bindings.setPlaying(_handle, 0, ++_operation);
      case 'seek':
        result = _bindings.seek(
          _handle,
          ((args['position'] as num).toInt() * 1000),
          ++_operation,
        );
      case 'rate':
        result = _bindings.setSpeed(
          _handle,
          (args['value'] as num).toDouble(),
          ++_operation,
        );
      case 'audio':
        result = _bindings.selectAudio(_handle, selectedStream!, ++_operation);
      case 'subtitle':
        result = _bindings.selectSubtitle(
          _handle,
          selectedStream!,
          ++_operation,
        );
      case 'subtitlePresentation':
        final presentation = calloc<NativeSubtitlePresentation>();
        try {
          presentation.ref
            ..structSize = sizeOf<NativeSubtitlePresentation>()
            ..version = 1
            ..enabled = 1
            ..originalAss = args['originalAss'] == true ? 1 : 0
            ..displayWidth = (args['displayWidth'] as num).toDouble()
            ..displayHeight = (args['displayHeight'] as num).toDouble()
            ..fontSize = (args['fontSize'] as num).toDouble()
            ..userScale = (args['userScale'] as num).toDouble()
            ..safeHorizontal = (args['safeHorizontal'] as num).toDouble()
            ..safeVertical = (args['safeVertical'] as num).toDouble();
          result = _bindings.setSubtitlePresentation(
            _handle,
            presentation,
            _readSnapshot().sessionId,
          );
        } finally {
          calloc.free(presentation);
        }
      case 'subtitleOff':
        result = _bindings.selectSubtitle(_handle, -1, ++_operation);
      case 'subtitleUri':
        final url = (args['url'] as String).toNativeUtf8();
        try {
          result = _bindings.addExternalSubtitle(_handle, url, ++_operation);
        } finally {
          calloc.free(url);
        }
      case 'volume':
        result = _bindings.setVolume(
          _handle,
          (args['value'] as num).toDouble().clamp(0.0, 1.5),
          ++_operation,
        );
      case 'enhancement':
        final request = calloc<NativeEnhancementRequest>();
        try {
          request.ref
            ..structSize = sizeOf<NativeEnhancementRequest>()
            ..interpolation = (args['interpolation'] as num?)?.toInt() ?? 0
            ..anime4k = (args['anime4k'] as num?)?.toInt() ?? 0
            ..superResolution = (args['superResolution'] as num?)?.toInt() ?? 0
            ..denoise = (args['denoise'] as num?)?.toInt() ?? 0
            ..sharpen = (args['sharpen'] as num?)?.toInt() ?? 0
            ..acceptLeaveNativeDolby = args['acceptLeaveNativeDolby'] == true
                ? 1
                : 0
            ..displayRefreshHz =
                (args['displayRefreshHz'] as num?)?.toInt() ?? 0;
          result = _bindings.configureEnhancement(_handle, request);
        } finally {
          calloc.free(request);
        }
      case 'frameDeadline':
        result = _bindings.noteFrameDeadline(
          _handle,
          args['met'] == true ? 1 : 0,
          (args['monotonicUs'] as num?)?.toInt() ?? -1,
        );
      case 'outputStatus':
        result = 0;
      default:
        throw UnsupportedError('Unknown core command $method');
    }
    if (result != 0 && method == 'audio' && _readSnapshot().state != 8) {
      _rejectedAudioStreams.add(selectedStream!);
      throw CoreTrackSelectionException(method, result);
    }
    _check(result, method);
    _CoreSnapshot snapshot;
    if (method == 'seek') {
      // The native seek call only queues a timeline change. Complete this
      // command after the new timeline has decoded media so a following rate
      // or track command cannot invalidate an in-flight FFmpeg seek.
      snapshot = await _waitSnapshot(
        (value) =>
            value.timelineVersion > timelineBefore &&
            value.state >= 2 &&
            value.state <= 5 &&
            (value.firstVideoFrameReady != 0 ||
                value.firstAudioFrameReady != 0),
      );
    } else if (method == 'audio') {
      try {
        snapshot = await _waitSnapshot(
          (value) =>
              value.audioStreamIndex == selectedStream && value.state != 6,
          trackSelection: method,
        );
      } on CoreTrackSelectionException {
        _rejectedAudioStreams.add(selectedStream!);
        rethrow;
      }
    } else if (method == 'subtitle' || method == 'subtitleOff') {
      snapshot = await _waitSnapshot(
        (value) =>
            value.subtitleStreamIndex == selectedStream && value.state != 6,
      );
    } else if (method == 'subtitleUri') {
      await _waitSnapshot((value) => value.externalSubtitlePending == 0);
      final external = _latestExternalSubtitle();
      if (external == null) {
        throw StateError(
          'External subtitle failed to load (${_readSnapshot().ffmpegError})',
        );
      }
      _check(
        _bindings.selectSubtitle(_handle, external, ++_operation),
        'external subtitle selection',
      );
      snapshot = await _waitSnapshot(
        (value) => value.subtitleStreamIndex == external && value.state != 6,
      );
    } else if (method == 'rate') {
      final speed = (args['value'] as num).toDouble();
      snapshot = await _waitSnapshot(
        (value) =>
            (value.playbackSpeed - speed).abs() < 0.001 && value.state != 6,
      );
    } else {
      snapshot = _readSnapshot();
    }
    return _finishOutput(_trackResult(snapshot, _serverStreams), snapshot);
  }

  Map<String, Object> _readEnhancementStatus() {
    final pointer = calloc<NativeEnhancementStatus>();
    pointer.ref.structSize = sizeOf<NativeEnhancementStatus>();
    try {
      _check(
        _bindings.enhancementStatus(_handle, pointer),
        'enhancement status',
      );
      final value = pointer.ref;
      return {
        'requestedInterpolation': value.requestedInterpolation,
        'effectiveInterpolation': value.effectiveInterpolation,
        'requestedAnime4k': value.requestedAnime4k,
        'effectiveAnime4k': value.effectiveAnime4k,
        'requestedSuperResolution': value.requestedSuperResolution,
        'effectiveSuperResolution': value.effectiveSuperResolution,
        'requestedDenoise': value.requestedDenoise,
        'effectiveDenoise': value.effectiveDenoise,
        'requestedSharpen': value.requestedSharpen,
        'effectiveSharpen': value.effectiveSharpen,
        'reasonInterpolation': value.reasonInterpolation,
        'reasonAnime4k': value.reasonAnime4k,
        'reasonSuperResolution': value.reasonSuperResolution,
        'reasonDenoise': value.reasonDenoise,
        'reasonSharpen': value.reasonSharpen,
        'interpolationBackend': value.interpolationBackend,
        'anime4kBackend': value.anime4kBackend,
        'superResolutionBackend': value.superResolutionBackend,
        'leftNativeDolby': value.leftNativeDolby,
        'sourceFrameRate': value.sourceFrameRate,
        'outputFrameRate': value.outputFrameRate,
      };
    } finally {
      calloc.free(pointer);
    }
  }

  Future<_CoreSnapshot> _waitSnapshot(
    bool Function(_CoreSnapshot) accept, {
    String? trackSelection,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) throw StateError('Core was disposed during command');
      final value = _readSnapshot();
      if (value.state == 8) {
        throw StateError('Core command failed (${value.ffmpegError})');
      }
      if (accept(value)) return value;
      if (trackSelection != null && value.state != 6 && value.ffmpegError < 0) {
        // A rejected optional audio change preserves the previous decoder.
        // Report that rejection immediately, rather than timing out and
        // turning otherwise healthy playback into a failed open.
        throw CoreTrackSelectionException(trackSelection, value.ffmpegError);
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    final last = _readSnapshot();
    throw TimeoutException(
      'Core did not confirm command '
      '(state=${last.state}, timeline=${last.timelineVersion}, '
      'video=${last.firstVideoFrameReady}, audio=${last.firstAudioFrameReady}, '
      'error=${last.ffmpegError})',
    );
  }

  int? _latestExternalSubtitle() {
    final track = calloc<NativeCoreTrack>();
    int? selected;
    try {
      for (
        var ordinal = 0;
        ordinal < _bindings.trackCount(_handle);
        ordinal++
      ) {
        track.ref.structSize = sizeOf<NativeCoreTrack>();
        if (_bindings.getTrack(_handle, ordinal, track) == 0 &&
            track.ref.type == 3 &&
            track.ref.isExternal != 0) {
          selected = track.ref.streamIndex;
        }
      }
    } finally {
      calloc.free(track);
    }
    return selected;
  }

  int _mapped(Object? index) {
    final stream = _trackMap[(index as num).toInt()];
    if (stream == null) throw StateError('Container track cannot be mapped');
    return stream;
  }

  void _check(int result, String action) {
    if (result != 0) throw StateError('Core rejected $action ($result)');
  }

  @override
  Future<void> stop() async {
    _poll?.cancel();
    _session = '';
    if (!_disposed) {
      try {
        await command('pause');
      } catch (_) {
        // A failed or not-yet-open core has no active audio to pause.
      }
    }
  }

  @override
  Widget buildView({Key? key}) => _DesktopCoreView(key: key, player: this);

  Future<void> resize(int width, int height) => _channel.invokeMethod<void>(
    'resize',
    {'handle': _handle.address, 'width': width, 'height': height},
  );

  @override
  Future<Map<String, dynamic>> surfaceStatus() async {
    final status = await _channel.invokeMapMethod<String, dynamic>('status', {
      'handle': _handle.address,
    });
    return status ?? const {};
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    _session = '';
    await retireSurface(
      channel: _channel,
      handle: _handle.address,
      needsRasterBarrier: Platform.isLinux || Platform.isMacOS,
    );
    await _destroyCore((_handle.address, _bindings.libraryPath));
    await _events.close();
    _nativeOverlay.dispose();
  }
}

Future<void> _destroyCore((int, String) identity) => Isolate.run(() {
  final bindings = CoreBindings(libraryPath: identity.$2);
  bindings.destroyLoopback(Pointer<Void>.fromAddress(identity.$1));
});

class _DesktopCoreView extends StatefulWidget {
  const _DesktopCoreView({super.key, required this.player});
  final DesktopCorePlayer player;
  @override
  State<_DesktopCoreView> createState() => _DesktopCoreViewState();
}

class _DesktopCoreViewState extends State<_DesktopCoreView>
    with SingleTickerProviderStateMixin {
  Size? _lastSize;
  final _textureKey = GlobalKey();
  late final Ticker _textureTicker;
  StreamSubscription<CorePlayerEvent>? _surfaceEvents;

  @override
  void initState() {
    super.initState();
    _textureTicker = createTicker((_) {
      // Keep the texture participating in Windows vsync while playing.
      // Native notifications arriving during rasterization can be coalesced;
      // repaint only the texture, without rebuilding player controls.
      _textureKey.currentContext?.findRenderObject()?.markNeedsPaint();
    });
    _listenToPlayer();
  }

  void _listenToPlayer() {
    widget.player.nativeOverlay.addListener(_onPresentationChanged);
    _setTexturePlaying(widget.player._previousState == 3);
    _surfaceEvents = widget.player.events.listen((event) {
      if (event.kind == 'playing') _setTexturePlaying(event.value == true);
    }, onDone: () => _setTexturePlaying(false));
  }

  void _setTexturePlaying(bool playing) {
    if (Platform.isWindows && playing && !widget.player._nativeOverlay.value) {
      if (!_textureTicker.isActive) _textureTicker.start();
    } else {
      _textureTicker.stop();
    }
  }

  void _onPresentationChanged() {
    _setTexturePlaying(widget.player._previousState == 3);
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _DesktopCoreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.nativeOverlay.removeListener(_onPresentationChanged);
      unawaited(_surfaceEvents?.cancel());
      _listenToPlayer();
    }
  }

  @override
  void dispose() {
    widget.player.nativeOverlay.removeListener(_onPresentationChanged);
    unawaited(_surfaceEvents?.cancel());
    _textureTicker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final size = Size(
        constraints.maxWidth * ratio,
        constraints.maxHeight * ratio,
      );
      if (size.width.isFinite && size.height.isFinite && size != _lastSize) {
        _lastSize = size;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(
              widget.player.resize(size.width.round(), size.height.round()),
            );
          }
        });
      }
      if (widget.player._nativeOverlay.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(widget.player._activateOverlay());
        });
        return const SizedBox.expand();
      }
      return RepaintBoundary(
        child: Texture(
          key: _textureKey,
          textureId: widget.player._textureId,
          // Windows scales in the core. macOS keeps the view aspect and uploads
          // at most the source resolution, so this sampler does the Retina scale.
          // Bilinear avoids generating mipmaps for every uploaded video frame.
          filterQuality: FilterQuality.low,
        ),
      );
    },
  );
}
