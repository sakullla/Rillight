import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:rillight/app/product.dart';
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

  Future<Map<String, Object?>> diagnostics() async {
    final driver = _driver;
    final result = <String, Object?>{'wake-lock': _wakeLock.diagnostics};
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
    lastFailure = null;
    position = request.start;
    duration = buffer = Duration.zero;
    isPlaying = false;
    try {
      final store = _settingsStore ??= await openPlayerSettingsStore();
      final settings = await store.read();
      final cache = diskCacheDirectory ?? PlayerDiskCache.defaultDirectory();
      await PlayerDiskCache.ensure(cache);
      await PlayerDiskCache.reclaim(
        cache,
        PlayerRuntimeOptions.effectiveDiskCacheLimitBytes(settings),
      );
      if (!_current(session)) return;
      final options = PlayerRuntimeOptions.build(
        settings: settings,
        cacheDir: cache.path,
        platform: defaultTargetPlatform,
        liveOrHlsStream: PlayerRuntimeOptions.isLiveOrHlsStream(request.url),
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
      if (url.scheme == 'http' ||
          url.scheme == 'https' ||
          request.credentialOrigin != null) {
        final proxy = await PlaybackHttpProxy.create(
          origin: request.credentialOrigin,
          headers: request.credentialHeaders.isNotEmpty
              ? request.credentialHeaders
              : request.headers,
        );
        session.proxy = proxy;
        if (!_current(session)) {
          await proxy.close();
          return;
        }
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
      session.ready.complete();
    }
  }

  void _onEvent(_Session session, MpvEvent event) {
    if (!_current(session)) return;
    switch (event.type) {
      case 'file-loaded':
        unawaited(_loaded(session));
      case 'first-frame':
        session.firstFrame = true;
        _ready(session);
      case 'error':
      case 'queue-overflow':
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
              buffer = _seconds(value);
              _emit(session, VideoEventKind.buffer, buffer);
            }
          case 'cache-speed':
            if (value is num) {
              _emit(session, VideoEventKind.cacheSpeed, value.toDouble());
            }
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

  Future<void> _loaded(_Session session) async {
    try {
      final tracks = await session.driver!.getProperty('track-list');
      if (!_current(session)) return;
      session.hasVideo =
          tracks is List &&
          tracks.any(
            (t) => t is Map && t['type'] == 'video' && t['albumart'] != true,
          );
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
    if (!session.ready.isCompleted) {
      session.ready.completeError(StateError('Media open cancelled'));
    }
    await session.subscription?.cancel();
    await session.proxy?.close();
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
  Future<void> seek(Duration position) => _driver.command([
    'seek',
    '${position.inMicroseconds / 1000000}',
    'absolute+exact',
  ]);
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
  Future<void> setSubtitleIndex(int index) => _select('sub', 'sid', index);
  Future<void> _select(String type, String property, int index) async {
    final driver = _driver;
    final tracks = await driver.getProperty('track-list');
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
    final url = uri.scheme == 'http' || uri.scheme == 'https'
        ? session.proxy?.register(uri) ?? uri
        : uri;
    await _driver.command(['sub-add', url.toString(), 'select', title ?? '']);
  }

  @override
  Future<void> setSubtitleOff() => _driver.setProperty('sid', 'no');
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
