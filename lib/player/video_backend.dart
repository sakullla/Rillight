import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:rillight/player/playback_models.dart';

class VideoOpenRequest {
  const VideoOpenRequest({
    required this.url,
    this.start = Duration.zero,
    this.sessionId = 0,
    this.headers = const {},
    this.credentialOrigin,
    this.credentialHeaders = const {},
    this.playMethod = PlayMethod.directStream,
    this.isInfiniteStream = false,
    this.mediaStreams = const [],
    this.startPaused = false,
  });

  final int sessionId;
  final Uri url;
  final Duration start;
  final Map<String, String> headers;
  final Uri? credentialOrigin;
  final Map<String, String> credentialHeaders;
  final PlayMethod playMethod;
  final bool isInfiniteStream;
  final List<MediaStreamInfo> mediaStreams;
  final bool startPaused;
  bool get dynamicSource =>
      isInfiniteStream || playMethod == PlayMethod.transcode;
}

/// Optional backend contract; existing desktop and fake defaults are unchanged.
abstract interface class VideoBackendCapabilities {
  Future<Map<String, dynamic>> deviceProfile(int maxStreamingBitrate);
}

enum TranscodeSubtitleDelivery { burnIn, external, manifest }

/// Optional: desktop retains its existing server-burned transcode behavior.
abstract interface class VideoBackendTranscodeSubtitles {
  TranscodeSubtitleDelivery transcodeSubtitleDelivery(MediaStreamInfo stream);
}

class VideoCompatibilityException implements Exception {
  const VideoCompatibilityException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The device cannot decode this mapped audio or subtitle.
///
/// Startup leaves the playable selection in place. A later manual choice
/// records the failure without reopening the video.
class DeviceTrackRejected implements Exception {
  const DeviceTrackRejected();

  @override
  String toString() => 'Device track is not playable';
}

/// Optional. Null means this backend has not classified [index].
/// False means selection must not be sent to the device.
abstract interface class VideoBackendTrackSupport {
  bool? audioTrackSupported(int index);
  bool? subtitleTrackSupported(int index);
}

enum VideoEventKind {
  position,
  duration,
  buffer,
  playing,
  buffering,
  completed,
  error,
  cacheSpeed,
  authenticationRequired,
}

/// The backend preserves the originating open's identity, including late events.
class VideoBackendEvent {
  const VideoBackendEvent(this.sessionId, this.kind, this.value);
  final int sessionId;
  final VideoEventKind kind;
  final Object value;
}

abstract class VideoBackend {
  Stream<VideoBackendEvent> get events;

  /// Cancels pending opens and stops audio/video before completing.
  Future<void> stop();
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;
  Stream<String> get errorStream;

  Duration get position;
  Duration get duration;
  Duration get buffer;
  bool get isPlaying;

  /// Actual selected container stream indices, independent of server defaults.
  int? get selectedAudioIndex;
  int? get selectedSubtitleIndex;

  Future<void> open(VideoOpenRequest request);
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
  Future<void> setAudioIndex(int index);

  /// 选中 [uri] 对应的外挂字幕后返回 true。
  /// 更新的字幕操作抢先完成时返回 false,不表示加载失败。
  Future<bool> setSubtitleUri(Uri uri, {String? title});

  /// 选择容器内嵌字幕轨道(按 MediaStream 索引,如直连时的 PGS 位图轨)。
  Future<void> setSubtitleIndex(int index);

  Future<void> setSubtitleOff();
  Future<void> dispose();

  Widget buildView({Key? key}) {
    return ColoredBox(key: key, color: const Color(0xFF000000));
  }
}

class FakeVideoBackend implements VideoBackend {
  FakeVideoBackend({this.duration = const Duration(minutes: 22)});

  @override
  Duration duration;

  @override
  Duration position = Duration.zero;

  @override
  Duration buffer = Duration.zero;

  @override
  bool isPlaying = false;

  Uri? openedUrl;
  bool openedPaused = false;
  Duration? openedStart;
  Map<String, String> openedHeaders = const {};
  int openCount = 0;
  int? audioIndex;
  Uri? subtitleUri;
  int? subtitleIndex;
  @override
  int? get selectedAudioIndex => audioIndex;
  @override
  int? get selectedSubtitleIndex => subtitleIndex;
  bool subtitleOff = false;
  double volume = 100;
  double rate = 1.0;

  int sessionId = 0;
  final _events = StreamController<VideoBackendEvent>.broadcast();
  @override
  Stream<VideoBackendEvent> get events => _events.stream;

  void emitEvent(VideoEventKind kind, Object value, {int? forSession}) {
    _events.add(VideoBackendEvent(forSession ?? sessionId, kind, value));
  }

  void emitBuffering(bool value) => emitEvent(VideoEventKind.buffering, value);

  @override
  Future<void> stop() async {
    isPlaying = false;
    emitEvent(VideoEventKind.playing, false);
  }

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffer = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<Duration> get bufferStream => _buffer.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Future<void> open(VideoOpenRequest request) async {
    sessionId = request.sessionId;
    openCount += 1;
    openedUrl = request.url;
    openedStart = request.start;
    openedPaused = request.startPaused;
    openedHeaders = request.headers;
    position = request.start;
    buffer = Duration.zero;
    isPlaying = !request.startPaused;
    subtitleOff = false;
    subtitleUri = null;
    subtitleIndex = null;
    _duration.add(duration);
    emitEvent(VideoEventKind.duration, duration);
    _position.add(position);
    emitEvent(VideoEventKind.position, position);
    _buffer.add(buffer);
    emitEvent(VideoEventKind.buffer, buffer);
    _playing.add(isPlaying);
    emitEvent(VideoEventKind.playing, isPlaying);
    _completed.add(false);
    emitEvent(VideoEventKind.completed, false);
  }

  @override
  Future<void> play() async {
    isPlaying = true;
    _playing.add(true);
    emitEvent(VideoEventKind.playing, true);
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    _playing.add(false);
    emitEvent(VideoEventKind.playing, false);
  }

  @override
  Future<void> playOrPause() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration value) async {
    position = value < Duration.zero ? Duration.zero : value;
    if (position > duration) {
      position = duration;
    }
    _position.add(position);
    emitEvent(VideoEventKind.position, position);
  }

  void emitBuffer(Duration value) {
    buffer = value < Duration.zero ? Duration.zero : value;
    _buffer.add(buffer);
    emitEvent(VideoEventKind.buffer, buffer);
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> setRate(double value) async {
    rate = value;
  }

  @override
  Future<void> setAudioIndex(int index) async {
    audioIndex = index;
  }

  @override
  Future<bool> setSubtitleUri(Uri uri, {String? title}) async {
    subtitleUri = uri;
    subtitleOff = false;
    return true;
  }

  @override
  Future<void> setSubtitleIndex(int index) async {
    subtitleIndex = index;
    subtitleUri = null;
    subtitleOff = false;
  }

  @override
  Future<void> setSubtitleOff() async {
    subtitleOff = true;
    subtitleUri = null;
  }

  void emitError(String message) {
    _error.add(message);
    emitEvent(VideoEventKind.error, message);
  }

  void completePlayback({Duration? at}) {
    isPlaying = false;
    position = at ?? duration;
    if (position > duration) {
      duration = position;
      _duration.add(duration);
      emitEvent(VideoEventKind.duration, duration);
    }
    _position.add(position);
    emitEvent(VideoEventKind.position, position);
    _playing.add(false);
    emitEvent(VideoEventKind.playing, false);
    _completed.add(true);
    emitEvent(VideoEventKind.completed, true);
  }

  /// keep-open 停在末帧:进度到头并暂停,但不发 completed。
  void pauseAtEndWithoutComplete({Duration? at}) {
    isPlaying = false;
    position = at ?? duration;
    if (position > duration) {
      duration = position;
      _duration.add(duration);
      emitEvent(VideoEventKind.duration, duration);
    }
    _position.add(position);
    emitEvent(VideoEventKind.position, position);
    _playing.add(false);
    emitEvent(VideoEventKind.playing, false);
  }

  /// 仅标记关闭:换集时宿主会新建 PlayerPage 并复用同一注入实例,
  /// 不真正关闭事件流,保证跨页仍可收发事件。
  @override
  Future<void> dispose() async {}

  @override
  Widget buildView({Key? key}) {
    return ColoredBox(key: key, color: const Color(0xFF000000));
  }
}
