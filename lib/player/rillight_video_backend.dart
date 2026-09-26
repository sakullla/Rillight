import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_transport_session.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_player/rillight_player.dart';

typedef CorePlayerFactory = Future<CorePlayer> Function();

/// A single app contract for the owned FFmpeg core on desktop and Android.
/// Source credentials stay inside the transport isolate; native code sees
/// only one sealed loopback URL for each registered resource.
class RillightVideoBackend extends VideoBackend
    implements
        VideoBackendCapabilities,
        VideoBackendTranscodeSubtitles,
        VideoBackendTrackSupport {
  RillightVideoBackend({
    PlayerSettingsStore? settingsStore,
    CorePlayerFactory? createPlayer,
    Directory? diskCacheDirectory,
  }) : _settingsStore = settingsStore,
       _createPlayer = createPlayer ?? CorePlayer.create,
       _diskCacheDirectory = diskCacheDirectory,
       _player = Platform.isAndroid && createPlayer == null
           ? AndroidCorePlayer()
           : null;

  PlayerSettingsStore? _settingsStore;
  final CorePlayerFactory _createPlayer;
  final Directory? _diskCacheDirectory;
  final _events = StreamController<VideoBackendEvent>.broadcast();
  final _nativeEvents = StreamController<Map<String, dynamic>>.broadcast();
  CorePlayer? _player;
  PlaybackTransportSession? _transport;
  StreamSubscription<CorePlayerEvent>? _coreEvents;
  Timer? _diagnosticsTimer;
  bool _diagnosticsBusy = false;
  bool _disposed = false;
  int _generation = 0;
  int _sessionId = 0;
  String _coreSession = '';
  int _bufferSequence = 0;
  int _lastProxySequence = -1;
  int _trackVersion = 0;
  Set<int> _playableAudio = const {};
  Set<int> _rejectedAudio = const {};
  Set<int> _playableSubtitle = const {};
  Set<int> _rejectedSubtitle = const {};
  bool _trackSupportKnown = false;
  String? _lastFailure;
  String? _lastCoreEvent;
  Map<String, Object?> _lastTransportDiagnostics = const {};
  bool _authenticationReported = false;
  VideoOpenRequest? _lastOpenRequest;
  bool _opened = false;
  bool _wantsPlayback = true;
  bool _recovering = false;
  int _recoveryEpoch = 0;
  Uri? _selectedSubtitleUri;
  String? _selectedSubtitleTitle;
  double _volume = 1;
  double _rate = 1;

  @override
  Duration position = Duration.zero;
  @override
  Duration duration = Duration.zero;
  @override
  Duration buffer = Duration.zero;
  @override
  bool isPlaying = false;
  @override
  int? selectedAudioIndex;
  @override
  int? selectedSubtitleIndex;
  BufferSnapshot bufferSnapshot = BufferSnapshot.empty(
    sessionId: 0,
    unknownReason: 'notOpened',
  );

  @override
  Stream<VideoBackendEvent> get events => _events.stream;
  Stream<Map<String, dynamic>> get nativeEvents => _nativeEvents.stream;
  String? get lastFailure => _lastFailure;

  Future<Map<String, Object?>> diagnostics() async {
    Map<String, Object?> transport = _lastTransportDiagnostics;
    final active = _transport;
    if (active != null) {
      try {
        transport = await active.diagnostics;
        _lastTransportDiagnostics = transport;
      } catch (_) {
        // The last sample remains useful after a stopped or failed session.
      }
    }
    return {
      ...transport,
      'backendSessionId': _sessionId,
      'coreSession': _coreSession,
      'corePlaying': isPlaying,
      'corePositionMs': position.inMilliseconds,
      'coreDurationMs': duration.inMilliseconds,
      'coreLastEvent': _lastCoreEvent,
      'selectedAudioIndex': selectedAudioIndex,
      'selectedSubtitleIndex': selectedSubtitleIndex,
      'bufferIdentity': bufferSnapshot.representationVersion,
      'bufferUnknownReason': bufferSnapshot.unknownReason,
      'bufferRanges': [
        for (final range in bufferSnapshot.ranges)
          {
            'startMs': range.start.inMilliseconds,
            'endMs': range.end.inMilliseconds,
          },
      ],
      'lastFailure': _lastFailure,
    };
  }

  Stream<T> _values<T>(VideoEventKind kind) => events
      .where((event) => event.kind == kind)
      .map((event) => event.value as T);
  @override
  Stream<Duration> get positionStream => _values(VideoEventKind.position);
  @override
  Stream<Duration> get durationStream => _values(VideoEventKind.duration);
  @override
  Stream<Duration> get bufferStream => _values(VideoEventKind.buffer);
  @override
  Stream<bool> get playingStream => _values(VideoEventKind.playing);
  @override
  Stream<bool> get completedStream => _values(VideoEventKind.completed);
  @override
  Stream<String> get errorStream => _values(VideoEventKind.error);

  void _emit(VideoEventKind kind, Object value, int generation) {
    if (!_disposed && generation == _generation) {
      _events.add(VideoBackendEvent(_sessionId, kind, value));
    }
  }

  @override
  Future<Map<String, dynamic>> deviceProfile(int maxStreamingBitrate) async {
    if (Platform.isAndroid) {
      final player = _player;
      final capabilities = player is AndroidCorePlayer
          ? await player.capabilities()
          : const <String, dynamic>{};
      return ownedCoreDeviceProfile(
        h264: capabilities['h264'] == true,
        aac: capabilities['aac'] == true,
        maxStreamingBitrate: maxStreamingBitrate.clamp(1, 20000000),
      );
    }
    return ownedCoreDeviceProfile(
      h264: true,
      aac: true,
      maxStreamingBitrate: maxStreamingBitrate,
    );
  }

  @override
  TranscodeSubtitleDelivery transcodeSubtitleDelivery(MediaStreamInfo stream) {
    switch (stream.deliveryMethod?.toLowerCase()) {
      case 'encode':
        return TranscodeSubtitleDelivery.burnIn;
      case 'external':
        return TranscodeSubtitleDelivery.external;
      case 'hls':
      case 'embed':
        return TranscodeSubtitleDelivery.manifest;
    }
    return const {
          'srt',
          'subrip',
          'vtt',
          'webvtt',
        }.contains(stream.codec?.toLowerCase())
        ? TranscodeSubtitleDelivery.external
        : TranscodeSubtitleDelivery.burnIn;
  }

  @override
  bool? audioTrackSupported(int index) =>
      _support(index, _playableAudio, _rejectedAudio);
  @override
  bool? subtitleTrackSupported(int index) =>
      _support(index, _playableSubtitle, _rejectedSubtitle);
  bool? _support(int index, Set<int> playable, Set<int> rejected) {
    if (!_trackSupportKnown) return null;
    if (rejected.contains(index)) return false;
    if (playable.contains(index)) return true;
    return null;
  }

  @override
  Future<void> open(VideoOpenRequest request) async {
    ++_recoveryEpoch;
    _recovering = false;
    _lastOpenRequest = request;
    _wantsPlayback = !request.startPaused;
    _selectedSubtitleUri = null;
    _selectedSubtitleTitle = null;
    await _open(request);
  }

  Future<void> _open(VideoOpenRequest request) async {
    if (_disposed) throw StateError('Player backend disposed');
    final generation = ++_generation;
    final sameSession = _sessionId == request.sessionId;
    _sessionId = request.sessionId;
    _coreSession = 'app-${request.sessionId}-$generation';
    position = request.start;
    duration = buffer = Duration.zero;
    isPlaying = false;
    selectedAudioIndex = selectedSubtitleIndex = null;
    if (sameSession) {
      ++_trackVersion;
      ++_bufferSequence;
    } else {
      _trackVersion = _bufferSequence = 0;
    }
    _lastProxySequence = -1;
    _trackSupportKnown = false;
    _opened = false;
    _lastFailure = null;
    _lastCoreEvent = null;
    _lastTransportDiagnostics = const {};
    _authenticationReported = false;
    bufferSnapshot = BufferSnapshot.empty(
      sessionId: request.sessionId,
      resourceId: request.url.toString(),
      trackVersion: _trackVersion,
      sequence: _bufferSequence,
      unknownReason: sameSession ? 'reconnecting' : 'preparing',
    );
    _emit(VideoEventKind.bufferSnapshot, bufferSnapshot, generation);
    await _stopSession(keepAndroidPlayer: true);
    if (_disposed || generation != _generation) return;
    try {
      final settings =
          await (_settingsStore ??= await openPlayerSettingsStore()).read();
      final transport = await PlaybackTransportSession.start(
        origin: request.credentialOrigin,
        headers: request.credentialHeaders.isNotEmpty
            ? request.credentialHeaders
            : request.headers,
        cacheRoot: _diskCacheDirectory ?? PlayerDiskCache.defaultDirectory(),
        memoryLimitBytes: 8 * 1024 * 1024,
        pendingLimitBytes: 2 * 1024 * 1024,
        diskLimitBytes: PlayerRuntimeOptions.effectiveDiskCacheLimitBytes(
          settings,
        ),
        readAheadBytes: 512 * 1024 * 1024,
        dynamicSource: request.dynamicSource,
        sessionBuffering: true,
      );
      if (_disposed || generation != _generation) {
        await transport.close();
        return;
      }
      _transport = transport;
      final sealed = await transport.register(request.url);
      if (_disposed || generation != _generation) return;
      final player = _player ??= await _createPlayer();
      if (_disposed || generation != _generation) {
        if (!Platform.isAndroid) await player.dispose();
        return;
      }
      _coreEvents = player.events.listen(
        (event) => _onCoreEvent(event, generation),
      );
      final result = await player.open(
        CorePlayerOpen(
          url: sealed,
          session: _coreSession,
          start: request.start,
          paused: request.startPaused,
          streams: [
            for (final stream in request.mediaStreams)
              CorePlayerTrack(
                index: stream.index,
                type: stream.type,
                language: stream.language,
                isExternal:
                    stream.type == 'Subtitle' &&
                    (request.playMethod == PlayMethod.transcode
                        ? transcodeSubtitleDelivery(stream) !=
                              TranscodeSubtitleDelivery.manifest
                        : stream.isExternal),
              ),
          ],
        ),
      );
      if (_disposed || generation != _generation) return;
      _readTrackSupport(result);
      selectedAudioIndex = result['audioIndex'] as int?;
      selectedSubtitleIndex = result['subtitleIndex'] as int?;
      _opened = true;
      _diagnosticsTimer = Timer.periodic(const Duration(milliseconds: 250), (
        _,
      ) {
        unawaited(_refreshDiagnostics(generation));
      });
      unawaited(_refreshDiagnostics(generation));
    } catch (error) {
      if (generation == _generation) {
        _lastFailure = error.toString();
        try {
          _lastTransportDiagnostics = await _transport?.diagnostics ?? const {};
          _reportAuthentication(_lastTransportDiagnostics, generation);
        } catch (_) {}
        await _stopSession(keepAndroidPlayer: true);
      }
      rethrow;
    }
  }

  void _onCoreEvent(CorePlayerEvent event, int generation) {
    if (event.session != _coreSession ||
        generation != _generation ||
        _disposed) {
      return;
    }
    _lastCoreEvent = event.kind;
    _nativeEvents.add({'kind': event.kind, 'value': event.value});
    switch (event.kind) {
      case 'position':
        position = Duration(
          milliseconds: (event.value as num).toInt().clamp(0, 1 << 52),
        );
        _emit(VideoEventKind.position, position, generation);
      case 'duration':
        duration = Duration(
          milliseconds: (event.value as num).toInt().clamp(0, 1 << 52),
        );
        _emit(VideoEventKind.duration, duration, generation);
      case 'playing':
        isPlaying = event.value == true;
        _emit(VideoEventKind.playing, isPlaying, generation);
      case 'buffering':
        _emit(VideoEventKind.buffering, event.value == true, generation);
      case 'completed':
        _emit(VideoEventKind.completed, event.value == true, generation);
      case 'error':
        isPlaying = false;
        _lastFailure = event.value.toString();
        if (_opened) {
          unawaited(_recoverFromCoreError(event.value.toString(), generation));
        } else if (!_recovering) {
          _emit(VideoEventKind.error, event.value.toString(), generation);
        }
      case 'authenticationRequired':
        _emit(VideoEventKind.authenticationRequired, event.value, generation);
      case 'interruption':
        isPlaying = false;
        _emit(VideoEventKind.playing, false, generation);
      default:
        break;
    }
  }

  void _reportAuthentication(Map<String, Object?> data, int generation) {
    if (_authenticationReported || generation != _generation) return;
    final status = data['authenticationStatus'];
    if (status != 401 && status != 403) return;
    _authenticationReported = true;
    _nativeEvents.add({'kind': 'authenticationRequired', 'value': status});
    _emit(VideoEventKind.authenticationRequired, status as int, generation);
  }

  Future<void> _recoverFromCoreError(String failure, int generation) async {
    if (_recovering || generation != _generation || _disposed) return;
    _recovering = true;
    final epoch = _recoveryEpoch;
    final request = _lastOpenRequest;
    final selectedAudio = selectedAudioIndex;
    final selectedSubtitle = selectedSubtitleIndex;
    final selectedUri = _selectedSubtitleUri;
    final selectedTitle = _selectedSubtitleTitle;
    try {
      Map<String, Object?> data = const {};
      try {
        data = await _transport?.diagnostics ?? const {};
        _lastTransportDiagnostics = data;
      } catch (_) {}
      if (epoch != _recoveryEpoch || _disposed) return;
      _reportAuthentication(data, generation);
      final status = data['lastUpstreamStatus'];
      final retryableStatus =
          status == 408 ||
          status == 429 ||
          (status is int && status >= 500 && status <= 599);
      final exhaustedTransport =
          ((data['recoveryFailures'] as num?)?.toInt() ?? 0) > 0;
      if (request == null ||
          _authenticationReported ||
          (!retryableStatus && !exhaustedTransport)) {
        _emit(VideoEventKind.error, failure, generation);
        return;
      }
      _emit(VideoEventKind.buffering, true, generation);
      for (var attempt = 0; attempt < 2; attempt++) {
        if (epoch != _recoveryEpoch || _disposed) return;
        await Future<void>.delayed(Duration(seconds: attempt + 1));
        if (epoch != _recoveryEpoch || _disposed) return;
        try {
          await _open(
            VideoOpenRequest(
              sessionId: request.sessionId,
              url: request.url,
              start: position,
              headers: request.headers,
              credentialOrigin: request.credentialOrigin,
              credentialHeaders: request.credentialHeaders,
              playMethod: request.playMethod,
              isInfiniteStream: request.isInfiniteStream,
              mediaStreams: request.mediaStreams,
              startPaused: !_wantsPlayback,
            ),
          );
          if (epoch != _recoveryEpoch || _disposed) return;
          if (selectedAudio != null) await setAudioIndex(selectedAudio);
          if (selectedUri != null) {
            await setSubtitleUri(selectedUri, title: selectedTitle);
          } else if (selectedSubtitle != null) {
            await setSubtitleIndex(selectedSubtitle);
          }
          await _command('volume', {'value': _volume});
          await _command('rate', {'value': _rate});
          await _command(_wantsPlayback ? 'play' : 'pause');
          _lastFailure = null;
          _emit(VideoEventKind.buffering, false, _generation);
          return;
        } catch (error) {
          failure = error.toString();
          if (epoch != _recoveryEpoch || _disposed) return;
          final auth = _lastTransportDiagnostics['authenticationStatus'];
          if (auth == 401 || auth == 403) return;
        }
      }
      _emit(VideoEventKind.error, failure, _generation);
    } finally {
      if (epoch == _recoveryEpoch) _recovering = false;
    }
  }

  Future<void> _refreshDiagnostics(int generation) async {
    final transport = _transport;
    if (_diagnosticsBusy || transport == null || generation != _generation) {
      return;
    }
    _diagnosticsBusy = true;
    final trackVersion = _trackVersion;
    try {
      if (duration > Duration.zero) await transport.refreshTimeline(duration);
      final data = await transport.diagnostics;
      _lastTransportDiagnostics = data;
      _reportAuthentication(data, generation);
      if (generation != _generation ||
          _disposed ||
          trackVersion != _trackVersion) {
        return;
      }
      final identity = data['timelineIdentity']?.toString() ?? '';
      final sequence = data['timelineSequence'] is num
          ? (data['timelineSequence'] as num).toInt()
          : 0;
      if (sequence < _lastProxySequence) return;
      _lastProxySequence = sequence;
      _bufferSequence = sequence > _bufferSequence
          ? sequence
          : _bufferSequence + 1;
      final unknown = data['timelineUnknownReason']?.toString();
      final ranges = <BufferedRange>[];
      if (unknown == null && data['cachedTimeRanges'] is List) {
        for (final raw in data['cachedTimeRanges'] as List) {
          if (raw is! Map || raw['startMs'] is! num || raw['endMs'] is! num) {
            continue;
          }
          ranges.add(
            BufferedRange(
              Duration(milliseconds: (raw['startMs'] as num).toInt()),
              Duration(milliseconds: (raw['endMs'] as num).toInt()),
            ),
          );
        }
      }
      bufferSnapshot = BufferSnapshot(
        sessionId: _sessionId,
        resourceId: identity.isEmpty ? '' : identity,
        representationVersion: identity,
        trackVersion: _trackVersion,
        sequence: _bufferSequence,
        ranges: ranges,
        unknownReason: unknown,
        duration: duration,
      );
      _emit(VideoEventKind.bufferSnapshot, bufferSnapshot, generation);
      final rate = data['upstreamBytesPerSecond'];
      if (rate is num) {
        _emit(VideoEventKind.cacheSpeed, rate.toDouble(), generation);
      }
    } catch (_) {
      if (generation == _generation && !_disposed) {
        bufferSnapshot = BufferSnapshot.empty(
          sessionId: _sessionId,
          trackVersion: _trackVersion,
          sequence: ++_bufferSequence,
          unknownReason: 'cacheUnavailable',
        );
        _emit(VideoEventKind.bufferSnapshot, bufferSnapshot, generation);
      }
    } finally {
      _diagnosticsBusy = false;
    }
  }

  Set<int> _indices(Object? raw) => raw is List
      ? {
          for (final item in raw)
            if (item is num) item.toInt(),
        }
      : const {};
  void _readTrackSupport(Map<String, dynamic> result) {
    if (!result.containsKey('rejectedAudio')) return;
    _trackSupportKnown = true;
    _playableAudio = _indices(result['playableAudio']);
    _rejectedAudio = _indices(result['rejectedAudio']);
    _playableSubtitle = _indices(result['playableSubtitle']);
    _rejectedSubtitle = _indices(result['rejectedSubtitle']);
  }

  Future<void> _command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final generation = _generation;
    final player = _player;
    if (player == null) throw StateError('Player has not opened');
    final result = await player.command(method, args);
    if (generation != _generation) {
      throw StateError('Superseded player command');
    }
    _readTrackSupport(result);
    selectedAudioIndex = result['audioIndex'] as int?;
    selectedSubtitleIndex = result['subtitleIndex'] as int?;
  }

  void _invalidateTrack() {
    bufferSnapshot = BufferSnapshot.empty(
      sessionId: _sessionId,
      trackVersion: ++_trackVersion,
      sequence: ++_bufferSequence,
      unknownReason: 'trackChanged',
    );
    _emit(VideoEventKind.bufferSnapshot, bufferSnapshot, _generation);
  }

  @override
  Future<void> play() async {
    _wantsPlayback = true;
    if (_recovering) return;
    await _command('play');
    isPlaying = true;
  }

  @override
  Future<void> pause() async {
    _wantsPlayback = false;
    if (_recovering) return;
    await _command('pause');
    isPlaying = false;
  }

  @override
  Future<void> playOrPause() => isPlaying ? pause() : play();
  @override
  Future<void> seek(Duration value) async {
    if (_recovering) {
      position = value;
      return;
    }
    await _transport?.seek();
    await _command('seek', {'position': value.inMilliseconds});
  }

  @override
  Future<void> setVolume(double value) async {
    _volume = value / 100;
    if (_recovering) return;
    await _command('volume', {'value': _volume});
  }

  @override
  Future<void> setRate(double value) async {
    _rate = value;
    if (_recovering) return;
    await _command('rate', {'value': value});
  }

  Future<void> setVideoScale(String mode) async {
    final player = _player;
    if (player is AndroidCorePlayer) {
      await player.command('setVideoScale', {'mode': mode});
    }
  }

  @override
  Future<void> setAudioIndex(int index) async {
    if (audioTrackSupported(index) == false) throw const DeviceTrackRejected();
    await _command('audio', {'index': index});
    _invalidateTrack();
  }

  @override
  Future<void> setSubtitleIndex(int index) async {
    if (subtitleTrackSupported(index) == false) {
      throw const DeviceTrackRejected();
    }
    await _command('subtitle', {'index': index});
    _selectedSubtitleUri = null;
    _selectedSubtitleTitle = null;
    _invalidateTrack();
  }

  @override
  Future<bool> setSubtitleUri(Uri uri, {String? title}) async {
    final transport = _transport;
    if (transport == null) throw StateError('Playback transport unavailable');
    final sealed = await transport.register(
      uri,
      role: PlaybackResourceRole.subtitle,
    );
    await _command('subtitleUri', {'url': sealed.toString(), 'title': title});
    _selectedSubtitleUri = uri;
    _selectedSubtitleTitle = title;
    _invalidateTrack();
    return true;
  }

  @override
  Future<void> setSubtitleOff() async {
    await _command('subtitleOff');
    _selectedSubtitleUri = null;
    _selectedSubtitleTitle = null;
    _invalidateTrack();
  }

  Future<void> _stopSession({required bool keepAndroidPlayer}) async {
    _diagnosticsTimer?.cancel();
    _diagnosticsTimer = null;
    await _coreEvents?.cancel();
    _coreEvents = null;
    final player = _player;
    if (player != null) {
      if (keepAndroidPlayer && player is AndroidCorePlayer) {
        await player.stop();
      } else {
        _player = null;
        await player.dispose();
      }
    }
    final transport = _transport;
    _transport = null;
    await transport?.close();
  }

  @override
  Future<void> stop() async {
    ++_recoveryEpoch;
    _recovering = false;
    ++_generation;
    isPlaying = false;
    await _stopSession(keepAndroidPlayer: true);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_recoveryEpoch;
    ++_generation;
    await _stopSession(keepAndroidPlayer: false);
    await _events.close();
    await _nativeEvents.close();
  }

  @override
  Widget buildView({Key? key}) =>
      _player?.buildView(key: key) ??
      ColoredBox(key: key, color: const Color(0xFF000000));
}
