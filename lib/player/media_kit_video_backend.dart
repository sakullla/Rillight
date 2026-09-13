import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

class MediaKitVideoBackend implements VideoBackend {
  MediaKitVideoBackend({PlayerSettingsStore? settingsStore}) {
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(
        title: kProductName,
        libass: true,
      ),
    );
    videoController = VideoController(_player);
    _settingsStore = settingsStore;
  }

  late final Player _player;
  late final VideoController videoController;
  PlayerSettingsStore? _settingsStore;

  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<bool> get completedStream => _player.stream.completed;
  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;
  @override
  bool get isPlaying => _player.state.playing;

  @override
  Future<void> open(VideoOpenRequest request) async {
    await _applyRuntimeOptions(request.url);
    await _player.open(
      Media(
        request.url.toString(),
        httpHeaders: request.headers.isEmpty ? null : request.headers,
        start: request.start > Duration.zero ? request.start : null,
      ),
    );
  }

  /// open 前集中注入 mpv 运行时属性(网络缓冲/硬件解码/音质)。
  ///
  /// 每次起播重新读设置文件:设置对新起播生效,文件是唯一权威。
  /// 属性注入尽力而为,单条失败或整体失败都不阻塞播放,
  /// 不兼容组合可经「恢复默认」回到受支持的基线。
  Future<void> _applyRuntimeOptions(Uri url) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      return;
    }
    try {
      final store = _settingsStore ??= await openPlayerSettingsStore();
      final settings = await store.read();
      final cacheDir = PlayerDiskCache.defaultDirectory();
      await PlayerDiskCache.ensure(cacheDir);
      await PlayerDiskCache.reclaim(
        cacheDir,
        PlayerRuntimeOptions.effectiveDiskCacheLimitBytes(settings),
      );
      final properties = PlayerRuntimeOptions.build(
        settings: settings,
        cacheDir: cacheDir.path,
        platform: _hostPlatform,
        liveOrHlsStream: PlayerRuntimeOptions.isLiveOrHlsStream(url),
      );
      for (final entry in properties.entries) {
        try {
          await platform.setProperty(entry.key, entry.value);
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setAudioIndex(int index) async {
    final tracks = _player.state.tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .toList();
    if (tracks.isEmpty) {
      await _player.setAudioTrack(AudioTrack(index.toString(), null, null));
      return;
    }
    for (final track in tracks) {
      if (track.id == index.toString() || track.id == '${index + 1}') {
        await _player.setAudioTrack(track);
        return;
      }
    }
    final offset = index < tracks.length ? index : tracks.length - 1;
    if (offset >= 0) {
      await _player.setAudioTrack(tracks[offset]);
    }
  }

  @override
  Future<void> setSubtitleUri(Uri uri, {String? title}) {
    return _player.setSubtitleTrack(
      SubtitleTrack.uri(uri.toString(), title: title),
    );
  }

  @override
  Future<void> setSubtitleOff() {
    return _player.setSubtitleTrack(SubtitleTrack.no());
  }

  @override
  Future<void> dispose() => _player.dispose();

  @override
  Widget buildView({Key? key}) {
    return Video(
      key: key,
      controller: videoController,
      controls: NoVideoControls,
      onEnterFullscreen: () async {},
      onExitFullscreen: () async {},
    );
  }
}

TargetPlatform get _hostPlatform {
  if (Platform.isWindows) {
    return TargetPlatform.windows;
  }
  if (Platform.isMacOS) {
    return TargetPlatform.macOS;
  }
  if (Platform.isLinux) {
    return TargetPlatform.linux;
  }
  return defaultTargetPlatform;
}
