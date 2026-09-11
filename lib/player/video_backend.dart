import 'dart:async';

import 'package:flutter/widgets.dart';

class VideoOpenRequest {
  const VideoOpenRequest({
    required this.url,
    this.start = Duration.zero,
    this.headers = const {},
  });

  final Uri url;
  final Duration start;
  final Map<String, String> headers;
}

abstract class VideoBackend {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;
  Stream<String> get errorStream;

  Duration get position;
  Duration get duration;
  bool get isPlaying;

  Future<void> open(VideoOpenRequest request);
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setAudioIndex(int index);
  Future<void> setSubtitleUri(Uri uri, {String? title});
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
  bool isPlaying = false;

  Uri? openedUrl;
  Duration? openedStart;
  Map<String, String> openedHeaders = const {};
  int openCount = 0;
  int? audioIndex;
  Uri? subtitleUri;
  bool subtitleOff = false;
  double volume = 100;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Future<void> open(VideoOpenRequest request) async {
    openCount += 1;
    openedUrl = request.url;
    openedStart = request.start;
    openedHeaders = request.headers;
    position = request.start;
    isPlaying = true;
    subtitleOff = false;
    _duration.add(duration);
    _position.add(position);
    _playing.add(true);
    _completed.add(false);
  }

  @override
  Future<void> play() async {
    isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    _playing.add(false);
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
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> setAudioIndex(int index) async {
    audioIndex = index;
  }

  @override
  Future<void> setSubtitleUri(Uri uri, {String? title}) async {
    subtitleUri = uri;
    subtitleOff = false;
  }

  @override
  Future<void> setSubtitleOff() async {
    subtitleOff = true;
    subtitleUri = null;
  }

  void emitError(String message) {
    _error.add(message);
  }

  void completePlayback() {
    isPlaying = false;
    position = duration;
    _position.add(position);
    _playing.add(false);
    _completed.add(true);
  }

  bool _closed = false;

  @override
  Future<void> dispose() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _completed.close();
    await _error.close();
  }

  @override
  Widget buildView({Key? key}) {
    return ColoredBox(key: key, color: const Color(0xFF000000));
  }
}
