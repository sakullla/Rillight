import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/media_source_format.dart';
import 'package:rillight/player/playback_check_in.dart';
import 'package:rillight/player/playback_coordinator.dart';
import 'package:rillight/player/playback_session.dart';
import 'package:rillight/player/playback_state.dart';
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

/// 跳过按钮在片头/片尾区间内一直保留,不跟 OSD 一起 8 秒消失。
/// Netflix/Infuse:Skip Intro 独立于控制条,暂停或唤出 OSD 时若仍在区间内再亮一次。

/// 进度/缓冲/网速刷新下限。mpv time-pos 接近逐帧,整页 setState 会把 CPU
/// 耗在 Flutter 合成上;弹幕用自己的 ticker 插值,不依赖这次通知。
const Duration kPlaybackUiMinInterval = Duration(milliseconds: 200);

/// 短于此时长的标记不弹出跳过钮。
const Duration kMinSkipSegment = Duration(seconds: 3);

/// 无片尾标记时,提前给出下一集入口的提前量。
const Duration kNextUpLead = Duration(minutes: 3);

/// 过短的剧集不提前弹出下一集,避免开场就出现。
const Duration kMinRuntimeForEarlyNextUp = Duration(minutes: 6);

/// 片尾标记只有落在结局附近才用来提前下一集。
/// 开场附近的「片尾」章节是错误标记,不能当成看完。
const Duration kTrustedOutroWindow = Duration(minutes: 8);

/// 距已知片长不超过此时长,才把 eof 当成这一集播完。
/// 更早的结束是断流或缓存误报,不能倒计时切下一集。
const Duration kNaturalEndTolerance = Duration(seconds: 45);

/// 播放器剧集面板一窗条数,与详情页分集窗口对齐。
const int kPlayerEpisodePageSize = 80;

/// 当前集所在窗的 StartIndex:前面留 [leading] 条,并尽量填满一页。
int playerEpisodeWindowStart({
  required int? indexNumber,
  required int total,
  int pageSize = kPlayerEpisodePageSize,
  int leading = 4,
}) {
  if (total <= pageSize || pageSize <= 0) {
    return 0;
  }
  final pos = math.max(0, (indexNumber ?? 1) - 1);
  var start = pos <= leading ? 0 : pos - leading;
  if (start + pageSize > total) {
    start = total - pageSize;
  }
  return start;
}

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
    this.stoppedTimeout = stoppedDeadline,
    this.disposeTimeout = stoppedDeadline,
    this.progressFailBannerFor = const Duration(seconds: 4),
    this.controlsHideAfter = const Duration(seconds: 5),
    this.nextEpisodeCountdown = const Duration(seconds: 10),
    this.seekStep = const Duration(seconds: 10),
    this.onClose,
    this.onOpenItem,
    this.onOpenItemDetail,
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
  final Duration stoppedTimeout;

  /// Native stop/dispose hang budget; close still fires [onClose] after this.
  final Duration disposeTimeout;
  final Duration progressFailBannerFor;
  final Duration controlsHideAfter;
  final Duration nextEpisodeCountdown;
  final Duration seekStep;
  final VoidCallback? onClose;
  final ValueChanged<String>? onOpenItem;

  /// 进程内不可播放的条目(如剧集)改为通知主窗口打开详情页;
  /// 独立播放进程在 [onOpenItem] 之外提供该回调。
  final void Function(String itemId, {String? seasonId})? onOpenItemDetail;
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
  final PlaybackCoordinator _operations = PlaybackCoordinator();
  final PlaybackState state = PlaybackState();
  PlaybackSession? _session;
  Future<void>? _disposing;
  int _trackRevision = 0;
  final _trackRevisions = <String, int>{};
  int? _snapshotOwner;
  String? trackFailure;
  String? _operationBaseUrl;
  String? _operationUserId;
  String? _operationToken;

  PlaybackOperation? _beginOperation() {
    final operation = _operations.begin();
    if (operation != null) {
      _operationBaseUrl = client.baseUrl?.toString();
      _operationUserId = client.userId;
      _operationToken = client.accessToken;
      _trackRevision++;
      _episodePageGen++;
      episodeListLoading = false;
      episodeLoadingMore = false;
      episodeLoadingEarlier = false;
      _nextTimer?.cancel();
      _nextTimer = null;
      nextEpisode = null;
      trackFailure = null;
    }
    return operation;
  }

  bool get isBuffering => state.buffering;
  bool _accepts(PlaybackOperation? operation) =>
      !_disposed &&
      _operations.accepts(operation) &&
      _operationBaseUrl == client.baseUrl?.toString() &&
      _operationUserId == client.userId &&
      _operationToken == client.accessToken;

  int volume = 100;
  int _unmutedVolume = 100;
  double playbackRate = 1.0;
  int maxStreamingBitrate = kMpvMaxStreamingBitrate;
  int? audioStreamIndex;
  int? subtitleStreamIndex;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  /// 条目或媒体源上的片长。进度条可能被更短的探测时长盖掉,切集仍以它为准。
  Duration _catalogRuntime = Duration.zero;
  Duration buffer = Duration.zero;

  /// HTTP 代理的上游接收速度，字节/秒；本地缓存命中不计入，无下载时为 0。
  double cacheSpeedBytesPerSec = 0;
  DateTime _lastPlaybackUi = DateTime.fromMillisecondsSinceEpoch(0);
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
  int episodeTotal = 0;
  int episodeWindowStart = 0;
  int episodeWindowEnd = 0;
  bool episodeLoadingMore = false;
  bool episodeLoadingEarlier = false;

  bool get hasMoreEpisodes => episodeWindowEnd < episodeTotal;

  bool get hasEarlierEpisodes => episodeWindowStart > 0;

  // --- 片头片尾跳过(R8) ---
  List<PlayerSkipSegment> _skipSegments = const [];
  PlayerSkipSegment? activeSkipSegment;
  bool skipPromptVisible = false;
  bool controlsPinned = false;
  bool _nextUpOffered = false;
  bool _nextUpLoading = false;
  bool _handlingCompleted = false;
  bool _pendingCompletion = false;

  // --- 媒体源切换(R9) ---
  List<PlaybackMediaSource> mediaSources = const [];
  String? activeMediaSourceId;

  /// 按发行组/版本标签跨集对齐(Emby 每集 MediaSourceId 和文件名都不同)。
  String? _preferredSourceName;

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

  /// 多个媒体源时才提供换源入口。
  bool get canSwitchMediaSource => mediaSources.length > 1;

  Timer? _progressTimer;
  Timer? _progressFailBannerTimer;
  Timer? _subtitleNoticeTimer;

  /// 换源/重开后重断言外挂字幕的到期时刻;挂在进度上报节拍上,
  /// 不新增独立定时器(避免测试与dispose遗漏时残留挂起定时器)。
  DateTime? _subtitleReassertDue;

  /// 本次播放下载的外挂字幕。停播后整目录删除,不留在系统临时目录。
  Directory? _subtitleCache;
  File? _activeSubtitleFile;
  int _subtitleFileSequence = 0;

  /// 在途 Stopped(_handleCompleted / _stopSession / close 共用);
  /// 后续 close()/shutdown 先等它,避免 exit(0) 截断上报。
  Future<void>? _pendingStopped;
  Future<void>? _closing;

  /// 快照 IO 串行化:写与删按发起顺序执行,避免 Stopped 删除后被迟到的
  /// Progress 写入复活;失败一律吞掉。
  final List<Future<void> Function()> _snapshotOps = [];
  bool _snapshotDraining = false;
  Timer? _hideTimer;
  Timer? _nextTimer;
  Timer? _settingsSaveTimer;
  StreamSubscription<VideoBackendEvent>? _eventSub;

  Future<void> start() async {
    final operation = _beginOperation();
    if (operation == null || _disposed) return;
    await _start(operation);
  }

  Future<void> _start(PlaybackOperation operation) async {
    final stopped = _stopSession();
    await _operations.interrupt(backend.stop);
    await stopped;
    if (!_accepts(operation)) return;
    state.phase = PlaybackPhase.loading;
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
    _nextUpOffered = false;
    _nextUpLoading = false;
    _handlingCompleted = false;
    _pendingCompletion = false;
    skipPromptVisible = false;
    loading = true;
    mediaSources = const [];
    _skipSegments = const [];
    activeSkipSegment = null;
    _emit();
    try {
      // A just-changed volume/rate may still be waiting on its debounce. Save
      // it before reading settings for the next item, otherwise a quick switch
      // restores the old value and the delayed save persists that stale value.
      if (_settingsSaveTimer != null) await _persistSettings();
      if (!_accepts(operation)) return;
      await _restoreSettings(operation);
      if (!_accepts(operation)) return;
      final loadedItem = await client.getItem(itemId);
      if (!_accepts(operation)) {
        return;
      }
      item = loadedItem;
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
        _resetEpisodeWindow();
      }
      try {
        final loadedUser = await client.getUser();
        if (!_accepts(operation)) return;
        user = loadedUser;
      } on EmbyException {
        if (!_accepts(operation)) return;
        user = null;
      }
      _catalogRuntime = durationFromTicks(item!.runTimeTicks ?? 0);
      duration = _catalogRuntime;
      _applyRememberedPreference();
      final memory = _rememberedPreference;
      final memorySubtitleOff = memory?.subtitleOff ?? false;
      subtitleStreamIndex = memorySubtitleOff
          ? null
          : (preferredSubtitleStreamIndex ?? memory?.subtitleStreamIndex);
      audioStreamIndex =
          preferredAudioStreamIndex ??
          memory?.audioStreamIndex ??
          audioStreamIndex;
      final chapterTicks = startTimeTicks;
      if (chapterTicks != null && chapterTicks > 0) {
        await _open(
          operation: operation,
          startTicks: chapterTicks,
          audio: audioStreamIndex,
          subtitle: subtitleStreamIndex,
          subtitleOff: memorySubtitleOff,
        );
        return;
      }
      final resumeTicks = item!.canResume ? item!.resumePositionTicks : 0;
      if (!autoResume) {
        await _open(
          operation: operation,
          startTicks: 0,
          audio: audioStreamIndex,
          subtitle: subtitleStreamIndex,
          subtitleOff: memorySubtitleOff,
        );
        return;
      }
      await _open(
        operation: operation,
        startTicks: resumeTicks > 0 ? _rewound(resumeTicks) : 0,
        audio: audioStreamIndex,
        subtitle: subtitleStreamIndex,
        subtitleOff: memorySubtitleOff,
      );
    } on EmbyException catch (failure) {
      if (!_accepts(operation)) {
        return;
      }
      error = PlayerErrorKind.load;
      loadFailure = failure;
      loading = false;
      _emit();
    }
  }

  Future<void> togglePlay() async {
    if (loading || error != null || _backgroundReleased) {
      return;
    }
    if (playbackEnded) {
      await replay();
      return;
    }
    final operation = _operations.current;
    if (operation != null) {
      await _operations.run(operation, backend.playOrPause);
    }
  }

  bool _backgroundReleased = false;
  Uri? _suspendedServer;
  String? _suspendedUser;
  String? _suspendedToken;
  int _suspendedTicks = 0;
  Future<void>? _suspending;
  bool get backgroundReleased => _backgroundReleased;

  /// Android hosts call this on a real background transition, not rotation.
  /// Release media promptly; the existing session owns bounded Stopped/reporting.
  Future<void> suspendPlayback() =>
      _suspending ??= _suspendPlayback().whenComplete(() => _suspending = null);

  Future<void> _suspendPlayback() async {
    if (_disposed || _backgroundReleased) return;
    _backgroundReleased = true;
    _suspendedServer = client.baseUrl;
    _suspendedUser = client.userId;
    _suspendedToken = client.accessToken;
    _suspendedTicks = ticksFromDuration(position);
    isPlaying = false;
    final stopped = _stopSession();
    _beginOperation();
    try {
      await _operations.interrupt(backend.stop).timeout(disposeTimeout);
    } finally {
      await stopped;
      loading = false;
      state.updatePlaying(false);
      _emit();
    }
  }

  /// Recreate a released native session at its saved position, always paused.
  /// A changed identity must re-enter through the authentication/player host.
  Future<void> restorePlayback() async {
    await _suspending;
    if (_disposed || !_backgroundReleased) return;
    if (client.baseUrl != _suspendedServer ||
        client.userId != _suspendedUser ||
        client.accessToken != _suspendedToken) {
      sessionExpired = true;
      _emit();
      return;
    }
    _backgroundReleased = false;
    final operation = _beginOperation();
    if (operation == null) return;
    await _open(
      operation: operation,
      startTicks: _suspendedTicks,
      audio: audioStreamIndex,
      subtitle: subtitleStreamIndex,
      subtitleOff: subtitleStreamIndex == null,
      startPaused: true,
    );
  }

  Future<void> replay() async {
    if (_disposed || _operations.isClosed) return;
    await _reopen(startTicks: 0);
  }

  /// A transport/decoder retry keeps the last observed position and tracks.
  /// Initial catalog failures still need the full startup sequence.
  Future<void> retryPlayback() async {
    if (_disposed || _operations.isClosed || sessionExpired) return;
    if (item == null || resolved == null) {
      await start();
    } else {
      await _reopen(startTicks: ticksFromDuration(position));
    }
  }

  void openEndedSeries() {
    final seriesId = item?.seriesId;
    if (seriesId != null && seriesId.isNotEmpty) {
      // 剧集不是片源:只请主窗口打开详情,绝不走 onOpenItem(_applyLaunch)。
      final openDetail = onOpenItemDetail;
      if (openDetail != null) {
        openDetail(seriesId, seasonId: item?.seasonId);
        return;
      }
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
      await _reopen(startTicks: ticksFromDuration(target));
      return;
    }
    if (isTranscode) {
      await _reopen(startTicks: ticksFromDuration(target));
      return;
    }
    final operation = _operations.current;
    if (operation == null) return;
    await _operations.run(operation, () => backend.seek(target));
    if (!_accepts(operation)) return;
    _setPosition(target);
    _emit();
    await _reportProgress(eventName: 'Seek');
  }

  static const volumeWheelStep = 5;

  Future<void> setVolume(int value) async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    volume = value.clamp(0, PlayerSettings.volumeMax);
    if (volume > 0) {
      _unmutedVolume = volume;
    }
    final selected = volume;
    await _operations.run(
      operation!,
      () => backend.setVolume(mpvVolumeForPercent(selected)),
    );
    if (!_accepts(operation)) return;
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
    return setVolume(volumeAfterWheelNudge(volume, delta));
  }

  /// 设置倍速:阶梯内取值,立即下发 backend 并持久化(跨集/重启沿用)。
  Future<void> setRate(double rate) async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    final value = rate
        .clamp(kPlaybackRateLadder.first, kPlaybackRateLadder.last)
        .toDouble();
    if (playbackRate == value) {
      onUserActivity();
      return;
    }
    playbackRate = value;
    await _operations.run(operation!, () => backend.setRate(value));
    if (!_accepts(operation)) return;
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

  Future<void> minimize() {
    onUserActivity();
    return window.minimize();
  }

  Future<void> setAudio(int index) async {
    if (loading || _operations.isClosed) return;
    if (isTranscode) {
      await _reopen(startTicks: ticksFromDuration(position), audio: index);
      return;
    }
    await _selectTrack(
      (_) => backend.setAudioIndex(index),
      () => audioStreamIndex = index,
      'AudioTrackChange',
    );
  }

  Future<void> setSubtitle(int? index) async {
    if (loading || _operations.isClosed) return;
    _subtitleReassertDue = null;
    final source = resolved?.mediaSource;
    if (source == null) return;
    final stream = index == null ? null : source.streamByIndex(index);
    if (index != null && (stream == null || !stream.isSubtitle)) return;
    final next = resolved!;
    bool burned(int? selected) {
      final candidate = selected == null
          ? null
          : source.streamByIndex(selected);
      return next.isTranscode &&
          candidate != null &&
          _transcodeSubtitleDelivery(candidate) ==
              TranscodeSubtitleDelivery.burnIn;
    }

    if (burned(index) || burned(subtitleStreamIndex)) {
      await _reopen(
        startTicks: ticksFromDuration(position),
        subtitle: index,
        subtitleOff: index == null,
      );
      return;
    }
    final previous = subtitleStreamIndex;
    await _selectTrack(
      (current) => _activatePlaybackSubtitle(next, index, current: current),
      () {
        subtitleStreamIndex = index;
        _clearSubtitleNotice();
      },
      'SubtitleTrackChange',
      serialized: false,
      onFailure: () {
        subtitleStreamIndex = previous;
        _emit();
      },
    );
  }

  Future<void> _selectTrack(
    Future<void> Function(bool Function() current) apply,
    VoidCallback commit,
    String event, {
    bool serialized = true,
    VoidCallback? onFailure,
  }) async {
    final operation = _operations.current;
    if (operation == null || !_accepts(operation)) return;
    final revision = ++_trackRevision;
    _trackRevisions[event] = revision;
    final session = _session;
    bool sessionCurrent() =>
        _accepts(operation) && identical(session, _session) && !disconnected;
    bool current() => sessionCurrent() && revision == _trackRevisions[event];
    try {
      Future<void> select() async {
        if (!current()) return;
        await apply(current);
        if (!sessionCurrent() ||
            (!serialized && revision != _trackRevisions[event])) {
          return;
        }
        // A newer selection may already be queued. This successful mutation is
        // still the actual backend state until that next selection succeeds.
        commit();
        trackFailure = null;
        _emit();
        await _persistSeriesPreference();
      }

      if (serialized) {
        await _operations.run(operation, select);
      } else {
        // Optional subtitle downloads must not block pause, seek or volume.
        await select();
      }
      if (!current()) return;
      await _reportProgress(eventName: event);
    } catch (failure) {
      if (!current()) return;
      onFailure?.call();
      trackFailure = failure.toString();
      _emit();
    }
  }

  void dismissTrackFailure() {
    trackFailure = null;
    _emit();
  }

  Future<void> setMaxBitrate(int bitrate) async {
    if (_operations.isClosed) return;
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

  DateTime? _ignoreHoverUntil;

  void onUserActivity() {
    controlsVisible = true;
    if (activeSkipSegment != null) {
      _showSkipPrompt();
    }
    _scheduleHide();
    _emit();
  }

  /// 单击收起后,Windows 改光标常会再送一次 hover,不能立刻把 OSD 拉回来。
  void onPointerHover() {
    final until = _ignoreHoverUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      return;
    }
    onUserActivity();
  }

  /// 剧集列表面板打开时钉住控制层,避免顶栏盖住关闭钮后又自动隐藏。
  void setControlsPinned(bool pinned) {
    controlsPinned = pinned;
    if (pinned) {
      controlsVisible = true;
      _hideTimer?.cancel();
    } else {
      _scheduleHide();
    }
    _emit();
  }

  void hideControlsOnPointerExit() {
    if (controlsPinned || !isPlaying || playbackEnded) {
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
    if (controlsPinned || playbackEnded) {
      onUserActivity();
      return;
    }
    if (controlsVisible) {
      _hideTimer?.cancel();
      controlsVisible = false;
      _ignoreHoverUntil = DateTime.now().add(const Duration(milliseconds: 400));
      _emit();
      return;
    }
    _ignoreHoverUntil = null;
    onUserActivity();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (controlsPinned) {
      return;
    }
    if (isPlaying && !playbackEnded) {
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

  /// 切到任意集(剧集列表入口):源 id 每集不同,保留显示名以便对齐同名版本;
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
  /// 首次起播请求携带的源/轨道/章节起点只对首个条目有效,换集后清除 id;
  /// 片源发行组标签保留,供下一集按组名对齐。
  Future<void> _playItem(String targetId, {required bool fromStart}) async {
    final operation = _beginOperation();
    if (operation == null || _disposed) return;
    final stopped = _stopSession();
    itemId = targetId;
    item = null;
    resolved = null;
    position = duration = buffer = Duration.zero;
    isPlaying = false;
    loading = true;
    state.phase = PlaybackPhase.loading;
    state.buffering = false;
    _emit();
    await _operations.interrupt(backend.stop);
    await stopped;
    if (!_accepts(operation)) return;
    activeMediaSourceId = null;
    preferredMediaSourceId = null;
    preferredAudioStreamIndex = null;
    preferredSubtitleStreamIndex = null;
    startTimeTicks = null;
    autoResume = !fromStart;
    await _start(operation);
  }

  // ---------------------------------------------------------------------
  // 剧集列表与切集(R7)
  // ---------------------------------------------------------------------

  /// 拉取当前剧的季列表与当前季的分集窗口。
  /// 失败仅置失败状态(入口隐藏/可重试),不阻塞播放。
  Future<void> loadEpisodeList() async {
    if (!canBrowseEpisodes) {
      return;
    }
    final seriesId = item!.seriesId!;
    if (_episodeSeriesId == seriesId) {
      await _ensureCurrentInWindow();
      return;
    }
    await _loadSeasons(seriesId);
  }

  /// 已加载剧集列表归属的 seriesId;start() 换条目时重置。
  String? _episodeSeriesId;

  Future<void> _loadSeasons(String seriesId) async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
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
      if (!_accepts(operation)) {
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
      await _loadSeasonEpisodes(seasonId, aroundCurrent: true);
      // 分集列表拉取成功后才标记归属;失败时保持未加载,
      // 保证同剧重试(loadEpisodeList)不会因早退而失效。
      if (!_accepts(operation)) return;
      _episodeSeriesId = seriesId;
      episodeListLoading = false;
      _emit();
    } on EmbyException {
      if (!_accepts(operation)) {
        return;
      }
      episodeListLoading = false;
      episodeListFailed = true;
      _emit();
    }
  }

  /// 切换剧集列表显示的季(不切集,仅换列表内容)。
  Future<void> selectSeason(String seasonId) async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    if (episodeListLoading || episodeSeasonId == seasonId) {
      return;
    }
    episodeListLoading = true;
    episodeListFailed = false;
    _emit();
    try {
      await _loadSeasonEpisodes(
        seasonId,
        aroundCurrent: item?.seasonId == seasonId,
      );
    } on EmbyException {
      if (!_accepts(operation)) {
        return;
      }
      episodeListFailed = true;
    }
    if (!_accepts(operation)) return;
    episodeListLoading = false;
    _emit();
  }

  Future<void> _ensureCurrentInWindow() async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    final seasonId = item?.seasonId ?? episodeSeasonId;
    if (seasonId == null || seasonId.isEmpty) {
      return;
    }
    if (episodeSeasonId != seasonId) {
      return;
    }
    if (episodes.any((episode) => episode.id == itemId)) {
      return;
    }
    episodeListLoading = true;
    episodeListFailed = false;
    episodes = const [];
    _emit();
    try {
      await _loadSeasonEpisodes(seasonId, aroundCurrent: true);
    } on EmbyException {
      if (!_accepts(operation)) {
        return;
      }
      episodeListFailed = true;
    }
    if (!_accepts(operation)) return;
    episodeListLoading = false;
    _emit();
  }

  Future<void> loadMoreEpisodes() async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    final seasonId = episodeSeasonId;
    if (seasonId == null ||
        seasonId.isEmpty ||
        episodeLoadingMore ||
        episodeLoadingEarlier ||
        episodeListLoading ||
        !hasMoreEpisodes) {
      return;
    }
    final gen = ++_episodePageGen;
    episodeLoadingMore = true;
    _emit();
    try {
      final page = await _querySeasonEpisodes(seasonId, episodeWindowEnd);
      if (!_accepts(operation) || gen != _episodePageGen) {
        return;
      }
      if (episodeSeasonId == seasonId) {
        episodes = _dedupeEpisodes([...episodes, ...page.items]);
        episodeTotal = page.totalRecordCount ?? episodeTotal;
        episodeWindowEnd = page.items.isEmpty
            ? episodeTotal
            : episodeWindowEnd + page.items.length;
      }
    } on EmbyException {
      if (!_accepts(operation) || gen != _episodePageGen) {
        return;
      }
      episodeListFailed = true;
    }
    if (!_accepts(operation) || gen != _episodePageGen) {
      return;
    }
    episodeLoadingMore = false;
    _emit();
  }

  Future<void> loadEarlierEpisodes() async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    final seasonId = episodeSeasonId;
    if (seasonId == null ||
        seasonId.isEmpty ||
        episodeLoadingEarlier ||
        episodeLoadingMore ||
        episodeListLoading ||
        !hasEarlierEpisodes) {
      return;
    }
    final gen = ++_episodePageGen;
    final start = math.max(0, episodeWindowStart - kPlayerEpisodePageSize);
    final limit = episodeWindowStart - start;
    episodeLoadingEarlier = true;
    _emit();
    try {
      final page = await _querySeasonEpisodes(seasonId, start, limit: limit);
      if (!_accepts(operation) || gen != _episodePageGen) {
        return;
      }
      if (episodeSeasonId == seasonId) {
        episodes = _dedupeEpisodes([...page.items, ...episodes]);
        episodeTotal = page.totalRecordCount ?? episodeTotal;
        episodeWindowStart = start;
      }
    } on EmbyException {
      if (!_accepts(operation) || gen != _episodePageGen) {
        return;
      }
      episodeListFailed = true;
    }
    if (!_accepts(operation) || gen != _episodePageGen) {
      return;
    }
    episodeLoadingEarlier = false;
    _emit();
  }

  Future<void> _loadSeasonEpisodes(
    String? seasonId, {
    required bool aroundCurrent,
  }) async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    if (seasonId == null || seasonId.isEmpty) {
      episodes = const [];
      episodeSeasonId = null;
      _resetEpisodeWindow();
      return;
    }
    final index = aroundCurrent ? item?.indexNumber : 1;
    var start = index == null || index <= 1 ? 0 : math.max(0, index - 1 - 4);
    var page = await _querySeasonEpisodes(seasonId, start);
    if (!_accepts(operation)) {
      return;
    }
    final total = page.totalRecordCount ?? page.items.length;
    final filledStart = playerEpisodeWindowStart(
      indexNumber: index,
      total: total,
    );
    if (filledStart != start) {
      page = await _querySeasonEpisodes(seasonId, filledStart);
      if (!_accepts(operation)) {
        return;
      }
      start = filledStart;
    }
    episodes = _dedupeEpisodes(page.items);
    episodeSeasonId = seasonId;
    episodeTotal = page.totalRecordCount ?? page.items.length;
    episodeWindowStart = start;
    episodeWindowEnd = start + page.items.length;
  }

  Future<EmbyItemPage> _querySeasonEpisodes(
    String seasonId,
    int startIndex, {
    int limit = kPlayerEpisodePageSize,
  }) {
    return client.queryItems(
      parentId: seasonId,
      includeItemTypes: 'Episode',
      recursive: true,
      sortBy: 'IndexNumber',
      sortOrder: 'Ascending',
      startIndex: startIndex,
      limit: limit,
      fields: EmbyClient.gridFields,
    );
  }

  void _resetEpisodeWindow() {
    episodeTotal = 0;
    episodeWindowStart = 0;
    episodeWindowEnd = 0;
    episodeLoadingMore = false;
    episodeLoadingEarlier = false;
  }

  List<EmbyItem> _dedupeEpisodes(Iterable<EmbyItem> items) {
    final seen = <String>{};
    return [
      for (final episode in items)
        if (seen.add(episode.id)) episode,
    ];
  }

  int _episodePageGen = 0;

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

  void _rebuildSkipSegments() {
    final current = item;
    final segments = <PlayerSkipSegment>[];
    if (current != null) {
      // 仅服务器章节标记驱动跳过段,无标记则不跳过。
      segments.addAll(_chapterSkipSegments(current.chapters));
    }
    _skipSegments = segments;
    _updateActiveSkip();
  }

  /// 服务器章节标记:优先 Emby `MarkerType`(IntroStart/IntroEnd/CreditsStart),
  /// 否则回退到 Name 含 Intro/Outro/片头/片尾 的章节区间。
  /// 一集可能有多处片头/片尾(如分割放送、多段回顾),标记路径按
  /// "每个起点配其后第一个同名终点"展开为多段。
  List<PlayerSkipSegment> _chapterSkipSegments(List<ItemChapter> chapters) {
    if (chapters.isEmpty) {
      return const [];
    }
    final introStarts = <Duration>[];
    final introEnds = <Duration>[];
    final creditsStarts = <Duration>[];
    final creditsEnds = <Duration>[];
    final named = <PlayerSkipSegment>[];
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final start = durationFromTicks(chapter.startPositionTicks);
      final type = chapter.markerType?.trim().toLowerCase() ?? '';
      switch (type) {
        case 'introstart':
          introStarts.add(start);
          continue;
        case 'introend':
          introEnds.add(start);
          continue;
        case 'creditsstart':
          creditsStarts.add(start);
          continue;
        case 'creditsend':
          creditsEnds.add(start);
          continue;
      }
      final name = chapter.name.toLowerCase();
      final isOutro = name.contains('outro') || name.contains('片尾');
      final isIntro =
          !isOutro && (name.contains('intro') || name.contains('片头'));
      if (!isIntro && !isOutro) {
        continue;
      }
      var end = i + 1 < chapters.length
          ? durationFromTicks(chapters[i + 1].startPositionTicks)
          : (duration > start ? duration : start + const Duration(seconds: 30));
      if (end <= start) {
        continue;
      }
      named.add(
        PlayerSkipSegment(
          kind: isOutro ? PlayerSkipKind.outro : PlayerSkipKind.intro,
          start: start,
          end: end,
        ),
      );
    }
    if (introStarts.isNotEmpty || creditsStarts.isNotEmpty) {
      final result = <PlayerSkipSegment>[];
      Duration? firstAfter(Duration start, List<Duration> ends) {
        Duration? match;
        for (final end in ends) {
          if (end > start && (match == null || end < match)) {
            match = end;
          }
        }
        return match;
      }

      for (final start in introStarts) {
        final end =
            firstAfter(start, introEnds) ?? start + const Duration(seconds: 90);
        if (end > start) {
          result.add(
            PlayerSkipSegment(
              kind: PlayerSkipKind.intro,
              start: start,
              end: end,
            ),
          );
        }
      }
      for (final start in creditsStarts) {
        final end =
            firstAfter(start, creditsEnds) ??
            (duration > start ? duration : start + const Duration(seconds: 30));
        if (end > start) {
          result.add(
            PlayerSkipSegment(
              kind: PlayerSkipKind.outro,
              start: start,
              end: end,
            ),
          );
        }
      }
      return result;
    }
    return named;
  }

  void _updateActiveSkip() {
    PlayerSkipSegment? next;
    for (final segment in _skipSegments) {
      if (position >= segment.start &&
          position < segment.end &&
          segment.end - segment.start >= kMinSkipSegment) {
        next = segment;
        break;
      }
    }
    final changed = !_sameSkip(activeSkipSegment, next);
    activeSkipSegment = next;
    if (next == null) {
      skipPromptVisible = false;
      return;
    }
    if (changed) {
      _showSkipPrompt();
    }
  }

  static bool _sameSkip(PlayerSkipSegment? a, PlayerSkipSegment? b) {
    if (identical(a, b)) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return a.kind == b.kind && a.start == b.start && a.end == b.end;
  }

  void _showSkipPrompt() {
    skipPromptVisible = true;
  }

  void _setPosition(Duration value) {
    position = value;
    _updateActiveSkip();
    _maybeOfferNextUp();
  }

  /// 片尾标记处,或无标记时片长最后约 3 分钟,提前给出下一集(不倒计时)。
  void _maybeOfferNextUp() {
    if (_disposed ||
        loading ||
        playbackEnded ||
        nextEpisode != null ||
        _nextUpOffered ||
        _nextUpLoading) {
      return;
    }
    final current = item;
    if (current == null || !current.isEpisode) {
      return;
    }
    if (duration <= Duration.zero) {
      return;
    }
    Duration? threshold;
    for (final segment in _skipSegments) {
      if (segment.kind != PlayerSkipKind.outro) continue;
      if (segment.start < duration - kTrustedOutroWindow) continue;
      threshold = segment.start;
      break;
    }
    if (threshold == null) {
      if (duration < kMinRuntimeForEarlyNextUp) {
        return;
      }
      threshold = duration - kNextUpLead;
      if (threshold < Duration.zero) {
        threshold = Duration.zero;
      }
    }
    if (position < threshold) {
      return;
    }
    _nextUpOffered = true;
    unawaited(_offerEarlyNextEpisode());
  }

  Future<void> _offerEarlyNextEpisode() async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    final current = item;
    if (current == null) {
      _nextUpOffered = false;
      return;
    }
    _nextUpLoading = true;
    try {
      final next = await client.getNextEpisode(current);
      if (!_accepts(operation)) {
        return;
      }
      if (next == null || nextEpisode != null) {
        if (next == null) {
          _nextUpOffered = false;
        }
        return;
      }
      if (playbackEnded || _handlingCompleted) {
        _presentCompletedNext(next);
        return;
      }
      nextEpisode = NextEpisodeOffer(item: next);
      _emit();
    } on EmbyException {
      if (_accepts(operation)) _nextUpOffered = false;
    } finally {
      if (_accepts(operation)) _nextUpLoading = false;
    }
  }

  void _beginNextEpisodeCountdown(EmbyItem next) {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    nextEpisode = NextEpisodeOffer(item: next, remaining: nextEpisodeCountdown);
    _emit();
    _nextTimer?.cancel();
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final offer = nextEpisode;
      if (!_accepts(operation) ||
          offer == null ||
          offer.item.id != next.id ||
          offer.remaining == null) {
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
    for (final source in mediaSources) {
      if (source.id == sourceId) {
        _preferredSourceName = _sourceFingerprint(source);
        break;
      }
    }
    onUserActivity();
    await _reopen(startTicks: startTicks);
  }

  /// 关闭播放器:取消定时器 → 在 [stoppedTimeout] 内等待 Stopped 送达
  /// (或失败/超时),并在 [disposeTimeout] 内结束 native dispose → 再回调
  /// [onClose]。宿主据此在 onClose 后安全退出进程。
  /// 重复调用加入同一次关闭,只触发一次 [onClose]。
  Future<void> close() {
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      await disposeAsync().timeout(disposeTimeout);
    } catch (_) {
      // mpv stop/dispose can hang on a live stream; the window must still close.
    }
    try {
      if (window.isFullScreen) await window.setFullScreen(false);
    } catch (_) {}
    onClose?.call();
  }

  /// Stops this media session but keeps the backend reusable for a new item.
  Future<void> shutdownSession() async {
    if (_disposed || _operations.isClosed) return;
    _operations.invalidate();
    _cancelPlaybackTimers();
    final stopped = _stopSession();
    await _operations.interrupt(backend.stop);
    await _operations.drained;
    await stopped;
    await _persistSettings();
    if (window.isFullScreen) await window.setFullScreen(false);
  }

  void _cancelPlaybackTimers() {
    _hideTimer?.cancel();
    _nextTimer?.cancel();
    _nextTimer = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    _subtitleReassertDue = null;
  }

  /// Flutter's synchronous dispose delegates to this joinable cleanup. Hosts
  /// await this before closing the native window or exiting the process.
  Future<void> disposeAsync() => _disposing ??= _disposeResources();

  Future<void> _disposeResources({bool reportStopped = true}) async {
    _operations.close();
    state.phase = PlaybackPhase.closing;
    _cancelPlaybackTimers();
    _progressFailBannerTimer?.cancel();
    _subtitleNoticeTimer?.cancel();
    _settingsSaveTimer?.cancel();
    final Future<void> stopped;
    if (reportStopped) {
      stopped = _stopSession();
    } else {
      // An unannounced widget teardown cannot await a network request. Keep the
      // last snapshot for the process host's Stopped compensation.
      _session?.stopped = true;
      _session = null;
      _sessionStarted = false;
      checkIn.stop();
      stopped = _awaitPendingStopped();
    }
    await _eventSub?.cancel();
    try {
      await _operations.interrupt(backend.stop);
    } finally {
      await _operations.drained;
      try {
        await backend.dispose();
      } finally {
        await _deleteSubtitleCache();
      }
    }
    isPlaying = false;
    state.buffering = false;
    await stopped;
    await _persistSettings();
    state.phase = PlaybackPhase.closed;
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
    _eventSub = backend.events.listen((event) {
      final operation = _operations.current;
      if (!_accepts(operation) || event.sessionId != operation!.id) return;
      switch (event.kind) {
        case VideoEventKind.position:
          final skip = activeSkipSegment;
          final prompt = skipPromptVisible;
          final offered = nextEpisode;
          _setPosition(event.value as Duration);
          if (identical(skip, activeSkipSegment) &&
              prompt == skipPromptVisible &&
              identical(offered, nextEpisode) &&
              !_playbackUiDue()) {
            return;
          }
        case VideoEventKind.duration:
          final value = event.value as Duration;
          if (value > Duration.zero) {
            duration = value;
            _rebuildSkipSegments();
            _maybeOfferNextUp();
          }
        case VideoEventKind.buffer:
          buffer = event.value as Duration;
          if (buffer < Duration.zero) buffer = Duration.zero;
          if (duration > Duration.zero && buffer > duration) buffer = duration;
        case VideoEventKind.cacheSpeed:
          final value = event.value;
          cacheSpeedBytesPerSec = value is num && value.isFinite && value > 0
              ? value.toDouble()
              : 0;
        case VideoEventKind.buffering:
          state.buffering = event.value as bool;
          if (!loading) state.updatePlaying(isPlaying);
        case VideoEventKind.playing:
          if (state.phase == PlaybackPhase.failed) return;
          final changed = isPlaying != event.value;
          isPlaying = event.value as bool;
          if (!loading) state.updatePlaying(isPlaying);
          if (isPlaying) {
            disconnected = false;
            disconnectDetail = null;
            onUserActivity();
          } else {
            controlsVisible = true;
            _hideTimer?.cancel();
          }
          if (changed && _sessionStarted && !disconnected) {
            unawaited(
              _reportProgress(eventName: isPlaying ? 'Unpause' : 'Pause'),
            );
          }
        case VideoEventKind.completed:
          if (event.value == true) {
            if (loading) {
              _pendingCompletion = true;
            } else {
              unawaited(_handleCompleted());
            }
          }
        case VideoEventKind.error:
          final message = event.value as String;
          if (!isFatalPlaybackError(message, playing: isPlaying)) return;
          disconnected = true;
          isPlaying = false;
          loading = false;
          disconnectDetail = message.trim().isEmpty ? null : message.trim();
          controlsVisible = true;
          state.phase = PlaybackPhase.failed;
          _hideTimer?.cancel();
        case VideoEventKind.authenticationRequired:
          sessionExpired = true;
          disconnected = true;
          loading = false;
          isPlaying = false;
          controlsVisible = true;
          state.phase = PlaybackPhase.failed;
          disconnectDetail = 'Media HTTP ${event.value}';
          _hideTimer?.cancel();
          _progressTimer?.cancel();
          unawaited(backend.stop().catchError((Object _) {}));
      }
      _lastPlaybackUi = DateTime.now();
      _emit();
    });
  }

  bool _playbackUiDue() {
    return DateTime.now().difference(_lastPlaybackUi) >= kPlaybackUiMinInterval;
  }

  Future<void> _open({
    required PlaybackOperation operation,
    required int startTicks,
    int? audio,
    int? subtitle,
    bool subtitleOff = false,
    bool forceTranscode = false,
    bool startPaused = false,
  }) async {
    if (!_accepts(operation)) return;
    loading = true;
    state.phase = PlaybackPhase.loading;
    state.buffering = false;
    isPlaying = false;
    disconnected = false;
    disconnectDetail = null;
    buffer = Duration.zero;
    cacheSpeedBytesPerSec = 0;
    nextEpisode = null;
    playbackEnded = false;
    _nextUpOffered = false;
    _nextUpLoading = false;
    _handlingCompleted = false;
    _pendingCompletion = false;
    _nextTimer?.cancel();
    _emit();

    try {
      // 不带 MediaSourceId 请求:部分服务端(含 Emby)收到该参数时只返回
      // 这一个源,播放器就再也列不出其它版本;全部源在本地用
      // [preferredPlaybackSourceId] 按 id/发行组标签挑选。
      final info = await client.getPlaybackInfo(
        itemId: itemId,
        maxStreamingBitrate: maxStreamingBitrate,
        startTimeTicks: startTicks > 0 ? startTicks : null,
        audioStreamIndex: audio ?? preferredAudioStreamIndex,
        subtitleStreamIndex: subtitleOff
            ? null
            : (subtitle ?? preferredSubtitleStreamIndex),
        deviceProfile: backend is VideoBackendCapabilities
            ? await (backend as VideoBackendCapabilities).deviceProfile(
                maxStreamingBitrate,
              )
            : null,
        forceTranscode: forceTranscode,
      );
      if (!_accepts(operation)) {
        return;
      }
      mediaSources = info.mediaSources;
      final chosenId = preferredPlaybackSourceId(
        sources: info.mediaSources,
        requestedId: activeMediaSourceId ?? preferredMediaSourceId,
        requestedName: _preferredSourceName,
      );
      if (chosenId != null) {
        activeMediaSourceId = chosenId;
      }
      final next = resolvePlayback(
        info: info,
        baseUrl: client.baseUrl!,
        accessToken: client.accessToken!,
        itemId: itemId,
        mediaSourceId: chosenId,
        forceTranscode: forceTranscode,
      );
      if (next == null) {
        error = PlayerErrorKind.noStream;
        loading = false;
        state.phase = PlaybackPhase.failed;
        _emit();
        return;
      }
      resolved = next;
      final memory = _rememberedPreference;
      final selectedAudio =
          matchPreferredStreamIndex(
            streams: next.mediaSource.audioStreams,
            preferredIndex:
                audio ?? preferredAudioStreamIndex ?? memory?.audioStreamIndex,
            language: memory?.audioLanguage,
            title: memory?.audioTitle,
          ) ??
          next.mediaSource.defaultAudioStreamIndex;
      final int? selectedSubtitle;
      if (subtitleOff) {
        selectedSubtitle = null;
      } else {
        selectedSubtitle =
            matchPreferredStreamIndex(
              streams: next.mediaSource.subtitleStreams,
              preferredIndex:
                  subtitle ??
                  preferredSubtitleStreamIndex ??
                  memory?.subtitleStreamIndex,
              language: memory?.subtitleLanguage,
              title: memory?.subtitleTitle,
            ) ??
            fallbackSubtitleStreamIndex(next.mediaSource);
      }

      if (selectedSubtitle != null) {
        final stream = next.mediaSource.streamByIndex(selectedSubtitle);
        if (stream != null && stream.isBitmapSubtitle) {
          if (next.isTranscode) {
            // 转码:服务器烧录进流。
            _showSubtitleNotice(SubtitleNoticeKind.bitmapBurnIn);
          }
          // 直连:保留选择,_applySubtitle 直接选内嵌轨道本地渲染。
        }
      }

      Future<void>? started;
      final subtitleRevision = ++_trackRevision;
      _trackRevisions['SubtitleTrackChange'] = subtitleRevision;
      await _operations.run(operation, () async {
        await backend.open(
          VideoOpenRequest(
            sessionId: operation.id,
            url: next.streamUrl,
            playMethod: next.playMethod,
            isInfiniteStream: next.mediaSource.isInfiniteStream,
            mediaStreams: next.isTranscode
                ? [
                    for (final stream in next.mediaSource.subtitleStreams)
                      if (_transcodeSubtitleDelivery(stream) ==
                          TranscodeSubtitleDelivery.manifest)
                        stream,
                  ]
                : next.mediaSource.mediaStreams,
            startPaused: startPaused,
            start: durationFromTicks(startTicks),
            credentialOrigin: client.baseUrl,
            credentialHeaders: client.sessionHeaders,
            // 仅当流地址与 Emby 服务器同源时附加会话头;strm 等远端
            // 直连地址传空 headers,避免令牌泄漏给第三方主机。
            headers: playbackStreamHeaders(
              streamUrl: next.streamUrl,
              baseUrl: client.baseUrl!,
              sessionHeaders: client.sessionHeaders,
            ),
          ),
        );
        if (!_accepts(operation)) return;
        final runtime =
            next.mediaSource.runTimeTicks ?? item?.runTimeTicks ?? 0;
        _catalogRuntime = durationFromTicks(runtime);
        if (runtime > 0) {
          duration = _catalogRuntime;
        }
        _setPosition(backend.position);
        _rebuildSkipSegments();
        isPlaying = backend.isPlaying;
        audioStreamIndex = next.isTranscode
            ? selectedAudio
            : backend.selectedAudioIndex;
        subtitleStreamIndex =
            next.isTranscode &&
                selectedSubtitle != null &&
                _transcodeSubtitleDelivery(
                      next.mediaSource.streamByIndex(selectedSubtitle)!,
                    ) ==
                    TranscodeSubtitleDelivery.burnIn
            ? selectedSubtitle
            : backend.selectedSubtitleIndex;
        loading = false;
        state.updatePlaying(isPlaying);
        // Publish readiness before optional commands or Playing can block.
        _emit();
        started = _beginSession(operation, startTicks: startTicks);
        if (_pendingCompletion) {
          _pendingCompletion = false;
          unawaited(_handleCompleted());
        }
        await _restoreParameter(
          operation,
          () => backend.setVolume(mpvVolumeForPercent(volume)),
        );
        await _restoreParameter(operation, () => backend.setRate(playbackRate));
        await _restoreParameter(operation, () async {
          if (selectedAudio != null && !next.isTranscode) {
            await backend.setAudioIndex(selectedAudio);
          }
          if (_accepts(operation)) audioStreamIndex = selectedAudio;
        });
      });
      if (!_accepts(operation) || disconnected) return;
      final subtitleSession = _session;
      bool ownsSubtitle() =>
          identical(subtitleSession, _session) &&
          subtitleRevision == _trackRevisions['SubtitleTrackChange'];
      await _restoreParameter(operation, () async {
        await _applySubtitle(
          next,
          operation,
          subtitle: selectedSubtitle,
          revision: subtitleRevision,
        );
        if (_accepts(operation) && ownsSubtitle()) {
          subtitleStreamIndex = selectedSubtitle;
        }
      }, accepts: ownsSubtitle);
      if (!_accepts(operation) || disconnected) return;
      // 换源/重开后部分后端会丢外挂字幕选择(字幕要等一会儿才出现),
      // 起流片刻后重断言一次,字幕晚显的问题即消失。
      if (ownsSubtitle()) _scheduleSubtitleReassert();
      await started;
      if (!_accepts(operation) || disconnected) return;
      error = null;
      _preferredSourceName = _sourceFingerprint(next.mediaSource);
      if (trackFailure == null) await _persistSeriesPreference();
      if (!_accepts(operation)) return;
      // 续播落在片头/片尾或最后几分钟时,loading 期间的 position 不会弹出
      // 跳过/下一集;开流完成后再判一次。
      _updateActiveSkip();
      _maybeOfferNextUp();
      onUserActivity();
      _emit();
    } on VideoCompatibilityException catch (failure) {
      if (!forceTranscode && _accepts(operation)) {
        await backend.stop();
        await _open(
          operation: operation,
          startTicks: startTicks,
          audio: audio,
          subtitle: subtitle,
          subtitleOff: subtitleOff,
          forceTranscode: true,
          startPaused: startPaused,
        );
      } else {
        await _failOpen(operation, detail: failure.toString());
      }
    } on EmbyException catch (failure) {
      await _failOpen(operation, failure: failure);
    } catch (error) {
      await _failOpen(operation, detail: error.toString());
    }
  }

  Future<void> _restoreParameter(
    PlaybackOperation operation,
    Future<void> Function() apply, {
    bool Function()? accepts,
  }) async {
    bool current() =>
        _accepts(operation) && !disconnected && (accepts?.call() ?? true);
    if (!current()) return;
    try {
      await apply();
    } on TimeoutException {
      // A missing native reply does not establish a healthy control channel.
      if (current()) rethrow;
    } catch (failure) {
      if (current()) {
        trackFailure = failure.toString();
        _emit();
      }
    }
  }

  Future<void> _failOpen(
    PlaybackOperation operation, {
    EmbyException? failure,
    String? detail,
  }) async {
    if (!_accepts(operation)) return;
    final stopped = _session?.id == operation.id
        ? _stopSession()
        : Future<void>.value();
    try {
      // Queue cleanup with the failed open's identity. A new operation can
      // supersede it while queued, and must never be stopped by stale cleanup.
      await _operations.run(operation, backend.stop);
      await stopped;
    } finally {
      if (_accepts(operation)) {
        isPlaying = false;
        state.buffering = false;
        error = PlayerErrorKind.load;
        loadFailure = failure;
        if (detail != null && detail.trim().isNotEmpty) {
          disconnectDetail = detail.trim();
        }
        state.phase = PlaybackPhase.failed;
        loading = false;
        _emit();
      }
    }
  }

  Future<void> _applySubtitle(
    ResolvedPlayback next,
    PlaybackOperation operation, {
    required int? subtitle,
    required int? revision,
  }) async {
    final session = _session;
    bool current() =>
        _accepts(operation) &&
        identical(session, _session) &&
        !disconnected &&
        revision == _trackRevisions['SubtitleTrackChange'];
    await _activatePlaybackSubtitle(next, subtitle, current: current);
  }

  TranscodeSubtitleDelivery _transcodeSubtitleDelivery(
    MediaStreamInfo stream,
  ) => backend is VideoBackendTranscodeSubtitles
      ? (backend as VideoBackendTranscodeSubtitles).transcodeSubtitleDelivery(
          stream,
        )
      : TranscodeSubtitleDelivery.burnIn;

  Future<void> _activatePlaybackSubtitle(
    ResolvedPlayback next,
    int? subtitle, {
    required bool Function() current,
  }) async {
    if (!current()) return;
    if (subtitle == null) {
      await backend.setSubtitleOff();
      return;
    }
    final stream = next.mediaSource.streamByIndex(subtitle);
    if (stream == null || !stream.isSubtitle) {
      throw StateError('Subtitle track is unavailable');
    }
    if (next.isTranscode) {
      switch (_transcodeSubtitleDelivery(stream)) {
        case TranscodeSubtitleDelivery.burnIn:
          // Preserve desktop/server Encode behavior.
          return;
        case TranscodeSubtitleDelivery.external:
          await _activateSubtitle(
            next.mediaSource,
            subtitle,
            forceExternal: true,
            current: current,
          );
          return;
        case TranscodeSubtitleDelivery.manifest:
          await backend.setSubtitleIndex(subtitle);
          return;
      }
    }
    await _activateSubtitle(next.mediaSource, subtitle, current: current);
  }

  /// 内嵌文本按容器流索引切换。外挂文本先整文件下载到本地,再交给 mpv。
  /// 菜单勾选只在调用方确认这次选择已经生效后更新。
  Future<void> _activateSubtitle(
    PlaybackMediaSource source,
    int? index, {
    bool forceExternal = false,
    required bool Function() current,
  }) async {
    if (!current()) return;
    if (index == null) {
      await backend.setSubtitleOff();
      return;
    }
    final stream = source.streamByIndex(index);
    if (stream == null || !stream.isSubtitle) {
      throw StateError('Subtitle track is unavailable');
    }
    if (!forceExternal && stream.isBitmapSubtitle) {
      await backend.setSubtitleIndex(index);
      return;
    }
    if (!forceExternal && !stream.isExternal) {
      try {
        // 内嵌文本(ASS 等)已在直连容器里。按流索引选择,避免再向
        // 服务器提取一份外挂文件(该请求会超时或选不中,字幕就不出现)。
        await backend.setSubtitleIndex(index);
        return;
      } on StateError {
        // 容器里没有对应轨道时,再走外挂地址。
      }
    }
    if (!current()) return;
    final deliveryUrl = stream.deliveryUrl;
    final remote = deliveryUrl != null && deliveryUrl.isNotEmpty
        ? embyResourceUri(client.baseUrl!, deliveryUrl, client.accessToken!)
        : client.subtitleStreamUrl(
            itemId: itemId,
            mediaSourceId: source.id,
            index: index,
            format: stream.externalSubtitleFormat,
          );
    final format = remote.path.toLowerCase().endsWith('.vtt')
        ? 'vtt'
        : remote.path.toLowerCase().endsWith('.srt')
        ? 'srt'
        : stream.externalSubtitleFormat;
    final file = await _downloadSubtitleFile(remote, index, format, current);
    if (file == null) return;
    var retained = false;
    try {
      if (!current()) return;
      final applied = await backend.setSubtitleUri(
        file.uri,
        title: stream.label,
      );
      if (!current()) return;
      if (!applied) {
        throw StateError('External subtitle was not selected');
      }
      // Capture the prior owner only at commit. Every download has a unique
      // path, so a superseded completion can only delete its own candidate.
      final previous = _activeSubtitleFile;
      _activeSubtitleFile = file;
      retained = true;
      if (previous != null) await _deleteSubtitleFile(previous);
    } finally {
      if (!retained) await _deleteSubtitleFile(file);
    }
  }

  Future<File?> _downloadSubtitleFile(
    Uri remote,
    int index,
    String format,
    bool Function() current,
  ) async {
    if (!current()) return null;
    final safeFormat = format.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final ext = safeFormat.isEmpty ? 'srt' : safeFormat;
    final safeId = itemId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final bytes = await client.readAuthorizedBytes(remote);
    if (!current()) return null;
    final sample = utf8
        .decode(
          bytes.take(math.min(bytes.length, 256)).toList(),
          allowMalformed: true,
        )
        .trimLeft()
        .toLowerCase();
    if (sample.isEmpty ||
        sample.startsWith('<!doctype') ||
        sample.startsWith('<html') ||
        sample.startsWith('{')) {
      throw StateError('Subtitle response was not a subtitle file');
    }
    var cache = _subtitleCache;
    if (cache == null) {
      final created = await Directory.systemTemp.createTemp(
        'rillight-subtitles-',
      );
      if (!current()) {
        await created.delete(recursive: true);
        return null;
      }
      cache = _subtitleCache;
      if (cache == null) {
        _subtitleCache = cache = created;
      } else {
        await created.delete(recursive: true);
        if (!current()) return null;
      }
    }
    final file = File(
      '${cache.path}${Platform.pathSeparator}$safeId-$index-${++_subtitleFileSequence}.$ext',
    );
    var completed = false;
    try {
      await file.writeAsBytes(bytes, flush: true);
      if (!current()) return null;
      completed = true;
      return file;
    } finally {
      if (!completed) await _deleteSubtitleFile(file);
    }
  }

  Future<void> _deleteSubtitleFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _deleteSubtitleCache() async {
    final cache = _subtitleCache;
    _subtitleCache = null;
    _activeSubtitleFile = null;
    if (cache == null) return;
    try {
      if (await cache.exists()) await cache.delete(recursive: true);
    } catch (_) {}
  }

  /// 起流 2 秒后重断言外挂字幕选择:直接播放的外挂文本字幕在重开
  /// 后偶发丢失,延迟重放一次即可恢复;烧录/内嵌轨道无副作用。
  /// 到期检查挂在进度上报节拍上执行。
  void _scheduleSubtitleReassert() {
    _subtitleReassertDue = DateTime.now().add(const Duration(seconds: 2));
  }

  void _maybeReassertSubtitle() {
    final due = _subtitleReassertDue;
    if (due == null || DateTime.now().isBefore(due)) {
      return;
    }
    _subtitleReassertDue = null;
    final current = resolved;
    final index = subtitleStreamIndex;
    if (current == null || index == null) {
      return;
    }
    final stream = current.mediaSource.streamByIndex(index);
    if (stream == null || !stream.isSubtitle) {
      return;
    }
    final operation = _operations.current;
    if (operation == null || loading) return;
    unawaited(
      _applySubtitle(
        current,
        operation,
        subtitle: index,
        revision: _trackRevisions['SubtitleTrackChange'],
      ).catchError((Object _) {}),
    );
  }

  Future<void> _reopen({
    required int startTicks,
    int? subtitle,
    int? audio,
    bool subtitleOff = false,
  }) async {
    final operation = _beginOperation();
    if (operation == null || _disposed) return;
    final nextSubtitle = subtitleOff ? null : subtitle ?? subtitleStreamIndex;
    final nextAudio = audio ?? audioStreamIndex;
    final stopped = _stopSession();
    await _operations.interrupt(backend.stop);
    await stopped;
    if (!_accepts(operation)) return;
    await _open(
      operation: operation,
      startTicks: startTicks,
      audio: nextAudio,
      subtitle: nextSubtitle,
      subtitleOff: nextSubtitle == null,
    );
  }

  bool _ownsSession(PlaybackSession session) =>
      identical(_session, session) &&
      !session.stopped &&
      session.ownsCredentials &&
      !_operations.isClosed &&
      !_disposed;

  Future<void> _beginSession(
    PlaybackOperation operation, {
    required int startTicks,
  }) async {
    if (!_accepts(operation)) return;
    final report = _currentReport(positionTicks: startTicks);
    final session = PlaybackSession(
      id: operation.id,
      client: client,
      report: report,
    );
    _session = session;
    checkIn.start();
    _sessionStarted = true;
    sessionExpired = false;
    try {
      await session.enqueue(() => client.reportPlaying(report));
      if (!_ownsSession(session) || !_accepts(operation)) return;
      _onReportSucceeded();
      _writeSnapshot(session, report);
    } on EmbyException catch (failure) {
      if (!_ownsSession(session) || !_accepts(operation)) return;
      _onReportFailed(failure);
    } catch (_) {
      if (!_ownsSession(session) || !_accepts(operation)) return;
      _onReportFailed(null);
    }
    if (!_ownsSession(session)) return;
    _progressTimer?.cancel();
    _progressTimer = null;
    if (sessionExpired) return;
    _progressTimer = Timer.periodic(progressInterval, (_) {
      _maybeReassertSubtitle();
      unawaited(_reportProgress(eventName: 'TimeUpdate'));
    });
  }

  Future<void> _reportProgress({String? eventName}) async {
    final session = _session;
    if (session == null || !_ownsSession(session) || sessionExpired) return;
    final report = _currentReport(eventName: eventName);
    session.report = report;
    try {
      await session.enqueue(() => client.reportProgress(report));
      if (!_ownsSession(session)) return;
      _onReportSucceeded();
      _writeSnapshot(session, report);
    } on EmbyException catch (failure) {
      if (_ownsSession(session)) _onReportFailed(failure);
    } catch (_) {
      if (_ownsSession(session)) _onReportFailed(null);
    }
  }

  Future<void> _stopSession() {
    _progressTimer?.cancel();
    _progressTimer = null;
    final session = _session;
    if (session == null) return _awaitPendingStopped();
    final report = _currentReport();
    session.report = report;
    session.stopped = true;
    _session = null;
    checkIn.stop();
    _sessionStarted = false;
    return _trackStopped(_doSendStopped(session, report));
  }

  Future<void> _awaitPendingStopped() async {
    final pending = _pendingStopped;
    if (pending != null) await pending;
  }

  Future<void> _trackStopped(Future<void> pending) {
    _pendingStopped = pending;
    return pending.whenComplete(() {
      if (identical(_pendingStopped, pending)) _pendingStopped = null;
    });
  }

  Future<void> _doSendStopped(
    PlaybackSession session,
    PlaybackReport report,
  ) async {
    try {
      await session
          .enqueue(() => client.reportStopped(report))
          .timeout(stoppedTimeout);
      if (!session.ownsCredentials) return;
      if (_session == null &&
          (_operations.current?.id == session.id || _backgroundReleased)) {
        _onReportSucceeded();
      }
      await _enqueueSnapshot(() async {
        final snapshot = await snapshotStore.read();
        if (_snapshotOwner == session.id &&
            snapshot?.playSessionId == report.playSessionId &&
            snapshot?.itemId == report.itemId &&
            snapshot?.baseUrl == session.baseUrl &&
            snapshot?.userId == session.userId) {
          await snapshotStore.delete();
        }
      });
    } on EmbyException catch (failure) {
      if (_session == null &&
          session.ownsCredentials &&
          (_operations.current?.id == session.id ||
              _operations.isClosed ||
              _backgroundReleased)) {
        _onReportFailed(failure);
      }
    } catch (_) {
      if (_session == null &&
          session.ownsCredentials &&
          (_operations.current?.id == session.id ||
              _operations.isClosed ||
              _backgroundReleased)) {
        _onReportFailed(null);
      }
    }
  }

  void _onReportSucceeded() {
    _reportFailureStreak = 0;
    _clearProgressSyncFailed();
  }

  /// [failure] 为 null 表示超时。
  void _onReportFailed(EmbyException? failure) {
    if (_operations.isClosed || _disposed) {
      progressSyncFailed = true;
      return;
    }
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

  void _writeSnapshot(PlaybackSession session, PlaybackReport report) {
    final baseUrl = session.baseUrl;
    final userId = session.userId;
    if (!_ownsSession(session) ||
        baseUrl == null ||
        userId == null ||
        userId.isEmpty) {
      return;
    }
    final snapshot = PlaybackSessionSnapshot(
      itemId: report.itemId,
      mediaSourceId: report.mediaSourceId,
      playSessionId: report.playSessionId,
      playMethod: report.playMethod,
      positionTicks: report.positionTicks,
      baseUrl: baseUrl,
      userId: userId,
      timestamp: DateTime.now(),
    );
    unawaited(
      _enqueueSnapshot(() async {
        if (_ownsSession(session)) {
          _snapshotOwner = session.id;
          await snapshotStore.write(snapshot);
        }
      }),
    );
  }

  /// 空闲时立刻执行(内存实现即时生效),忙时按序排队;任何失败吞掉。
  /// 返回对应本次操作完成的 Future,供 Stopped 成功路径在 onClose 前等待删除。
  Future<void> _enqueueSnapshot(Future<void> Function() operation) {
    final done = Completer<void>();
    _snapshotOps.add(() async {
      try {
        await operation();
      } catch (_) {
      } finally {
        if (!done.isCompleted) {
          done.complete();
        }
      }
    });
    if (!_snapshotDraining) {
      unawaited(_drainSnapshotOps());
    }
    return done.future;
  }

  Future<void> _drainSnapshotOps() async {
    _snapshotDraining = true;
    try {
      while (_snapshotOps.isNotEmpty) {
        final operation = _snapshotOps.removeAt(0);
        await operation();
      }
    } finally {
      _snapshotDraining = false;
      if (_snapshotOps.isNotEmpty) {
        unawaited(_drainSnapshotOps());
      }
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

  /// 进度必须接近目录片长或当前片长里更长的那个。
  /// 解复用器把截断流报成很短的 duration 时,不能把开场 eof 当成播完。
  bool _reachedEpisodeEnd() {
    final known = duration > _catalogRuntime ? duration : _catalogRuntime;
    if (known <= Duration.zero) return false;
    return known - position <= kNaturalEndTolerance;
  }

  Future<void> _handleCompleted() async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    if (_disposed || _handlingCompleted || playbackEnded) {
      return;
    }
    if (!_reachedEpisodeEnd()) return;
    _handlingCompleted = true;
    state.phase = PlaybackPhase.ended;
    state.buffering = false;
    isPlaying = false;
    controlsVisible = true;
    _hideTimer?.cancel();
    final pending = _stopSession();
    _pendingStopped = pending;
    unawaited(
      pending.whenComplete(() {
        if (identical(_pendingStopped, pending)) {
          _pendingStopped = null;
        }
      }),
    );

    final existing = nextEpisode?.item;
    if (existing != null) {
      _presentCompletedNext(existing);
      return;
    }
    if (item == null || !item!.isEpisode) {
      _showPlaybackEnded();
      return;
    }
    // 先出结束引导,避免等下一集请求时停在末帧没有入口。
    _showPlaybackEnded();
    try {
      final next = await client.getNextEpisode(item!);
      if (!_accepts(operation) || next == null) {
        return;
      }
      _presentCompletedNext(next);
    } on EmbyException {
      // 结束卡已在。
    }
  }

  void _presentCompletedNext(EmbyItem next) {
    if (_disposed) {
      return;
    }
    playbackEnded = false;
    final autoplay = user?.enableNextEpisodeAutoPlay ?? true;
    if (!autoplay) {
      nextEpisode = NextEpisodeOffer(item: next);
      _emit();
      return;
    }
    _beginNextEpisodeCountdown(next);
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
  Future<void> _restoreSettings(PlaybackOperation operation) async {
    try {
      final settings = await (await _settings()).read();
      if (!_accepts(operation)) return;
      volume = settings.clampedVolume;
      playbackRate = settings.effectivePlaybackRate;
      _seriesPreferences = Map.of(settings.seriesPreferences);
      if (volume > 0) {
        _unmutedVolume = volume;
      }
      await _operations.run(
        operation,
        () => backend.setVolume(mpvVolumeForPercent(volume)),
      );
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
      final value = PlayerSettings(
        volume: volume,
        playbackRate: playbackRate,
        seriesPreferences: Map.of(_seriesPreferences),
      );
      await (await _settings()).write(value);
    } catch (_) {}
  }

  /// start() 时按 item.seriesId 解析记忆的音轨/字幕/码率。
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
    _preferredSourceName = preference.mediaSourceName ?? _preferredSourceName;
  }

  /// 播放中选择音轨/字幕(含关闭)/码率后写入按剧记忆。
  Future<void> _persistSeriesPreference() async {
    final seriesId = item?.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return;
    }
    final source = resolved?.mediaSource;
    final audio = audioStreamIndex == null
        ? null
        : source?.streamByIndex(audioStreamIndex!);
    final subtitle = subtitleStreamIndex == null
        ? null
        : source?.streamByIndex(subtitleStreamIndex!);
    final hasSubtitles = source?.subtitleStreams.isNotEmpty ?? false;
    _preferredSourceName = _sourceFingerprint(source) ?? _preferredSourceName;
    _seriesPreferences = Map.of(_seriesPreferences);
    _seriesPreferences[seriesId] = PlayerSeriesPreference(
      audioStreamIndex: audioStreamIndex,
      audioLanguage: audio?.language,
      audioTitle: audio?.displayTitle ?? audio?.label,
      subtitleStreamIndex: subtitleStreamIndex,
      subtitleLanguage: subtitle?.language,
      subtitleTitle: subtitle?.displayTitle ?? subtitle?.label,
      subtitleOff: subtitleStreamIndex == null && hasSubtitles,
      maxStreamingBitrate: maxStreamingBitrate,
      mediaSourceName: _preferredSourceName,
    );
    await _writeSettings();
  }

  /// 跨集只记发行组,不记整段场景文件名。
  String? _sourceFingerprint(PlaybackMediaSource? source) {
    if (source == null) {
      return null;
    }
    final fingerprint = mediaSourceFingerprint(source.name ?? source.label);
    if (fingerprint.isNotEmpty) {
      return fingerprint;
    }
    final label = source.label.trim();
    return label.isEmpty ? null : label;
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
    if (_disposed) return;
    unawaited(_disposing ??= _disposeResources(reportStopped: false));
    _disposed = true;
    window.removeListener(_emit);
    super.dispose();
  }
}

/// UI 音量百分比到 mpv volume。
///
/// 100 为原片 0 dB;超过 100 为额外增益,上限 [PlayerSettings.volumeMax]。
/// 滑条旁显示的就是这个百分比,必须一对一交给 backend。
double mpvVolumeForPercent(int percent) {
  return percent.clamp(0, PlayerSettings.volumeMax).toDouble();
}

/// 滚轮按 5% 一档对齐,从滑条上的 91 也能经过 100,而不是 96、101。
@visibleForTesting
int volumeAfterWheelNudge(int volume, int delta) {
  const step = PlayerController.volumeWheelStep;
  const max = PlayerSettings.volumeMax;
  if (delta == 0) {
    return volume.clamp(0, max);
  }
  if (delta > 0) {
    final next = volume % step == 0
        ? volume + step
        : (volume ~/ step + 1) * step;
    return next.clamp(0, max);
  }
  final previous = volume % step == 0 ? volume - step : (volume ~/ step) * step;
  return previous.clamp(0, max);
}

/// 时间轴缓存带比例:mpv `demuxer-cache-time` / 片长。
///
/// 对应 HTML video `buffered` 的单段近似(缓存终点),画在已播轨道下面。
double playerBufferFraction({
  required Duration buffer,
  required Duration duration,
}) {
  final durationMs = duration.inMilliseconds;
  if (durationMs <= 0) {
    return 0;
  }
  return (buffer.inMilliseconds / durationMs).clamp(0.0, 1.0);
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
