import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/playback_check_in.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

enum PlayerErrorKind { load, notPlayable, noStream }

enum SubtitleNoticeKind { bitmapFailed }

class NextEpisodeOffer {
  const NextEpisodeOffer({required this.item, this.remaining});

  final EmbyItem item;
  final Duration? remaining;

  bool get autoplay => remaining != null;
}

class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.client,
    required this.itemId,
    required this.backend,
    required this.window,
    this.autoResume = true,
    this.progressInterval = const Duration(seconds: 10),
    this.progressFailBannerFor = const Duration(seconds: 4),
    this.controlsHideAfter = const Duration(seconds: 5),
    this.nextEpisodeCountdown = const Duration(seconds: 10),
    this.seekStep = const Duration(seconds: 10),
    this.onClose,
    this.onOpenItem,
    this.preferredMediaSourceId,
    this.preferredAudioStreamIndex,
    this.preferredSubtitleStreamIndex,
    this.startTimeTicks,
    this.settingsStore,
  }) {
    _bindBackend();
    window.addListener(_emit);
  }

  final EmbyClient client;
  String itemId;
  final VideoBackend backend;
  final PlayerWindow window;
  bool autoResume;
  final Duration progressInterval;
  final Duration progressFailBannerFor;
  final Duration controlsHideAfter;
  final Duration nextEpisodeCountdown;
  final Duration seekStep;
  final VoidCallback? onClose;
  final ValueChanged<String>? onOpenItem;
  PlayerSettingsStore? settingsStore;
  final String? preferredMediaSourceId;
  final int? preferredAudioStreamIndex;
  final int? preferredSubtitleStreamIndex;
  final int? startTimeTicks;

  final PlaybackCheckInMachine checkIn = PlaybackCheckInMachine();

  bool loading = true;
  bool controlsVisible = true;
  bool isPlaying = false;
  bool disconnected = false;
  String? disconnectDetail;
  bool progressSyncFailed = false;
  bool _disposed = false;
  bool _sessionStarted = false;
  int volume = 100;
  int _unmutedVolume = 100;
  int maxStreamingBitrate = kMpvMaxStreamingBitrate;
  int? audioStreamIndex;
  int? subtitleStreamIndex;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  PlayerErrorKind? error;
  EmbyException? loadFailure;
  SubtitleNoticeKind? subtitleNotice;
  NextEpisodeOffer? nextEpisode;
  bool playbackEnded = false;
  EmbyItem? item;
  EmbyUser? user;
  ResolvedPlayback? resolved;

  PlayMethod? get playMethod => resolved?.playMethod;
  bool get isTranscode => playMethod == PlayMethod.transcode;
  bool get isFullScreen => window.isFullScreen;
  List<MediaStreamInfo> get audioTracks =>
      resolved?.mediaSource.audioStreams ?? const [];
  List<MediaStreamInfo> get subtitleTracks =>
      resolved?.mediaSource.subtitleStreams ?? const [];

  Timer? _progressTimer;
  Timer? _progressFailBannerTimer;
  DateTime? _progressFailBannerAt;
  Timer? _subtitleNoticeTimer;
  Timer? _hideTimer;
  Timer? _nextTimer;
  Timer? _volumeSaveTimer;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;

  Future<void> start() async {
    error = null;
    loadFailure = null;
    disconnected = false;
    disconnectDetail = null;
    progressSyncFailed = false;
    subtitleNotice = null;
    nextEpisode = null;
    playbackEnded = false;
    loading = true;
    _emit();
    try {
      await _restoreVolume();
      item = await client.getItem(itemId);
      if (_disposed) {
        return;
      }
      if (!item!.isPlayable) {
        error = PlayerErrorKind.notPlayable;
        loading = false;
        _emit();
        return;
      }
      try {
        user = await client.getUser();
      } on EmbyException {
        user = null;
      }
      duration = durationFromTicks(item!.runTimeTicks ?? 0);
      subtitleStreamIndex = preferredSubtitleStreamIndex;
      audioStreamIndex = preferredAudioStreamIndex ?? audioStreamIndex;
      final chapterTicks = startTimeTicks;
      if (chapterTicks != null && chapterTicks > 0) {
        await _open(startTicks: chapterTicks);
        return;
      }
      final resumeTicks = item!.canResume
          ? item!.userData.playbackPositionTicks
          : 0;
      if (!autoResume) {
        await _open(startTicks: 0);
        return;
      }
      await _open(startTicks: resumeTicks > 0 ? _rewound(resumeTicks) : 0);
    } on EmbyException catch (failure) {
      if (_disposed) {
        return;
      }
      error = PlayerErrorKind.load;
      loadFailure = failure;
      loading = false;
      _emit();
    }
  }

  Future<void> togglePlay() async {
    if (loading || error != null) {
      return;
    }
    if (playbackEnded) {
      await replay();
      return;
    }
    await backend.playOrPause();
  }

  Future<void> replay() async {
    if (_disposed) {
      return;
    }
    playbackEnded = false;
    nextEpisode = null;
    _nextTimer?.cancel();
    _nextTimer = null;
    await _open(startTicks: 0);
  }

  void openEndedSeries() {
    final seriesId = item?.seriesId;
    if (seriesId != null && seriesId.isNotEmpty) {
      onOpenItem?.call(seriesId);
      return;
    }
    unawaited(close());
  }

  Future<void> seekRelative(Duration delta) {
    var target = position + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (duration > Duration.zero && target > duration) {
      target = duration;
    }
    return seekTo(target);
  }

  Future<void> seekTo(Duration target) async {
    if (resolved == null) {
      return;
    }
    onUserActivity();
    if (playbackEnded) {
      playbackEnded = false;
      await _open(startTicks: ticksFromDuration(target));
      return;
    }
    if (isTranscode) {
      await _reopen(startTicks: ticksFromDuration(target));
      return;
    }
    await backend.seek(target);
    position = target;
    _emit();
    await _reportProgress(eventName: 'Seek');
  }

  static const volumeWheelStep = 5;

  Future<void> setVolume(int value) async {
    volume = value.clamp(0, 100);
    if (volume > 0) {
      _unmutedVolume = volume;
    }
    await backend.setVolume(mpvVolumeForPercent(volume));
    onUserActivity();
    _scheduleVolumeSave();
  }

  Future<void> toggleMute() {
    if (volume > 0) {
      return setVolume(0);
    }
    return setVolume(_unmutedVolume <= 0 ? 100 : _unmutedVolume);
  }

  Future<void> nudgeVolume(int delta) {
    onUserActivity();
    return setVolume(volume + delta);
  }

  Future<void> setAudio(int index) async {
    audioStreamIndex = index;
    if (isTranscode) {
      await _reopen(startTicks: ticksFromDuration(position));
      return;
    }
    await backend.setAudioIndex(index);
    _emit();
    await _reportProgress(eventName: 'AudioTrackChange');
  }

  Future<void> setSubtitle(int? index) async {
    if (index == null) {
      subtitleStreamIndex = null;
      _clearSubtitleNotice();
      await backend.setSubtitleOff();
      _emit();
      await _reportProgress(eventName: 'SubtitleTrackChange');
      return;
    }
    final stream = resolved?.mediaSource.streamByIndex(index);
    if (stream == null || !stream.isSubtitle) {
      return;
    }
    if (stream.isBitmapSubtitle) {
      await _reopen(startTicks: ticksFromDuration(position), subtitle: index);
      return;
    }
    subtitleStreamIndex = index;
    _clearSubtitleNotice();
    final source = resolved!.mediaSource;
    await backend.setSubtitleUri(
      client.subtitleStreamUrl(
        itemId: itemId,
        mediaSourceId: source.id,
        index: index,
        format: stream.externalSubtitleFormat,
      ),
      title: stream.label,
    );
    _emit();
    await _reportProgress(eventName: 'SubtitleTrackChange');
  }

  Future<void> setMaxBitrate(int bitrate) async {
    maxStreamingBitrate = bitrate;
    await _reopen(startTicks: ticksFromDuration(position));
  }

  Future<void> toggleFullScreen() {
    return window.setFullScreen(!window.isFullScreen);
  }

  Future<void> onEscape() async {
    if (window.isFullScreen) {
      await window.setFullScreen(false);
      return;
    }
    await close();
  }

  void onUserActivity() {
    controlsVisible = true;
    _scheduleHide();
    _emit();
  }

  void hideControlsOnPointerExit() {
    if (!isPlaying || nextEpisode != null || playbackEnded) {
      return;
    }
    _hideTimer?.cancel();
    if (!controlsVisible) {
      return;
    }
    controlsVisible = false;
    _emit();
  }

  void toggleControls() {
    if (nextEpisode != null || playbackEnded) {
      onUserActivity();
      return;
    }
    if (controlsVisible) {
      _hideTimer?.cancel();
      controlsVisible = false;
      _emit();
      return;
    }
    onUserActivity();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (isPlaying && nextEpisode == null && !playbackEnded) {
      _hideTimer = Timer(controlsHideAfter, () {
        controlsVisible = false;
        _emit();
      });
    }
  }

  void cancelNextEpisode() {
    _nextTimer?.cancel();
    _nextTimer = null;
    nextEpisode = null;
    onUserActivity();
  }

  Future<void> playNextEpisode() async {
    final next = nextEpisode?.item;
    _nextTimer?.cancel();
    _nextTimer = null;
    nextEpisode = null;
    if (next == null) {
      return;
    }
    if (onOpenItem != null) {
      await shutdownSession();
      onOpenItem!(next.id);
      return;
    }
    await shutdownSession();
    itemId = next.id;
    autoResume = false;
    await start();
  }

  Future<void> close() async {
    _hideTimer?.cancel();
    _nextTimer?.cancel();
    _progressTimer?.cancel();
    final shouldReport = checkIn.stop();
    _sessionStarted = false;
    if (window.isFullScreen) {
      await window.setFullScreen(false);
    }
    onClose?.call();
    if (!shouldReport) {
      return;
    }
    try {
      await client.reportStopped(_currentReport());
    } on EmbyException {
      _markProgressSyncFailed();
    }
  }

  Future<void> shutdownSession() async {
    if (_disposed) {
      return;
    }
    _hideTimer?.cancel();
    _nextTimer?.cancel();
    await _persistVolume();
    await _stopSession();
    if (window.isFullScreen) {
      await window.setFullScreen(false);
    }
  }

  void _bindBackend() {
    _positionSub = backend.positionStream.listen((value) {
      position = value;
      if (disconnected && isPlaying) {
        disconnected = false;
        disconnectDetail = null;
      }
      _emit();
    });
    _durationSub = backend.durationStream.listen((value) {
      if (value > Duration.zero) {
        duration = value;
        _emit();
      }
    });
    _playingSub = backend.playingStream.listen((playing) {
      isPlaying = playing;
      if (playing) {
        disconnected = false;
        disconnectDetail = null;
        onUserActivity();
      } else {
        controlsVisible = true;
        _hideTimer?.cancel();
      }
      _emit();
      if (_sessionStarted && !disconnected) {
        unawaited(_reportProgress(eventName: playing ? 'Unpause' : 'Pause'));
      }
    });
    _completedSub = backend.completedStream.listen((done) {
      if (done) {
        unawaited(_handleCompleted());
      }
    });
    _errorSub = backend.errorStream.listen((message) {
      if (_disposed || isPlaying) {
        return;
      }
      if (!isFatalPlaybackError(message, playing: false)) {
        return;
      }
      disconnected = true;
      disconnectDetail = message.trim().isEmpty ? null : message.trim();
      controlsVisible = true;
      _hideTimer?.cancel();
      _emit();
    });
  }

  Future<void> _open({
    required int startTicks,
    int? audio,
    int? subtitle,
  }) async {
    loading = true;
    disconnected = false;
    disconnectDetail = null;
    nextEpisode = null;
    playbackEnded = false;
    _nextTimer?.cancel();
    _emit();

    try {
      final info = await client.getPlaybackInfo(
        itemId: itemId,
        maxStreamingBitrate: maxStreamingBitrate,
        startTimeTicks: startTicks > 0 ? startTicks : null,
        audioStreamIndex: audio ?? preferredAudioStreamIndex,
        subtitleStreamIndex: subtitle ?? preferredSubtitleStreamIndex,
        mediaSourceId: preferredMediaSourceId,
      );
      if (_disposed) {
        return;
      }
      final next = resolvePlayback(
        info: info,
        baseUrl: client.baseUrl!,
        accessToken: client.accessToken!,
        itemId: itemId,
      );
      if (next == null) {
        error = PlayerErrorKind.noStream;
        loading = false;
        _emit();
        return;
      }
      resolved = next;
      audioStreamIndex = audio ?? next.mediaSource.defaultAudioStreamIndex;
      if (subtitle != null) {
        subtitleStreamIndex = subtitle;
      } else {
        subtitleStreamIndex = _defaultTextSubtitle(next.mediaSource);
      }

      if (subtitle != null) {
        final stream = next.mediaSource.streamByIndex(subtitle);
        if (stream != null && stream.isBitmapSubtitle && !next.isTranscode) {
          subtitleStreamIndex = null;
          _showSubtitleNotice(SubtitleNoticeKind.bitmapFailed);
        }
      }

      await backend.open(
        VideoOpenRequest(
          url: next.streamUrl,
          start: durationFromTicks(startTicks),
          headers: client.sessionHeaders,
        ),
      );
      await backend.setVolume(mpvVolumeForPercent(volume));
      position = durationFromTicks(startTicks);
      final runtime = next.mediaSource.runTimeTicks ?? item?.runTimeTicks ?? 0;
      if (runtime > 0) {
        duration = durationFromTicks(runtime);
      }
      isPlaying = backend.isPlaying;

      await _applyTracks(next);
      await _beginSession(startTicks: startTicks);
      loading = false;
      error = null;
      onUserActivity();
      _emit();
    } on EmbyException catch (failure) {
      if (_disposed) {
        return;
      }
      error = PlayerErrorKind.load;
      loadFailure = failure;
      loading = false;
      _emit();
    }
  }

  Future<void> _applyTracks(ResolvedPlayback next) async {
    if (audioStreamIndex != null) {
      await backend.setAudioIndex(audioStreamIndex!);
    }
    if (subtitleStreamIndex == null) {
      await backend.setSubtitleOff();
      return;
    }
    if (next.isTranscode) {
      return;
    }
    final stream = next.mediaSource.streamByIndex(subtitleStreamIndex!);
    if (stream == null || !stream.isTextSubtitle) {
      return;
    }
    await backend.setSubtitleUri(
      client.subtitleStreamUrl(
        itemId: itemId,
        mediaSourceId: next.mediaSource.id,
        index: subtitleStreamIndex!,
        format: stream.externalSubtitleFormat,
      ),
      title: stream.label,
    );
  }

  int? _defaultTextSubtitle(PlaybackMediaSource source) {
    final index = source.defaultSubtitleStreamIndex;
    if (index == null) {
      return null;
    }
    final stream = source.streamByIndex(index);
    if (stream != null && stream.isTextSubtitle) {
      return index;
    }
    return null;
  }

  Future<void> _reopen({required int startTicks, int? subtitle}) async {
    await _stopSession();
    await _open(
      startTicks: startTicks,
      audio: audioStreamIndex,
      subtitle: subtitle ?? subtitleStreamIndex,
    );
  }

  Future<void> _beginSession({required int startTicks}) async {
    checkIn.start();
    _sessionStarted = true;
    try {
      await client.reportPlaying(_currentReport(positionTicks: startTicks));
      _clearProgressSyncFailed();
    } on EmbyException {
      _markProgressSyncFailed();
    }
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(progressInterval, (_) {
      unawaited(_reportProgress(eventName: 'TimeUpdate'));
    });
  }

  Future<void> _reportProgress({String? eventName}) async {
    if (!checkIn.canProgress) {
      return;
    }
    try {
      await client.reportProgress(_currentReport(eventName: eventName));
      _clearProgressSyncFailed();
    } on EmbyException {
      _markProgressSyncFailed();
    }
  }

  Future<void> _stopSession() async {
    _progressTimer?.cancel();
    _progressTimer = null;
    if (!checkIn.stop()) {
      _sessionStarted = false;
      return;
    }
    _sessionStarted = false;
    try {
      await client.reportStopped(_currentReport());
      _clearProgressSyncFailed();
    } on EmbyException {
      _markProgressSyncFailed();
    }
  }

  void _markProgressSyncFailed() {
    final now = DateTime.now();
    final last = _progressFailBannerAt;
    if (last != null && now.difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _progressFailBannerAt = now;
    progressSyncFailed = true;
    _emit();
    _progressFailBannerTimer?.cancel();
    _progressFailBannerTimer = Timer(progressFailBannerFor, () {
      if (_disposed) {
        return;
      }
      progressSyncFailed = false;
      _emit();
    });
  }

  void _showSubtitleNotice(SubtitleNoticeKind kind) {
    _subtitleNoticeTimer?.cancel();
    subtitleNotice = kind;
    _emit();
    _subtitleNoticeTimer = Timer(progressFailBannerFor, () {
      if (_disposed) {
        return;
      }
      subtitleNotice = null;
      _emit();
    });
  }

  void _clearSubtitleNotice() {
    _subtitleNoticeTimer?.cancel();
    _subtitleNoticeTimer = null;
    if (subtitleNotice == null) {
      return;
    }
    subtitleNotice = null;
    _emit();
  }

  void _clearProgressSyncFailed() {
    _progressFailBannerTimer?.cancel();
    _progressFailBannerTimer = null;
    _progressFailBannerAt = null;
    if (!progressSyncFailed) {
      return;
    }
    progressSyncFailed = false;
    _emit();
  }

  PlaybackReport _currentReport({int? positionTicks, String? eventName}) {
    final resolvedPlayback = resolved;
    return PlaybackReport(
      itemId: itemId,
      mediaSourceId: resolvedPlayback?.mediaSource.id ?? itemId,
      playSessionId: resolvedPlayback?.playSessionId ?? '',
      playMethod: resolvedPlayback?.playMethod ?? PlayMethod.directStream,
      positionTicks: positionTicks ?? ticksFromDuration(position),
      isPaused: !isPlaying,
      volumeLevel: volume,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      eventName: eventName,
    );
  }

  Future<void> _handleCompleted() async {
    if (_disposed || checkIn.isStopped) {
      return;
    }
    isPlaying = false;
    unawaited(_stopSession());
    if (item == null || !item!.isEpisode) {
      _showPlaybackEnded();
      return;
    }
    try {
      final next = await client.getNextEpisode(item!);
      if (_disposed) {
        return;
      }
      if (next == null) {
        _showPlaybackEnded();
        return;
      }
      final autoplay = user?.enableNextEpisodeAutoPlay ?? true;
      if (!autoplay) {
        nextEpisode = NextEpisodeOffer(item: next);
        controlsVisible = true;
        _emit();
        return;
      }
      nextEpisode = NextEpisodeOffer(
        item: next,
        remaining: nextEpisodeCountdown,
      );
      controlsVisible = true;
      _emit();
      _nextTimer?.cancel();
      _nextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        final offer = nextEpisode;
        if (offer == null || offer.remaining == null) {
          timer.cancel();
          return;
        }
        final left = offer.remaining! - const Duration(seconds: 1);
        if (left <= Duration.zero) {
          timer.cancel();
          unawaited(playNextEpisode());
        } else {
          nextEpisode = NextEpisodeOffer(item: offer.item, remaining: left);
          _emit();
        }
      });
    } on EmbyException {
      _showPlaybackEnded();
    }
  }

  void _showPlaybackEnded() {
    if (_disposed) {
      return;
    }
    playbackEnded = true;
    nextEpisode = null;
    controlsVisible = true;
    _hideTimer?.cancel();
    _emit();
  }

  Future<PlayerSettingsStore> _settings() async {
    return settingsStore ??= await openPlayerSettingsStore();
  }

  Future<void> _restoreVolume() async {
    try {
      volume = (await (await _settings()).read()).clampedVolume;
      if (volume > 0) {
        _unmutedVolume = volume;
      }
      await backend.setVolume(mpvVolumeForPercent(volume));
    } catch (_) {}
  }

  void _scheduleVolumeSave() {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistVolume());
    });
  }

  Future<void> _persistVolume() async {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = null;
    try {
      await (await _settings()).write(PlayerSettings(volume: volume));
    } catch (_) {}
  }

  int _rewound(int ticks) {
    final rewind = (user?.resumeRewindSeconds ?? 0) * kEmbyTicksPerSecond;
    final value = ticks - rewind;
    return value < 0 ? 0 : value;
  }

  void _emit() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _progressFailBannerTimer?.cancel();
    _subtitleNoticeTimer?.cancel();
    _nextTimer?.cancel();
    _volumeSaveTimer?.cancel();
    unawaited(_persistVolume());
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_completedSub?.cancel());
    unawaited(_errorSub?.cancel());
    window.removeListener(_emit);
    unawaited(backend.dispose());
    super.dispose();
  }
}

/// UI 音量百分比(0–100)到 mpv volume 的感知幂映射:f(x) = x³。
///
/// mpv 的音量刻度近似线性作用于信号幅度,而人耳响度感知近似幂律;
/// 以立方曲线换算,使等量百分比变化对应等量听感变化,与主流播放器一致。
/// 持久化与 UI 显示均保存用户百分比,所有 backend 音量调用统一经此换算。
double mpvVolumeForPercent(int percent) {
  final x = (percent.clamp(0, 100)) / 100;
  return 100 * x * x * x;
}

bool isFatalPlaybackError(String message, {required bool playing}) {
  final text = message.toLowerCase();
  if (text.contains('end of file') ||
      text.contains('libass') ||
      text.contains('subtitle')) {
    return false;
  }
  const network = [
    'connection',
    'network',
    'http error',
    'failed to open',
    'timed out',
    'timeout',
    'connection lost',
  ];
  if (network.any(text.contains)) {
    return true;
  }
  return !playing;
}
