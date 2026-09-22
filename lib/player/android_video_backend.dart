import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_android_player/rillight_android_player.dart';

/// Media3 owns media resources; this adapter preserves controller identities.
class AndroidVideoBackend extends VideoBackend
    implements VideoBackendCapabilities {
  AndroidVideoBackend({AndroidPlayer? player})
    : _player = player ?? AndroidPlayer() {
    _subscription = _player.events.listen(_onEvent);
  }
  final AndroidPlayer _player;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  final _events = StreamController<VideoBackendEvent>.broadcast();
  final _native = StreamController<Map<String, dynamic>>.broadcast();

  /// Includes ready, firstFrame and interruption; useful to hosts and smoke tools.
  Stream<Map<String, dynamic>> get nativeEvents => _native.stream;
  int _session = 0;
  bool _disposed = false;
  bool _stopped = true;
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
  Stream<T> _values<T>(VideoEventKind kind) =>
      events.where((e) => e.kind == kind).map((e) => e.value as T);
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

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed || _stopped) return;
    _native.add(event);
    final kind = VideoEventKind.values
        .where((k) => k.name == event['kind'])
        .firstOrNull;
    if (kind == null) return;
    Object value = event['value'] as Object;
    if ([
      VideoEventKind.position,
      VideoEventKind.duration,
      VideoEventKind.buffer,
    ].contains(kind)) {
      value = Duration(milliseconds: (value as num).toInt());
    }
    switch (kind) {
      case VideoEventKind.position:
        position = value as Duration;
      case VideoEventKind.duration:
        duration = value as Duration;
      case VideoEventKind.buffer:
        buffer = value as Duration;
      case VideoEventKind.playing:
        isPlaying = value as bool;
      case VideoEventKind.error:
        isPlaying = false;
      default:
        break;
    }
    _events.add(VideoBackendEvent(_session, kind, value));
  }

  @override
  Future<Map<String, dynamic>> deviceProfile(int maxStreamingBitrate) async {
    final codecs = await _player.capabilities();
    return androidDeviceProfile(
      h264: codecs['h264'] == true,
      aac: codecs['aac'] == true,
      maxStreamingBitrate: maxStreamingBitrate.clamp(1, 20000000),
    );
  }

  @override
  Future<void> open(VideoOpenRequest request) async {
    _session = request.sessionId;
    _stopped = false;
    position = request.start;
    duration = buffer = Duration.zero;
    isPlaying = false;
    selectedAudioIndex = selectedSubtitleIndex = null;
    try {
      final result = await _player.open({
        'url': request.url.toString(),
        'start': request.start.inMilliseconds,
        'paused': request.startPaused,
        'headers': request.headers,
        'credentialOrigin': request.credentialOrigin?.toString(),
        'credentialHeaders': request.credentialHeaders,
        'streams': [
          for (final s in request.mediaStreams)
            {
              'index': s.index,
              'type': s.type,
              'language': s.language,
              'external': s.isExternal,
            },
        ],
      });
      selectedAudioIndex = result['audioIndex'] as int?;
      selectedSubtitleIndex = result['subtitleIndex'] as int?;
    } on PlatformException catch (error) {
      if (error.message?.contains('DECOD') == true ||
          error.message?.contains('PARSING') == true) {
        throw VideoCompatibilityException(error.message!);
      }
      throw StateError(error.message ?? 'Android playback failed');
    }
  }

  Future<void> _command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      final result = await _player.command(method, args);
      selectedAudioIndex = result['audioIndex'] as int?;
      selectedSubtitleIndex = result['subtitleIndex'] as int?;
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Android playback command failed');
    }
  }

  @override
  Future<void> play() => _command('play');
  @override
  Future<void> pause() => _command('pause');
  @override
  Future<void> playOrPause() => isPlaying ? pause() : play();
  @override
  Future<void> seek(Duration position) =>
      _command('seek', {'position': position.inMilliseconds});
  @override
  Future<void> setVolume(double volume) =>
      _command('volume', {'value': volume / 100});
  @override
  Future<void> setRate(double rate) => _command('rate', {'value': rate});
  @override
  Future<void> setAudioIndex(int index) => _command('audio', {'index': index});
  @override
  Future<void> setSubtitleIndex(int index) =>
      _command('subtitle', {'index': index});
  @override
  Future<bool> setSubtitleUri(Uri uri, {String? title}) async {
    await _command('subtitleUri', {'url': uri.toString(), 'title': title});
    return true;
  }

  @override
  Future<void> setSubtitleOff() => _command('subtitleOff');
  @override
  Future<void> stop() async {
    if (_stopped || _disposed) return;
    _stopped = true;
    isPlaying = false;
    await _command('stop');
  }

  @override
  Widget buildView({Key? key}) => _player.buildView(key: key);
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    isPlaying = false;
    try {
      await _player.dispose();
    } finally {
      await _subscription.cancel();
      await _events.close();
      await _native.close();
    }
  }
}
