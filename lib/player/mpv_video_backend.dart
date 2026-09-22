import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_wake_lock.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_player/rillight_player.dart';

/// Small test seam around the actual per-session libmpv core and renderer.
abstract class MpvSessionDriver {
  Stream<MpvEvent> get events;
  String get nativeVersion;
  Future<void> command(List<String> arguments);
  Future<void> setProperty(String name, String value);
  Future<Object?> getProperty(String name);
  Future<void> dispose();
  Widget buildView();
}

class _NativeDriver implements MpvSessionDriver {
  _NativeDriver(this.player);
  final MpvPlayer player;
  @override
  Stream<MpvEvent> get events => player.events;
  @override
  String get nativeVersion => player.nativeVersion;
  @override
  Future<void> command(List<String> arguments) => player.command(arguments);
  @override
  Future<void> setProperty(String name, String value) =>
      player.setProperty(name, value);
  @override
  Future<Object?> getProperty(String name) => player.getProperty(name);
  @override
  Future<void> dispose() => player.dispose();
  @override
  Widget buildView() => MpvVideoView(player: player);
}

typedef MpvSessionFactory =
    Future<MpvSessionDriver> Function(Map<String, String> options);

class _Session {
  _Session(this.id) {
    ready.future.ignore();
  }
  final int id;
  final ready = Completer<void>();
  Future<MpvSessionDriver>? creating;
  MpvSessionDriver? driver;
  PlaybackHttpProxy? proxy;
  Timer? speedTimer;
  Future<void> policyUpdate = Future<void>.value();
  StreamSubscription<MpvEvent>? subscription;
  Future<void>? retiring;
  bool cancelled = false;
  bool failed = false;
  bool ended = false;
  bool loaded = false;
  bool firstFrame = false;
  bool hasVideo = true;
  bool paused = false;
  bool idle = true;
  Duration demuxerBuffer = Duration.zero;
  int bufferTicks = 0;
  int subtitleRevision = 0;
  final trace = <Map<String, Object?>>[];
  final clock = Stopwatch()..start();
}

class MpvVideoBackend implements VideoBackend {
  MpvVideoBackend({
    PlayerSettingsStore? settingsStore,
    MpvSessionFactory? createSession,
    PlaybackWakeLock? wakeLock,
    this.openTimeout = const Duration(seconds: 45),
    this.diskCacheDirectory,
  }) : _settingsStore = settingsStore,
       _wakeLock = wakeLock ?? PlaybackWakeLock(),
       _createSession =
           createSession ??
           ((options) async =>
               _NativeDriver(await MpvPlayer.create(options: options)));

  PlayerSettingsStore? _settingsStore;
  final MpvSessionFactory _createSession;
  final PlaybackWakeLock _wakeLock;
  final Duration openTimeout;
  final Directory? diskCacheDirectory;
  final _events = StreamController<VideoBackendEvent>.broadcast();
  final _view = ValueNotifier<MpvSessionDriver?>(null);
  _Session? _active;
  int _generation = 0;
  Future<void>? _disposing;
  bool _disposed = false;
  Future<void> _retirement = Future<void>.value();
  double _volume = 100;
  double _rate = 1;
  String? get nativeVersion => _active?.driver?.nativeVersion;
  Object? lastFailure;
  Map<String, Object?>? _lastCacheDiagnostics;
  List<Map<String, Object?>>? _lastOpenTrace;
  int? _lastSessionId;

  Future<Map<String, Object?>> diagnostics() async {
    final driver = _active?.driver;
    final result = <String, Object?>{
      'wake-lock': _wakeLock.diagnostics,
      'cache': _active?.proxy?.diagnostics ?? _lastCacheDiagnostics,
      'sessionId': _active?.id ?? _lastSessionId,
      'openTrace': _active?.trace.toList() ?? _lastOpenTrace,
    };
    if (driver == null) return result;
    for (final key in [
      'mpv-version',
      'ffmpeg-version',
      'hwdec-current',
      'vd-lavc-dr',
      'video-output-driver',
      'current-vo',
      'audio-params',
      'video-params',
      'track-list',
      'avsync',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'mistimed-frame-count',
      'demuxer-cache-state',
      'demuxer-max-bytes',
      'demuxer-max-back-bytes',
      'demuxer-readahead-secs',
    ]) {
      try {
        result[key] = await driver.getProperty(key);
      } catch (_) {}
    }
    return result;
  }

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
  @override
  Stream<VideoBackendEvent> get events => _events.stream;
  Stream<T> _stream<T>(VideoEventKind kind) =>
      events.where((e) => e.kind == kind).map((e) => e.value as T);
  @override
  Stream<Duration> get positionStream => _stream(VideoEventKind.position);
  @override
  Stream<Duration> get durationStream => _stream(VideoEventKind.duration);
  @override
  Stream<Duration> get bufferStream => _stream(VideoEventKind.buffer);
  @override
  Stream<bool> get playingStream => _stream(VideoEventKind.playing);
  @override
  Stream<bool> get completedStream => _stream(VideoEventKind.completed);
  @override
  Stream<String> get errorStream => _stream(VideoEventKind.error);

  bool _current(_Session session) =>
      !_disposed && !session.cancelled && identical(_active, session);
  void _emit(_Session session, VideoEventKind kind, Object value) {
    if (_current(session)) {
      _events.add(VideoBackendEvent(session.id, kind, value));
    }
  }

  @override
  Future<void> open(VideoOpenRequest request) async {
    final generation = ++_generation;
    await _stopActive();
    if (_disposed || generation != _generation) return;
    final session = _Session(request.sessionId);
    _active = session;
    _lastCacheDiagnostics = null;
    lastFailure = null;
    position = request.start;
    duration = buffer = Duration.zero;
    isPlaying = false;
    selectedAudioIndex = selectedSubtitleIndex = null;
    Future<SessionByteCache?>? openingCache;
    try {
      final store = _settingsStore ??= await openPlayerSettingsStore();
      final settings = await store.read();
      final cache = diskCacheDirectory ?? PlayerDiskCache.defaultDirectory();
      if (!_current(session)) return;
      final options = PlayerRuntimeOptions.build(
        settings: settings,
        cacheDir: cache.path,
        platform: defaultTargetPlatform,
        // HTTP content type and HLS state are learned by the proxy. A missing
        // duration is not a live-stream signal.
        liveOrHlsStream:
            request.dynamicSource ||
            request.url.scheme == 'http' ||
            request.url.scheme == 'https',
      );
      // Force lavf so ff-index is the actual FFmpeg stream index, not a guess
      // made by another container demuxer. Credentials stay in the proxy.
      options.addAll({
        'title': kProductName,
        'demuxer': 'lavf',
        'pause': 'no',
        'volume': '$_volume',
        'speed': '$_rate',
        'network-timeout': '20',
      });
      final usesProxy =
          request.url.scheme == 'http' ||
          request.url.scheme == 'https' ||
          request.credentialOrigin != null;
      // Disk-cache startup is independent from libmpv initialization. Start
      // both together so a cold cache directory does not add another serial
      // wait before loadfile can begin.
      if (usesProxy) {
        openingCache =
            SessionByteCache.open(
              root: cache,
              memoryLimitBytes: 8 * 1024 * 1024,
              pendingLimitBytes: 2 * 1024 * 1024,
              diskLimitBytes: PlayerRuntimeOptions.effectiveDiskCacheLimitBytes(
                settings,
              ),
              diskSessionLimitBytes: 64 * 1024 * 1024,
            ).then((opened) async {
              if (!_current(session)) {
                await opened.close();
                return null;
              }
              return opened;
            });
      }
      session.creating = _createSession(options);
      final driver = await session.creating!;
      session.driver = driver;
      if (!_current(session)) {
        await _retire(session);
        return;
      }
      _view.value = driver;
      session.subscription = driver.events.listen(
        (event) => _onEvent(session, event),
      );
      var url = request.url;
      if (usesProxy) {
        final byteCache = await openingCache!;
        if (byteCache == null) return;
        if (!_current(session)) {
          await byteCache.close();
          return;
        }
        late PlaybackHttpProxy proxy;
        try {
          proxy = await PlaybackHttpProxy.create(
            origin: request.credentialOrigin,
            headers: request.credentialHeaders.isNotEmpty
                ? request.credentialHeaders
                : request.headers,
            cache: byteCache,
            // Session-owned media buffering is cleared on stop/dispose. This
            // explicitly allows no-store media to use temporary disk space;
            // reuse still requires upstream validation, with no account/session
            // sharing. Keys, subtitles and manifests remain outside the cache.
            sessionBuffering: true,
            readAheadBytes: 512 * 1024 * 1024,
            dynamicSource: request.dynamicSource,
            onStreamChanged: (stream) {
              session.policyUpdate = session.policyUpdate
                  .then((_) async {
                    if (!_current(session)) return;
                    final conservative =
                        stream == PlaybackCacheStream.conservative;
                    await byteCache.resize(
                      memoryBytes: (conservative ? 8 : 32) * 1024 * 1024,
                      pendingBytes: (conservative ? 2 : 4) * 1024 * 1024,
                      diskBytes: conservative
                          ? 64 * 1024 * 1024
                          : PlayerRuntimeOptions.effectiveDiskCacheLimitBytes(
                              settings,
                            ),
                    );
                    for (final property
                        in PlayerRuntimeOptions.bufferProperties(
                          conservative: conservative,
                        ).entries) {
                      if (!_current(session)) return;
                      await driver.setProperty(property.key, property.value);
                    }
                  })
                  .catchError((Object _) {});
              return session.policyUpdate;
            },
          );
        } catch (_) {
          await byteCache.close();
          rethrow;
        }
        session.proxy = proxy;
        if (!_current(session)) {
          await proxy.close();
          return;
        }
        session.speedTimer = Timer.periodic(const Duration(milliseconds: 250), (
          _,
        ) {
          proxy.resumeAfterDiskRecovery();
          _emit(
            session,
            VideoEventKind.cacheSpeed,
            proxy.upstreamBytesPerSecond,
          );
          if (++session.bufferTicks % 4 == 0) {
            unawaited(
              proxy.refreshTimeline(duration).then((_) {
                if (_current(session)) _publishBuffer(session);
              }),
            );
          }
        });
        if (url.scheme == 'http' || url.scheme == 'https') {
          url = proxy.register(url);
        }
      }
      if (!_current(session)) return;
      if (request.start > Duration.zero) {
        await driver.setProperty(
          'start',
          '${request.start.inMicroseconds / 1000000}',
        );
      }
      if (!_current(session)) return;
      await driver.command(['loadfile', url.toString(), 'replace']);
      await session.ready.future.timeout(openTimeout);
    } catch (failure) {
      // If libmpv failed before the parallel cache future was consumed, make
      // sure a successfully opened cache is still closed.
      try {
        final opened = await openingCache;
        await opened?.close();
      } catch (_) {}
      if (_current(session)) {
        lastFailure = failure;
        await _stopActive();
        rethrow;
      }
      if (session.failed) rethrow;
    }
  }

  void _ready(_Session session) {
    if (session.loaded &&
        (!session.hasVideo || session.firstFrame) &&
        !session.ready.isCompleted) {
      _trace(session, 'ready');
      session.ready.complete();
    }
  }

  void _onEvent(_Session session, MpvEvent event) {
    if (!_current(session)) return;
    switch (event.type) {
      case 'request':
        _trace(session, 'request', event.value);
      case 'file-loaded':
        _trace(session, 'file-loaded');
        unawaited(_loaded(session));
      case 'first-frame':
        _trace(session, 'first-frame');
        session.firstFrame = true;
        _ready(session);
      case 'error':
      case 'queue-overflow':
        _trace(session, 'engine-failure');
        final failure = StateError('Playback engine failed');
        session.failed = true;
        lastFailure = failure;
        isPlaying = false;
        _wakeLock.update(false);
        _emit(session, VideoEventKind.playing, false);
        if (!session.ready.isCompleted) session.ready.completeError(failure);
        _emit(session, VideoEventKind.error, failure.toString());
        unawaited(stop().catchError((Object _) {}));
      case 'end-file':
        session.ended = true;
        isPlaying = false;
        _wakeLock.update(false);
        _emit(session, VideoEventKind.playing, false);
        final value = event.value;
        if (value is Map && value['reason'] == 0) {
          _emit(session, VideoEventKind.completed, true);
        } else if (value is Map && value['reason'] == 4) {
          if (!session.ready.isCompleted) {
            session.ready.completeError(StateError('Failed to open media'));
          }
          _emit(session, VideoEventKind.error, 'Failed to open media');
        }
      case 'property':
        final value = event.value;
        switch (event.property) {
          case 'time-pos':
            if (value is num) {
              position = _seconds(value);
              _emit(session, VideoEventKind.position, position);
            }
          case 'duration':
            if (value is num) {
              duration = _seconds(value);
              _emit(session, VideoEventKind.duration, duration);
            }
          case 'demuxer-cache-time':
            if (value is num) {
              session.demuxerBuffer = _seconds(value);
              _publishBuffer(session);
            }
          case 'cache-speed':
            // mpv includes loopback cache hits here, so it is not a network rate.
            _emit(
              session,
              VideoEventKind.cacheSpeed,
              session.proxy?.upstreamBytesPerSecond ?? 0.0,
            );
          case 'pause':
            if (value is bool) {
              session.paused = value;
              _playing(session);
            }
          case 'core-idle':
            if (value is bool) {
              session.idle = value;
              _playing(session);
            }
          case 'paused-for-cache':
            if (value is bool) _emit(session, VideoEventKind.buffering, value);
          case 'eof-reached':
            if (value is bool) {
              session.ended = value;
              _playing(session);
              if (value) _emit(session, VideoEventKind.completed, true);
            }
        }
    }
  }

  void _trace(_Session session, String event, [Object? request]) {
    if (session.trace.length == 48) session.trace.removeAt(0);
    session.trace.add({
      'sessionId': session.id,
      'elapsedMs': session.clock.elapsedMilliseconds,
      'event': event,
      'request': ?request,
    });
  }

  void _publishBuffer(_Session session) {
    buffer =
        session.proxy?.bufferedEnd(position, session.demuxerBuffer) ??
        session.demuxerBuffer;
    if (duration > Duration.zero && buffer > duration) buffer = duration;
    _emit(session, VideoEventKind.buffer, buffer);
  }

  Future<void> _loaded(_Session session) async {
    try {
      final tracks = await session.driver!.getProperty('track-list');
      if (!_current(session)) return;
      if (tracks is! List ||
          !tracks.any(
            (t) => t is Map && (t['type'] == 'audio' || t['type'] == 'video'),
          )) {
        throw StateError('No playable media tracks');
      }
      session.hasVideo = tracks.any(
        (t) => t is Map && t['type'] == 'video' && t['albumart'] != true,
      );
      for (final track in tracks) {
        if (track is Map &&
            track['selected'] == true &&
            track['ff-index'] is int) {
          if (track['type'] == 'audio') {
            selectedAudioIndex = track['ff-index'] as int;
          }
          if (track['type'] == 'sub') {
            selectedSubtitleIndex = track['ff-index'] as int;
          }
        }
      }
      session.loaded = true;
      _ready(session);
      _playing(session);
    } catch (_) {
      if (_current(session) && !session.ready.isCompleted) {
        session.ready.completeError(
          StateError('Unable to inspect media tracks'),
        );
      }
    }
  }

  void _playing(_Session session) {
    final playing =
        session.loaded &&
        !session.paused &&
        !session.idle &&
        !session.ended &&
        !session.failed;
    _wakeLock.update(playing);
    if (playing != isPlaying) {
      isPlaying = playing;
      _emit(session, VideoEventKind.playing, playing);
    }
  }

  static Duration _seconds(num value) =>
      Duration(microseconds: (value * 1000000).round());

  @override
  Future<void> stop() async {
    ++_generation;
    await _stopActive();
  }

  Future<void> _stopActive() async {
    final releasingWakeLock = _wakeLock.release();
    final session = _active;
    if (session != null) {
      _lastSessionId = session.id;
      _lastOpenTrace = session.trace.toList();
    }
    _active = null;
    isPlaying = false;
    _view.value = null;
    if (session != null) {
      _retirement = Future.wait([
        _retirement,
        _retire(session),
      ]).then<void>((_) {});
    }
    await Future.wait([_retirement, releasingWakeLock]);
  }

  Future<void> _retire(_Session session) =>
      session.retiring ??= _retireResources(session);
  Future<void> _retireResources(_Session session) async {
    session.cancelled = true;
    session.speedTimer?.cancel();
    if (!session.ready.isCompleted) {
      session.ready.completeError(StateError('Media open cancelled'));
    }
    await session.subscription?.cancel();
    await session.proxy?.close();
    _lastCacheDiagnostics = session.proxy?.diagnostics;
    await session.policyUpdate;
    final creating = session.creating;
    if (creating != null) {
      MpvSessionDriver driver;
      try {
        driver = await creating;
      } catch (_) {
        return;
      }
      await driver.dispose();
    }
  }

  MpvSessionDriver get _driver =>
      _active?.driver ?? (throw StateError('No active media'));
  @override
  Future<void> play() => _driver.setProperty('pause', 'no');
  @override
  Future<void> pause() => _driver.setProperty('pause', 'yes');
  @override
  Future<void> playOrPause() => _driver.command(['cycle', 'pause']);
  @override
  Future<void> seek(Duration position) async {
    final session = _active;
    if (session != null) {
      session.demuxerBuffer = position;
      this.position = position;
      _publishBuffer(session);
    }
    final driver = _driver;
    session?.proxy?.cancelPendingReads(preserveSubtitles: true);
    await driver.command([
      'seek',
      '${position.inMicroseconds / 1000000}',
      'absolute+exact',
    ]);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _active?.driver?.setProperty('volume', '$volume');
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _active?.driver?.setProperty('speed', '$rate');
  }

  @override
  Future<void> setAudioIndex(int index) => _select('audio', 'aid', index);
  @override
  Future<void> setSubtitleIndex(int index) {
    final session = _active;
    if (session == null) throw StateError('No active media');
    return _select(
      'sub',
      'sid',
      index,
      subtitleRevision: ++session.subtitleRevision,
    );
  }

  Future<void> _select(
    String type,
    String property,
    int index, {
    int? subtitleRevision,
  }) async {
    final session = _active;
    if (session == null) throw StateError('No active media');
    final driver = session.driver!;
    final tracks = await driver.getProperty('track-list');
    if (!_current(session) ||
        (subtitleRevision != null &&
            subtitleRevision != session.subtitleRevision)) {
      return;
    }
    final matches = tracks is List
        ? tracks
              .where(
                (t) =>
                    t is Map &&
                    t['type'] == type &&
                    t['external'] != true &&
                    t['ff-index'] == index,
              )
              .toList()
        : const [];
    if (matches.length != 1) {
      throw StateError('Requested $type track is unavailable');
    }
    await driver.setProperty(property, '${(matches.single as Map)['id']}');
  }

  @override
  Future<void> setSubtitleUri(Uri uri, {String? title}) async {
    final session = _active;
    if (session == null) throw StateError('No active media');
    final revision = ++session.subtitleRevision;
    bool current() => _current(session) && revision == session.subtitleRevision;
    final driver = session.driver!;
    final url = uri.scheme == 'http' || uri.scheme == 'https'
        ? session.proxy?.register(uri, role: PlaybackResourceRole.subtitle) ??
              uri
        : uri;
    // Pin the actual selection before loading. `auto` adds the external track
    // without selecting it, so a late completion cannot replace a newer
    // choice or turn a timed-out optional load into a committed selection.
    final selected = await driver.getProperty('sid');
    if (!current()) return;
    await driver.setProperty('sid', selected is num ? '$selected' : 'no');
    if (!current()) return;
    final loading = driver.command([
      'sub-add',
      url.toString(),
      'auto',
      title ?? '',
    ]);
    try {
      await loading;
    } on TimeoutException {
      if (!current()) return;
      _trace(session, 'subtitle-load-timeout');
      // mpv waits for the external subtitle body before completing sub-add.
      // Keep the player responsive and let the operation finish in the
      // background when the native control channel is still healthy.
      try {
        final actual = await driver
            .getProperty('sid')
            .timeout(const Duration(seconds: 2));
        if (!current()) return;
        if (!session.loaded ||
            (session.hasVideo && !session.firstFrame) ||
            session.failed ||
            actual != selected) {
          throw StateError('Unable to confirm subtitle selection');
        }
      } catch (_) {
        if (!current()) return;
        if (_current(session)) {
          _onEvent(
            session,
            const MpvEvent(
              'error',
              error: 'Subtitle timeout health check failed',
            ),
          );
        }
        rethrow;
      }
      _trace(session, 'subtitle-timeout-control-responsive');
      unawaited(
        loading.then<void>((_) async {
          if (!current()) return;
          try {
            await _selectExternalSubtitle(session, driver, url, revision);
          } catch (_) {}
        }, onError: (Object error, StackTrace stack) {}),
      );
      throw StateError(
        'External subtitle loading timed out; playback continues',
      );
    }
    await _selectExternalSubtitle(session, driver, url, revision);
  }

  Future<void> _selectExternalSubtitle(
    _Session session,
    MpvSessionDriver driver,
    Uri url,
    int revision,
  ) async {
    if (!_current(session) || revision != session.subtitleRevision) return;
    final tracks = await driver.getProperty('track-list');
    if (!_current(session) || revision != session.subtitleRevision) return;
    final matches = tracks is List
        ? tracks
              .where(
                (track) =>
                    track is Map &&
                    track['type'] == 'sub' &&
                    track['external-filename'] == url.toString(),
              )
              .toList()
        : const [];
    if (matches.isEmpty) throw StateError('External subtitle is unavailable');
    await driver.setProperty('sid', '${(matches.last as Map)['id']}');
  }

  @override
  Future<void> setSubtitleOff() {
    final session = _active;
    if (session == null) throw StateError('No active media');
    ++session.subtitleRevision;
    return session.driver!.setProperty('sid', 'no');
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    try {
      await stop();
    } finally {
      await _wakeLock.dispose();
    }
    await _events.close();
    _view.dispose();
  }

  @override
  Widget buildView({Key? key}) => ValueListenableBuilder<MpvSessionDriver?>(
    key: key,
    valueListenable: _view,
    builder: (context, driver, _) =>
        driver?.buildView() ?? const ColoredBox(color: Color(0xFF000000)),
  );
}
