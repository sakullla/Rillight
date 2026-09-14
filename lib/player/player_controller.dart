import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/playback_check_in.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

enum PlayerErrorKind { load, notPlayable, noStream }

enum SubtitleNoticeKind { bitmapFailed, bitmapBurnIn }

/// 跳过区间类别:片头/片尾。
enum PlayerSkipKind { intro, outro }

/// 一个可跳过的区间(服务器章节标记或手动时长换算)。
class PlayerSkipSegment {
  const PlayerSkipSegment({
    required this.kind,
    required this.start,
    required this.end,
  });

  final PlayerSkipKind kind;
  final Duration start;
  final Duration end;
}

/// 手动片头/片尾时长的可选档位(秒)。
const List<int> kManualSkipChoices = [30, 60, 90, 120];

/// 倍速固定阶梯(快捷键降/升档与控制层菜单共用)。
const List<double> kPlaybackRateLadder = [
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
  2.5,
  3.0,
];

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
    PlaybackSessionSnapshotStore? snapshotStore,
  }) : snapshotStore =
           snapshotStore ??
           FilePlaybackSessionSnapshotStore.forCurrentProcess() {
    activeMediaSourceId = preferredMediaSourceId;
    _bindBackend();
    window.addListener(_emit);
  }

  /// 关窗/换集时等待 Stopped 送达的上限;超时视为失败,不再阻塞。
  static const Duration stoppedDeadline = Duration(seconds: 3);

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

  /// 会话快照:Playing/Progress 成功后写入,Stopped 成功后删除,
  /// 供宿主在播放进程被终止后代发 Stopped。
  final PlaybackSessionSnapshotStore snapshotStore;

  /// 首次起播请求携带的源/轨道/章节起点;进程内切集([_playItem])时清除,
  /// 这些偏好只对最初打开的条目有效。
  String? preferredMediaSourceId;
  int? preferredAudioStreamIndex;
  int? preferredSubtitleStreamIndex;
  int? startTimeTicks;

  final PlaybackCheckInMachine checkIn = PlaybackCheckInMachine();

  bool loading = true;
  bool controlsVisible = true;
  bool isPlaying = false;
  bool disconnected = false;
  String? disconnectDetail;

  /// 进度同步失败横幅是否显示。单次失败 [progressFailBannerFor] 后自动隐藏;
  /// 连续两次及以上失败([progressSyncPersistent])持续显示直到任一上报成功
  /// 或用户手动关闭([dismissProgressSyncBanner])。
  bool progressSyncFailed = false;
  bool progressSyncPersistent = false;

  /// 服务器返回 401:进度轮询已停止,横幅改为「会话已过期」文案;
  /// 快照保留,交由宿主用主进程会话代发 Stopped。
  bool sessionExpired = false;
  int _reportFailureStreak = 0;
  bool _disposed = false;
  bool _sessionStarted = false;
  int volume = 100;
  int _unmutedVolume = 100;
  double playbackRate = 1.0;
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
  PlayerSeriesPreference? _rememberedPreference;
  Map<String, PlayerSeriesPreference> _seriesPreferences = const {};

  // --- 剧集列表与切集(R7) ---
  bool episodeListLoading = false;
  bool episodeListFailed = false;
  List<EmbyItem> seasons = const [];
  List<EmbyItem> episodes = const [];
  String? episodeSeasonId;

  // --- 片头片尾跳过(R8) ---
  List<PlayerSkipSegment> _skipSegments = const [];
  bool _hasServerSkipMarkers = false;
  PlayerSkipSegment? activeSkipSegment;
  int? manualIntroSkipSeconds;
  int? manualOutroSkipSeconds;

  // --- 媒体源切换(R9) ---
  List<PlaybackMediaSource> mediaSources = const [];
  String? activeMediaSourceId;

  PlayMethod? get playMethod => resolved?.playMethod;
  bool get isTranscode => playMethod == PlayMethod.transcode;
  bool get isFullScreen => window.isFullScreen;
  List<MediaStreamInfo> get audioTracks =>
      resolved?.mediaSource.audioStreams ?? const [];
  List<MediaStreamInfo> get subtitleTracks =>
      resolved?.mediaSource.subtitleStreams ?? const [];

  /// 播放剧集时才提供剧集列表入口;电影不显示。
  bool get canBrowseEpisodes {
    final current = item;
    final seriesId = current?.seriesId;
    return current != null &&
        current.isEpisode &&
        seriesId != null &&
        seriesId.isNotEmpty;
  }

  /// 无服务器章节标记的剧集才提供手动片头/片尾设置。
  bool get canSetManualSkip => canBrowseEpisodes && !_hasServerSkipMarkers;

  /// 多个媒体源时才提供换源入口。
  bool get canSwitchMediaSource => mediaSources.length > 1;

  Timer? _progressTimer;
  Timer? _progressFailBannerTimer;
  Timer? _subtitleNoticeTimer;

  /// 播放完成路径发出但未等待的 Stopped;close()/shutdownSession() 先等它,
  /// 保证倒计时期间关窗不会与之竞争。
  Future<void>? _pendingStopped;

  /// 快照 IO 串行化:写与删按发起顺序执行,避免 Stopped 删除后被迟到的
  /// Progress 写入复活;失败一律吞掉。
  final List<Future<void> Function()> _snapshotOps = [];
  bool _snapshotDraining = false;
  Timer? _hideTimer;
  Timer? _nextTimer;
  Timer? _settingsSaveTimer;
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
    progressSyncPersistent = false;
    sessionExpired = false;
    _reportFailureStreak = 0;
    _progressFailBannerTimer?.cancel();
    _progressFailBannerTimer = null;
    subtitleNotice = null;
    nextEpisode = null;
    playbackEnded = false;
    loading = true;
    mediaSources = const [];
    _skipSegments = const [];
    _hasServerSkipMarkers = false;
    activeSkipSegment = null;
    manualIntroSkipSeconds = null;
    manualOutroSkipSeconds = null;
    _emit();
    try {
      await _restoreSettings();
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
      // 换条目后,另一剧的剧集列表不再复用。
      if (_episodeSeriesId != null && _episodeSeriesId != item!.seriesId) {
        _episodeSeriesId = null;
        seasons = const [];
        episodes = const [];
        episodeSeasonId = null;
      }
      try {
        user = await client.getUser();
      } on EmbyException {
        user = null;
      }
      duration = durationFromTicks(item!.runTimeTicks ?? 0);
      _applyRememberedPreference();
      subtitleStreamIndex = preferredSubtitleStreamIndex;
      audioStreamIndex = preferredAudioStreamIndex ?? audioStreamIndex;
      final memory = _rememberedPreference;
      final memoryAudio = memory?.audioStreamIndex;
      final memorySubtitle = memory?.subtitleStreamIndex;
      final memorySubtitleOff =
          memory != null && memory.subtitleStreamIndex == null;
      final chapterTicks = startTimeTicks;
      if (chapterTicks != null && chapterTicks > 0) {
        await _open(
          startTicks: chapterTicks,
          audio: memoryAudio,
          subtitle: memorySubtitle,
          subtitleOff: memorySubtitleOff,
        );
        return;
      }
      final resumeTicks = item!.canResume
          ? item!.userData.playbackPositionTicks
          : 0;
      if (!autoResume) {
        await _open(
          startTicks: 0,
          audio: memoryAudio,
          subtitle: memorySubtitle,
          subtitleOff: memorySubtitleOff,
        );
        return;
      }
      await _open(
        startTicks: resumeTicks > 0 ? _rewound(resumeTicks) : 0,
        audio: memoryAudio,
        subtitle: memorySubtitle,
        subtitleOff: memorySubtitleOff,
      );
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
    await _open(
      startTicks: 0,
      audio: audioStreamIndex,
      subtitle: subtitleStreamIndex,
      subtitleOff: subtitleStreamIndex == null,
    );
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
      await _open(
        startTicks: ticksFromDuration(target),
        audio: audioStreamIndex,
        subtitle: subtitleStreamIndex,
        subtitleOff: subtitleStreamIndex == null,
      );
      return;
    }
    if (isTranscode) {
      await _reopen(startTicks: ticksFromDuration(target));
      return;
    }
    await backend.seek(target);
    _setPosition(target);
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
    _scheduleSettingsSave();
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

  /// 设置倍速:阶梯内取值,立即下发 backend 并持久化(跨集/重启沿用)。
  Future<void> setRate(double rate) async {
    final value = rate
        .clamp(kPlaybackRateLadder.first, kPlaybackRateLadder.last)
        .toDouble();
    if (playbackRate == value) {
      onUserActivity();
      return;
    }
    playbackRate = value;
    await backend.setRate(playbackRate);
    onUserActivity();
    _scheduleSettingsSave();
  }

  /// 快捷键降档([ )与升档( ] ):沿固定阶梯移动。
  void nudgeRateDown() {
    unawaited(_stepRate(-1));
  }

  void nudgeRateUp() {
    unawaited(_stepRate(1));
  }

  Future<void> _stepRate(int direction) async {
    double next;
    if (direction > 0) {
      next = kPlaybackRateLadder.last;
      for (final value in kPlaybackRateLadder) {
        if (value > playbackRate) {
          next = value;
          break;
        }
      }
    } else {
      next = kPlaybackRateLadder.first;
      for (final value in kPlaybackRateLadder.reversed) {
        if (value < playbackRate) {
          next = value;
          break;
        }
      }
    }
    await setRate(next);
  }

  bool get isAlwaysOnTop => window.isAlwaysOnTop;

  Future<void> toggleAlwaysOnTop() {
    onUserActivity();
    return window.setAlwaysOnTop(!window.isAlwaysOnTop);
  }

  Future<void> setAudio(int index) async {
    audioStreamIndex = index;
    await _persistSeriesPreference();
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
      await _persistSeriesPreference();
      await _reportProgress(eventName: 'SubtitleTrackChange');
      return;
    }
    final stream = resolved?.mediaSource.streamByIndex(index);
    if (stream == null || !stream.isSubtitle) {
      return;
    }
    if (stream.isBitmapSubtitle) {
      // 先记录选择意图(供按剧记忆)。
      subtitleStreamIndex = index;
      await _persistSeriesPreference();
      if (!isTranscode) {
        // 直连:mpv 直接渲染容器内嵌位图轨道,无需烧录重开。
        _clearSubtitleNotice();
        await backend.setSubtitleIndex(index);
        _emit();
        await _reportProgress(eventName: 'SubtitleTrackChange');
        return;
      }
      // 转码:请求服务器烧录进流。
      _showSubtitleNotice(SubtitleNoticeKind.bitmapBurnIn);
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
    await _persistSeriesPreference();
    await _reportProgress(eventName: 'SubtitleTrackChange');
  }

  Future<void> setMaxBitrate(int bitrate) async {
    maxStreamingBitrate = bitrate;
    await _persistSeriesPreference();
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
    await _playItem(next.id, fromStart: true);
  }

  /// 切到任意集(剧集列表入口):换集后重置为默认媒体源,
  /// 续播语义由 start() 按新集的进度决定。
  Future<void> playEpisode(EmbyItem episode) async {
    if (episode.id == itemId) {
      return;
    }
    await _playItem(episode.id, fromStart: false);
  }

  /// 进程内切到另一集(ADR-4):不经 host 重启通道,直接以新 itemId
  /// 重走 start(),autoResume 由 [fromStart] 决定——剧集列表切集
  /// (fromStart=false)时部分观看的集从续播位置起播。
  /// 首次起播请求携带的源/轨道/章节起点只对首个条目有效,换集后清除。
  Future<void> _playItem(String targetId, {required bool fromStart}) async {
    await shutdownSession();
    itemId = targetId;
    activeMediaSourceId = null;
    preferredMediaSourceId = null;
    preferredAudioStreamIndex = null;
    preferredSubtitleStreamIndex = null;
    startTimeTicks = null;
    autoResume = !fromStart;
    await start();
  }

  // ---------------------------------------------------------------------
  // 剧集列表与切集(R7)
  // ---------------------------------------------------------------------

  /// 拉取当前剧的季列表与当前季的分集列表。
  /// 失败仅置失败状态(入口隐藏/可重试),不阻塞播放。
  Future<void> loadEpisodeList() async {
    if (!canBrowseEpisodes) {
      return;
    }
    final seriesId = item!.seriesId!;
    if (_episodeSeriesId == seriesId) {
      // 同剧已加载:仅刷新当前集高亮,不重复拉取。
      return;
    }
    await _loadSeasons(seriesId);
  }

  /// 已加载剧集列表归属的 seriesId;start() 换条目时重置。
  String? _episodeSeriesId;

  Future<void> _loadSeasons(String seriesId) async {
    episodeListLoading = true;
    episodeListFailed = false;
    _emit();
    try {
      final loaded = await client.getItems(
        parentId: seriesId,
        includeItemTypes: 'Season',
        recursive: true,
        sortBy: 'IndexNumber',
        sortOrder: 'Ascending',
        fields: EmbyClient.gridFields,
      );
      if (_disposed) {
        return;
      }
      seasons = loaded;
      var seasonId = item?.seasonId;
      final hasSeason =
          seasonId != null && loaded.any((season) => season.id == seasonId);
      if (!hasSeason) {
        // 回退:按季号匹配,否则取第一季。
        final parentIndex = item?.parentIndexNumber;
        var matched = parentIndex == null
            ? null
            : loaded
                  .where((season) => season.indexNumber == parentIndex)
                  .toList();
        if (matched != null && matched.isNotEmpty) {
          seasonId = matched.first.id;
        } else {
          seasonId = loaded.isEmpty ? null : loaded.first.id;
        }
      }
      await _loadSeasonEpisodes(seasonId);
      // 分集列表拉取成功后才标记归属;失败时保持未加载,
      // 保证同剧重试(loadEpisodeList)不会因早退而失效。
      _episodeSeriesId = seriesId;
      episodeListLoading = false;
      _emit();
    } on EmbyException {
      if (_disposed) {
        return;
      }
      episodeListLoading = false;
      episodeListFailed = true;
      _emit();
    }
  }

  /// 切换剧集列表显示的季(不切集,仅换列表内容)。
  Future<void> selectSeason(String seasonId) async {
    if (episodeListLoading || episodeSeasonId == seasonId) {
      return;
    }
    episodeListLoading = true;
    episodeListFailed = false;
    _emit();
    try {
      await _loadSeasonEpisodes(seasonId);
    } on EmbyException {
      if (_disposed) {
        return;
      }
      episodeListFailed = true;
    }
    episodeListLoading = false;
    _emit();
  }

  Future<void> _loadSeasonEpisodes(String? seasonId) async {
    if (seasonId == null || seasonId.isEmpty) {
      episodes = const [];
      episodeSeasonId = null;
      return;
    }
    final loaded = await client.getItems(
      parentId: seasonId,
      includeItemTypes: 'Episode',
      recursive: true,
      sortBy: 'IndexNumber',
      sortOrder: 'Ascending',
      fields: EmbyClient.gridFields,
    );
    if (_disposed) {
      return;
    }
    episodes = loaded;
    episodeSeasonId = seasonId;
  }

  // ---------------------------------------------------------------------
  // 片头片尾跳过(R8)
  // ---------------------------------------------------------------------

  /// 跳过当前所在区间(跳到区间终点)。
  Future<void> skipCurrentSegment() async {
    final segment = activeSkipSegment;
    if (segment == null) {
      return;
    }
    onUserActivity();
    await seekTo(segment.end);
  }

  /// 手动设置片头时长(秒);null/非正数表示关闭。按剧记忆并立即生效。
  Future<void> setManualIntroSkip(int? seconds) async {
    manualIntroSkipSeconds = _normalizeManualSkip(seconds);
    await _persistSeriesPreference();
    _rebuildSkipSegments();
    _emit();
  }

  /// 手动设置片尾时长(秒);null/非正数表示关闭。按剧记忆并立即生效。
  Future<void> setManualOutroSkip(int? seconds) async {
    manualOutroSkipSeconds = _normalizeManualSkip(seconds);
    await _persistSeriesPreference();
    _rebuildSkipSegments();
    _emit();
  }

  /// 关闭手动片头/片尾(不影响服务器章节标记)。
  Future<void> clearManualSkip() async {
    manualIntroSkipSeconds = null;
    manualOutroSkipSeconds = null;
    await _persistSeriesPreference();
    _rebuildSkipSegments();
    _emit();
  }

  static int? _normalizeManualSkip(int? seconds) =>
      (seconds != null && seconds > 0) ? seconds : null;

  void _rebuildSkipSegments() {
    final current = item;
    final segments = <PlayerSkipSegment>[];
    _hasServerSkipMarkers = false;
    if (current != null) {
      final chapterSegments = _chapterSkipSegments(current.chapters);
      if (chapterSegments.isNotEmpty) {
        // 优先服务器章节标记。
        _hasServerSkipMarkers = true;
        segments.addAll(chapterSegments);
      } else {
        final intro = manualIntroSkipSeconds;
        final outro = manualOutroSkipSeconds;
        if (intro != null && intro > 0) {
          segments.add(
            PlayerSkipSegment(
              kind: PlayerSkipKind.intro,
              start: Duration.zero,
              end: Duration(seconds: intro),
            ),
          );
        }
        if (outro != null && outro > 0 && duration > Duration.zero) {
          final end = duration;
          var start = end - Duration(seconds: outro);
          if (start < Duration.zero) {
            start = Duration.zero;
          }
          if (start < end) {
            segments.add(
              PlayerSkipSegment(
                kind: PlayerSkipKind.outro,
                start: start,
                end: end,
              ),
            );
          }
        }
      }
    }
    _skipSegments = segments;
    _updateActiveSkip();
  }

  /// 服务器章节标记:Name 含 Intro/Outro/片头/片尾 的章节区间。
  /// 区间终点为下一章节起点;末章取片长(不可得时退 30 秒)。
  List<PlayerSkipSegment> _chapterSkipSegments(List<ItemChapter> chapters) {
    if (chapters.isEmpty) {
      return const [];
    }
    final result = <PlayerSkipSegment>[];
    for (var i = 0; i < chapters.length; i++) {
      final name = chapters[i].name.toLowerCase();
      final isOutro = name.contains('outro') || name.contains('片尾');
      final isIntro =
          !isOutro && (name.contains('intro') || name.contains('片头'));
      if (!isIntro && !isOutro) {
        continue;
      }
      final start = durationFromTicks(chapters[i].startPositionTicks);
      var end = i + 1 < chapters.length
          ? durationFromTicks(chapters[i + 1].startPositionTicks)
          : (duration > start ? duration : start + const Duration(seconds: 30));
      if (end <= start) {
        continue;
      }
      result.add(
        PlayerSkipSegment(
          kind: isOutro ? PlayerSkipKind.outro : PlayerSkipKind.intro,
          start: start,
          end: end,
        ),
      );
    }
    return result;
  }

  void _updateActiveSkip() {
    PlayerSkipSegment? next;
    for (final segment in _skipSegments) {
      if (position >= segment.start && position < segment.end) {
        next = segment;
        break;
      }
    }
    activeSkipSegment = next;
  }

  void _setPosition(Duration value) {
    position = value;
    _updateActiveSkip();
  }

  // ---------------------------------------------------------------------
  // 媒体源切换(R9)
  // ---------------------------------------------------------------------

  /// 播放中切换媒体源:从当前进度继续,字幕/音轨选择尽量迁移
  /// (新源缺失所选轨道时回退默认,见 [_open])。
  Future<void> switchMediaSource(String sourceId) async {
    final current = resolved;
    if (current == null ||
        sourceId == current.mediaSource.id ||
        mediaSources.every((source) => source.id != sourceId)) {
      return;
    }
    final startTicks = ticksFromDuration(position);
    activeMediaSourceId = sourceId;
    onUserActivity();
    await _reopen(startTicks: startTicks);
  }

  /// 关闭播放器:取消定时器 → 在 [stoppedDeadline] 内等待 Stopped 送达
  /// (或失败/超时)→ 再回调 [onClose]。宿主据此在 onClose 后安全退出进程。
  Future<void> close() async {
    _hideTimer?.cancel();
    _nextTimer?.cancel();
    _nextTimer = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    await _awaitPendingStopped();
    final shouldReport = checkIn.stop();
    _sessionStarted = false;
    if (window.isFullScreen) {
      await window.setFullScreen(false);
    }
    if (shouldReport) {
      await _sendStopped();
    }
    onClose?.call();
  }

  Future<void> shutdownSession() async {
    if (_disposed) {
      return;
    }
    _hideTimer?.cancel();
    _nextTimer?.cancel();
    _nextTimer = null;
    await _persistSettings();
    await _stopSession();
    if (window.isFullScreen) {
      await window.setFullScreen(false);
    }
  }

  /// 手动关闭进度同步失败横幅(持续显示态可关闭;失败计数保留,
  /// 再次失败仍按持续态显示)。
  void dismissProgressSyncBanner() {
    _progressFailBannerTimer?.cancel();
    _progressFailBannerTimer = null;
    if (!progressSyncFailed) {
      return;
    }
    progressSyncFailed = false;
    _emit();
  }

  void _bindBackend() {
    _positionSub = backend.positionStream.listen((value) {
      _setPosition(value);
      if (disconnected && isPlaying) {
        disconnected = false;
        disconnectDetail = null;
      }
      _emit();
    });
    _durationSub = backend.durationStream.listen((value) {
      if (value > Duration.zero) {
        duration = value;
        // 片长更新后手动片尾区间终点随之变化。
        _rebuildSkipSegments();
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
    bool subtitleOff = false,
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
        subtitleStreamIndex: subtitleOff
            ? null
            : (subtitle ?? preferredSubtitleStreamIndex),
        mediaSourceId: activeMediaSourceId ?? preferredMediaSourceId,
      );
      if (_disposed) {
        return;
      }
      mediaSources = info.mediaSources;
      final next = resolvePlayback(
        info: info,
        baseUrl: client.baseUrl!,
        accessToken: client.accessToken!,
        itemId: itemId,
        mediaSourceId: activeMediaSourceId ?? preferredMediaSourceId,
      );
      if (next == null) {
        error = PlayerErrorKind.noStream;
        loading = false;
        _emit();
        return;
      }
      resolved = next;
      audioStreamIndex = audio ?? next.mediaSource.defaultAudioStreamIndex;
      // 记忆的音轨在新一集不存在时回退默认,避免下发无效轨道。
      if (audioStreamIndex != null &&
          !next.mediaSource.audioStreams.any(
            (stream) => stream.index == audioStreamIndex,
          )) {
        audioStreamIndex = next.mediaSource.defaultAudioStreamIndex;
      }
      if (subtitle != null) {
        final stream = next.mediaSource.streamByIndex(subtitle);
        if (stream != null && stream.isSubtitle) {
          subtitleStreamIndex = subtitle;
        } else {
          subtitleStreamIndex = _defaultTextSubtitle(next.mediaSource);
        }
      } else if (subtitleOff) {
        subtitleStreamIndex = null;
      } else {
        subtitleStreamIndex = _defaultTextSubtitle(next.mediaSource);
      }

      if (subtitle != null) {
        final stream = next.mediaSource.streamByIndex(subtitle);
        if (stream != null && stream.isBitmapSubtitle) {
          if (next.isTranscode) {
            // 转码:服务器烧录进流。
            _showSubtitleNotice(SubtitleNoticeKind.bitmapBurnIn);
          }
          // 直连:保留选择,_applyTracks 直接选内嵌轨道本地渲染。
        }
      }

      await backend.open(
        VideoOpenRequest(
          url: next.streamUrl,
          start: durationFromTicks(startTicks),
          // 仅当流地址与 Emby 服务器同源时附加会话头;strm 等远端
          // 直连地址传空 headers,避免令牌泄漏给第三方主机。
          headers: playbackStreamHeaders(
            streamUrl: next.streamUrl,
            baseUrl: client.baseUrl!,
            sessionHeaders: client.sessionHeaders,
          ),
        ),
      );
      await backend.setVolume(mpvVolumeForPercent(volume));
      // 换集/重开不重置倍速:mpv 重新起流后显式恢复当前倍速。
      await backend.setRate(playbackRate);
      final runtime = next.mediaSource.runTimeTicks ?? item?.runTimeTicks ?? 0;
      if (runtime > 0) {
        duration = durationFromTicks(runtime);
      }
      _setPosition(durationFromTicks(startTicks));
      _rebuildSkipSegments();
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
    final stream = next.mediaSource.streamByIndex(subtitleStreamIndex!);
    if (stream == null || !stream.isSubtitle) {
      return;
    }
    if (next.isTranscode) {
      // 转码:字幕由服务器烧录进流,不另选择轨道。
      return;
    }
    if (stream.isBitmapSubtitle) {
      // 直连:mpv 直接渲染容器内嵌位图轨道(PGS 等)。
      await backend.setSubtitleIndex(subtitleStreamIndex!);
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
    sessionExpired = false;
    try {
      await client.reportPlaying(_currentReport(positionTicks: startTicks));
      _onReportSucceeded();
      _writeSnapshot(positionTicks: startTicks);
    } on EmbyException catch (failure) {
      _onReportFailed(failure);
    }
    _progressTimer?.cancel();
    _progressTimer = null;
    if (sessionExpired) {
      return;
    }
    _progressTimer = Timer.periodic(progressInterval, (_) {
      unawaited(_reportProgress(eventName: 'TimeUpdate'));
    });
  }

  Future<void> _reportProgress({String? eventName}) async {
    if (!checkIn.canProgress || sessionExpired) {
      return;
    }
    try {
      await client.reportProgress(_currentReport(eventName: eventName));
      _onReportSucceeded();
      // 请求期间会话已停止(Stopped 已删快照)时不再写入,避免复活快照。
      if (checkIn.canProgress) {
        _writeSnapshot();
      }
    } on EmbyException catch (failure) {
      _onReportFailed(failure);
    }
  }

  Future<void> _stopSession() async {
    _progressTimer?.cancel();
    _progressTimer = null;
    await _awaitPendingStopped();
    final shouldReport = checkIn.stop();
    _sessionStarted = false;
    if (!shouldReport) {
      return;
    }
    await _sendStopped();
  }

  Future<void> _awaitPendingStopped() async {
    final pending = _pendingStopped;
    if (pending != null) {
      await pending;
    }
  }

  /// 发送 Stopped,以 [stoppedDeadline] 为上限;成功后删除会话快照,
  /// 超时/异常按上报失败处理(快照保留供宿主代发)。
  Future<void> _sendStopped() async {
    try {
      await client.reportStopped(_currentReport()).timeout(stoppedDeadline);
      _onReportSucceeded();
      _enqueueSnapshot(snapshotStore.delete);
    } on EmbyException catch (failure) {
      _onReportFailed(failure);
    } on TimeoutException {
      _onReportFailed(null);
    }
  }

  void _onReportSucceeded() {
    _reportFailureStreak = 0;
    sessionExpired = false;
    _clearProgressSyncFailed();
  }

  /// [failure] 为 null 表示超时。
  void _onReportFailed(EmbyException? failure) {
    if (failure?.kind == EmbyFailureKind.sessionExpired) {
      _progressTimer?.cancel();
      _progressTimer = null;
      _progressFailBannerTimer?.cancel();
      _progressFailBannerTimer = null;
      sessionExpired = true;
      progressSyncFailed = true;
      progressSyncPersistent = true;
      _emit();
      return;
    }
    _reportFailureStreak += 1;
    _markProgressSyncFailed(persistent: _reportFailureStreak >= 2);
  }

  void _markProgressSyncFailed({required bool persistent}) {
    progressSyncFailed = true;
    progressSyncPersistent = persistent;
    _emit();
    _progressFailBannerTimer?.cancel();
    _progressFailBannerTimer = null;
    if (persistent) {
      return;
    }
    _progressFailBannerTimer = Timer(progressFailBannerFor, () {
      if (_disposed) {
        return;
      }
      progressSyncFailed = false;
      _emit();
    });
  }

  void _writeSnapshot({int? positionTicks}) {
    final baseUrl = client.baseUrl;
    final userId = client.userId;
    if (baseUrl == null || userId == null || userId.isEmpty) {
      return;
    }
    final report = _currentReport(positionTicks: positionTicks);
    final snapshot = PlaybackSessionSnapshot(
      itemId: report.itemId,
      mediaSourceId: report.mediaSourceId,
      playSessionId: report.playSessionId,
      playMethod: report.playMethod,
      positionTicks: report.positionTicks,
      baseUrl: baseUrl.toString(),
      userId: userId,
      timestamp: DateTime.now(),
    );
    _enqueueSnapshot(() => snapshotStore.write(snapshot));
  }

  /// 空闲时立刻执行(内存实现即时生效),忙时按序排队;任何失败吞掉。
  void _enqueueSnapshot(Future<void> Function() operation) {
    _snapshotOps.add(operation);
    if (!_snapshotDraining) {
      unawaited(_drainSnapshotOps());
    }
  }

  Future<void> _drainSnapshotOps() async {
    _snapshotDraining = true;
    try {
      while (_snapshotOps.isNotEmpty) {
        final operation = _snapshotOps.removeAt(0);
        try {
          await operation();
        } catch (_) {}
      }
    } finally {
      _snapshotDraining = false;
    }
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
    if (!progressSyncFailed && !progressSyncPersistent) {
      return;
    }
    progressSyncFailed = false;
    progressSyncPersistent = false;
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
    final pending = _stopSession();
    _pendingStopped = pending;
    unawaited(
      pending.whenComplete(() {
        if (identical(_pendingStopped, pending)) {
          _pendingStopped = null;
        }
      }),
    );
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

  /// 读取音量/倍速与按剧记忆,起播与换集前恢复。
  Future<void> _restoreSettings() async {
    try {
      final settings = await (await _settings()).read();
      volume = settings.clampedVolume;
      playbackRate = settings.effectivePlaybackRate;
      _seriesPreferences = Map.of(settings.seriesPreferences);
      if (volume > 0) {
        _unmutedVolume = volume;
      }
      await backend.setVolume(mpvVolumeForPercent(volume));
    } catch (_) {}
  }

  void _scheduleSettingsSave() {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_writeSettings());
    });
  }

  Future<void> _persistSettings() async {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = null;
    await _writeSettings();
  }

  /// 写入播放进程持有的全部设置(音量/倍速/按剧记忆);
  /// 文件存储为合并写,不会清掉主进程写入的其他字段。
  Future<void> _writeSettings() async {
    try {
      await (await _settings()).write(
        PlayerSettings(
          volume: volume,
          playbackRate: playbackRate,
          seriesPreferences: _seriesPreferences,
        ),
      );
    } catch (_) {}
  }

  /// start() 时按 item.seriesId 解析记忆的音轨/字幕/码率与手动片头片尾。
  void _applyRememberedPreference() {
    _rememberedPreference = null;
    final seriesId = item?.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return;
    }
    final preference = _seriesPreferences[seriesId];
    if (preference == null) {
      return;
    }
    _rememberedPreference = preference;
    if (preference.maxStreamingBitrate != null) {
      maxStreamingBitrate = preference.maxStreamingBitrate!;
    }
    manualIntroSkipSeconds = preference.introSkipSeconds;
    manualOutroSkipSeconds = preference.outroSkipSeconds;
  }

  /// 播放中选择音轨/字幕(含关闭)/码率/手动片头片尾后写入按剧记忆。
  Future<void> _persistSeriesPreference() async {
    final seriesId = item?.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return;
    }
    _seriesPreferences = Map.of(_seriesPreferences);
    _seriesPreferences[seriesId] = PlayerSeriesPreference(
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      maxStreamingBitrate: maxStreamingBitrate,
      introSkipSeconds: manualIntroSkipSeconds,
      outroSkipSeconds: manualOutroSkipSeconds,
    );
    await _writeSettings();
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
    _settingsSaveTimer?.cancel();
    unawaited(_persistSettings());
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
