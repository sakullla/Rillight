import '../auth/server_entry_coordinator.dart';
export '../auth/line_selection.dart';
import 'playback_recovery_coordinator.dart';
import '../platform/network_change_monitor.dart';

import 'package:rillight/player/playback_persistence.dart';

import 'dart:async';

import 'package:rillight/player/player_host_command.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/playback_metadata.dart';
import 'package:rillight/media_server/resources.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/media_source_format.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/player/cache/next_episode_prefix.dart';
import 'package:rillight/player/playback_check_in.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/playback_coordinator.dart';
import 'package:rillight/player/playback_session.dart';

import 'playback_runtime.dart';
import 'player_bindings.dart'
    show
        PlaybackObservationSink,
        PlaybackSwitchDispatcher,
        PlaybackReportOutcomeSink;
import 'player_window_host.dart';
import '../auth/auth_controller.dart';
import '../auth/server_access.dart';
import '../auth/server_list_store.dart';
import '../aggregation/history/history_writer.dart';
import '../aggregation/identity/media_identity.dart';
import '../aggregation/query/same_source_query.dart';

import 'package:rillight/player/playback_switch_preflight.dart';
export 'package:rillight/player/playback_switch_preflight.dart';
import 'package:rillight/player/playback_state.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/session_subtitle_files.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_startup.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

part 'player_line_transactions.dart';

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

  final MediaItem item;
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
    this.networkSlowAfter = const Duration(seconds: 6),
    this.seekStep = const Duration(seconds: 10),
    this.seekTimeout = const Duration(seconds: 12),
    Duration? recoveryTimeout,
    Duration? recoveryOpenTimeout,
    this.onClose,
    this.onOpenItem,
    this.onOpenItemDetail,
    this.preferredMediaSourceId,
    this.preferredAudioStreamIndex,
    this.preferredSubtitleStreamIndex,
    this.startPosition,
    this.preferredSecondarySubtitleStreamIndex,
    this.subtitleFilePicker,
    this.settingsStore,
    this.runtime,
    this.requestSourcePassword,
    this.observationSink,
    this.switchDispatcher,
    this.reportOutcomeSink,
    this.sourceOpenResult,
    this.openRequest,
    this.routeLeaseKey,
    this.playbackLineSnapshot = const [],
    this.verifiedPlaybackServerId,
    this.initialLineSelection,
    this.recoveryDeadlineUtc,
    this.recoveryAttemptDeadlineUtc,
    this.recoveryAttemptedLineIds = const [],
    this.nextPrefixFetch,
    this._startupData,
    PlaybackSessionSnapshotStore? snapshotStore,
  }) : recoveryTimeout = recoveryTimeout ?? const Duration(seconds: 45),
       recoveryOpenTimeout =
           recoveryOpenTimeout ??
           recoveryTimeout ??
           const Duration(seconds: 45),
       snapshotStore =
           snapshotStore ??
           FilePlaybackSessionSnapshotStore.forCurrentProcess() {
    _pauseIntent = openRequest?.startPaused ?? false;
    startPosition ??= openRequest?.startPosition;
    preferredMediaSourceId ??= openRequest?.mediaSourceId;
    preferredAudioStreamIndex ??= openRequest?.audioStreamIndex;
    preferredSubtitleStreamIndex ??= openRequest?.subtitleStreamIndex;
    preferredSecondarySubtitleStreamIndex ??=
        openRequest?.secondarySubtitleStreamIndex;
    maxStreamingBitrate =
        openRequest?.maxStreamingBitrate ?? maxStreamingBitrate;
    activeMediaSourceId = _scopedPlayback ? null : preferredMediaSourceId;
    if (routeLeaseKey != null) {
      runtime?.mountPlayer(
        routeLeaseKey!,
        () => _disposed || _revoked ? null : origin,
      );
    }
    runtime?.registry.access.addRevocationHook(_revokeSource);
    runtime?.registry.access.addCleanupHook(_closeRevokedSource);
    runtime?.registry.access.addTerminationHook(_terminateRevokedSource);
    runtime?.registry.addMembershipCleanup(_membershipRevoked);
    runtime?.registry.addSourceRevocation(_sourceRevoked);
    _installLineTransactions();
    _bindBackend();
    window.addListener(_emit);
  }

  /// 关窗/换集时等待 Stopped 送达的上限;超时视为失败,不再阻塞。
  static const Duration stoppedDeadline = Duration(seconds: 3);

  MediaServerClient client;
  final PlaybackRuntime? runtime;
  final Future<String?> Function(SavedServer server)? requestSourcePassword;
  ServerEntryTicket? _switchEntry;
  ServerEntryTicket? _pendingEntryCommit;
  final PlaybackObservationSink? observationSink;
  final PlaybackSwitchDispatcher? switchDispatcher;
  final PlaybackReportOutcomeSink? reportOutcomeSink;
  final Future<void> Function(String itemId, String? version, bool succeeded)?
  sourceOpenResult;
  bool get _scopedPlayback => runtime != null || observationSink != null;
  final PlayerOpenRequest? openRequest;
  final Object? routeLeaseKey;
  PlaybackOrigin? origin;
  PlaybackOrigin? activeOrigin;
  String? activeLineId;
  String? pendingLineId;
  List<ServerLine> playbackLineSnapshot;
  String? verifiedPlaybackServerId;

  bool _suspendLinePreference = false;
  String? playbackLineFailure;
  final LineSelection? initialLineSelection;
  final DateTime? recoveryDeadlineUtc;
  final DateTime? recoveryAttemptDeadlineUtc;
  final List<String> recoveryAttemptedLineIds;
  bool _initialRecoveryConsumed = false;

  /// One automatic line recovery per outage. A failed or cancelled attempt
  /// must not start another one when the player reports the same fault again.
  bool _holdAutomaticLineRecovery = false;
  LineSelection? _savedLineSelection;
  int _lineRevision = 0;
  PlaybackRecoveryBudget? _lineBudget;
  Future<void>? _lineRecovery;
  Future<void> Function(SwitchResumeChoice, int?, int?, bool, bool)?
  _confirmLine;
  Completer<void>? _lineConfirmationResult;
  int? _hostLineRequestRevision;
  DateTime? _lineSelectionDeadlineUtc;
  NetworkChangeMonitor? _networkChanges;
  StreamSubscription<void>? _networkChangeSubscription;
  bool _networkChanged = false;
  bool get networkChangePending => _networkChanged;
  bool _lineTransactionOpening = false;
  void Function()? _lineRollback;

  PlaybackOrigin? _switchTarget;
  MediaItem? _switchTargetItem;
  ({
    PlaybackOrigin origin,
    ResolvedPlayback playback,
    MediaItem? item,
    int position,
    int? audio,
    int? subtitle,
    bool paused,
  })?
  _restoreOrigin;
  PlaybackSession? _revokedSession;
  bool _revoked = false;
  bool get permissionRevoked => _revoked;
  bool _revokedCleanupComplete = false;
  Future<PlayerStartupData?>? _startupData;
  final _openStageMs = <String, int>{};

  /// Wall-clock milliseconds per open stage of the latest open attempt.
  /// Remote triage compares these against the startup baseline document.
  Map<String, int> get openStageTimings => Map.unmodifiable(_openStageMs);
  List<PlaybackMediaSource>? _startupVersions;
  DateTime? _startupVersionsAt;

  /// One-shot inherited versions from the launch handoff. Only a fresh,
  /// same-item, first open may skip source discovery; every reopen, renewal
  /// or retry negotiates from the server again.
  List<PlaybackMediaSource>? _takeStartupVersions(String itemId) {
    final versions = _startupVersions;
    final fetchedAt = _startupVersionsAt;
    _startupVersions = null;
    _startupVersionsAt = null;
    if (versions == null || versions.isEmpty) return null;
    if (openRequest?.itemId != itemId) return null;
    if (fetchedAt == null ||
        DateTime.now().difference(fetchedAt) > const Duration(seconds: 30)) {
      return null;
    }
    return versions;
  }

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

  /// How long buffering must stay below the expected bitrate before the hint.
  final Duration networkSlowAfter;
  final Duration seekStep;
  final Duration seekTimeout;

  /// Total wall-clock budget for a retry or media-source change.
  final Duration recoveryTimeout;
  // Opening must outlive origin header recovery and the native first-frame
  // deadline. Stopping the old session keeps the shorter control deadline.
  final Duration recoveryOpenTimeout;
  final VoidCallback? onClose;
  final ValueChanged<String>? onOpenItem;

  /// 进程内不可播放的条目(如剧集)改为通知主窗口打开详情页;
  /// 独立播放进程在 [onOpenItem] 之外提供该回调。
  final void Function(
    String itemId, {
    String? seasonId,
    PlayerHostOpenItemCommand? command,
  })?
  onOpenItemDetail;
  PlayerSettingsStore? settingsStore;

  final NextPrefixFetch? nextPrefixFetch;
  NextEpisodePrefix? _nextPrefix;
  bool _userPausedPrefix = false;
  bool _prefixYield = false;

  /// 会话快照:Playing/Progress 成功后写入,Stopped 成功后删除,
  /// 供宿主在播放进程被终止后代发 Stopped。
  final PlaybackSessionSnapshotStore snapshotStore;

  /// 首次起播请求携带的源/轨道/章节起点;进程内切集([_playItem])时清除,
  /// 这些偏好只对最初打开的条目有效。
  String? preferredMediaSourceId;
  int? preferredAudioStreamIndex;
  int? preferredSubtitleStreamIndex;
  Duration? startPosition;

  /// 首次起播请求携带的次字幕显式预选;消费后清除,不进入持久化。
  int? preferredSecondarySubtitleStreamIndex;

  final PlaybackCheckInMachine checkIn = PlaybackCheckInMachine();

  bool loading = true;
  bool controlsVisible = true;
  bool isPlaying = false;

  // Native loading/stop events are observations, not a user pause request.
  // Keep the requested state while no ready playback state is available.
  bool _pauseIntent = false;
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
  Map<String, Object?>? _lastProgressFailure;
  Map<String, Object?>? _lastCleanupFailure;

  /// Safe diagnostics: never include a server address, credential or raw error.
  Map<String, Object?> get progressSyncDiagnostics => {
    'failed': progressSyncFailed,
    'persistent': progressSyncPersistent,
    'lastFailure': _lastProgressFailure,
    'pendingCleanupCount': _pendingResourceCleanup.length,
    'lastCleanupFailure': _lastCleanupFailure,
  };

  Map<String, Object?> _syncFailure(String stage, Object? failure) => {
    'stage': stage,
    'kind': failure is MediaServerException
        ? failure.kind.name
        : failure is TimeoutException
        ? 'timeout'
        : 'local',
    if (failure is MediaServerException) 'statusCode': failure.statusCode,
  };
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
  int? _sourceRenewalOperation;
  bool _sourceRenewalRequired = false;
  final Set<String> _refreshedSourceUrls = {};
  DateTime? _lineRetryAfter;
  DateTime? get playbackRetryAfter => _lineRetryAfter;
  String? _operationBaseUrl;
  String? _operationUserId;
  String? _operationToken;

  PlaybackOperation? _beginOperation({
    bool keepNextPrefix = false,
    bool lineTransaction = false,
  }) {
    if (!lineTransaction && _lineTransactionOpening) cancelLineRecovery();
    final operation = _operations.begin();
    if (operation != null) {
      if (!lineTransaction) {
        _finishLineConfirmation(const PlaybackRecoveryCancelled());
        _lineSelectionDeadlineUtc = null;
        ++_lineRevision;
        _lineBudget?.cancel();
        _confirmLine = null;
        if (_sourceRenewalOperation != null) {
          _sourceRenewalOperation = null;
          _sourceRenewalRequired = false;
          _lineBudget = null;
          isRecovering = false;
        }
      }
      _refreshedSourceUrls.clear();
      ++_switchInspection;
      switchConfirmation = null;
      _switchOriginal = null;
      if (_recoveryOperation != null) {
        _recoveryOperation = null;
        _recovery = null;
        _recoveryBase = null;
        isRecovering = false;
        pendingMediaSourceId = null;
      }
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
      if (!keepNextPrefix) unawaited(_discardNextPrefix());
      trackFailure = null;
    }
    return operation;
  }

  bool get isBuffering => state.buffering;
  bool _accepts(PlaybackOperation? operation) =>
      !_disposed &&
      !_revoked &&
      (origin?.permit.isValid ?? true) &&
      _operations.accepts(operation) &&
      _operationBaseUrl == client.baseUrl?.toString() &&
      _operationUserId == client.userId &&
      _operationToken == client.accessToken;

  int volume = 100;
  int _unmutedVolume = 100;
  int _volumeRevision = 0;
  int _rateRevision = 0;
  double playbackRate = 1.0;
  PlaybackOutputStatus outputStatus = PlaybackOutputStatus.unknown;

  /// Test and backend hook. Does not pause, seek, or change the Android
  /// background-release flag.
  void applyObservedOutput(PlaybackOutputStatus value) {
    if (value == outputStatus) return;
    outputStatus = value;
    _emit();
  }

  Future<void> refreshOutputStatus() async {
    final report = backend;
    if (_disposed || report is! VideoBackendOutputReport) return;
    final output = report as VideoBackendOutputReport;
    try {
      final next = await output.refreshOutputStatus();
      if (_disposed) return;
      applyObservedOutput(next);
    } catch (_) {
      // A failed status read leaves the last sample and the playing session.
    }
  }

  int maxStreamingBitrate = kCoreMaxStreamingBitrate;
  int? audioStreamIndex;
  int? subtitleStreamIndex;

  /// 次字幕(槽位 1)当前选中的服务器流索引;null 表示关闭或该槽
  /// 当前由会话导入文件占用。次字幕不进入任何持久化偏好,默认关闭。
  int? secondarySubtitleStreamIndex;

  /// 占用主/次字幕槽的会话导入文件 id;与 [subtitleStreamIndex]/
  /// [secondarySubtitleStreamIndex] 互斥,同一文件不可重复占用两槽。
  String? primarySubtitleFileId;
  String? secondarySubtitleFileId;

  /// 会话内导入的字幕候选:严格校验后的受控临时目录副本。
  final SessionSubtitleStore _subtitleImports = SessionSubtitleStore();

  /// 当前会话的导入候选列表(按导入顺序稳定)。
  List<SessionSubtitleFile> get sessionSubtitleFiles => _subtitleImports.files;

  /// 最近一次导入结果(失败/重复),供 UI 提示;成功或用户清除后为 null。
  SubtitleImportOutcome? subtitleImportNotice;

  /// 最近一次槽位互斥或烧录限制的拒绝 token,UI 负责本地化。
  String? subtitleSelectionNotice;

  /// 可注入的文件选择边界;缺省使用系统选择器。
  AppFilePicker? subtitleFilePicker;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  /// 条目或媒体源上的片长。直连时进度条可以采用更准确的探测时长;
  /// 转码 HLS 的探测时长常常只是剩余窗口,不能把整条进度盖成剩余长度。
  Duration _catalogRuntime = Duration.zero;

  /// Transcode HLS already starts at this media time. Core timestamps are
  /// relative to that origin and must be added back for the seek bar.
  Duration _streamOrigin = Duration.zero;
  DateTime? _knownBufferHeldAt;
  Duration buffer = Duration.zero;
  BufferSnapshot bufferSnapshot = BufferSnapshot.empty(
    sessionId: 0,
    unknownReason: 'notOpened',
  );

  /// HTTP 代理的上游接收速度，字节/秒；本地缓存命中不计入，无下载时为 0。
  double cacheSpeedBytesPerSec = 0;
  bool networkSlow = false;
  bool _networkSlowDismissed = false;
  DateTime? _slowSince;
  DateTime _lastPlaybackUi = DateTime.fromMillisecondsSinceEpoch(0);
  PlayerErrorKind? error;
  MediaServerException? _loadFailure;
  MediaServerException? get loadFailure => _loadFailure;
  set loadFailure(MediaServerException? value) {
    _loadFailure = value?.statusCode == 403
        ? MediaServerException(
            MediaServerFailureKind.rateLimited,
            statusCode: 403,
            detail: value!.detail,
            cause: value,
          )
        : value;
  }

  SubtitleNoticeKind? subtitleNotice;
  NextEpisodeOffer? nextEpisode;
  bool playbackEnded = false;
  MediaItem? item;
  MediaUser? user;
  ResolvedPlayback? resolved;
  PlayerSeriesPreference? _rememberedPreference;
  Map<String, PlayerSeriesPreference> _seriesPreferences = const {};
  Map<String, PlayerSeriesPreference> _itemPreferences = const {};

  // --- 剧集列表与切集(R7) ---
  bool episodeListLoading = false;
  bool episodeListFailed = false;
  List<MediaItem> seasons = const [];
  List<MediaItem> episodes = const [];
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
  bool skipIntroEnabled = true;
  bool skipOutroEnabled = true;
  static const _defaultControlsPin = 'player-controls-default';
  final Set<Object> _controlsPinOwners = {};
  bool get controlsPinned => _controlsPinOwners.isNotEmpty;
  bool _nextUpOffered = false;

  /// 用户取消过下一集后，这个控制器不再开始自动倒计时。
  /// 新的 [PlayerController] 才重新允许自动连播。
  bool _nextAutoplayCancelled = false;

  /// 这一集没有下一集时才显示跳过片尾。有下一集时下一集按钮代替它。
  bool _outroSkipAllowed = false;
  bool _nextUpLoading = false;
  bool _handlingCompleted = false;
  bool _pendingCompletion = false;

  // --- 媒体源切换(R9) ---
  List<PlaybackMediaSource> mediaSources = const [];
  String? activeMediaSourceId;
  String? pendingMediaSourceId;
  bool isRecovering = false;
  Future<void>? _recovery;
  PlaybackOperation? _recoveryOperation;
  Future<void>? _nativeRetirement;
  ({
    ResolvedPlayback? previous,
    String? oldSourceId,
    int startTicks,
    int? audio,
    int? subtitle,
    bool paused,
  })?
  _recoveryBase;

  /// 按发行组/版本标签跨集对齐(Emby 每集 MediaSourceId 和文件名都不同)。
  String? _preferredSourceName;

  PlayMethod? get playMethod => resolved?.playMethod;
  bool get isTranscode => playMethod == PlayMethod.transcode;
  bool get isFullScreen => window.isFullScreen;
  List<MediaStreamInfo> get audioTracks =>
      resolved?.mediaSource.audioStreams ?? const [];
  List<MediaStreamInfo> get subtitleTracks =>
      resolved?.mediaSource.subtitleStreams ?? const [];

  List<MediaStreamInfo> get selectableAudioTracks {
    final support = backend;
    if (isTranscode || support is! VideoBackendTrackSupport) return audioTracks;
    return audioTracks
        .where(
          (track) =>
              (support as VideoBackendTrackSupport).audioTrackSupported(
                track.index,
              ) !=
              false,
        )
        .toList(growable: false);
  }

  // Subtitle off is always available, including when a server omits track
  // metadata or a single subtitle cannot currently be decoded.
  List<MediaStreamInfo> get selectableSubtitleTracks => subtitleTracks;

  bool get canConfigureSubtitles =>
      selectableSubtitleTracks.isNotEmpty || subtitleStreamIndex != null;

  /// 无自带字幕的媒体也保留本地导入入口:媒体成功打开即可导入。
  bool get canImportSubtitleFiles =>
      resolved != null && !_disposed && !_operations.isClosed;

  bool get hasSecondarySubtitle =>
      secondarySubtitleStreamIndex != null || secondarySubtitleFileId != null;

  /// 同一服务器流是否已占用另一槽位(用于菜单禁用与提示)。
  bool subtitleStreamOccupiesOtherSlot(int slot, int streamIndex) => slot == 0
      ? secondarySubtitleStreamIndex == streamIndex
      : subtitleStreamIndex == streamIndex && primarySubtitleFileId == null;

  /// 会话导入文件是否已占用另一槽位。
  bool subtitleFileOccupiesOtherSlot(int slot, String fileId) => slot == 0
      ? secondarySubtitleFileId == fileId
      : primarySubtitleFileId == fileId;

  /// 转码烧录字幕无法独立关闭,不能冒充可独立关闭的次字幕来源。
  bool streamIsBurnedIn(int index) {
    final source = resolved?.mediaSource;
    if (source == null || !isTranscode) return false;
    final stream = source.streamByIndex(index);
    return stream != null &&
        _transcodeSubtitleDelivery(stream) == TranscodeSubtitleDelivery.burnIn;
  }

  bool get canSwitchAudioTrack => selectableAudioTracks.length > 1;
  bool get canSwitchQuality => availableBitrates.length > 1;

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

  bool get canChoosePlaybackLine => playbackLines.isNotEmpty;

  bool isConfiguredPlaybackUrl(Uri? url) {
    if (url == null) return false;
    for (final line in playbackLines) {
      if (Uri.tryParse(line.address) == url) return true;
    }
    return false;
  }

  void bindPlaybackLineSnapshot(
    List<ServerLine> lines, {
    String? verifiedServerId,
  }) {
    playbackLineSnapshot = List<ServerLine>.unmodifiable(lines);
    if (verifiedServerId != null && verifiedServerId.isNotEmpty) {
      verifiedPlaybackServerId = verifiedServerId;
    }
    _emit();
  }

  Timer? _progressTimer;
  Timer? _progressFailBannerTimer;
  Timer? _subtitleNoticeTimer;

  /// 换源/重开后重断言外挂字幕的到期时刻;挂在进度上报节拍上,
  /// 不新增独立定时器(避免测试与dispose遗漏时残留挂起定时器)。
  DateTime? _subtitleReassertDue;

  /// 本次播放下载的外挂字幕。停播后整目录删除,不留在系统临时目录。
  Directory? _subtitleCache;
  final Map<int, File> _activeSubtitleFiles = {};
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

  final Set<PlaybackResourceLease> _pendingResourceCleanup = {};
  final Map<PlaybackResourceLease, PlaybackSessionSnapshot> _cleanupSnapshots =
      {};

  bool _sameCleanup(PlaybackSessionSnapshot a, PlaybackSessionSnapshot b) =>
      a.playSessionId == b.playSessionId &&
      a.serviceType == b.serviceType &&
      a.baseUrl == b.baseUrl &&
      a.userId == b.userId;

  Future<void> _replaceSnapshotPreservingCleanup(
    PlaybackSessionSnapshot snapshot,
  ) async {
    final old = await snapshotStore.read();
    final pending = <PlaybackSessionSnapshot>[
      ...?old?.pendingCleanups,
      if (old?.cleanupOnly == true && !_sameCleanup(old!, snapshot))
        old.withPendingCleanups(const []),
    ].where((entry) => !_sameCleanup(entry, snapshot)).toList();
    await snapshotStore.write(snapshot.withPendingCleanups(pending));
  }

  Future<void> _persistFailedPreparation(
    PlaybackResourceLease lease, {
    PlaybackOrigin? target,
    String? targetItemId,
    String? sourceId,
  }) async {
    _pendingResourceCleanup.add(lease);
    final owner = target?.client ?? client;
    final base = owner.baseUrl;
    final user = owner.userId;
    final identity = target?.source ?? origin?.source ?? openRequest?.source;
    if (base == null || user == null) return;
    final cleanupItem = lease.itemId ?? targetItemId ?? itemId;
    final cleanupVersion = lease.mediaSourceId ?? sourceId ?? '';
    final snapshot = PlaybackSessionSnapshot(
      cleanupOnly: true,
      serviceType: owner.serviceType,
      itemId: cleanupItem,
      mediaSourceId: cleanupVersion,
      playSessionId: lease.id,
      playMethod: PlayMethod.transcode,
      position: Duration.zero,
      baseUrl: base.toString(),
      userId: user,
      timestamp: DateTime.now(),
      source: identity == null
          ? null
          : SourceReference(
              account: identity.account,
              itemId: cleanupItem,
              mediaSourceId: cleanupVersion,
            ),
      libraryId:
          target?.libraryId ?? origin?.libraryId ?? openRequest?.libraryId,
      accessGeneration:
          target?.permit.accessGeneration ??
          origin?.permit.accessGeneration ??
          openRequest?.accessGeneration,
    );
    _cleanupSnapshots[lease] = snapshot;
    await _enqueueSnapshot(() async {
      final old = await snapshotStore.read();
      if (old == null) {
        await snapshotStore.write(snapshot);
        return;
      }
      if (_sameCleanup(old, snapshot)) return;
      final children = [
        ...old.pendingCleanups.where((entry) => !_sameCleanup(entry, snapshot)),
        snapshot,
      ];
      await snapshotStore.write(old.withPendingCleanups(children));
    });
  }

  Future<void> _releasePrepared(PlaybackResourceLease? lease) async {
    if (lease == null) return;
    _pendingResourceCleanup.add(lease);
    try {
      await lease.release();
      _pendingResourceCleanup.remove(lease);
      await _enqueueSnapshot(() async {
        final snapshot = await snapshotStore.read();
        if (snapshot == null) return;
        final identity = _cleanupSnapshots[lease];
        bool matches(PlaybackSessionSnapshot value) => identity != null
            ? _sameCleanup(value, identity)
            : value.playSessionId == lease.id;
        final pending = snapshot.pendingCleanups
            .where((entry) => !matches(entry))
            .toList();
        if (snapshot.cleanupOnly && matches(snapshot)) {
          if (pending.isEmpty) {
            await snapshotStore.delete();
          } else {
            await snapshotStore.write(
              pending.first.withPendingCleanups(pending.skip(1).toList()),
            );
          }
        } else if (pending.length != snapshot.pendingCleanups.length) {
          await snapshotStore.write(snapshot.withPendingCleanups(pending));
        }
        _cleanupSnapshots.remove(lease);
      });
    } catch (failure) {
      // Cleanup has its own retry record; it does not undo reported progress.
      _lastCleanupFailure = _syncFailure('release', failure);
      if (!_cleanupSnapshots.containsKey(lease)) {
        await _persistFailedPreparation(lease);
      }
    }
  }

  Future<void> _writePreparationSnapshot(
    PlaybackOperation operation,
    PlaybackInfo info, {
    ResolvedPlayback? playback,
    required int startTicks,
  }) async {
    final source = playback?.mediaSource ?? info.primarySource;
    final base = client.baseUrl;
    final user = client.userId;
    if (source == null ||
        base == null ||
        user == null ||
        info.resources == null) {
      return;
    }
    final identity = origin?.source ?? openRequest?.source;
    final snapshot = PlaybackSessionSnapshot(
      cleanupOnly: true,
      serviceType: client.serviceType,
      itemId: itemId,
      mediaSourceId: source.id,
      playSessionId: info.playSessionId,
      playMethod:
          playback?.playMethod ??
          (source.transcodingUrl != null
              ? PlayMethod.transcode
              : PlayMethod.directStream),
      position: durationFromTicks(startTicks),
      baseUrl: base.toString(),
      userId: user,
      timestamp: DateTime.now(),
      source: identity == null
          ? null
          : SourceReference(
              account: identity.account,
              itemId: itemId,
              mediaSourceId: source.id,
            ),
      libraryId: origin?.libraryId ?? openRequest?.libraryId,
      accessGeneration:
          origin?.permit.accessGeneration ?? openRequest?.accessGeneration,
    );
    _cleanupSnapshots[info.resources!] = snapshot;
    await _enqueueSnapshot(() async {
      if (_accepts(operation)) {
        _snapshotOwner = operation.id;
        await _replaceSnapshotPreservingCleanup(snapshot);
      }
    });
  }

  Future<void> retryResourceCleanup() async {
    for (final lease in _pendingResourceCleanup.toList()) {
      await _releasePrepared(lease);
    }
  }

  Future<T> _sourceRequest<T>(Future<T> Function() request) async {
    if (_revoked) throw StateError('Playback permission revoked');
    if (_pendingResourceCleanup.length >=
        PlaybackSessionSnapshot.maxPendingCleanups) {
      throw StateError(
        'Retry pending resource cleanup before preparing more playback',
      );
    }
    final permit = origin?.permit;
    PlaybackResourceLease? acquired;
    Future<T> capture() async {
      final value = await request();
      if (value is PlaybackInfo) acquired = value.resources;
      return value;
    }

    try {
      final result = permit == null
          ? await capture()
          : await permit.dispatch((_) => capture());
      if (_revoked) throw StateError('Playback permission revoked');
      return result;
    } catch (error) {
      if (error is PlaybackPreparationException) acquired = error.resources;
      await _releasePrepared(acquired);
      rethrow;
    }
  }

  Future<void> start() async {
    _startNetworkObservation();
    // Starting a new intent supersedes catalogue paging synchronously, before
    // asynchronous line discovery gets a chance to complete.
    _episodePageGen++;
    episodeListLoading = false;
    episodeLoadingMore = false;
    episodeLoadingEarlier = false;
    try {
      if (await _startHelperRecovery()) return;
      if (await _startAutomaticLines()) return;
    } catch (failure) {
      if (_disposed || _revoked || _operations.isClosed) return;
      loading = false;
      isPlaying = false;
      error = PlayerErrorKind.load;
      state.phase = PlaybackPhase.failed;
      playbackLineFailure = _lineFailureText(failure);
      _emit();
      return;
    }
    if (runtime != null && origin == null) {
      try {
        final resolvedOrigin = await runtime!.resolve(
          openRequest ??
              PlayerOpenRequest(
                itemId: itemId,
                mediaSourceId: preferredMediaSourceId,
              ),
        );
        if (_disposed || _revoked) return;
        resolvedOrigin.permit.requireValid();
        origin = resolvedOrigin;
        client = resolvedOrigin.client;
        final lines = runtime!.registry
            .project()
            .firstWhere(
              (s) => s.id == resolvedOrigin.source.account.configuredServerId,
            )
            .lines;
        for (final line in lines) {
          if (Uri.parse(line.address) == client.baseUrl) {
            activeLineId = line.id;
          }
        }
      } catch (_) {
        loading = false;
        error = PlayerErrorKind.load;
        state.phase = PlaybackPhase.failed;
        disconnectDetail = 'Playback source permission unavailable';
        _emit();
        return;
      }
    }

    final operation = _beginOperation();
    if (operation == null || _disposed) return;
    await _start(operation);
    if (_accepts(operation) && state.phase == PlaybackPhase.failed) {
      await _recoverPlaybackLines(automatic: true);
    }
  }

  Future<void> _start(
    PlaybackOperation operation, {
    bool skipStop = false,
    bool? startPaused,
    void Function(String stage)? onStage,
  }) async {
    if (!skipStop) {
      final stopped = _stopSession();
      await _operations.interrupt(backend.stop);
      await stopped;
    }
    if (!_accepts(operation)) return;
    _pauseIntent =
        startPaused ??
        (openRequest?.itemId == itemId && openRequest?.startPaused == true);
    state.phase = PlaybackPhase.loading;
    state.buffering = false;
    isPlaying = false;
    position = buffer = Duration.zero;
    bufferSnapshot = BufferSnapshot.empty(
      sessionId: operation.id,
      unknownReason: 'preparing',
    );
    cacheSpeedBytesPerSec = 0;
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
    _outroSkipAllowed = false;
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
      onStage?.call('catalog metadata');

      late MediaItem loadedItem;
      MediaUser? loadedUser;
      await Future.wait<void>([
        _restoreSettings(operation),
        () async {
          final startup = _startupData;
          _startupData = null;
          final prepared = await startup;
          if (!_accepts(operation)) return;
          if (prepared != null &&
              prepared.item.id == itemId &&
              (prepared.user == null || prepared.user!.id == client.userId)) {
            loadedItem = prepared.item;
            loadedUser = prepared.user;
            _startupVersions = prepared.versions;
            _startupVersionsAt = prepared.fetchedAt;
            if (loadedUser == null) {
              try {
                loadedUser = await _sourceRequest(client.getUser);
              } on MediaServerException {
                // Optional preferences must not fail otherwise playable media.
              }
            }
            return;
          }
          await Future.wait<void>([
            _sourceRequest(() => client.getItem(itemId))
                .then<void>((value) => loadedItem = value),
            () async {
              try {
                loadedUser = await _sourceRequest(client.getUser);
              } on MediaServerException {
                // Optional preferences must not fail otherwise playable media.
              }
            }(),
          ], eagerError: true);
        }(),
      ], eagerError: true);
      if (!_accepts(operation)) {
        return;
      }

      item = loadedItem;
      if (!item!.isPlayable) {
        error = PlayerErrorKind.notPlayable;
        loading = false;
        state.phase = PlaybackPhase.failed;
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
      user = loadedUser;
      _catalogRuntime = (item!.runtime ?? Duration.zero);
      duration = _catalogRuntime;
      _applyRememberedPreference();
      final memory = _rememberedPreference;
      final memorySubtitleOff =
          (openRequest?.itemId == itemId && openRequest?.subtitleOff == true) ||
          (preferredSubtitleStreamIndex == null &&
              (memory?.subtitleOff ?? false));
      subtitleStreamIndex = memorySubtitleOff
          ? null
          : (preferredSubtitleStreamIndex ?? memory?.subtitleStreamIndex);
      audioStreamIndex =
          preferredAudioStreamIndex ??
          memory?.audioStreamIndex ??
          audioStreamIndex;
      final chapterPosition = startPosition;
      if (chapterPosition != null && chapterPosition > Duration.zero) {
        await _open(
          operation: operation,
          startTicks: ticksFromDuration(chapterPosition),
          startPaused:
              startPaused ??
              (openRequest?.itemId == itemId &&
                  openRequest?.startPaused == true),
          audio: audioStreamIndex,
          subtitle: subtitleStreamIndex,
          subtitleOff: memorySubtitleOff,
          onStage: onStage,
        );
        return;
      }
      final resumeTicks = item!.canResume
          ? ticksFromDuration(item!.resumePosition)
          : 0;
      if (!autoResume) {
        await _open(
          operation: operation,
          startTicks: 0,
          startPaused:
              startPaused ??
              (openRequest?.itemId == itemId &&
                  openRequest?.startPaused == true),
          audio: audioStreamIndex,
          subtitle: subtitleStreamIndex,
          subtitleOff: memorySubtitleOff,
          onStage: onStage,
        );
        return;
      }
      await _open(
        operation: operation,
        startTicks: resumeTicks > 0 ? _rewound(resumeTicks) : 0,
        startPaused:
            startPaused ??
            (openRequest?.itemId == itemId && openRequest?.startPaused == true),
        audio: audioStreamIndex,
        subtitle: subtitleStreamIndex,
        subtitleOff: memorySubtitleOff,
        onStage: onStage,
      );
    } on MediaServerException catch (failure) {
      if (!_accepts(operation)) {
        return;
      }
      error = PlayerErrorKind.load;
      loadFailure = failure;
      loading = false;
      state.phase = PlaybackPhase.failed;
      _emit();
    } catch (failure) {
      if (!_accepts(operation)) return;
      error = PlayerErrorKind.load;
      loading = false;
      state.phase = PlaybackPhase.failed;
      _emit();
    }
  }

  Future<void> togglePlay() async {
    final restoring = _restoring;
    if (loading && restoring != null && !_backgroundReleased) {
      final revision = _lifecycleRevision;
      _playAfterRestore = true;
      await restoring;
      if (_playAfterRestore &&
          revision == _lifecycleRevision &&
          !_disposed &&
          !loading &&
          !_backgroundReleased &&
          error == null) {
        _playAfterRestore = false;
        if (!isPlaying) await togglePlay();
      }
      return;
    }
    if (loading || error != null || _backgroundReleased) {
      return;
    }
    if (playbackEnded) {
      await replay();
      return;
    }
    final operation = _operations.current;
    if (operation != null) {
      // The UI event is the last confirmed playback state. A native command
      // may update the backend optimistically before its state event arrives,
      // so toggling the backend's own flag can issue the opposite command.
      final resume = !isPlaying;
      _pauseIntent = !resume;
      if (resume) {
        _userPausedPrefix = false;
      } else {
        _userPausedPrefix = true;
        unawaited(_discardNextPrefix());
      }
      await _operations.run(operation, resume ? backend.play : backend.pause);
      if (resume) _noteNextOffer();
    }
  }

  bool _backgroundReleased = false;
  bool _playAfterRestore = false;
  Uri? _suspendedServer;
  String? _suspendedUser;
  String? _suspendedToken;
  int _suspendedTicks = 0;
  PlaybackInfo? _lastPlaybackInfo;
  PlaybackInfo? _suspendedPreparation;
  List<PlaybackMediaSource>? _suspendedSources;
  ResolvedPlayback? _suspendedPlayback;
  Duration? _suspendedStreamOrigin;
  int _openingStartTicks = 0;
  bool _openingPositionObserved = false;
  bool _suspendedAtEnd = false;
  Future<void>? _suspending;
  Future<void>? _suspendRetirement;
  Future<void>? _restoring;
  int? _restoringRevision;
  bool _suspendReleasePending = false;
  int _lifecycleRevision = 0;
  bool get backgroundReleased => _backgroundReleased;

  /// Android hosts call this on a real background transition, not rotation.
  /// Pause a ready native session, retaining bounded cache when supported.
  Future<void> suspendPlayback() {
    _lifecycleRevision++;
    return _suspending ??= _suspendPlayback().whenComplete(
      () => _suspending = null,
    );
  }

  Future<void> _suspendPlayback() async {
    if (_disposed || _backgroundReleased) return;
    _playAfterRestore = false;
    _backgroundReleased = true;
    _suspendedServer = client.baseUrl;
    _suspendedUser = client.userId;
    _suspendedToken = client.accessToken;
    _suspendedTicks = loading && !_openingPositionObserved
        ? _openingStartTicks
        : ticksFromDuration(position);
    _suspendedAtEnd = playbackEnded || state.phase == PlaybackPhase.ended;
    final preparation = _lastPlaybackInfo;
    final playback = resolved;
    if (!loading &&
        !_suspendedAtEnd &&
        backend is VideoBackendSuspension &&
        preparation != null &&
        playback != null &&
        identical(preparation.resources, playback.resources) &&
        !(playback.resources?.isReleased ?? false) &&
        !playback.isTranscode &&
        !playback.mediaSource.isInfiniteStream) {
      // Loading clears before optional subtitles and Playing reporting finish.
      // Retain only the completed preparation/playback pair; otherwise stopping
      // releases its lease and restoration must negotiate a fresh stream.
      _suspendedPreparation = preparation;
      _suspendedPlayback = playback;
      _suspendedStreamOrigin = _streamOrigin;
      _suspendedSources = List.of(mediaSources);
    }
    isPlaying = false;
    final stopped = _stopSession(
      retainResources: _suspendedPreparation != null,
    );
    _beginOperation();
    final retirement = _operations.interrupt(
      backend is VideoBackendSuspension
          ? (backend as VideoBackendSuspension).suspend
          : backend.stop,
      ensureRetired: true,
    );
    _suspendRetirement = retirement;
    _suspendReleasePending = false;
    try {
      await retirement.timeout(disposeTimeout);
    } on TimeoutException {
      // The UI deadline does not transfer ownership of a still active handle.
      _suspendReleasePending = true;
    } catch (_) {
      // Keep the failed retirement as the foreground gate. Closing remains
      // possible, while a failed stop must never authorize another open.
      _suspendReleasePending = true;
    } finally {
      await stopped;
      loading = false;
      if (_suspendReleasePending) {
        state.phase = PlaybackPhase.failed;
        disconnectDetail = 'Playback resources are still being released';
      } else {
        state.updatePlaying(false);
      }
      _emit();
    }
  }

  /// Restore the retained session (or reopen interrupted startup), paused.
  /// A changed identity must re-enter through the authentication/player host.
  Future<void> restorePlayback() {
    final existing = _restoring;
    if (existing != null && _restoringRevision == _lifecycleRevision) {
      return existing;
    }
    final revision = _lifecycleRevision;
    final restoration = _restorePlayback(revision);
    _restoring = restoration;
    _restoringRevision = revision;
    unawaited(
      restoration.whenComplete(() {
        if (identical(_restoring, restoration)) {
          _restoring = null;
          _restoringRevision = null;
        }
      }),
    );
    return restoration;
  }

  Future<void> _restorePlayback(int lifecycleRevision) async {
    try {
      await _suspending;
    } catch (_) {
      if (!_disposed && lifecycleRevision == _lifecycleRevision) {
        loading = false;
        state.phase = PlaybackPhase.failed;
        disconnectDetail = 'Playback resources could not be released';
        _emit();
      }
      return;
    }
    if (_disposed || !_backgroundReleased) return;
    if (client.baseUrl != _suspendedServer ||
        client.userId != _suspendedUser ||
        client.accessToken != _suspendedToken) {
      sessionExpired = true;
      await _operations.interrupt(backend.stop, ensureRetired: true);
      await _stopSession();
      _emit();
      return;
    }
    final suspendedOperation = _operations.current;
    final retirement = _suspendRetirement;
    if (retirement != null) {
      try {
        await retirement;
      } catch (_) {
        if (!_disposed && lifecycleRevision == _lifecycleRevision) {
          loading = false;
          state.phase = PlaybackPhase.failed;
          disconnectDetail = 'Playback resources could not be released';
          _emit();
        }
        return;
      }
    }
    if (_disposed ||
        lifecycleRevision != _lifecycleRevision ||
        !_backgroundReleased ||
        !_accepts(suspendedOperation)) {
      return;
    }
    _suspendRetirement = null;
    _suspendReleasePending = false;
    _backgroundReleased = false;
    if (_suspendedAtEnd) {
      // EOF has no next video frame. Reopening at duration would leave native
      // startup waiting forever. Restore the ended UI; only explicit replay
      // creates a new decoder at zero, and returning never starts audio.
      loading = false;
      isPlaying = false;
      playbackEnded = true;
      controlsVisible = true;
      state.phase = PlaybackPhase.ended;
      if (duration > Duration.zero && position > duration) {
        _setPosition(duration);
      }
      _emit();
      return;
    }
    final operation = _beginOperation();
    if (operation == null) return;
    final preparation = _suspendedPreparation;
    final playback = _suspendedPlayback;
    final sources = _suspendedSources;
    final streamOrigin = _suspendedStreamOrigin;
    _suspendedPreparation = null;
    _suspendedPlayback = null;
    _suspendedSources = null;
    _suspendedStreamOrigin = null;
    await _open(
      operation: operation,
      startTicks: _suspendedTicks,
      audio: audioStreamIndex,
      subtitle: subtitleStreamIndex,
      subtitleOff: subtitleStreamIndex == null,
      startPaused: true,
      preparedInfo: preparation,
      preparedPlayback: playback,
      preparedSources: sources,
      preparedStreamOrigin: streamOrigin,
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
    if (_lineRetryAfter?.isAfter(DateTime.now()) == true) return;
    if (playbackLineSelection.isAutomatic && playbackLines.isNotEmpty) {
      await _recoverPlaybackLines();
    } else {
      await _recover();
    }
  }

  Future<void> _recover({
    String? sourceId,
    PlaybackSwitchPlan? switchPlan,
    int? switchStartTicks,
    int? switchAudio,
    int? switchSubtitle,
    bool? paused,
  }) {
    if (_disposed ||
        _operations.isClosed ||
        sessionExpired ||
        _backgroundReleased) {
      return Future<void>.value();
    }
    final existing = _recoveryOperation == null ? null : _recovery;
    final replacing = existing != null && pendingMediaSourceId != sourceId;
    if (existing != null && !replacing) return existing;
    if (_nativeRetirement != null && !replacing) {
      loading = false;
      state.phase = PlaybackPhase.failed;
      disconnectDetail = 'Playback resources are still being released';
      _emit();
      return Future<void>.value();
    }
    final base = replacing
        ? _recoveryBase!
        : (
            previous: resolved,
            oldSourceId: activeMediaSourceId,
            startTicks: switchStartTicks ?? ticksFromDuration(position),
            audio: switchPlan == null ? audioStreamIndex : switchAudio,
            subtitle: switchPlan == null ? subtitleStreamIndex : switchSubtitle,
            paused:
                paused ?? switchPlan?.paused ?? (!isPlaying && !disconnected),
          );
    final priorRetirement = replacing ? _nativeRetirement : null;
    if (replacing) {
      // A newer user intent owns the result. The old request may finish its
      // native cleanup, but none of its metadata or events can commit.
      _operations.invalidate();
      resolved = base.previous;
    }
    final operation = _beginOperation();
    if (operation == null) return Future<void>.value();
    _recoveryOperation = operation;
    _recoveryBase = base;
    isRecovering = true;
    pendingMediaSourceId = sourceId;
    loading = true;
    error = null;
    loadFailure = null;
    disconnected = false;
    disconnectDetail = null;
    state.phase = PlaybackPhase.loading;
    state.buffering = false;
    isPlaying = false;
    controlsVisible = true;
    _emit();
    final work = _runRecovery(
      operation: operation,
      previous: base.previous,
      oldSourceId: base.oldSourceId,
      sourceId: sourceId,
      startTicks: base.startTicks,
      audio: base.audio,
      subtitle: base.subtitle,
      paused: base.paused,
      originalStartTicks: switchPlan?.positionTicks ?? base.startTicks,
      originalAudio: audioStreamIndex,
      originalSubtitle: subtitleStreamIndex,
      priorRetirement: priorRetirement,
    );
    _recovery = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_recovery, work)) _recovery = null;
      }),
    );
    return work;
  }

  Future<void> _runRecovery({
    required PlaybackOperation operation,
    required ResolvedPlayback? previous,
    required String? oldSourceId,
    required String? sourceId,
    required int startTicks,
    required int? audio,
    required int? subtitle,
    required bool paused,
    required int originalStartTicks,
    required int? originalAudio,
    required int? originalSubtitle,
    Future<void>? priorRetirement,
  }) async {
    final clock = Stopwatch()..start();
    Duration remaining() => recoveryTimeout - clock.elapsed;
    Duration stoppingRemaining() {
      final control = recoveryTimeout - clock.elapsed;
      return remaining() < control ? remaining() : control;
    }

    String stage = 'stop';
    try {
      if (priorRetirement != null) {
        stage = 'retire previous operation';
        await priorRetirement.timeout(stoppingRemaining());
        if (!_accepts(operation)) return;
      }
      stage = 'stop';
      final stopped = _stopSession();
      final retirement = _operations.interrupt(
        backend.stop,
        ensureRetired: true,
      );
      _trackNativeRetirement(retirement);
      await Future.wait([retirement, stopped]).timeout(stoppingRemaining());
      if (!_accepts(operation)) return;
      if (previous == null) {
        stage = 'catalog metadata';
        await _start(
          operation,
          skipStop: true,
          onStage: (value) => stage = value,
        ).timeout(remaining());
      } else {
        stage = 'open';
        await _open(
          operation: operation,
          startTicks: startTicks,
          audio: audio,
          subtitle: subtitle,
          subtitleOff: subtitle == null,
          startPaused: paused,
          requestedSourceId: sourceId,
          strictTracks: sourceId != null,
          onStage: (value) => stage = value,
        ).timeout(remaining());
      }
      if (!_accepts(operation)) return;
      if (state.phase != PlaybackPhase.failed &&
          error == null &&
          !loading &&
          !disconnected) {
        // Track indices belong to a media source. Successfully selecting a
        // compatible track after switching versions is not a loading failure.
        return;
      }
      if (sourceId != null &&
          oldSourceId != null &&
          !sessionExpired &&
          remaining() > Duration.zero) {
        final sourceFailure = disconnectDetail ?? loadFailure?.toString();
        stage = 'restore previous source';
        // The failed target must not consume the fallback's header/first-frame
        // budget. Restoration is a separate bounded attempt, still owned by
        // this operation so cancellation and a newer switch take precedence.
        // Compensation shares the original deadline.

        resolved = previous;
        await _open(
          operation: operation,
          startTicks: originalStartTicks,
          audio: originalAudio,
          subtitle: originalSubtitle,
          subtitleOff: originalSubtitle == null,
          startPaused: paused,
          requestedSourceId: oldSourceId,
          strictTracks: true,
          onStage: (value) => stage = value,
        ).timeout(remaining());
        if (!_accepts(operation)) return;
        if (state.phase != PlaybackPhase.failed && !loading && !disconnected) {
          trackFailure = sourceFailure == null
              ? 'Source change failed; previous source restored'
              : 'Source change failed; previous source restored: $sourceFailure';
          _emit();
          return;
        }
      }
      resolved = previous;
    } on TimeoutException {
      if (!_accepts(operation)) return;

      // Keep the command barrier and native handle owned until open/stop exits.
      _operations.invalidate();
      if (stage != 'stop' &&
          stage != 'retire previous operation' &&
          _nativeRetirement == null) {
        _trackNativeRetirement(
          _operations.interrupt(backend.stop, ensureRetired: true),
        );
      }
      loading = false;
      isPlaying = false;
      state.phase = PlaybackPhase.failed;
      state.buffering = false;
      error = PlayerErrorKind.load;
      disconnectDetail = 'Playback recovery timed out during $stage';
      resolved = previous;
      _emit();
    } catch (failure) {
      if (!_accepts(operation)) return;
      loading = false;
      isPlaying = false;
      state.phase = PlaybackPhase.failed;
      state.buffering = false;
      error = PlayerErrorKind.load;
      disconnectDetail = 'Playback recovery failed during $stage: $failure';
      resolved = previous;
      _emit();
    } finally {
      if (identical(_recoveryOperation, operation)) {
        _recoveryOperation = null;
        _recoveryBase = null;
        isRecovering = false;
        if (!_scopedPlayback || state.phase == PlaybackPhase.failed) {
          pendingMediaSourceId = null;
        }
        _emit();
      }
    }
  }

  void _trackNativeRetirement(Future<void> retirement) {
    _nativeRetirement = retirement;
    unawaited(
      retirement.then<void>(
        (_) {
          if (identical(_nativeRetirement, retirement)) {
            _nativeRetirement = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_nativeRetirement, retirement)) {
            _nativeRetirement = null;
          }
        },
      ),
    );
  }

  PlayerHostOpenItemCommand? get endedSeriesCommand {
    final id = item?.seriesId;
    if (id == null || id.isEmpty || permissionRevoked) return null;
    final actual = origin;
    if (actual != null) {
      if (!actual.permit.isValid) return null;
      return PlayerHostOpenItemCommand(
        itemId: id,
        seasonId: item?.seasonId,
        source: SourceReference(account: actual.source.account, itemId: id),
        libraryId: actual.libraryId,
        accessGeneration: actual.permit.accessGeneration,
      );
    }
    final request = openRequest;
    if (request?.source == null) return null;
    return PlayerHostOpenItemCommand(
      itemId: id,
      seasonId: item?.seasonId,
      source: SourceReference(account: request!.source!.account, itemId: id),
      libraryId: request.libraryId,
      accessGeneration: request.accessGeneration,
    );
  }

  void openEndedSeries() {
    final seriesId = item?.seriesId;
    if (seriesId != null && seriesId.isNotEmpty) {
      // 剧集不是片源:只请主窗口打开详情,绝不走 onOpenItem(_applyLaunch)。
      final openDetail = onOpenItemDetail;
      if (openDetail != null) {
        final command = endedSeriesCommand;
        if ((origin != null || openRequest?.source != null) &&
            command == null) {
          return;
        }
        openDetail(seriesId, seasonId: item?.seasonId, command: command);
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
    if (disconnected && !sessionExpired) {
      await _reopen(startTicks: ticksFromDuration(target));
      return;
    }
    if (playbackEnded) {
      playbackEnded = false;
      await _reopen(startTicks: ticksFromDuration(target));
      return;
    }
    final film = resolved!.filmTimeline;
    final destination = film?.locate(target);
    if (film != null && destination == null) {
      trackFailure =
          'Part duration is unknown; cannot locate requested position';
      _emit();
      return;
    }
    if (resolved!.startsAtRequestedPosition ||
        (destination != null && destination.index != resolved!.partIndex)) {
      await _reopen(startTicks: ticksFromDuration(target));
      return;
    }
    final operation = _operations.current;
    if (operation == null) return;
    final revision = ++_seekRevision;
    _prefixYield = true;
    _seekInFlight = true;
    var failed = false;
    try {
      // Keep the actual command in the coordinator after the UI deadline.
      // Recovery must retire that command before another native open starts.
      await _operations
          .run(operation, () => backend.seek(target - _streamOrigin))
          .timeout(seekTimeout);
    } catch (_) {
      failed = true;
    } finally {
      if (revision == _seekRevision) {
        _seekInFlight = false;
        _prefixYield = false;
      }
    }
    if (!_accepts(operation) || revision != _seekRevision) return;
    if (failed) {
      // A rejected/expired seek can leave the core in RECOVERING forever.
      // Try one bounded reopen at the requested point. Transient playing=false
      // during the seek must not turn this recovery into a user pause.
      await _recover(
        switchStartTicks: ticksFromDuration(target),
        paused: _pauseIntent,
      );
      return;
    }
    _setPosition(target);
    _emit();
    await _reportProgress(eventName: 'Seek');
  }

  PhoneSubtitleSettings phoneSubtitleSettings = const PhoneSubtitleSettings();
  String? subtitlePresentationError;
  SubtitlePresentation? _subtitleViewport;
  Future<void>? _subtitlePresentationTail;
  int _subtitleSettingsRevision = 0;

  /// No independent text track means there is no effective font-size control.
  bool get canAdjustSubtitleSize {
    if (_suspendedAtEnd) return false;
    final index = subtitleStreamIndex;
    if (index == null) return false;
    final stream = resolved?.mediaSource.streamByIndex(index);
    if (stream == null || !stream.isTextSubtitle) return false;
    return !(resolved?.isTranscode == true &&
        _transcodeSubtitleDelivery(stream) == TranscodeSubtitleDelivery.burnIn);
  }

  /// Uses the actual video display rectangle on every platform.
  /// PiP callers pass its actual rectangle; its short height caps font size.
  Future<void> updateSubtitleViewport({
    required double width,
    required double height,
    double textScale = 1,
    bool landscape = false,
    double safeHorizontal = 12,
    double safeVertical = 8,
  }) async {
    if (!width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0 ||
        !textScale.isFinite ||
        textScale <= 0) {
      return;
    }
    final viewport = SubtitlePresentation(
      displayWidth: width,
      displayHeight: height,
      // Scale with the displayed picture, not its encoded resolution or DPI.
      // Keep phone/PiP readability while allowing desktop and TV to grow.
      fontSize: math.max(landscape ? 24.0 : 20.0, height * 0.045) * textScale,
      safeHorizontal: safeHorizontal.clamp(0, width * 0.49),
      safeVertical: safeVertical.clamp(0, height * 0.49),
    );
    final previous = _subtitleViewport;
    if (previous != null &&
        previous.displayWidth == viewport.displayWidth &&
        previous.displayHeight == viewport.displayHeight &&
        previous.fontSize == viewport.fontSize &&
        previous.safeHorizontal == viewport.safeHorizontal &&
        previous.safeVertical == viewport.safeVertical) {
      return;
    }
    _subtitleViewport = viewport;
    await _queueSubtitlePresentation(phoneSubtitleSettings, save: false);
  }

  Future<void> setPhoneSubtitleSettings(PhoneSubtitleSettings settings) =>
      _queueSubtitlePresentation(settings, save: true);

  Future<void> resetPhoneSubtitleSettings() =>
      setPhoneSubtitleSettings(const PhoneSubtitleSettings());

  Future<void> _queueSubtitlePresentation(
    PhoneSubtitleSettings settings, {
    required bool save,
  }) {
    final operation = _operations.current;
    final viewport = _subtitleViewport;
    if (!save && viewport == null) return Future<void>.value();
    final revision = save
        ? ++_subtitleSettingsRevision
        : _subtitleSettingsRevision;
    final work = (_subtitlePresentationTail ?? Future<void>.value()).then((
      _,
    ) async {
      if (operation != null && !_accepts(operation)) return;
      final effective = save ? settings : phoneSubtitleSettings;
      var applied = false;
      try {
        if (_canSendPlaybackParameters &&
            viewport != null &&
            backend is VideoBackendSubtitlePresentation &&
            operation != null) {
          await (backend as VideoBackendSubtitlePresentation)
              .setSubtitlePresentation(
                SubtitlePresentation(
                  displayWidth: viewport.displayWidth,
                  displayHeight: viewport.displayHeight,
                  fontSize: viewport.fontSize,
                  userScale: effective.size.scale,
                  originalAss: effective.originalAss,
                  safeHorizontal: viewport.safeHorizontal,
                  safeVertical: viewport.safeVertical,
                ),
                sessionId: operation.id,
              );
        }
        if (operation != null && !_accepts(operation)) return;
        if (save) {
          phoneSubtitleSettings = settings;
          applied = true;
          await (await _settings()).writePatch(
            PlayerSettings(phoneSubtitles: settings),
          );
        }
        if (revision == _subtitleSettingsRevision) {
          subtitlePresentationError = null;
        }
      } catch (_) {
        if (operation == null || _accepts(operation)) {
          subtitlePresentationError = applied
              ? '字幕显示设置已应用，但未能保存，请重试'
              : '字幕显示设置未生效，请重试';
        }
      }
      _emit();
    });
    _subtitlePresentationTail = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  static const volumeWheelStep = 5;

  bool get _canSendPlaybackParameters =>
      !loading &&
      !_suspendedAtEnd &&
      switch (state.phase) {
        PlaybackPhase.playing ||
        PlaybackPhase.paused ||
        PlaybackPhase.buffering ||
        PlaybackPhase.ended => true,
        _ => false,
      };

  Future<void> setVolume(int value) async {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    volume = value.clamp(0, PlayerSettings.volumeMax);
    _volumeRevision++;
    if (volume > 0) {
      _unmutedVolume = volume;
    }
    final selected = volume;
    if (!_canSendPlaybackParameters) {
      onUserActivity();
      _scheduleSettingsSave();
      return;
    }
    await _operations.run(operation!, () async {
      if (_canSendPlaybackParameters) {
        await backend.setVolume(mpvVolumeForPercent(selected));
      }
    });
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
    _rateRevision++;
    if (playbackRate == value) {
      onUserActivity();
      if (!_canSendPlaybackParameters) _scheduleSettingsSave();
      return;
    }
    playbackRate = value;
    if (!_canSendPlaybackParameters) {
      onUserActivity();
      _scheduleSettingsSave();
      return;
    }
    await _operations.run(operation!, () async {
      if (_canSendPlaybackParameters) await backend.setRate(value);
    });
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
      (_) => _selectDeviceTrack(
        audio: true,
        index: index,
        select: () => backend.setAudioIndex(index),
      ),
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
    if (index != null && secondarySubtitleStreamIndex == index) {
      _refuseSubtitleSlot('occupied');
      return;
    }
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
      // 用户把主槽切回服务器轨时先放弃会话文件占用,避免 `_open` 后的
      // 槽位恢复把刚做的烧录重开选择又覆盖回文件。
      if (index != null) primarySubtitleFileId = null;
      await _reopen(
        startTicks: ticksFromDuration(position),
        subtitle: index,
        subtitleOff: index == null,
      );
      return;
    }
    final previous = subtitleStreamIndex;
    final previousFile = primarySubtitleFileId;
    await _selectTrack(
      (current) => _activatePlaybackSubtitle(next, index, current: current),
      () {
        subtitleStreamIndex = index;
        primarySubtitleFileId = null;
        _clearSubtitleNotice();
      },
      'SubtitleTrackChange',
      serialized: false,
      onFailure: () {
        subtitleStreamIndex = previous;
        primarySubtitleFileId = previousFile;
        _emit();
      },
    );
  }

  /// 主字幕槽选择会话导入文件;null 表示关闭主字幕。
  Future<void> setSubtitleFromFile(String? fileId) async {
    if (loading || _operations.isClosed) return;
    if (fileId == null) {
      await setSubtitle(null);
      return;
    }
    if (resolved == null) return;
    final file = _subtitleImports.byId(fileId);
    if (file == null) return;
    if (fileId == secondarySubtitleFileId) {
      _refuseSubtitleSlot('occupied');
      return;
    }
    final previous = subtitleStreamIndex;
    final previousFile = primarySubtitleFileId;
    await _selectTrack(
      (current) =>
          _applySubtitleSource(slot: 0, fileId: fileId, current: current),
      () {
        primarySubtitleFileId = fileId;
        subtitleStreamIndex = null;
        _clearSubtitleNotice();
      },
      'SubtitleTrackChange',
      serialized: false,
      onFailure: () {
        subtitleStreamIndex = previous;
        primarySubtitleFileId = previousFile;
        _emit();
      },
    );
  }

  /// 次字幕槽选择服务器流;null 表示关闭次字幕。次字幕与主字幕相互独立,
  /// 失败回滚不影响主字幕与播放位置。
  Future<void> setSecondarySubtitle(int? index) async {
    if (loading || _operations.isClosed) return;
    final source = resolved?.mediaSource;
    if (source == null && index != null) return;
    if (index == null && !hasSecondarySubtitle) return;
    if (index != null) {
      final stream = source!.streamByIndex(index);
      if (stream == null || !stream.isSubtitle) return;
      if (subtitleStreamOccupiesOtherSlot(1, index)) {
        _refuseSubtitleSlot('occupied');
        return;
      }
      if (streamIsBurnedIn(index)) {
        _refuseSubtitleSlot('burn-in');
        return;
      }
    }
    final previousIndex = secondarySubtitleStreamIndex;
    final previousFile = secondarySubtitleFileId;
    await _selectTrack(
      (current) =>
          _applySubtitleSource(slot: 1, streamIndex: index, current: current),
      () {
        secondarySubtitleStreamIndex = index;
        secondarySubtitleFileId = null;
        _clearSubtitleNotice();
      },
      'SecondarySubtitleTrackChange',
      serialized: false,
      onFailure: () {
        secondarySubtitleStreamIndex = previousIndex;
        secondarySubtitleFileId = previousFile;
        _emit();
      },
    );
  }

  /// 次字幕槽选择会话导入文件;null 表示关闭次字幕。
  Future<void> setSecondarySubtitleFromFile(String? fileId) async {
    if (loading || _operations.isClosed) return;
    if (fileId == null) {
      await setSecondarySubtitle(null);
      return;
    }
    if (resolved == null) return;
    final file = _subtitleImports.byId(fileId);
    if (file == null) return;
    if (subtitleFileOccupiesOtherSlot(1, fileId)) {
      _refuseSubtitleSlot('occupied');
      return;
    }
    final previousIndex = secondarySubtitleStreamIndex;
    final previousFile = secondarySubtitleFileId;
    await _selectTrack(
      (current) =>
          _applySubtitleSource(slot: 1, fileId: fileId, current: current),
      () {
        secondarySubtitleFileId = fileId;
        secondarySubtitleStreamIndex = null;
        _clearSubtitleNotice();
      },
      'SecondarySubtitleTrackChange',
      serialized: false,
      onFailure: () {
        secondarySubtitleStreamIndex = previousIndex;
        secondarySubtitleFileId = previousFile;
        _emit();
      },
    );
  }

  void _refuseSubtitleSlot(String token) {
    subtitleSelectionNotice = token;
    trackFailure = null;
    onUserActivity();
    _emit();
  }

  void clearSubtitleSelectionNotice() {
    subtitleSelectionNotice = null;
    _emit();
  }

  void clearSubtitleImportNotice() {
    subtitleImportNotice = null;
    _emit();
  }

  /// 弹出系统文件选择并导入会话内字幕。取消不提示;其余结果记录在
  /// [subtitleImportNotice] 供 UI 展示。导入只增加候选,不改变当前选择。
  Future<SubtitleImportOutcome> importSubtitleFile({
    AppFilePicker? picker,
  }) async {
    final selection =
        picker ?? subtitleFilePicker ?? const DefaultAppFilePicker();
    PickedAppFile? picked;
    try {
      picked = await selection.pickFile(
        dialogTitle: 'Subtitles',
        allowedExtensions: kSubtitleImportExtensions.toList(),
      );
    } on AppFilePickerUnavailableException {
      return _noteSubtitleImport(SubtitleImportOutcome.pickerUnavailable);
    }
    if (picked == null) return SubtitleImportOutcome.cancelled;
    final Uint8List bytes;
    try {
      bytes = await picked.readBytes(kMaxSubtitleFileBytes);
    } on AppFileTooLargeException {
      return _noteSubtitleImport(SubtitleImportOutcome.tooLarge);
    } on AppFileReadException {
      return _noteSubtitleImport(SubtitleImportOutcome.unreadable);
    }
    return importSubtitleBytes(fileName: picked.fileName, bytes: bytes);
  }

  /// 校验并把字节复制进会话受控目录。测试与原生窗口检查直接复用。
  Future<SubtitleImportOutcome> importSubtitleBytes({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final result = await _subtitleImports.add(
      fileName: fileName,
      bytes: bytes,
      createDirectory: _ensureSubtitleCache,
    );
    if (result.outcome != SubtitleImportOutcome.added &&
        result.outcome != SubtitleImportOutcome.cancelled) {
      subtitleImportNotice = result.outcome;
    } else {
      subtitleImportNotice = null;
    }
    _emit();
    return result.outcome;
  }

  SubtitleImportOutcome _noteSubtitleImport(SubtitleImportOutcome outcome) {
    subtitleImportNotice = outcome;
    _emit();
    return outcome;
  }

  /// 统一的槽位应用:off/服务器流/会话文件 → backend 槽位语义。
  Future<void> _applySubtitleSource({
    required int slot,
    required bool Function() current,
    int? streamIndex,
    String? fileId,
  }) async {
    if (!current()) return;
    if (streamIndex == null && fileId == null) {
      await backend.setSubtitleOff(slot: slot);
      return;
    }
    if (fileId != null) {
      final file = _subtitleImports.byId(fileId);
      if (file == null) throw StateError('Imported subtitle is unavailable');
      final applied = await backend.setSubtitleUri(
        file.file.uri,
        title: file.label,
        slot: slot,
      );
      if (!current()) return;
      if (!applied) throw StateError('Imported subtitle was not selected');
      _activeSubtitleFiles[slot] = file.file;
      return;
    }
    final index = streamIndex!;
    final next = resolved!;
    final stream = next.mediaSource.streamByIndex(index);
    if (stream == null || !stream.isSubtitle) {
      throw StateError('Subtitle track is unavailable');
    }
    if (slot == 1 && next.isTranscode) {
      final delivery = _transcodeSubtitleDelivery(stream);
      if (delivery != TranscodeSubtitleDelivery.burnIn) {
        await _activateSubtitle(
          next.mediaSource,
          index,
          forceExternal: delivery == TranscodeSubtitleDelivery.external,
          current: current,
          slot: slot,
        );
        return;
      }
      throw StateError('Burned-in subtitles cannot fill the secondary slot');
    }
    await _activateSubtitle(
      next.mediaSource,
      index,
      current: current,
      slot: slot,
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
      onUserActivity();
    }
  }

  void dismissTrackFailure() {
    trackFailure = null;
    _emit();
  }

  void dismissPlaybackLineFailure() {
    playbackLineFailure = null;
    _emit();
  }

  Future<void> setMaxBitrate(int bitrate) async {
    if (_operations.isClosed || loading || bitrate == maxStreamingBitrate) {
      return;
    }
    if (!availableBitrates.contains(bitrate)) {
      trackFailure = 'The server cannot provide this quality';
      _emit();
      return;
    }
    final previous = maxStreamingBitrate;
    final startTicks = ticksFromDuration(position);
    final paused = !isPlaying;
    final opened = await _reopen(
      startTicks: startTicks,
      requestedBitrate: bitrate,
      startPaused: paused,
    );
    if (opened && _qualityConfirmed(bitrate)) {
      maxStreamingBitrate = bitrate;
      trackFailure = null;
      _emit();
      await _persistSeriesPreference();
      return;
    }
    if (!_operations.isClosed && !_disposed) {
      await _reopen(
        startTicks: startTicks,
        requestedBitrate: previous,
        startPaused: paused,
      );
      trackFailure = 'The server did not confirm this quality';
      _emit();
    }
  }

  bool _qualityConfirmed(int requestedBitrate) {
    if (requestedBitrate == kCoreMaxStreamingBitrate) return true;
    final playback = resolved;
    if (playback == null) return false;
    final confirmed = playback.outputBitrate;
    return confirmed != null && confirmed > 0 && confirmed <= requestedBitrate;
  }

  List<int> get availableBitrates {
    final source = resolved?.mediaSource;
    if (source == null || !source.supportsTranscoding) {
      return const [kCoreMaxStreamingBitrate];
    }
    final sourceBitrate = source.bitrate;
    return [
      kCoreMaxStreamingBitrate,
      for (final value in kTranscodeBitrates.skip(1))
        if (sourceBitrate == null || value < sourceBitrate) value,
    ];
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
  void setControlsPinned(bool pinned, {Object? owner}) {
    if (_disposed) return;
    final token = owner ?? _defaultControlsPin;
    if (pinned) {
      _controlsPinOwners.add(token);
    } else {
      _controlsPinOwners.remove(token);
    }
    pinned = controlsPinned;
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
    _nextAutoplayCancelled = true;
    _clearNextEpisodeOffer();
  }

  void _clearNextEpisodeOffer() {
    _nextTimer?.cancel();
    _nextTimer = null;
    nextEpisode = null;
    unawaited(_discardNextPrefix());
    onUserActivity();
  }

  Future<void> playNextEpisode() async {
    final next = nextEpisode?.item;
    final finishCurrent = _shouldFinishCurrentEpisode();
    _nextTimer?.cancel();
    _nextTimer = null;
    nextEpisode = null;
    if (next == null) {
      return;
    }
    // The button is an explicit play request. Carrying a pause from the
    // finished episode leaves the next item on a still frame.
    await _playItem(
      next.id,
      fromStart: true,
      finishCurrent: finishCurrent,
      startPaused: false,
    );
  }

  /// 切到任意集(剧集列表入口):源 id 每集不同,保留显示名以便对齐同名版本;
  /// 续播语义由 start() 按新集的进度决定。
  /// 已经到片尾再切走时,把当前集标成已看。
  Future<void> playEpisode(MediaItem episode) async {
    if (episode.id == itemId) {
      return;
    }
    await _playItem(
      episode.id,
      fromStart: false,
      finishCurrent: _shouldFinishCurrentEpisode(),
    );
  }

  /// 进程内切到另一集(ADR-4):不经 host 重启通道,直接以新 itemId
  /// 重走 start(),autoResume 由 [fromStart] 决定——剧集列表切集
  /// (fromStart=false)时部分观看的集从续播位置起播。
  /// 首次起播请求携带的源/轨道/章节起点只对首个条目有效,换集后清除 id;
  /// 片源发行组标签保留,供下一集按组名对齐。
  Future<void> _playItem(
    String targetId, {
    required bool fromStart,
    bool finishCurrent = false,
    bool? startPaused,
  }) async {
    final actual = origin;
    // Native open and rate/seek recovery may finish before playing arrives,
    // even after buffering clears. That observation is not a user pause.
    final paused =
        startPaused ?? (!playbackEnded && !_handlingCompleted && _pauseIntent);
    if (runtime == null && switchDispatcher != null) {
      await switchDispatcher!({'action': 'authorizeItem', 'item': targetId});
      if (_disposed || _revoked) return;
    }
    PlaybackOrigin? nextOrigin;
    if (runtime != null && actual != null) {
      // Resolve the concrete next item again: version ids and library membership
      // do not carry over from the previous episode.
      nextOrigin = await runtime!.resolveItem(actual, targetId);
      if (_disposed || _revoked || !identical(origin, actual)) return;
      if (nextOrigin.client.baseUrl != actual.client.baseUrl) {
        final lines = runtime!.registry
            .project()
            .firstWhere((s) => s.id == actual.source.account.configuredServerId)
            .lines;
        final line = lines.singleWhere(
          (l) => Uri.parse(l.address) == actual.client.baseUrl,
        );
        nextOrigin = await runtime!.resolveLine(nextOrigin, line.id, null);
        if (_disposed || _revoked || !identical(origin, actual)) return;
      }
    }
    final handoff = _nextPrefix?.itemId == targetId;
    final operation = _beginOperation(keepNextPrefix: handoff);
    if (operation == null || _disposed) return;
    final finishedId = itemId;
    final stopped = _stopSession(
      positionTicks: finishCurrent ? _completedTicks() : null,
      played: finishCurrent,
    );
    if (finishCurrent) {
      _showEpisodePlayed(finishedId);
    }
    if (targetId != itemId) _resetSessionSubtitles();
    itemId = targetId;
    item = null;
    resolved = null;
    _streamOrigin = Duration.zero;
    _knownBufferHeldAt = null;
    position = duration = buffer = Duration.zero;
    bufferSnapshot = BufferSnapshot.empty(
      sessionId: operation.id,
      unknownReason: 'preparing',
    );
    _pauseIntent = paused;
    isPlaying = false;
    loading = true;
    state.phase = PlaybackPhase.loading;
    state.buffering = false;
    _emit();
    await _operations.interrupt(backend.stop);
    await stopped;
    if (finishCurrent) {
      try {
        await _sourceRequest(() => client.markPlayed(finishedId));
      } catch (_) {
        // 片尾位置的 Stopped 仍会让服务端按进度标已看。
      }
    }
    if (!_accepts(operation)) return;
    if (nextOrigin != null) {
      nextOrigin.permit.requireValid();
      origin = nextOrigin;
      client = nextOrigin.client;
    }
    activeOrigin = null;
    activeMediaSourceId = null;
    preferredMediaSourceId = null;
    preferredAudioStreamIndex = null;
    preferredSubtitleStreamIndex = null;
    startPosition = null;
    preferredSecondarySubtitleStreamIndex = null;
    autoResume = !fromStart;
    // Freeze credentials after retiring the old owner and installing the
    // verified concrete next-item line client.
    final nextOperation = _beginOperation(keepNextPrefix: handoff);
    if (nextOperation == null) return;
    await _start(nextOperation, skipStop: true, startPaused: paused);
    if (handoff) await _discardNextPrefix();
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
      final loaded = await _sourceRequest(
        () => client.getItems(
          parentId: seriesId,
          includeItemTypes: 'Season',
          recursive: true,
          sortBy: 'IndexNumber',
          sortOrder: 'Ascending',
          fields: MediaServerClient.gridFields,
        ),
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
    } on MediaServerException {
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
    } on MediaServerException {
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
    } on MediaServerException {
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
    } on MediaServerException {
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
    } on MediaServerException {
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

  Future<MediaItemPage> _querySeasonEpisodes(
    String seasonId,
    int startIndex, {
    int limit = kPlayerEpisodePageSize,
  }) {
    return _sourceRequest(
      () => client.queryItems(
        parentId: seasonId,
        includeItemTypes: 'Episode',
        recursive: true,
        sortBy: 'IndexNumber',
        sortOrder: 'Ascending',
        startIndex: startIndex,
        limit: limit,
        fields: MediaServerClient.gridFields,
      ),
    );
  }

  void _resetEpisodeWindow() {
    episodeTotal = 0;
    episodeWindowStart = 0;
    episodeWindowEnd = 0;
    episodeLoadingMore = false;
    episodeLoadingEarlier = false;
  }

  List<MediaItem> _dedupeEpisodes(Iterable<MediaItem> items) {
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
      final start = chapter.startPosition;
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
          ? chapters[i + 1].startPosition
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
        final end = firstAfter(start, introEnds);
        if (end != null && end > start) {
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
      if (segment.kind == PlayerSkipKind.intro && !skipIntroEnabled ||
          segment.kind == PlayerSkipKind.outro && !skipOutroEnabled) {
        continue;
      }
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
    if (next.kind == PlayerSkipKind.outro &&
        item?.isEpisode == true &&
        !_outroSkipAllowed) {
      skipPromptVisible = false;
      return;
    }
    final revealOutro =
        next.kind == PlayerSkipKind.outro &&
        _outroSkipAllowed &&
        !skipPromptVisible;
    if (changed || revealOutro) {
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
    skipPromptVisible = activeSkipSegment != null;
  }

  void _setPosition(Duration value) {
    position = value;
    _updateActiveSkip();
    _maybeOfferNextUp();
  }

  Duration _displayedPosition(Duration reported) {
    if (_streamOrigin <= Duration.zero) return reported;
    final shifted = _streamOrigin + reported;
    final limit = duration > _catalogRuntime ? duration : _catalogRuntime;
    if (limit > Duration.zero && shifted > limit) return limit;
    return shifted;
  }

  bool _shorterTranscodeWindow(Duration probed) {
    return isTranscode &&
        _catalogRuntime > Duration.zero &&
        probed + const Duration(seconds: 1) < _catalogRuntime;
  }

  BufferSnapshot _stabilizeBufferSnapshot(BufferSnapshot next) {
    final local = next;
    next = _streamOrigin <= Duration.zero
        ? local
        : BufferSnapshot(
            sessionId: local.sessionId,
            resourceId: local.resourceId,
            representationVersion: local.representationVersion,
            trackVersion: local.trackVersion,
            sequence: local.sequence,
            unknownReason: local.unknownReason,
            ranges: local.ranges.map(
              (r) =>
                  BufferedRange(r.start + _streamOrigin, r.end + _streamOrigin),
            ),
            byteCoverage: resolved?.filmTimeline == null
                ? local.byteCoverage
                : null,
            duration: duration > Duration.zero ? duration : null,
          );
    final previous = bufferSnapshot;
    final same =
        previous.sessionId == next.sessionId &&
        previous.resourceId.isNotEmpty &&
        previous.resourceId == next.resourceId &&
        previous.representationVersion == next.representationVersion &&
        previous.trackVersion == next.trackVersion;
    final transient = _transientBufferGap(next.unknownReason);
    if (transient && same && previous.isKnown && previous.ranges.isNotEmpty) {
      _knownBufferHeldAt ??= DateTime.now();
      if (DateTime.now().difference(_knownBufferHeldAt!) <
          const Duration(seconds: 2)) {
        return BufferSnapshot(
          sessionId: next.sessionId,
          resourceId: next.resourceId,
          representationVersion: next.representationVersion,
          trackVersion: next.trackVersion,
          sequence: next.sequence,
          ranges: previous.ranges,
        );
      }
    }
    _knownBufferHeldAt = next.isKnown && next.ranges.isNotEmpty
        ? null
        : _knownBufferHeldAt;
    if (!transient || !same) {
      _knownBufferHeldAt = null;
    }
    return next;
  }

  bool _sameBufferPresentation(BufferSnapshot a, BufferSnapshot b) {
    if (a.isKnown != b.isKnown || a.ranges.length != b.ranges.length) {
      return false;
    }
    for (var i = 0; i < a.ranges.length; i++) {
      if (a.ranges[i] != b.ranges[i]) return false;
    }
    if (a.usesByteEstimate != b.usesByteEstimate) return false;
    if (a.usesByteEstimate) {
      final left = a.byteCoverage!;
      final right = b.byteCoverage!;
      if (left.totalBytes != right.totalBytes ||
          left.ranges.length != right.ranges.length) {
        return false;
      }
      for (var i = 0; i < left.ranges.length; i++) {
        if (left.ranges[i] != right.ranges[i]) return false;
      }
    }
    return true;
  }

  bool _transientBufferGap(String? reason) {
    return reason == 'indexUnavailable' ||
        reason == 'mediaMappingUnavailable' ||
        reason == 'hlsTimingUnavailable' ||
        reason == 'hlsManifestTooLarge';
  }

  Future<ResolvedPlayback?> _expandStrm(
    PlaybackOperation operation,
    ResolvedPlayback playback,
  ) async {
    if (!playback.requiresStrmExpansion) return playback;
    try {
      final bytes = await client.readAuthorizedBytes(
        playback.streamUrl,
        receiveTimeout: const Duration(seconds: 15),
        attempts: 1,
        maxBytes: 64 * 1024,
      );
      if (!_accepts(operation)) return null;
      final target = parseStrmTarget(utf8.decode(bytes, allowMalformed: true));
      if (target == null) return _strmTranscodeFallback(playback);
      return ResolvedPlayback(
        playMethod: PlayMethod.directPlay,
        streamUrl: target,
        playSessionId: playback.playSessionId,
        mediaSource: playback.mediaSource,
        itemId: playback.itemId,
        authorization: playback.authorization,
        canRenewUrlInPlace: playback.canRenewUrlInPlace,
        outputBitrate: playback.outputBitrate,
        timeline: playback.timeline,
        filmTimeline: playback.filmTimeline,
        partIndex: playback.partIndex,
        partStartPosition: playback.partStartPosition,
        streamStartsAtRequestedPosition:
            playback.streamStartsAtRequestedPosition,
        resources: playback.resources,
      );
    } on MediaServerException {
      final fallback = _strmTranscodeFallback(playback);
      if (fallback == null) rethrow;
      return fallback;
    } catch (_) {
      return _strmTranscodeFallback(playback);
    }
  }

  ResolvedPlayback? _strmTranscodeFallback(ResolvedPlayback playback) {
    final transcoding = playback.mediaSource.transcodingUrl;
    final base = client.baseUrl;
    final token = client.accessToken;
    if (transcoding == null ||
        transcoding.isEmpty ||
        base == null ||
        token == null ||
        token.isEmpty) {
      return null;
    }
    if (playback.mediaSource.audioStreams.any(
      (stream) => isOriginalDolbyAudioCodec(stream.codec),
    )) {
      return null;
    }
    return ResolvedPlayback(
      playMethod: PlayMethod.transcode,
      streamUrl: client.resolveResource(transcoding),
      playSessionId: playback.playSessionId,
      mediaSource: playback.mediaSource,
      itemId: playback.itemId,
      authorization: playback.authorization,
      canRenewUrlInPlace: playback.canRenewUrlInPlace,
      outputBitrate: playback.mediaSource.transcodingOutputBitrate,
      timeline: playback.timeline,
      filmTimeline: playback.filmTimeline,
      partIndex: playback.partIndex,
      partStartPosition: playback.partStartPosition,
      streamStartsAtRequestedPosition: playback.streamStartsAtRequestedPosition,
      resources: playback.resources,
    );
  }

  /// 片尾标记处,或无标记时片长最后约 3 分钟,提前给出下一集(不倒计时)。
  void _maybeOfferNextUp() {
    if (_disposed ||
        !skipOutroEnabled ||
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
    final threshold = _closingThreshold();
    if (threshold == null || position < threshold) {
      return;
    }
    _nextUpOffered = true;
    if (activeSkipSegment?.kind == PlayerSkipKind.outro) {
      skipPromptVisible = false;
    }
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
      final next = await _sourceRequest(() => client.getNextEpisode(current));
      if (!_accepts(operation)) {
        return;
      }
      if (next == null || nextEpisode != null) {
        if (next == null) {
          _nextUpOffered = false;
          _outroSkipAllowed = true;
          _updateActiveSkip();
          _emit();
        }
        return;
      }
      if (playbackEnded || _handlingCompleted) {
        _presentCompletedNext(next);
        return;
      }
      if (!skipOutroEnabled) {
        _nextUpOffered = false;
        return;
      }
      nextEpisode = NextEpisodeOffer(item: next);
      _noteNextOffer();
      _emit();
    } on MediaServerException {
      if (_accepts(operation)) {
        _nextUpOffered = false;
        _outroSkipAllowed = true;
        _updateActiveSkip();
        _emit();
      }
    } finally {
      if (_accepts(operation)) _nextUpLoading = false;
    }
  }

  void _beginNextEpisodeCountdown(MediaItem next) {
    final operation = _operations.current;
    if (!_accepts(operation)) return;
    nextEpisode = NextEpisodeOffer(item: next, remaining: nextEpisodeCountdown);
    _noteNextOffer();
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

  PreferenceResolution? preferenceResolution;
  bool scopedPreferencePending = false;
  bool _savePreferenceAfterObservation = false;
  void acknowledgeScopedPreference() => scopedPreferencePending = false;
  PlaybackSwitchPlan? switchConfirmation;
  ResolvedPlayback? _switchOriginal;
  int _switchInspection = 0;
  bool _hostSwitchPending = false;
  bool _seekInFlight = false;
  int _seekRevision = 0;

  Future<void> _inspectHostSwitch(Map<String, dynamic> target) async {
    if (_revoked || resolved == null || switchDispatcher == null) {
      throw StateError('Playback unavailable');
    }
    final original = resolved;
    final inspection = ++_switchInspection;
    final reply = await switchDispatcher!({
      'action': 'inspect',
      ...target,
      'item': itemId,
      'version': resolved!.mediaSource.id,
      'position': ticksFromDuration(position),
      'paused': !isPlaying,
      'bitrate': maxStreamingBitrate,
      'audio': audioStreamIndex,
      'subtitle': subtitleStreamIndex,
    });
    if (_revoked || _disposed || !identical(resolved, original)) return;
    if (inspection != _switchInspection) {
      await switchDispatcher!({'action': 'cancel'});
      return;
    }
    switchConfirmation = PlaybackSwitchPlan.fromJson(
      Map<String, dynamic>.from(reply['plan'] as Map),
    );
    _switchOriginal = original;
    _hostSwitchPending = true;
    _emit();
    if (!switchConfirmation!.needsConfirmation) {
      await confirmMediaSourceSwitch(SwitchResumeChoice.currentPosition);
    }
  }

  /// An explicit version choice within the current item needs no aggregation
  /// confirmation. Refresh its playback URL once, as part of the normal open.
  Future<void> switchMediaVersion(String sourceId) async {
    final current = resolved;
    if (!_accepts(_operations.current) || current == null) return;
    if (!isRecovering && sourceId == activeMediaSourceId) return;
    final target = mediaSources.where((source) => source.id == sourceId);
    if (target.length != 1) return;
    final plan = PlaybackSwitchPlan.inspect(
      original: current.mediaSource,
      target: target.single,
      positionTicks: ticksFromDuration(position),
      paused: !isPlaying && !isRecovering,
      maxStreamingBitrate: maxStreamingBitrate,
      audioIndex: audioStreamIndex,
      subtitleIndex: subtitleStreamIndex,
    );
    ++_switchInspection;
    switchConfirmation = null;
    _switchOriginal = null;
    _switchTarget = null;
    _switchTargetItem = null;
    onUserActivity();
    // Matching tracks carry over by language/title, never by numeric index.
    // Missing audio uses the target default; missing subtitles are disabled.
    // A shorter edition starts at zero; an unknown duration tries the current
    // position, with the freshly fetched metadata checked again during open.
    await _recover(
      sourceId: sourceId,
      switchPlan: plan,
      switchStartTicks:
          plan.targetRuntimeTicks != null &&
              plan.positionTicks >= plan.targetRuntimeTicks!
          ? 0
          : plan.positionTicks,
      switchAudio: plan.audioIndex,
      switchSubtitle: plan.subtitleIndex,
    );
  }

  /// Preflight leaves the old native/session active. Equal runtimes are not
  /// timeline proof and indices are never carried between different versions.
  Future<void> switchMediaSource(String sourceId) async {
    final current = resolved;
    final operation = _operations.current;
    if (!_accepts(operation) ||
        current == null ||
        (_switchTarget == null && sourceId == current.mediaSource.id)) {
      return;
    }
    final inspection = ++_switchInspection;
    switchConfirmation = null;
    _switchOriginal = null;
    onUserActivity();
    try {
      final target = _switchTarget;
      final info = target == null
          ? await _sourceRequest(
              () => client.inspectPlaybackInfo(
                itemId: itemId,
                mediaSourceId: sourceId,
                maxStreamingBitrate: maxStreamingBitrate,
                subtitleStreamIndex: -1,
              ),
            ).timeout(recoveryTimeout)
          : await target.permit
                .dispatch(
                  (_) => target.client.inspectPlaybackInfo(
                    itemId: target.source.itemId,
                    mediaSourceId: sourceId,
                    maxStreamingBitrate: maxStreamingBitrate,
                    subtitleStreamIndex: -1,
                  ),
                )
                .timeout(recoveryTimeout);
      if (!_accepts(operation) ||
          inspection != _switchInspection ||
          !identical(resolved, current)) {
        return;
      }
      final targets = info.mediaSources.where((s) => s.id == sourceId);
      if (targets.length != 1) {
        trackFailure = 'Requested media source is no longer available';
        _emit();
        return;
      }
      final plan = PlaybackSwitchPlan.inspect(
        original: current.mediaSource,
        target: targets.single,
        positionTicks: ticksFromDuration(position),
        paused: !isPlaying,
        maxStreamingBitrate: maxStreamingBitrate,
        audioIndex: audioStreamIndex,
        subtitleIndex: subtitleStreamIndex,
        sameVersion:
            target != null &&
            target.source.account == origin?.source.account &&
            target.source.itemId == itemId &&
            target.source.mediaSourceId == current.mediaSource.id,
      );
      switchConfirmation = plan;
      _switchOriginal = current;
      _emit();
      if (!plan.needsConfirmation) {
        await confirmMediaSourceSwitch(SwitchResumeChoice.currentPosition);
      }
    } catch (failure) {
      if (failure is PlaybackPreparationException) {
        await _persistFailedPreparation(
          failure.resources,
          target: _switchTarget,
          targetItemId: _switchTarget?.source.itemId,
          sourceId: sourceId,
        );
        await _releasePrepared(failure.resources);
      }
      if (!_accepts(operation) || inspection != _switchInspection) return;
      trackFailure = 'Source preflight failed: $failure';
      _emit();
    }
  }

  /// Missing language requires an explicit target index or acceptance of the
  /// target default; subtitle absence can instead be explicitly turned off.
  Future<void> confirmMediaSourceSwitch(
    SwitchResumeChoice choice, {
    int? audioIndex,
    int? subtitleIndex,
    bool acceptDefaultAudio = false,
    bool turnSubtitlesOff = false,
  }) async {
    final lineConfirmation = _confirmLine;
    if (lineConfirmation != null) {
      await lineConfirmation(
        choice,
        audioIndex,
        subtitleIndex,
        turnSubtitlesOff,
        acceptDefaultAudio,
      );
      return;
    }
    final plan = switchConfirmation;
    if (choice == SwitchResumeChoice.cancel) {
      _switchEntry?.cancel();
      _switchEntry = null;
      if (_hostSwitchPending) {
        await switchDispatcher!({'action': 'cancel'});
        _hostSwitchPending = false;
      }
      ++_switchInspection;
      switchConfirmation = null;
      _switchOriginal = null;
      _switchTarget = null;
      _switchTargetItem = null;
      pendingLineId = null;
      _emit();
      return;
    }
    if (plan == null) return;
    if (!identical(resolved, _switchOriginal) ||
        _disposed ||
        sessionExpired ||
        _operations.isClosed ||
        _backgroundReleased) {
      throw StateError('Switch confirmation expired');
    }
    if (choice == SwitchResumeChoice.currentPosition &&
        !plan.canTryCurrentPosition) {
      throw StateError('Resume position is outside the known target timeline');
    }
    if ((audioIndex != null &&
            !plan.audioChoices.any((s) => s.index == audioIndex)) ||
        (subtitleIndex != null &&
            !plan.subtitleChoices.any((s) => s.index == subtitleIndex))) {
      throw StateError('Selected target track does not exist');
    }
    if (plan.audioNeedsChoice && audioIndex == null && !acceptDefaultAudio) {
      throw StateError('Choose audio or explicitly accept target default');
    }
    if (plan.subtitleNeedsChoice &&
        subtitleIndex == null &&
        !turnSubtitlesOff) {
      throw StateError('Choose subtitles or explicitly turn them off');
    }
    if (_hostSwitchPending) {
      await switchDispatcher!({
        'action': 'confirm',
        'choice': choice.name,
        'audio': audioIndex,
        'subtitle': subtitleIndex,
        'acceptDefaultAudio': acceptDefaultAudio,
        'turnSubtitlesOff': turnSubtitlesOff,
      });
      _hostSwitchPending = false;
      switchConfirmation = null;
      _switchOriginal = null;
      return;
    }
    final target = _switchTarget;
    if (target != null) {
      target.permit.requireValid();
      await _commitSourceSwitch(
        target,
        plan,
        choice,
        audioIndex: audioIndex ?? plan.audioIndex,
        subtitleIndex: turnSubtitlesOff
            ? null
            : (subtitleIndex ?? plan.subtitleIndex),
      );
      return;
    }
    switchConfirmation = null;
    _switchOriginal = null;
    // Keep the captured intent; the dialog must not silently resume a pause or
    // recompute an out-of-range position from an advancing old session.
    maxStreamingBitrate = plan.maxStreamingBitrate;
    await _recover(
      sourceId: plan.sourceId,
      switchPlan: plan,
      switchStartTicks: choice == SwitchResumeChoice.beginning
          ? 0
          : plan.positionTicks,
      switchAudio: audioIndex ?? plan.audioIndex,
      switchSubtitle: turnSubtitlesOff
          ? null
          : (subtitleIndex ?? plan.subtitleIndex),
    );
  }

  /// Confirmed T4 comparison only; episode continuation additionally consumes
  /// T2's concrete lookup rather than playing the series or a neighbouring item.
  Future<void> switchConfirmedSource(
    SourceComparison candidate,
    String version, {
    EpisodeComparison? episode,
  }) async {
    if (!candidate.decision.confirmed ||
        (runtime == null && switchDispatcher == null) ||
        (runtime != null && origin == null)) {
      throw StateError('A permitted confirmed source is required');
    }
    var reference = candidate.source.reference;
    if (item?.isEpisode == true) {
      if (episode?.lookup.status != EpisodeLookupStatus.confirmed ||
          episode?.lookup.source == null ||
          episode!.target != candidate.source.reference) {
        throw StateError('Concrete target episode is not confirmed');
      }
      reference = episode.lookup.source!.reference;
    }
    if (switchDispatcher != null && runtime == null) {
      await _inspectHostSwitch({
        'target': encodeSource(reference),
        'work': encodeSource(candidate.source.reference.item),
        'library': candidate.source.libraryId,
        'targetVersion': version,
        'numbering': episode?.lookup.source?.numberingScheme,
      });
      return;
    }
    final original = origin!;
    _switchEntry?.cancel();
    final entry = await runtime!.prepareSourceEntry(
      reference.account.configuredServerId,
      requestPassword: requestSourcePassword,
    );
    if (entry == null) return;
    _switchEntry = entry;
    try {
      final target = await runtime!.resolve(
        PlayerOpenRequest(
          itemId: reference.itemId,
          source: reference,
          work: candidate.source.reference.item,
          libraryId: candidate.source.libraryId,
          mediaSourceId: version,
          accessGeneration: entry.generation,
        ),
        entry: entry,
      );
      await runtime!.requireEquivalent(
        original,
        target,
        numberingScheme: episode?.lookup.source?.numberingScheme,
      );
      target.permit.requireValid();
      if (!identical(origin, original) || _revoked || _disposed) return;
      _switchTargetItem = await target.permit.dispatch(
        (c) => c.getItem(reference.itemId),
      );
      _switchTarget = target;
      await switchMediaSource(version);
      if (switchConfirmation == null && !entry.isCommitted) {
        entry.cancel();
        _switchEntry = null;
        _switchTarget = null;
        _switchTargetItem = null;
      }
    } catch (_) {
      entry.cancel();
      _switchEntry = null;
      rethrow;
    }
  }

  /// Identity is checked anonymously before attaching credentials to a line.
  Future<void> lockCurrentServer() async {
    if (runtime != null &&
        origin != null &&
        runtime?.registry.access.isProtected(
              origin!.source.account.configuredServerId,
            ) ==
            true) {
      await runtime!.registry.access.lock(
        origin!.source.account.configuredServerId,
      );
      return;
    }
    if (switchDispatcher != null && openRequest?.source != null && !_revoked) {
      await switchDispatcher!({'action': 'lock'});
      return;
    }
    throw StateError('Private playback authority required');
  }

  Future<void> switchHostTarget(Map<String, dynamic> target) async {
    if (runtime != null || switchDispatcher == null || _revoked || _disposed) {
      throw StateError('Helper playback authority required');
    }
    await _inspectHostSwitch({
      'target': target['target'],
      'work': target['work'],
      'library': target['library'],
      'targetVersion': target['targetVersion'],
      'numbering': target['numbering'],
    });
  }

  List<ServerLine> get playbackLines {
    final actual = origin;
    final playback = runtime;
    if (playback != null && actual != null) {
      for (final server in playback.registry.project()) {
        if (server.id == actual.source.account.configuredServerId) {
          return server.lines;
        }
      }
    }
    return playbackLineSnapshot;
  }

  String? get playbackServerIdentity {
    final fromOrigin = origin?.source.account.verifiedServerId;
    if (fromOrigin != null && fromOrigin.isNotEmpty) return fromOrigin;
    final known = verifiedPlaybackServerId;
    if (known != null && known.isNotEmpty) return known;
    return null;
  }

  bool playbackLineIsCurrent(ServerLine line) {
    final current = client.baseUrl;
    if (current == null) return false;
    return Uri.tryParse(line.address) == current;
  }

  ServerLine? _playbackLineById(String lineId) {
    for (final line in playbackLines) {
      if (line.id == lineId) return line;
    }
    return null;
  }

  Future<void> _commitSourceSwitch(
    PlaybackOrigin target,
    PlaybackSwitchPlan plan,
    SwitchResumeChoice choice, {
    int? audioIndex,
    int? subtitleIndex,
  }) async {
    final old = origin!;
    final entry = _switchEntry;
    _switchEntry = null;
    _pendingEntryCommit = entry;
    final previous = resolved!;
    _restoreOrigin = (
      origin: old,
      playback: previous,
      item: item,
      position: plan.positionTicks,
      audio: audioStreamIndex,
      subtitle: subtitleStreamIndex,
      paused: plan.paused,
    );
    final nextItem = _switchTargetItem;
    pendingLineId ??= _lineFor(target);
    _savePreferenceAfterObservation = true;
    switchConfirmation = null;
    _switchOriginal = null;
    _switchTarget = null;
    _switchTargetItem = null;
    final stopped = _stopSession();
    _operations.invalidate();
    try {
      await Future.wait([
        stopped,
        _operations.interrupt(backend.stop, ensureRetired: true),
      ]).timeout(recoveryTimeout);
      target.permit.requireValid();
      if (_disposed || _revoked) return;
      origin = target;
      client = target.client;
      if (target.source.itemId != itemId) _resetSessionSubtitles();
      itemId = target.source.itemId;
      item = nextItem;
      final operation = _beginOperation();
      if (operation == null) return;
      maxStreamingBitrate = plan.maxStreamingBitrate;
      pendingMediaSourceId = plan.sourceId;
      await _open(
        operation: operation,
        startTicks: choice == SwitchResumeChoice.beginning
            ? 0
            : plan.positionTicks,
        audio: audioIndex,
        subtitle: subtitleIndex,
        subtitleOff: subtitleIndex == null,
        requestedSourceId: plan.sourceId,
        startPaused: plan.paused,
        strictTracks: true,
      ).timeout(recoveryTimeout);
      if (entry != null && !entry.isCommitted) {
        _pendingEntryCommit = null;
        entry.cancel();
        await restoreOriginalSource();
      } else {
        _restoreOrigin = null;
      }
    } catch (failure) {
      _pendingEntryCommit = null;
      entry?.cancel();
      if (old.permit.isValid && !_disposed && !_revoked) {
        await restoreOriginalSource();
        return;
      }
      await _operations
          .interrupt(backend.stop, ensureRetired: true)
          .timeout(disposeTimeout);
      loading = false;
      isPlaying = false;
      state.phase = PlaybackPhase.failed;
      disconnectDetail =
          'Source switch failed; original source may be restored: $failure';
      _emit();
    }
  }

  String? _lineFor(PlaybackOrigin source) {
    for (final server in runtime!.registry.project()) {
      if (server.id != source.source.account.configuredServerId) continue;
      for (final line in server.lines) {
        if (Uri.parse(line.address) == source.client.baseUrl) return line.id;
      }
    }
    return null;
  }

  bool get canRestoreOriginalSource =>
      !_revoked &&
      !_disposed &&
      (_restoreOrigin != null || switchDispatcher != null);

  Future<void> restoreOriginalSource() async {
    if (runtime == null && switchDispatcher != null) {
      if (_revoked) throw StateError('Playback permission revoked');
      await switchDispatcher!({'action': 'restore'});
      return;
    }
    final original = _restoreOrigin;
    if (original == null || _disposed || _revoked) {
      throw StateError('No restorable source');
    }
    original.origin.permit.requireValid();
    await _stopSession();
    await _operations
        .interrupt(backend.stop, ensureRetired: true)
        .timeout(recoveryTimeout);
    original.origin.permit.requireValid();
    origin = original.origin;
    pendingLineId = _lineFor(original.origin);
    _savePreferenceAfterObservation = true;
    client = origin!.client;
    if (origin!.source.itemId != itemId) _resetSessionSubtitles();
    itemId = origin!.source.itemId;
    item = original.item;
    final operation = _beginOperation();
    if (operation == null) return;
    await _open(
      operation: operation,
      startTicks: original.position,
      audio: original.audio,
      subtitle: original.subtitle,
      subtitleOff: original.subtitle == null,
      startPaused: original.paused,
      requestedSourceId: original.playback.mediaSource.id,
      strictTracks: true,
    ).timeout(recoveryTimeout);
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
      // Future.timeout does not cancel dispose, so a hung stop never reaches
      // the restore inside _disposeResources.
    } finally {
      // A finished dispose already restored and cleared this record. A second
      // call then leaves the session alone, including an independent runtime
      // client that never stored one.
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
    // The invalidated operation no longer accepts the backend's stopped
    // event. Publish the stopped state here so the UI releases its wake lock.
    isPlaying = false;
    loading = false;
    state.buffering = false;
    state.phase = PlaybackPhase.idle;
    _emit();
    final stopped = _stopSession();
    try {
      await _operations.interrupt(backend.stop);
      await _operations.drained;
      await stopped;
      await retryResourceCleanup();
    } finally {
      // Stop can fail after a shared-client line switch. Put the browsing
      // session back on its previous address before this shutdown ends.
    }
    await retryResourceCleanup();
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
  Future<void> disposeAsync({bool notifyStopped = true}) =>
      _disposing ??= _disposeResources(notifyStopped: notifyStopped);

  Future<void> _disposeResources({
    bool reportStopped = true,
    bool notifyStopped = true,
  }) async {
    _disposeLineTransactions();
    _switchEntry?.cancel();
    _pendingEntryCommit?.cancel();
    _switchEntry = null;
    _pendingEntryCommit = null;
    unawaited(_discardNextPrefix());
    _operations.close();
    state.phase = PlaybackPhase.closing;
    _cancelPlaybackTimers();
    // Closing invalidates backend events, so publish the stopped state while
    // the page is still mounted to release its display wake lock.
    isPlaying = false;
    loading = false;
    state.buffering = false;
    if (notifyStopped) _emit();
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
      await stopped;
      await retryResourceCleanup();
    } finally {
      // close() still leaves the player when stop or dispose throws. Put the
      // shared browsing session back before that exit, including on failure.
    }
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
          _openingPositionObserved = true;
          final skip = activeSkipSegment;
          final prompt = skipPromptVisible;
          final offered = nextEpisode;
          final previousPosition = position;
          _setPosition(_displayedPosition(event.value as Duration));
          final frozenSession = _session;
          if (frozenSession?.frozenStop != null &&
              origin?.permit.isValid == true) {
            frozenSession!.frozenStop!.updateReport(
              origin!.permit,
              _currentReport(),
            );
          }
          if (_scopedPlayback &&
              isPlaying &&
              !loading &&
              !_seekInFlight &&
              position > previousPosition) {
            final session = _session;
            session?.lastObservedPositionTicks = ticksFromDuration(position);
            if (session != null && !session.actuallyStarted) {
              session.actuallyStarted = true;
              unawaited(
                _persistObservation(session).catchError((Object failure) {
                  if (_ownsSession(session)) {
                    _lastProgressFailure = _syncFailure('observation', failure);
                    _markProgressSyncFailed(persistent: true);
                  }
                }),
              );
            }
          }
          _updateNetworkSlow();
          if (identical(skip, activeSkipSegment) &&
              prompt == skipPromptVisible &&
              identical(offered, nextEpisode) &&
              !_playbackUiDue()) {
            return;
          }
        case VideoEventKind.duration:
          final value = event.value as Duration;
          if (value > Duration.zero &&
              resolved?.filmTimeline == null &&
              !_shorterTranscodeWindow(value)) {
            duration = value;
            _rebuildSkipSegments();
            _maybeOfferNextUp();
          }
        case VideoEventKind.buffer:
          buffer = _displayedPosition(event.value as Duration);
          if (buffer < Duration.zero) buffer = Duration.zero;
          if (duration > Duration.zero && buffer > duration) buffer = duration;
        case VideoEventKind.bufferSnapshot:
          final next = event.value as BufferSnapshot;
          if (next.sessionId != operation.id ||
              next.sequence < bufferSnapshot.sequence ||
              next.trackVersion < bufferSnapshot.trackVersion) {
            return;
          }
          final previous = bufferSnapshot;
          bufferSnapshot = _stabilizeBufferSnapshot(next);
          _updateNetworkSlow();
          // Speed readouts are throttled. Cache coverage still updates the
          // combined timeline without waiting for a position tick.
          if (!_sameBufferPresentation(previous, bufferSnapshot) ||
              _playbackUiDue()) {
            _lastPlaybackUi = DateTime.now();
            _emit();
          }
          return;
        case VideoEventKind.cacheSpeed:
          final value = event.value;
          final next = value is num && value.isFinite && value > 0
              ? value.toDouble()
              : 0.0;
          final sameReadout =
              formatNetworkThroughput(next) ==
              formatNetworkThroughput(cacheSpeedBytesPerSec);
          cacheSpeedBytesPerSec = next;
          final slowBefore = networkSlow;
          _updateNetworkSlow();
          // The readout is coarse (KB/s or MB/s). Rebuilding the player for an
          // unchanged label steals frames from the texture upload.
          if (sameReadout && slowBefore == networkSlow && !_playbackUiDue()) {
            return;
          }
        case VideoEventKind.buffering:
          if (disconnected || state.phase == PlaybackPhase.failed) return;
          state.buffering = event.value as bool;
          _updateNetworkSlow();
          if (!loading) state.updatePlaying(isPlaying);
        case VideoEventKind.playing:
          if (state.phase == PlaybackPhase.failed) return;
          final changed = isPlaying != event.value;
          isPlaying = event.value as bool;
          if (!loading) state.updatePlaying(isPlaying);
          if (isPlaying) {
            disconnected = false;
            disconnectDetail = null;
            _holdAutomaticLineRecovery = false;
            if (changed) onUserActivity();
          } else {
            controlsVisible = true;
            _hideTimer?.cancel();
          }
          if (changed && _sessionStarted && !disconnected) {
            unawaited(
              _reportProgress(eventName: isPlaying ? 'Unpause' : 'Pause'),
            );
          }
        case VideoEventKind.interrupted:
          _pauseIntent = true;
          _userPausedPrefix = true;
          unawaited(_discardNextPrefix());
        case VideoEventKind.completed:
          if (event.value == true) {
            if (loading) {
              _pendingCompletion = true;
            } else {
              unawaited(_handleCompleted());
            }
          }
        case VideoEventKind.error:
          final failure = event.value;
          final message = failure is String
              ? failure
              : _lineFailureText(failure);
          if (failure is PlaybackRecoveryFailure) {
            final kind = switch (failure.kind) {
              PlaybackRecoveryFailureKind.forbidden =>
                MediaServerFailureKind.forbidden,
              PlaybackRecoveryFailureKind.certificate =>
                MediaServerFailureKind.certificate,
              PlaybackRecoveryFailureKind.identity =>
                MediaServerFailureKind.incompatibleServer,
              PlaybackRecoveryFailureKind.unauthorized =>
                MediaServerFailureKind.sessionExpired,
              PlaybackRecoveryFailureKind.rateLimited =>
                MediaServerFailureKind.rateLimited,
              _ => MediaServerFailureKind.unreachable,
            };
            loadFailure = MediaServerException(kind, cause: failure);
            _lineRetryAfter = failure.retryAfter == null
                ? null
                : DateTime.now().add(failure.retryAfter!);
          } else if (!isFatalPlaybackError(message, playing: isPlaying)) {
            return;
          } else {
            // A new transport fault cannot inherit a previous operation's
            // terminal classification after that operation has recovered.
            loadFailure = failure is MediaServerException ? failure : null;
            _lineRetryAfter = null;
          }
          playbackLineFailure = _lineFailureText(
            loadFailure ??
                const PlaybackRecoveryFailure(
                  PlaybackRecoveryFailureKind.network,
                ),
          );
          disconnected = true;
          isPlaying = false;
          loading = false;
          state.buffering = false;
          disconnectDetail = message.trim().isEmpty ? null : message.trim();
          controlsVisible = true;
          state.phase = PlaybackPhase.failed;
          _hideTimer?.cancel();
          if (_lineTransactionOpening) _invalidateHelperLineCommit();
          if (!_lineTransactionOpening &&
              !isRecovering &&
              !_holdAutomaticLineRecovery) {
            _holdAutomaticLineRecovery = true;
            unawaited(_recoverPlaybackLines(automatic: true));
          }
        case VideoEventKind.authenticationRequired:
          loadFailure = const MediaServerException(
            MediaServerFailureKind.sessionExpired,
          );
          playbackLineFailure = _lineFailureText(loadFailure!);
          if (_lineTransactionOpening) _invalidateHelperLineCommit();
          sessionExpired = true;
          disconnected = true;
          loading = false;
          state.buffering = false;
          isPlaying = false;
          controlsVisible = true;
          state.phase = PlaybackPhase.failed;
          disconnectDetail = 'Media HTTP ${event.value}';
          _hideTimer?.cancel();
          _progressTimer?.cancel();
          unawaited(backend.stop().catchError((Object _) {}));
        case VideoEventKind.sourceRefreshRequired:
          unawaited(
            _renewSourceUrl(
              operation,
              required: event.value is RequiredSourceRenewal,
            ),
          );
        case VideoEventKind.outputStatus:
          final next = event.value;
          if (next is PlaybackOutputStatus) applyObservedOutput(next);
          return;
      }
      _lastPlaybackUi = DateTime.now();
      _emit();
    });
  }

  bool _playbackUiDue() {
    return DateTime.now().difference(_lastPlaybackUi) >= kPlaybackUiMinInterval;
  }

  Future<void> _renewSourceUrl(
    PlaybackOperation operation, {
    bool required = false,
  }) async {
    final current = resolved;
    final renewal = backend;
    if (current == null ||
        renewal is! VideoBackendSourceRenewal ||
        !_accepts(operation)) {
      return;
    }
    if (_sourceRenewalOperation == operation.id) {
      if (required) {
        _sourceRenewalRequired = true;
        isRecovering = true;
        _emit();
      }
      return;
    }
    final mayRefresh = _refreshedSourceUrls.add(current.streamUrl.toString());
    if (!mayRefresh && !required) return;
    _sourceRenewalOperation = operation.id;
    _sourceRenewalRequired = required;
    final wasRecovering = isRecovering;
    if (required) {
      isRecovering = true;
      controlsVisible = true;
      _emit();
    }
    final ownsBudget = _lineBudget == null;
    final root = _lineBudget ?? PlaybackRecoveryBudget(total: recoveryTimeout);
    if (ownsBudget) _lineBudget = root;
    final budget = root.child(const Duration(seconds: 5));
    PlaybackResourceLease? preparation;
    Object? failure;
    var succeeded = false;
    try {
      if (!mayRefresh) {
        throw const PlaybackRecoveryFailure(
          PlaybackRecoveryFailureKind.network,
        );
      }
      if (current.isTranscode || !current.canRenewUrlInPlace) {
        await _recoverPlaybackLines(
          selection: playbackLineSelection,
          sharedBudget: root,
        );
        return;
      }
      final requestClient = client;
      final profile = backend is VideoBackendCapabilities
          ? await budget.run(
              () => (backend as VideoBackendCapabilities).playbackCapabilities(
                maxStreamingBitrate,
              ),
            )
          : null;
      if (!_accepts(operation)) return;
      final info = await budget.run(
        () => _sourceRequest<PlaybackInfo>(
          () => requestClient
              .getPlaybackInfo(
                itemId: itemId,
                mediaSourceId: current.mediaSource.id,
                maxStreamingBitrate: maxStreamingBitrate,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                capabilities: profile,
              )
              .timeout(budget.remaining),
        ),
      );
      preparation = info.resources;
      if (budget.isExpired ||
          budget.isCancelled ||
          !_accepts(operation) ||
          !identical(resolved, current)) {
        return;
      }
      final resolvedNext = client.resolvePlayback(
        info: info,
        itemId: itemId,
        mediaSourceId: current.mediaSource.id,
      );
      if (resolvedNext == null ||
          resolvedNext.isTranscode ||
          resolvedNext.mediaSource.id != current.mediaSource.id) {
        return;
      }
      final next = await budget.run(() => _expandStrm(operation, resolvedNext));
      if (next == null ||
          next.isTranscode ||
          next.requiresStrmExpansion ||
          next.mediaSource.id != current.mediaSource.id ||
          budget.isExpired ||
          budget.isCancelled ||
          !_accepts(operation)) {
        return;
      }
      await budget.run(
        () => (renewal as VideoBackendSourceRenewal).refreshSourceUrl(
          next.streamUrl,
        ),
        onCancel: () {
          if (_sourceRenewalRequired && _accepts(operation)) {
            _trackNativeRetirement(
              _operations.interrupt(backend.stop, ensureRetired: true),
            );
          }
        },
      );
      succeeded = true;
    } catch (error) {
      failure = error;
    } finally {
      // Resource cleanup keeps its own retry record and must not extend the
      // foreground recovery deadline while a provider DELETE is outstanding.
      unawaited(_releasePrepared(preparation).catchError((Object _) {}));
      if (_sourceRenewalOperation == operation.id) {
        _sourceRenewalOperation = null;
        final mandatory = _sourceRenewalRequired;
        _sourceRenewalRequired = false;
        if (_accepts(operation) && mandatory) {
          if (backend is VideoBackendSourceRenewalFeedback) {
            (backend as VideoBackendSourceRenewalFeedback).finishSourceRenewal(
              succeeded: succeeded,
            );
          }
          if (!succeeded || disconnected) {
            loadFailure = failure is MediaServerException
                ? failure
                : const MediaServerException(
                    MediaServerFailureKind.unreachable,
                  );
            sessionExpired =
                PlaybackRecoveryCoordinator.classify(loadFailure!) ==
                PlaybackRecoveryFailureKind.unauthorized;
            playbackLineFailure = _lineFailureText(loadFailure!);
            error = PlayerErrorKind.load;
            loading = false;
            isPlaying = false;
            disconnected = true;
            state.phase = PlaybackPhase.failed;
            state.buffering = false;
            // An enclosing open/line recovery already owns this deadline.
            // Otherwise continue this same root, never start another 45 s.
            if (!_lineTransactionOpening && _lineRecovery == null) {
              isRecovering = false;
              await _recoverPlaybackLines(automatic: true, sharedBudget: root);
            }
          } else {
            isRecovering = wasRecovering;
          }
          _emit();
        }
      }
      if (ownsBudget && identical(_lineBudget, root)) _lineBudget = null;
    }
  }

  void _updateNetworkSlow() {
    final sourceBitrate = resolved?.mediaSource.bitrate;
    final expected =
        isTranscode && maxStreamingBitrate < kCoreMaxStreamingBitrate
        ? maxStreamingBitrate
        : sourceBitrate;
    // A quiet network is normal while reading cached media. Incomplete time
    // mapping also cannot establish a stall: require actual buffering.
    final slow =
        !_networkSlowDismissed &&
        !loading &&
        !disconnected &&
        expected != null &&
        expected > 0 &&
        isBuffering &&
        cacheSpeedBytesPerSec * 8 < expected * 0.7;
    if (!slow) {
      _slowSince = null;
      networkSlow = false;
      return;
    }
    _slowSince ??= DateTime.now();
    networkSlow = DateTime.now().difference(_slowSince!) >= networkSlowAfter;
  }

  void dismissNetworkSlowHint() {
    _networkSlowDismissed = true;
    networkSlow = false;
    _slowSince = null;
    notifyListeners();
  }

  Future<void> _open({
    required PlaybackOperation operation,
    required int startTicks,
    String? requestedSourceId,
    void Function(String stage)? onStage,
    int? audio,
    int? subtitle,
    bool subtitleOff = false,
    bool forceTranscode = false,
    String? compatibilityReason,
    bool startPaused = false,
    int? requestedBitrate,
    bool strictTracks = false,
    PlaybackInfo? preparedInfo,
    ResolvedPlayback? preparedPlayback,
    List<PlaybackMediaSource>? preparedSources,
    Duration? preparedStreamOrigin,
  }) async {
    if (!_accepts(operation)) {
      await _releasePrepared(preparedInfo?.resources);
      return;
    }
    final openedAt = DateTime.now();
    _openStageMs.clear();
    void stage(String name) {
      _openStageMs[name] = DateTime.now().difference(openedAt).inMilliseconds;
      onStage?.call(name);
    }

    PlaybackResourceLease? preparing;
    _pauseIntent = startPaused;
    _openingStartTicks = startTicks;
    _openingPositionObserved = false;
    _lastPlaybackInfo = null;
    loading = true;
    state.phase = PlaybackPhase.loading;
    state.buffering = false;
    isPlaying = false;
    disconnected = false;
    disconnectDetail = null;
    buffer = Duration.zero;
    bufferSnapshot = BufferSnapshot.empty(
      sessionId: operation.id,
      unknownReason: 'preparing',
    );
    cacheSpeedBytesPerSec = 0;
    networkSlow = false;
    _networkSlowDismissed = false;
    _slowSince = null;
    nextEpisode = null;
    playbackEnded = false;
    _suspendedAtEnd = false;
    _nextUpOffered = false;
    _nextUpLoading = false;
    _outroSkipAllowed = false;
    _handlingCompleted = false;
    _pendingCompletion = false;
    _nextTimer?.cancel();
    _emit();

    try {
      stage('metadata');
      final requestClient = client;
      PlaybackInfo? info = preparedInfo;
      preparing = info?.resources;
      // Discover versions before selecting the saved intent. This path cannot
      // allocate a transcode, select a server track, or fail on the default
      // version's playback capability before the chosen version is known.
      var sources =
          preparedSources ??
          info?.mediaSources ??
          (requestClient is PlaybackMetadataProvider
              ? (_takeStartupVersions(itemId) ??
                    await _sourceRequest<List<PlaybackMediaSource>>(
                      () => (requestClient as PlaybackMetadataProvider)
                          .getPlaybackSources(
                            itemId: itemId,
                            position: durationFromTicks(startTicks),
                          ),
                    ))
              : playbackSourcesFromItem(item!));
      if (!_accepts(operation)) return;
      var legacyDiscovery = false;
      if (sources.isEmpty && requestClient is! PlaybackMetadataProvider) {
        // Older adapters may omit sources from catalog metadata. Preserve their
        // PlaybackInfo discovery contract; metadata request failures never get
        // here, and providers with explicit metadata support never use it.
        legacyDiscovery = true;
        final legacyProfile = backend is VideoBackendCapabilities
            ? await (backend as VideoBackendCapabilities).playbackCapabilities(
                requestedBitrate ?? maxStreamingBitrate,
              )
            : null;
        if (!_accepts(operation)) return;
        info = await _sourceRequest<PlaybackInfo>(
          () => requestClient.getPlaybackInfo(
            itemId: itemId,
            mediaSourceId:
                requestedSourceId ??
                activeMediaSourceId ??
                preferredMediaSourceId,
            maxStreamingBitrate: requestedBitrate ?? maxStreamingBitrate,
            startPosition: durationFromTicks(startTicks),
            audioStreamIndex: audio ?? preferredAudioStreamIndex,
            subtitleStreamIndex: subtitleOff
                ? -1
                : subtitle ?? preferredSubtitleStreamIndex,
            capabilities: legacyProfile,
            forceTranscode: forceTranscode,
          ),
        );
        preparing = info.resources;
        if (!_accepts(operation)) return;
        if (_pendingEntryCommit == null) {
          await _writePreparationSnapshot(
            operation,
            info,
            startTicks: startTicks,
          );
        }
        sources = info.mediaSources;
      }
      mediaSources = sources;
      if (runtime != null && origin != null && _pendingEntryCommit == null) {
        await runtime!.importLegacyPreferences(
          origin!,
          item!,
          sources,
          await (await _settings()).read(),
        );
        if (!_accepts(operation)) return;
        preferenceResolution = runtime!.preference(origin!, item!, sources);
      }
      final preference = preferenceResolution;
      final explicitVersion = requestedSourceId ?? preferredMediaSourceId;
      if (_scopedPlayback &&
          runtime != null &&
          explicitVersion == null &&
          preference?.failure != null &&
          preference!.failure != PreferenceFailure.notConfigured) {
        await _failOpen(
          operation,
          detail:
              'Source preference requires explicit selection: ${preference.failure}',
        );
        return;
      }
      final previousBitrate = maxStreamingBitrate;
      if (!strictTracks &&
          preference?.failure == null &&
          preference?.selected != null &&
          (explicitVersion == null ||
              explicitVersion == preference!.selected!.source.mediaSourceId)) {
        final settings = preference!.preference!.settings;
        // Connection intent belongs to SavedServer. A historical preference's
        // line cannot override automatic recovery or a user's current fixed line.
        _rememberedPreference = settings;
        if (requestedBitrate == null && settings.maxStreamingBitrate != null) {
          maxStreamingBitrate = settings.maxStreamingBitrate!;
        }
      }
      final requestedVersion =
          requestedSourceId ??
          activeMediaSourceId ??
          preferredMediaSourceId ??
          _rememberedPreference?.mediaSourceId ??
          preference?.selected?.source.mediaSourceId;
      final chosenId = preferredPlaybackSourceId(
        sources: sources,
        requestedId: requestedVersion,
        requestedName: _preferredSourceName,
      );
      if (requestedSourceId != null && chosenId != requestedSourceId) {
        await _failOpen(
          operation,
          detail: 'Requested media source is no longer available',
        );
        return;
      }
      final memory = strictTracks ? null : _rememberedPreference;
      final targetSource = sources
          .where((source) => source.id == chosenId)
          .firstOrNull;
      if (targetSource == null) {
        await _failOpen(
          operation,
          detail: 'No playback source metadata is available',
        );
        return;
      }
      final exactSavedSource =
          memory?.mediaSourceId != null &&
          memory!.mediaSourceId == targetSource.id;
      final defaultAudio = targetSource.defaultAudioStreamIndex;
      final selectedAudio =
          matchPreferredStreamIndex(
            streams: targetSource.audioStreams,
            exactIndex:
                strictTracks ||
                exactSavedSource ||
                preferredAudioStreamIndex != null,
            preferredIndex:
                audio ??
                (strictTracks ? null : preferredAudioStreamIndex) ??
                memory?.audioStreamIndex,
            language: preferredAudioStreamIndex == null
                ? memory?.audioLanguage
                : null,
            title: preferredAudioStreamIndex == null
                ? memory?.audioTitle
                : null,
          ) ??
          (targetSource.audioStreams.any(
                (stream) => stream.index == defaultAudio,
              )
              ? defaultAudio
              : targetSource.audioStreams.firstOrNull?.index);
      final selectedSubtitle =
          subtitleOff ||
              (!strictTracks &&
                  subtitle == null &&
                  preferredSubtitleStreamIndex == null &&
                  memory?.subtitleOff == true)
          ? null
          : matchPreferredStreamIndex(
                  streams: targetSource.subtitleStreams,
                  exactIndex:
                      strictTracks ||
                      exactSavedSource ||
                      preferredSubtitleStreamIndex != null,
                  preferredIndex:
                      subtitle ??
                      (strictTracks ? null : preferredSubtitleStreamIndex) ??
                      memory?.subtitleStreamIndex,
                  language: preferredSubtitleStreamIndex == null
                      ? memory?.subtitleLanguage
                      : null,
                  title: preferredSubtitleStreamIndex == null
                      ? memory?.subtitleTitle
                      : null,
                ) ??
                fallbackSubtitleStreamIndex(targetSource);
      // Resolve once. These exact IDs drive negotiation, native open, UI and
      // reports; a second language/title match after transcode can pick a
      // different track with the same label.
      final bitrate = requestedBitrate ?? maxStreamingBitrate;
      final profile = backend is VideoBackendCapabilities
          ? await (backend as VideoBackendCapabilities).playbackCapabilities(
              bitrate,
            )
          : null;
      if (!_accepts(operation)) return;
      if (info == null ||
          (legacyDiscovery && (memory != null || previousBitrate != bitrate))) {
        if (info != null) {
          await _releasePrepared(preparing);
          preparing = null;
        }
        info = await _sourceRequest<PlaybackInfo>(
          () => requestClient.getPlaybackInfo(
            itemId: itemId,
            mediaSourceId: chosenId,
            maxStreamingBitrate: bitrate,
            startPosition: durationFromTicks(startTicks),
            audioStreamIndex: selectedAudio,
            subtitleStreamIndex: selectedSubtitle ?? -1,
            capabilities: profile,
            forceTranscode: forceTranscode,
          ),
        );
        preparing = info.resources;
      }
      if (!_accepts(operation)) return;
      await _writePreparationSnapshot(operation, info, startTicks: startTicks);
      mediaSources = [
        for (final source in sources) info.sourceById(source.id) ?? source,
        for (final source in info.mediaSources)
          if (!sources.any((metadata) => metadata.id == source.id)) source,
      ];
      final resolvedNext =
          preparedPlayback ??
          client.resolvePlayback(
            info: info,
            itemId: itemId,
            mediaSourceId: chosenId,
            forceTranscode: forceTranscode,
          );
      if (!_accepts(operation)) return;
      final next =
          preparedPlayback ??
          (resolvedNext == null
              ? null
              : await _expandStrm(operation, resolvedNext));
      if (!_accepts(operation)) return;
      if (next == null) {
        if (compatibilityReason != null) {
          await _failOpen(operation, detail: compatibilityReason);
          return;
        }
        error = PlayerErrorKind.noStream;
        loading = false;
        state.phase = PlaybackPhase.failed;
        _emit();
        return;
      }
      resolved = next;
      await _writePreparationSnapshot(
        operation,
        info,
        playback: next,
        startTicks: startTicks,
      );
      if (!_accepts(operation)) return;
      final sourceRuntime = next.filmTimeline != null
          ? next.filmTimeline!.duration ?? Duration.zero
          : next.mediaSource.runtime ?? item?.runtime ?? Duration.zero;
      if (startTicks > 0 &&
          sourceRuntime > Duration.zero &&
          durationFromTicks(startTicks) >= sourceRuntime) {
        await _failOpen(
          operation,
          detail: 'Resume position is outside target timeline',
        );
        return;
      }
      final boundedStartTicks = startTicks;
      if (strictTracks &&
          ((audio != null &&
                  !next.mediaSource.audioStreams.any(
                    (s) => s.index == audio,
                  )) ||
              (subtitle != null &&
                  !next.mediaSource.subtitleStreams.any(
                    (s) => s.index == subtitle,
                  )))) {
        await _failOpen(
          operation,
          detail: 'Confirmed target language track is no longer available',
        );
        return;
      }
      if ((selectedAudio != null &&
              !next.mediaSource.audioStreams.any(
                (stream) => stream.index == selectedAudio,
              )) ||
          (selectedSubtitle != null &&
              !next.mediaSource.subtitleStreams.any(
                (stream) => stream.index == selectedSubtitle,
              ))) {
        await _failOpen(
          operation,
          detail: 'Negotiated playback omitted the selected track',
        );
        return;
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

      stage('native open');
      // The transcoding URL already includes StartTimeTicks. Seeking the core
      // to the same absolute time lands inside a playlist that starts at 0.
      _streamOrigin =
          preparedStreamOrigin ??
          (next.filmTimeline != null
              ? next.streamOrigin ??
                    (throw StateError('Unknown film Part offset'))
              : next.startsAtRequestedPosition
              ? durationFromTicks(boundedStartTicks)
              : Duration.zero);
      await _operations.run(operation, () async {
        await backend.open(
          VideoOpenRequest(
            sessionId: operation.id,
            cacheIdentity: jsonEncode([
              client.userId,
              itemId,
              next.mediaSource.id,
              activeLineId,
              _streamOrigin.inMicroseconds,
            ]),
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
            // Keep the first decoded frame silent until the saved volume,
            // speed and audio selection are applied at the resume position.
            startPaused: startPaused,
            // Android tunneling requires play intent while opening its paired
            // audio/video codecs. Keep this output hold on desktop sinks.
            holdPlaybackForSettings: !Platform.isAndroid,
            start: durationFromTicks(boundedStartTicks) - _streamOrigin,
            authorization: next.authorization,
            credentialOrigin: client.baseUrl,
            credentialHeaders:
                next.authorization?.headersFor(client.baseUrl!) ??
                client.sessionHeaders,
            // 所有媒体地址保留 UA，会话凭据仅发往 Emby 同源地址。
            headers: playbackStreamHeaders(
              streamUrl: next.streamUrl,
              baseUrl: client.baseUrl!,
              sessionHeaders:
                  next.authorization?.headersFor(next.streamUrl) ??
                  client.sessionHeaders,
            ),
            warmedPrefix: _nextPrefix?.itemId == itemId
                ? _nextPrefix!.bytes
                : null,
            warmedPrefixEtag: _nextPrefix?.itemId == itemId
                ? _nextPrefix!.etag
                : null,
            warmedPrefixTotalBytes: _nextPrefix?.itemId == itemId
                ? _nextPrefix!.totalBytes
                : null,
          ),
        );
        if (!_accepts(operation)) return;
        final runtime = next.filmTimeline != null
            ? next.filmTimeline!.duration ?? Duration.zero
            : next.mediaSource.runtime ?? item?.runtime ?? Duration.zero;
        _catalogRuntime = runtime;
        if (next.filmTimeline != null) duration = runtime;
        if (runtime > Duration.zero) {
          duration = _catalogRuntime;
        }
        _setPosition(_displayedPosition(backend.position));
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
        stage('restore volume');
        final volumeApplied = await _restoreParameter(
          operation,
          () => backend.setVolume(mpvVolumeForPercent(volume)),
        );
        stage('restore playback rate');
        final rateApplied = await _restoreParameter(
          operation,
          () => backend.setRate(playbackRate),
        );
        if ((_lineTransactionOpening ||
                isRecovering ||
                _pendingEntryCommit != null ||
                sourceOpenResult != null) &&
            (!volumeApplied || !rateApplied)) {
          throw StateError('Required playback settings were not restored');
        }
        stage('restore audio track');
        final audioApplied = await _restoreParameter(operation, () async {
          if (selectedAudio != null && !next.isTranscode) {
            if (backend.selectedAudioIndex != selectedAudio) {
              await _selectDeviceTrack(
                audio: true,
                index: selectedAudio,
                select: () => backend.setAudioIndex(selectedAudio),
              );
            }
          }
        });
        if (strictTracks && !audioApplied) {
          throw StateError('Required audio track was not restored');
        }
        if (_accepts(operation)) {
          audioStreamIndex = audioApplied
              ? selectedAudio
              : backend.selectedAudioIndex;
        }
        if (!_accepts(operation)) return;
        if (!_pauseIntent && !backend.isPlaying) await backend.play();
        if (!_accepts(operation)) return;
        await sourceOpenResult?.call(itemId, chosenId, true);
        if (!_accepts(operation)) return;
        final entry = _pendingEntryCommit;
        if (entry != null) {
          await entry.prepareCommit();
          if (!_accepts(operation)) return;
          if (!entry.commit()) throw StateError('Source entry commit failed');
          _pendingEntryCommit = null;
        }
        isPlaying = backend.isPlaying;
        // The ordinary player's source is confirmed by the successful native
        // open/settings restore. Optional subtitles and server reporting must
        // not leave its source menu unselected while playback is already ready.
        // Scoped playback still requires its persisted viewing observation.
        if (!_scopedPlayback) activeMediaSourceId = chosenId;
        if (!isRecovering) {
          loading = false;
          state.updatePlaying(isPlaying);
        }
        // Optional subtitles and server reporting cannot hold audible startup.
        _emit();
        started = _beginSession(operation, startTicks: boundedStartTicks);
        if (_pendingCompletion) {
          _pendingCompletion = false;
          unawaited(_handleCompleted());
        }
        await _queueSubtitlePresentation(phoneSubtitleSettings, save: false);
      });
      if (!_accepts(operation) || disconnected) return;
      final subtitleSession = _session;
      bool ownsSubtitle() =>
          identical(subtitleSession, _session) &&
          subtitleRevision == _trackRevisions['SubtitleTrackChange'];
      stage('restore subtitle track');
      final subtitleApplied = await _restoreParameter(operation, () async {
        await _applySubtitle(
          next,
          operation,
          subtitle: selectedSubtitle,
          revision: subtitleRevision,
        );
      }, accepts: ownsSubtitle);
      if (strictTracks && !subtitleApplied) {
        throw StateError('Required subtitle track was not restored');
      }
      if (subtitleApplied && ownsSubtitle()) {
        subtitleStreamIndex = selectedSubtitle;
      } else if (ownsSubtitle() && !disconnected) {
        subtitleStreamIndex = backend.selectedSubtitleIndex;
      }
      if (!_accepts(operation) || disconnected) return;
      // 换源/重开后部分后端会丢外挂字幕选择(字幕要等一会儿才出现),
      // 起流片刻后重断言一次,字幕晚显的问题即消失。
      if (subtitleApplied && ownsSubtitle()) _scheduleSubtitleReassert();
      onStage?.call('restore session subtitle slots');
      final slotsSession = _session;
      bool ownsSlots() =>
          _accepts(operation) &&
          identical(slotsSession, _session) &&
          !disconnected;
      // 首次起播的显式次字幕预选只消费一次;之后的会话状态由
      // 用户选择与恢复逻辑维护。
      final preferredSecondary = preferredSecondarySubtitleStreamIndex;
      if (preferredSecondary != null &&
          secondarySubtitleStreamIndex == null &&
          secondarySubtitleFileId == null &&
          preferredSecondary != selectedSubtitle &&
          next.mediaSource.streamByIndex(preferredSecondary)?.isSubtitle ==
              true) {
        secondarySubtitleStreamIndex = preferredSecondary;
      }
      preferredSecondarySubtitleStreamIndex = null;
      await _restoreParameter(
        operation,
        () => _restoreSessionSubtitleSlots(next, current: ownsSlots),
        accepts: ownsSubtitle,
      );
      if (isRecovering || preparedPlayback != null) {
        // Reporting is independent of whether the native stream is usable.
        unawaited(started);
      } else {
        await started;
      }
      if (!_accepts(operation) || disconnected) return;
      error = null;
      loadFailure = null;
      playbackLineFailure = null;
      _lineRetryAfter = null;
      if (_scopedPlayback) {
        pendingMediaSourceId = chosenId;
      }
      _preferredSourceName = _sourceFingerprint(next.mediaSource);
      if (trackFailure == null) {
        if (isRecovering) {
          unawaited(_persistSeriesPreference().catchError((Object _) {}));
        } else {
          await _persistSeriesPreference();
        }
      }
      if (!_accepts(operation)) return;
      stage('ready');
      _lastPlaybackInfo = info;
      loading = false;
      state.updatePlaying(isPlaying);
      // 续播落在片头/片尾或最后几分钟时,loading 期间的 position 不会弹出
      // 跳过/下一集;开流完成后再判一次。
      _updateActiveSkip();
      _maybeOfferNextUp();
      onUserActivity();
      _emit();
    } on VideoCompatibilityException catch (failure) {
      if (!forceTranscode && _accepts(operation)) {
        stage('compatibility stop');
        final retirement = _operations.interrupt(
          backend.stop,
          ensureRetired: true,
        );
        if (isRecovering) _trackNativeRetirement(retirement);
        await retirement;
        await _releasePrepared(preparing);
        preparing = null;
        await _open(
          operation: operation,
          startTicks: startTicks,
          requestedSourceId: requestedSourceId,
          onStage: onStage,
          audio: audio,
          subtitle: subtitle,
          subtitleOff: subtitleOff,
          forceTranscode: true,
          compatibilityReason: failure.message,
          startPaused: startPaused,
          requestedBitrate: requestedBitrate,
        );
      } else {
        await _failOpen(operation, detail: failure.toString());
      }
    } on MediaServerException catch (failure) {
      await _failOpen(operation, failure: failure);
    } catch (error) {
      var detail = error.toString();
      if (backend is VideoBackendFailureContext) {
        final context = await (backend as VideoBackendFailureContext)
            .failureContext()
            .timeout(const Duration(seconds: 2));
        if (context != null && context.isNotEmpty) {
          detail = '$detail ($context)';
        }
      }
      await _failOpen(operation, detail: detail);
    } finally {
      if (!identical(_session?.resources, preparing)) {
        await _releasePrepared(preparing);
      }
    }
  }

  Future<bool> _restoreParameter(
    PlaybackOperation operation,
    Future<void> Function() apply, {
    bool Function()? accepts,
  }) async {
    bool current() =>
        _accepts(operation) && !disconnected && (accepts?.call() ?? true);
    if (!current()) return false;
    try {
      await apply();
      return current();
    } on DeviceTrackRejected {
      // Startup restore keeps the playable track and stays silent.
      return false;
    } on TimeoutException {
      // A missing native reply does not establish a healthy control channel.
      if (current()) rethrow;
      return false;
    } catch (failure) {
      if (current()) {
        trackFailure = failure.toString();
        _emit();
      }
      return false;
    }
  }

  /// Skips a mapped track the device cannot play instead of selecting it.
  Future<void> _selectDeviceTrack({
    required bool audio,
    required int index,
    required Future<void> Function() select,
  }) async {
    if (backend is! VideoBackendTrackSupport) {
      await select();
      return;
    }
    final support = backend as VideoBackendTrackSupport;
    final supported = audio
        ? support.audioTrackSupported(index)
        : support.subtitleTrackSupported(index);
    if (supported == false) throw const DeviceTrackRejected();
    await select();
  }

  Future<void> _failOpen(
    PlaybackOperation operation, {
    MediaServerException? failure,
    String? detail,
  }) async {
    if (!_accepts(operation)) return;
    try {
      await sourceOpenResult?.call(
        itemId,
        resolved?.mediaSource.id ?? preferredMediaSourceId,
        false,
      );
    } catch (_) {
      /* Host expiry already cancels this launch. */
    }

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
        if (_openStageMs.isNotEmpty) {
          final trace = _openStageMs.entries
              .map((entry) => '${entry.key}=${entry.value}ms')
              .join(' ');
          disconnectDetail = disconnectDetail == null
              ? 'stages: $trace'
              : '$disconnectDetail; stages: $trace';
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
    int slot = 0,
  }) async {
    if (!current()) return;
    if (subtitle == null) {
      await backend.setSubtitleOff(slot: slot);
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
            slot: slot,
          );
          return;
        case TranscodeSubtitleDelivery.manifest:
          await _selectDeviceTrack(
            audio: false,
            index: subtitle,
            select: () => backend.setSubtitleIndex(subtitle, slot: slot),
          );
          return;
      }
    }
    await _activateSubtitle(
      next.mediaSource,
      subtitle,
      current: current,
      slot: slot,
    );
  }

  /// 内嵌文本按容器流索引切换。外挂文本先整文件下载到本地，再交给播放核心。
  /// 菜单勾选只在调用方确认这次选择已经生效后更新。
  /// [slot] 0 为主字幕,1 为次字幕;两槽的下载副本互不挤占。
  Future<void> _activateSubtitle(
    PlaybackMediaSource source,
    int? index, {
    bool forceExternal = false,
    required bool Function() current,
    int slot = 0,
  }) async {
    if (!current()) return;
    if (index == null) {
      await backend.setSubtitleOff(slot: slot);
      return;
    }
    final stream = source.streamByIndex(index);
    if (stream == null || !stream.isSubtitle) {
      throw StateError('Subtitle track is unavailable');
    }
    if (!forceExternal && stream.isBitmapSubtitle) {
      await _selectDeviceTrack(
        audio: false,
        index: index,
        select: () => backend.setSubtitleIndex(index, slot: slot),
      );
      return;
    }
    if (!forceExternal && !stream.isExternal) {
      try {
        // 内嵌文本(ASS 等)已在直连容器里。按流索引选择,避免再向
        // 服务器提取一份外挂文件(该请求会超时或选不中,字幕就不出现)。
        await _selectDeviceTrack(
          audio: false,
          index: index,
          select: () => backend.setSubtitleIndex(index, slot: slot),
        );
        return;
      } on DeviceTrackRejected {
        rethrow;
      } on StateError {
        // 容器里没有对应轨道时,再走外挂地址。
      }
    }
    if (!current()) return;
    final deliveryUrl = stream.deliveryUrl;
    final remote = deliveryUrl != null && deliveryUrl.isNotEmpty
        ? client.resolveResource(deliveryUrl)
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
        index: index,
        slot: slot,
      );
      if (!current()) return;
      if (!applied) {
        throw StateError('External subtitle was not selected');
      }
      // Capture the prior owner only at commit. Every download has a unique
      // path, so a superseded completion can only delete its own candidate.
      final previous = _activeSubtitleFiles[slot];
      _activeSubtitleFiles[slot] = file;
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
    final bytes = await _sourceRequest(
      () => client.readAuthorizedBytes(remote),
    );
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
    final cache = await _ensureSubtitleCache();
    if (!current()) return null;
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
    // Imported candidates remain reusable until the whole media session ends.
    if (_subtitleImports.files.any((entry) => entry.file.path == file.path)) {
      return;
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 会话字幕缓存目录:服务器下载副本与导入副本共用同一受控临时目录。
  Future<Directory> _ensureSubtitleCache() async {
    final existing = _subtitleCache;
    if (existing != null) return existing;
    final created = await Directory.systemTemp.createTemp(
      'rillight-subtitles-',
    );
    var settled = _subtitleCache;
    if (settled == null) {
      _subtitleCache = settled = created;
    } else {
      await created.delete(recursive: true);
    }
    return settled;
  }

  Future<void> _deleteSubtitleCache() async {
    final cache = _subtitleCache;
    _subtitleCache = null;
    _activeSubtitleFiles.clear();
    primarySubtitleFileId = null;
    secondarySubtitleFileId = null;
    await _subtitleImports.clear();
    if (cache == null) return;
    try {
      if (await cache.exists()) await cache.delete(recursive: true);
    } catch (_) {}
  }

  /// 换媒体时清理会话字幕:导入候选、两槽文件占用与次字幕选择。
  /// 同一媒体的换源/重开不经过这里,槽位在 `_open` 完成后重注册。
  void _resetSessionSubtitles() {
    secondarySubtitleStreamIndex = null;
    secondarySubtitleFileId = null;
    primarySubtitleFileId = null;
    subtitleImportNotice = null;
    subtitleSelectionNotice = null;
    _activeSubtitleFiles.clear();
    unawaited(_subtitleImports.clear());
  }

  /// 同会话恢复(换源/重开)后重注册两槽:会话文件副本与次字幕选择。
  /// 每个槽独立处理,失败只放弃该槽,不影响主字幕服务器轨与播放位置。
  Future<void> _restoreSessionSubtitleSlots(
    ResolvedPlayback next, {
    required bool Function() current,
  }) async {
    final primaryFile = primarySubtitleFileId;
    if (primaryFile != null) {
      try {
        await _applySubtitleSource(
          slot: 0,
          fileId: primaryFile,
          current: current,
        );
        if (current()) subtitleStreamIndex = null;
      } catch (_) {
        if (current()) primarySubtitleFileId = null;
      }
    }
    final secondaryFile = secondarySubtitleFileId;
    if (secondaryFile != null) {
      try {
        await _applySubtitleSource(
          slot: 1,
          fileId: secondaryFile,
          current: current,
        );
      } catch (_) {
        if (current()) secondarySubtitleFileId = null;
      }
      return;
    }
    final secondaryIndex = secondarySubtitleStreamIndex;
    if (secondaryIndex != null) {
      final stream = next.mediaSource.streamByIndex(secondaryIndex);
      if (stream == null ||
          !stream.isSubtitle ||
          (next.isTranscode &&
              _transcodeSubtitleDelivery(stream) ==
                  TranscodeSubtitleDelivery.burnIn) ||
          !current()) {
        if (current()) secondarySubtitleStreamIndex = null;
        return;
      }
      try {
        await _applySubtitleSource(
          slot: 1,
          streamIndex: secondaryIndex,
          current: current,
        );
      } catch (_) {
        if (current()) secondarySubtitleStreamIndex = null;
      }
    }
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

  Future<bool> _reopen({
    required int startTicks,
    int? subtitle,
    int? audio,
    bool subtitleOff = false,
    int? requestedBitrate,
    bool startPaused = false,
  }) async {
    final before = resolved;
    final currentOperation = _operations.current;
    PlaybackInfo? prepared;
    var nextSubtitle = subtitleOff ? null : subtitle ?? subtitleStreamIndex;
    var nextAudio = audio ?? audioStreamIndex;
    if (before?.filmTimeline != null && client is PartPlaybackProvider) {
      try {
        final profile = backend is VideoBackendCapabilities
            ? await (backend as VideoBackendCapabilities).playbackCapabilities(
                requestedBitrate ?? maxStreamingBitrate,
              )
            : null;
        prepared = await _sourceRequest<PlaybackInfo>(
          () => (client as PartPlaybackProvider).preparePart(
            itemId: itemId,
            previous: before!.mediaSource,
            position: durationFromTicks(startTicks),
            audioIndex: nextAudio,
            subtitleIndex: nextSubtitle,
            maxStreamingBitrate: requestedBitrate ?? maxStreamingBitrate,
            capabilities: profile,
          ),
        );
        if (prepared.resources != null) {
          await _persistFailedPreparation(
            prepared.resources!,
            sourceId: before!.mediaSource.id,
          );
          _pendingResourceCleanup.remove(prepared.resources);
        }
        if (!_accepts(currentOperation) || !identical(before, resolved)) {
          await _releasePrepared(prepared.resources);
          return false;
        }
        nextAudio = prepared.primarySource?.defaultAudioStreamIndex;
        nextSubtitle = prepared.primarySource?.defaultSubtitleStreamIndex;
        if (nextSubtitle != null && nextSubtitle < 0) nextSubtitle = null;
      } catch (failure) {
        if (failure is PlaybackPreparationException) {
          await _persistFailedPreparation(
            failure.resources,
            sourceId: before?.mediaSource.id,
          );
        }
        if (failure is PartTrackSelectionRequired &&
            _accepts(currentOperation) &&
            identical(before, resolved)) {
          switchConfirmation = PlaybackSwitchPlan.inspect(
            original: before!.mediaSource,
            target: failure.target,
            positionTicks: startTicks,
            paused: _pauseIntent,
            maxStreamingBitrate: requestedBitrate ?? maxStreamingBitrate,
            audioIndex: nextAudio,
            subtitleIndex: nextSubtitle,
            timelineConfirmed: true,
          );
          _switchOriginal = before;
          _switchTarget = null;
          _switchTargetItem = null;
        }
        trackFailure = 'Part playback requires selection or retry: $failure';
        _emit();
        return false;
      }
    }
    final operation = _beginOperation();
    if (operation == null || _disposed) {
      await _releasePrepared(prepared?.resources);
      return false;
    }
    final stopped = _stopSession();
    await _operations.interrupt(backend.stop);
    await stopped;
    if (!_accepts(operation)) return false;
    await _open(
      operation: operation,
      startTicks: startTicks,
      audio: nextAudio,
      subtitle: nextSubtitle,
      subtitleOff: nextSubtitle == null,
      requestedBitrate: requestedBitrate,
      startPaused: startPaused,
      preparedInfo: prepared,
    );
    return _accepts(operation) && !loading && error == null && resolved != null;
  }

  bool _ownsSession(PlaybackSession session) =>
      identical(_session, session) &&
      !session.stopped &&
      !session.revoked &&
      session.ownsCredentials &&
      (session.watchSession == null ||
          runtime?.history.sessionById(session.watchSession!.id) ==
              session.watchSession) &&
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
      resources: resolved?.resources,
      permit: origin?.permit,
      frozenStop:
          origin != null &&
              runtime?.registry.access.isProtected(
                    origin!.source.account.configuredServerId,
                  ) ==
                  true
          ? runtime!.registry.freezeStop(
              origin!.permit,
              report,
              actualClient: client,
            )
          : null,
    );
    _session = session;
    if (runtime != null && origin != null) {
      session.watchSession = await runtime!.begin(
        origin!,
        report.mediaSourceId,
      );
      if (!_ownsSession(session) || !_accepts(operation)) return;
    }
    checkIn.start();
    _sessionStarted = true;
    sessionExpired = false;
    _writeSnapshot(session, report);
    try {
      await session.enqueue(() => session.client.reportPlaying(report));
      if (!_ownsSession(session) || !_accepts(operation)) return;
      _onReportSucceeded();
      _writeSnapshot(session, report);
    } on MediaServerException catch (failure) {
      if (!_ownsSession(session) || !_accepts(operation)) return;
      _onReportFailed(failure, stage: 'playing');
    } catch (failure) {
      if (!_ownsSession(session) || !_accepts(operation)) return;
      _onReportFailed(failure, stage: 'playing');
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
    var observationSequence = session.eventSequence;
    var sent = false;
    try {
      if (_scopedPlayback && session.actuallyStarted && isPlaying) {
        final observing = _persistObservation(session);
        observationSequence = session.eventSequence;
        await observing;
        if (!_ownsSession(session)) return;
      }
      await session.observations;
      var record = session.lastRecord;
      if (runtime != null && record != null) {
        final order = record.localOrder;
        final current = runtime!.history.records().where(
          (r) => r.localOrder == order,
        );
        record = current.length == 1 ? current.single : null;
      }
      sent = true;
      if (runtime != null && record != null) {
        Object? remoteFailure;
        await runtime!.history.synchronize(record, (_, _) async {
          try {
            await session.enqueue(() => session.client.reportProgress(report));
          } catch (failure) {
            remoteFailure = failure;
            rethrow;
          }
        });
        if (remoteFailure != null) throw remoteFailure!;
      } else {
        await session.enqueue(() => session.client.reportProgress(report));
      }
      if (!_ownsSession(session)) return;
      await reportOutcomeSink?.call(report, observationSequence, true);
      _onReportSucceeded();
      _writeSnapshot(session, report);
    } on MediaServerException catch (failure) {
      if (_ownsSession(session)) {
        if (sent) {
          await reportOutcomeSink?.call(report, observationSequence, false);
        }
        _onReportFailed(failure, stage: sent ? 'progress' : 'observation');
      }
    } catch (failure) {
      if (_ownsSession(session)) {
        if (sent) {
          await reportOutcomeSink?.call(report, observationSequence, false);
        }
        _onReportFailed(failure, stage: sent ? 'progress' : 'observation');
      }
    }
  }

  Future<void> _stopSession({
    int? positionTicks,
    bool played = false,
    bool retainResources = false,
  }) {
    _progressTimer?.cancel();
    _progressTimer = null;
    final session = _session;
    if (session == null) {
      final retained = _suspendedPreparation;
      _suspendedPreparation = null;
      _suspendedPlayback = null;
      _suspendedSources = null;
      _suspendedStreamOrigin = null;
      return () async {
        // Reporting must retire its progress snapshot before lease cleanup
        // removes it, including a Back gesture during pending suspension.
        await _awaitPendingStopped();
        await _releasePrepared(retained?.resources);
      }();
    }
    final report = _currentReport(positionTicks: positionTicks);
    session.report = report;
    if (_scopedPlayback && session.actuallyStarted) {
      unawaited(
        _persistObservation(
          session,
          finalObservation: true,
          played: played,
        ).catchError((Object failure) {
          _lastProgressFailure = _syncFailure('finalObservation', failure);
          progressSyncFailed = true;
        }),
      );
    }
    session.stopped = true;
    _session = null;
    checkIn.stop();
    _sessionStarted = false;
    return _trackStopped(
      _doSendStopped(session, report, retainResources: retainResources),
    );
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
    PlaybackReport report, {
    bool retainResources = false,
  }) async {
    await _writeSnapshot(session, report, stopping: true);
    try {
      await session.observations.timeout(stoppedTimeout);
      await session
          .enqueue(() => session.client.reportStopped(report))
          .timeout(stoppedTimeout);
      if (!session.ownsCredentials) return;
      if (_session == null &&
          _snapshotOwner == session.id &&
          (_operations.current?.id == session.id ||
              _operations.isClosed ||
              _backgroundReleased)) {
        _onReportSucceeded();
      }
      await _enqueueSnapshot(() async {
        final snapshot = await snapshotStore.read();
        if (_snapshotOwner == session.id &&
            snapshot?.playSessionId == report.playSessionId &&
            snapshot?.itemId == report.itemId &&
            snapshot?.baseUrl == session.baseUrl &&
            snapshot?.userId == session.userId) {
          final pending = snapshot!.pendingCleanups;
          if (!retainResources || session.resources != null) {
            // Progress is already committed. A crash from here must retry
            // cleanup only, never replay an old Stopped position.
            await snapshotStore.write(
              snapshot.withPendingCleanups(pending, cleanupOnly: true),
            );
          } else if (pending.isEmpty) {
            await snapshotStore.delete();
          } else {
            await snapshotStore.write(
              pending.first.withPendingCleanups(pending.skip(1).toList()),
            );
          }
        }
      });
    } on MediaServerException catch (failure) {
      if (_session == null &&
          _snapshotOwner == session.id &&
          session.ownsCredentials &&
          (_operations.current?.id == session.id ||
              _operations.isClosed ||
              _backgroundReleased)) {
        _onReportFailed(failure, stage: 'stopped');
      }
    } catch (failure) {
      if (_session == null &&
          _snapshotOwner == session.id &&
          session.ownsCredentials &&
          (_operations.current?.id == session.id ||
              _operations.isClosed ||
              _backgroundReleased)) {
        _onReportFailed(failure, stage: 'stopped');
      }
    } finally {
      if (!retainResources) {
        await _releasePrepared(
          session.resources ??
              PlaybackResourceLease(
                id: report.playSessionId,
                itemId: report.itemId,
                mediaSourceId: report.mediaSourceId,
                release: () async {
                  if (session.ownsCredentials) {
                    await session.client.releasePlayback(report);
                  }
                },
              ),
        );
      }
      final watch = session.watchSession;
      if (watch != null) runtime?.history.endSession(watch);
      final frozen = session.frozenStop;
      if (frozen != null) runtime?.registry.releaseStop(frozen);
    }
  }

  void _onReportSucceeded() {
    _reportFailureStreak = 0;
    _clearProgressSyncFailed();
  }

  void _onReportFailed(Object? failure, {required String stage}) {
    _lastProgressFailure = _syncFailure(stage, failure);
    if (_operations.isClosed || _disposed) {
      progressSyncFailed = true;
      return;
    }
    if (failure is MediaServerException &&
        failure.kind == MediaServerFailureKind.sessionExpired) {
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

  Future<void> _writeSnapshot(
    PlaybackSession session,
    PlaybackReport report, {
    bool stopping = false,
  }) {
    final baseUrl = session.baseUrl;
    final userId = session.userId;
    bool ownsSnapshot() => stopping
        ? !session.revoked &&
              session.ownsCredentials &&
              (_snapshotOwner == null || _snapshotOwner! <= session.id)
        : _ownsSession(session);
    if (!ownsSnapshot() ||
        baseUrl == null ||
        userId == null ||
        userId.isEmpty) {
      return Future.value();
    }
    final snapshot = PlaybackSessionSnapshot(
      serviceType: session.client.serviceType,
      itemId: report.itemId,
      mediaSourceId: report.mediaSourceId,
      playSessionId: report.playSessionId,
      playMethod: report.playMethod,
      position: Duration(
        microseconds: (report.position.inMicroseconds * 10) ~/ 10,
      ),
      baseUrl: baseUrl,
      userId: userId,
      timestamp: DateTime.now(),
      source: (origin?.source ?? openRequest?.source) == null
          ? null
          : SourceReference(
              account: (origin?.source ?? openRequest!.source!).account,
              itemId: report.itemId,
              mediaSourceId: report.mediaSourceId,
            ),
      libraryId: origin?.libraryId ?? openRequest?.libraryId,
      accessGeneration:
          origin?.permit.accessGeneration ?? openRequest?.accessGeneration,
    );
    return _enqueueSnapshot(() async {
      if (ownsSnapshot()) {
        _snapshotOwner = session.id;
        await _replaceSnapshotPreservingCleanup(snapshot);
      }
    });
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

  Future<void> _persistObservation(
    PlaybackSession session, {
    bool finalObservation = false,
    bool played = false,
  }) {
    final watch = session.watchSession;
    final eligible = finalObservation
        ? identical(_session, session) &&
              !session.stopped &&
              !session.revoked &&
              session.ownsCredentials
        : _ownsSession(session);
    if (!_scopedPlayback ||
        !eligible ||
        !session.actuallyStarted ||
        (!isPlaying && !finalObservation)) {
      return Future.value();
    }
    final observedTicks = session.lastObservedPositionTicks;
    if (observedTicks == null) return Future.value();
    final timeline = WatchTimeline(
      durationTicks: ticksFromDuration(duration),
      edition: resolved?.mediaSource.name,
      season: item?.parentIndexNumber,
      episode: item?.indexNumber,
    );
    final sequence = ++session.eventSequence;
    final observedReport = _currentReport(positionTicks: observedTicks);
    final work = session.observations.then((_) async {
      // A normal stop drains already observed events before retiring history.
      // Revocation, unlike stop, forbids any queued observation/IPC dispatch.
      if (session.revoked || !(session.permit?.isValid ?? !_revoked)) return;
      final bool recorded;
      if (runtime != null && watch != null) {
        final record = await runtime!.history.observe(
          session: watch,
          eventSequence: sequence,
          positionTicks: observedTicks,
          actuallyPlaying: true,
          played: played,
          timeline: timeline,
        );
        recorded = record != null;
        if (record != null) session.lastRecord = record;
      } else {
        recorded = await observationSink!(
          observedReport,
          timeline,
          sequence,
          played: played,
        );
      }
      if (!recorded) throw StateError('Actual observation was not persisted');
      if (_ownsSession(session)) {
        activeMediaSourceId = session.report.mediaSourceId;
        activeOrigin = origin;
        activeLineId = pendingLineId ?? activeLineId;
        pendingLineId = null;
        pendingMediaSourceId = null;
        if (_savePreferenceAfterObservation && runtime != null) {
          await _persistSeriesPreference();
          _savePreferenceAfterObservation = false;
        }
        _emit();
      }
    });
    session.observations = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<void> _releaseRevokedResources(PlaybackSession? session) async {
    if (session != null) {
      await _enqueueSnapshot(() async {
        final snapshot = await snapshotStore.read();
        if (snapshot != null &&
            snapshot.playSessionId == session.report.playSessionId &&
            snapshot.baseUrl == session.baseUrl &&
            snapshot.userId == session.userId) {
          await snapshotStore.write(
            PlaybackSessionSnapshot.fromJson({
              ...snapshot.toJson(),
              'cleanupOnly': true,
            })!,
          );
        }
      });
      await _releasePrepared(
        session.resources ??
            PlaybackResourceLease(
              id: session.report.playSessionId,
              release: () async {},
            ),
      );
    }
    await retryResourceCleanup();
  }

  void _revokeSource() {
    final id =
        origin?.source.account.configuredServerId ??
        openRequest?.source?.account.configuredServerId;
    if (id == null ||
        (runtime?.registry.access.revokingServerId != id &&
            origin?.permit.isValid != false)) {
      return;
    }
    _revokePlayback();
  }

  Future<void> _membershipRevoked(
    SourceAccount? account,
    String serverId,
  ) async {
    if (origin?.source.account.configuredServerId != serverId &&
        _switchTarget?.source.account.configuredServerId != serverId) {
      return;
    }
    _revokePlayback();
    await Future.wait([
      _operations
          .interrupt(backend.stop, ensureRetired: true)
          .timeout(disposeTimeout),
      _releaseRevokedResources(_revokedSession),
    ]);
  }

  void _sourceRevoked(String serverId) {
    if (origin?.permit.isValid == true &&
        (_switchTarget == null || _switchTarget!.permit.isValid)) {
      return;
    }
    if (origin?.permit.isValid != false &&
        origin?.source.account.configuredServerId != serverId &&
        _switchTarget?.source.account.configuredServerId != serverId) {
      return;
    }
    _revokePlayback();
    // Private lock uses the already frozen RestrictedStop transaction. Other
    // scope revocations must stop native playback too, with no compensating
    // requests or snapshots dispatched through a revoked normal permit.
    unawaited(
      _operations
          .interrupt(backend.stop, ensureRetired: true)
          .timeout(disposeTimeout)
          .catchError((Object _) {}),
    );
    unawaited(_releaseRevokedResources(_revokedSession));
    unawaited(_deleteSubtitleCache());
  }

  void _revokePlayback() {
    if (_revoked) return;
    _revoked = true;
    _finishLineConfirmation(const PlaybackRecoveryCancelled());
    _confirmLine = null;
    _sourceRenewalOperation = null;
    _sourceRenewalRequired = false;
    isRecovering = false;
    ++_lineRevision;
    _lineBudget?.cancel();
    _revokedSession = _session;
    _revokedSession?.revoked = true;
    _session = null;
    _operations.invalidate();
    _progressTimer?.cancel();
    _nextTimer?.cancel();
    switchConfirmation = null;
    _switchOriginal = null;
    _switchTarget = null;
    _switchTargetItem = null;
    _restoreOrigin = null;
    activeOrigin = null;
    activeMediaSourceId = null;
    pendingMediaSourceId = null;
    activeLineId = null;
    pendingLineId = null;
    resolved = null;
    item = null;
    user = null;
    episodes = [];
    mediaSources = [];
    nextEpisode = null;
    isPlaying = false;
    loading = false;
    sessionExpired = true;
    _streamOrigin = Duration.zero;
    _knownBufferHeldAt = null;
    position = duration = buffer = Duration.zero;
    bufferSnapshot = BufferSnapshot.empty(
      sessionId: 0,
      unknownReason: 'revoked',
    );
    trackFailure = null;
    preferenceResolution = null;
    subtitleNotice = null;
    activeSkipSegment = null;
    _skipSegments = const [];
    state.phase = PlaybackPhase.failed;
    disconnectDetail = 'Playback permission revoked';
    unawaited(_discardNextPrefix());
    _emit();
  }

  Future<void> revokeFromHost({bool reportStopped = true}) async {
    final session = _session;
    final report = session == null ? null : _currentReport();
    _revokePlayback();
    if (session != null) session.revoked = true;
    try {
      await Future.wait([
        _operations
            .interrupt(backend.stop, ensureRetired: true)
            .timeout(disposeTimeout),
        if (reportStopped && session != null && report != null)
          session.client.stopPlayback(report).timeout(stoppedTimeout),
        _releaseRevokedResources(session),
      ]);
    } finally {
      client.clearSession();
    }
  }

  Future<void> _closeRevokedSource(ServerStopPermit permit) async {
    if (!_revoked ||
        _revokedSession?.frozenStop?.account.configuredServerId !=
            permit.serverId) {
      return;
    }
    final session = _revokedSession;
    _revokedSession = null;
    final stopped = session?.frozenStop?.reportStopped(permit);
    try {
      await Future.wait([
        _operations
            .interrupt(backend.stop, ensureRetired: true)
            .timeout(disposeTimeout)
            .then((_) {
              _revokedCleanupComplete = true;
            }),
        if (stopped != null) stopped.timeout(stoppedTimeout),
        _releaseRevokedResources(session),
        _deleteSubtitleCache(),
      ]);
      _revokedCleanupComplete = true;
    } finally {
      client.clearSession();
    }
  }

  void _terminateRevokedSource() {
    if (!_revoked) return;
    client.clearSession();
    if (_revokedCleanupComplete) return;
    unawaited(
      backend.dispose().timeout(disposeTimeout).catchError((Object _) {}),
    );
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
    subtitleSelectionNotice = null;
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
      position: Duration(
        microseconds: (positionTicks ?? ticksFromDuration(position)) ~/ 10,
      ),
      isPaused: !isPlaying,
      volumeLevel: volume,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      eventName: eventName,
    );
  }

  /// 片尾提示已经出现,或进度进入片尾/自然结束,离开时算看完。
  bool _shouldFinishCurrentEpisode() {
    final current = item;
    if (current == null || !current.isEpisode || current.userData.played) {
      return false;
    }
    if (playbackEnded || nextEpisode != null) {
      return true;
    }
    final threshold = _closingThreshold();
    if (threshold != null && position >= threshold) {
      return true;
    }
    return _reachedEpisodeEnd();
  }

  /// 片尾标记处,或无标记时片长最后约 3 分钟。短片只认自然结束。
  Duration? _closingThreshold() {
    if (duration <= Duration.zero) {
      return null;
    }
    for (final segment in _skipSegments) {
      if (segment.kind != PlayerSkipKind.outro) continue;
      if (segment.start < duration - kTrustedOutroWindow) continue;
      return segment.start;
    }
    if (duration < kMinRuntimeForEarlyNextUp) {
      return null;
    }
    final threshold = duration - kNextUpLead;
    return threshold < Duration.zero ? Duration.zero : threshold;
  }

  int _completedTicks() {
    var end = position;
    if (duration > end) end = duration;
    if (_catalogRuntime > end) end = _catalogRuntime;
    return ticksFromDuration(end);
  }

  void _showEpisodePlayed(String id) {
    if (id.isEmpty) {
      return;
    }
    episodes = [
      for (final episode in episodes)
        if (episode.id == id)
          episode.copyWith(
            userData: episode.userData.copyWith(
              played: true,
              playbackPosition: Duration(microseconds: (0) ~/ 10),
              playedPercentage: 100,
            ),
          )
        else
          episode,
    ];
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
    final playback = resolved;
    final film = playback?.filmTimeline;
    if (film != null && playback!.partIndex + 1 < film.parts.length) {
      final part = film.parts[playback.partIndex];
      final offset = playback.partOffset;
      if (offset == null || part.duration == null) {
        trackFailure = 'Part duration is unknown; cannot continue the film';
        _emit();
        return;
      }
      // A late or spurious completed event must not skip unplayed content.
      if (position + kNaturalEndTolerance < offset + part.duration!) return;
      _handlingCompleted = true;
      try {
        await _reopen(startTicks: ticksFromDuration(offset + part.duration!));
      } finally {
        _handlingCompleted = false;
      }
      return;
    }
    if (!_reachedEpisodeEnd()) return;
    _handlingCompleted = true;
    state.phase = PlaybackPhase.ended;
    state.buffering = false;
    isPlaying = false;
    controlsVisible = true;
    _hideTimer?.cancel();
    final pending = _stopSession(played: true);
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
      final next = await _sourceRequest(() => client.getNextEpisode(item!));
      if (!_accepts(operation) || next == null) {
        return;
      }
      _presentCompletedNext(next);
    } on MediaServerException {
      // 结束卡已在。
    }
  }

  void _presentCompletedNext(MediaItem next) {
    if (_disposed) {
      return;
    }
    playbackEnded = false;
    final autoplay =
        !_nextAutoplayCancelled && (user?.enableNextEpisodeAutoPlay ?? true);
    if (!autoplay) {
      nextEpisode = NextEpisodeOffer(item: next);
      _noteNextOffer();
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
    unawaited(_discardNextPrefix());
    controlsVisible = true;
    _hideTimer?.cancel();
    _emit();
  }

  int get preparedNextPrefixBytes => _nextPrefix?.storedBytes ?? 0;

  @visibleForTesting
  Future<Uint8List?> readPreparedNextPrefix() =>
      _nextPrefix?.readStored() ?? Future<Uint8List?>.value(null);

  void _noteNextOffer() {
    final next = nextEpisode?.item;
    if (next == null || _userPausedPrefix || _disposed) return;
    unawaited(_armNextPrefix(next));
  }

  Future<void> _armNextPrefix(MediaItem next) async {
    final operation = _operations.current;
    if (!_accepts(operation) || _userPausedPrefix) return;
    if (nextEpisode?.item.id != next.id) return;
    final base = client.baseUrl;
    final token = client.accessToken;
    if (base == null || token == null || token.isEmpty) return;
    PlaybackResourceLease? preparation;
    try {
      final requestClient = client;
      final profile = backend is VideoBackendCapabilities
          ? await (backend as VideoBackendCapabilities).playbackCapabilities(
              maxStreamingBitrate,
            )
          : null;
      if (!_accepts(operation) ||
          _userPausedPrefix ||
          nextEpisode?.item.id != next.id) {
        return;
      }
      final info = await _sourceRequest<PlaybackInfo>(
        () => requestClient.getPlaybackInfo(
          itemId: next.id,
          maxStreamingBitrate: maxStreamingBitrate,
          capabilities: profile,
        ),
      );
      preparation = info.resources;
      if (!_accepts(operation) ||
          _userPausedPrefix ||
          nextEpisode?.item.id != next.id) {
        return;
      }
      final resolvedPlayback = client.resolvePlayback(
        info: info,
        itemId: next.id,
        mediaSourceId: preferredPlaybackSourceId(
          sources: info.mediaSources,
          requestedName: _preferredSourceName,
        ),
      );
      if (resolvedPlayback == null || operation == null) return;
      final playback = await _expandStrm(operation, resolvedPlayback);
      if (playback == null || playback.requiresStrmExpansion) return;
      if (!_accepts(operation) || nextEpisode?.item.id != next.id) return;
      final prefix = _nextPrefix ??= NextEpisodePrefix(fetch: nextPrefixFetch);
      await prefix.start(
        itemId: next.id,
        url: playback.streamUrl,
        authorization: playback.authorization,
        headers: playbackStreamHeaders(
          streamUrl: playback.streamUrl,
          baseUrl: base,
          sessionHeaders:
              playback.authorization?.headersFor(playback.streamUrl) ??
              client.sessionHeaders,
        ),
        yieldToForeground: () => _prefixYield || cacheSpeedBytesPerSec > 0,
      );
    } catch (_) {
      // A failed prefix never changes the current episode.
    } finally {
      await _releasePrepared(preparation);
    }
  }

  Future<void> _discardNextPrefix() async {
    final prefix = _nextPrefix;
    _nextPrefix = null;
    if (prefix != null) await prefix.discard();
  }

  Future<PlayerSettingsStore> _settings() async {
    return settingsStore ??= await openPlayerSettingsStore();
  }

  /// 读取音量/倍速与按剧记忆,起播与换集前恢复。
  Future<void> _restoreSettings(PlaybackOperation operation) async {
    final volumeRevision = _volumeRevision;
    final rateRevision = _rateRevision;
    final subtitleRevision = _subtitleSettingsRevision;
    try {
      final settings = await (await _settings()).read();
      if (!_accepts(operation)) return;
      if (volumeRevision == _volumeRevision) volume = settings.clampedVolume;
      if (rateRevision == _rateRevision) {
        playbackRate = settings.effectivePlaybackRate;
      }
      if (subtitleRevision == _subtitleSettingsRevision) {
        phoneSubtitleSettings = settings.effectivePhoneSubtitles;
      }
      skipIntroEnabled = settings.isSkipIntroEnabled;
      skipOutroEnabled = settings.isSkipOutroEnabled;
      _seriesPreferences = !_scopedPlayback
          ? Map.of(settings.seriesPreferences)
          : const {};
      _itemPreferences = !_scopedPlayback
          ? Map.of(settings.itemPreferences)
          : const {};
      if (volume > 0) {
        _unmutedVolume = volume;
      }
    } catch (_) {}
  }

  void _scheduleSettingsSave() {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_writeSettings());
    });
  }

  Future<void> setSkipEnabled(PlayerSkipKind kind, bool enabled) async {
    if (kind == PlayerSkipKind.intro) {
      skipIntroEnabled = enabled;
    } else {
      skipOutroEnabled = enabled;
      if (!enabled && nextEpisode?.autoplay == false) {
        _clearNextEpisodeOffer();
      }
      // Re-enabling can offer the next episode again at the closing marker.
      if (enabled) _nextUpOffered = false;
    }
    _updateActiveSkip();
    _emit();
    try {
      await (await _settings()).writePatch(
        PlayerSettings(
          skipIntroEnabled: kind == PlayerSkipKind.intro ? enabled : null,
          skipOutroEnabled: kind == PlayerSkipKind.outro ? enabled : null,
        ),
      );
    } catch (_) {}
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
        seriesPreferences: !_scopedPlayback
            ? Map.of(_seriesPreferences)
            : const {},
        itemPreferences: !_scopedPlayback ? Map.of(_itemPreferences) : const {},
      );
      await (await _settings()).writePatch(value);
    } catch (_) {}
  }

  String get _itemPreferenceKey =>
      jsonEncode([client.baseUrl?.toString(), client.userId, itemId]);

  /// Prefer this item's exact selection, then use portable series memory.
  void _applyRememberedPreference() {
    _rememberedPreference = null;
    final seriesId = item?.seriesId;
    final preference =
        _itemPreferences[_itemPreferenceKey] ?? _seriesPreferences[seriesId];
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
    if (_suspendLinePreference) {
      // A temporary playback line must not create or rewrite source preference.
      if (_suspendLinePreference) return;
    }
    if (_scopedPlayback) {
      if (runtime == null && observationSink != null) {
        scopedPreferencePending = true;
        return;
      }
      final actual = origin;
      final version = activeMediaSourceId;
      final source = resolved?.mediaSource;
      if (runtime == null || actual == null || source == null) return;
      if (version == null ||
          version != source.id ||
          !identical(activeOrigin, actual)) {
        _savePreferenceAfterObservation = true;
        return;
      }
      final audio = audioStreamIndex == null
          ? null
          : source.streamByIndex(audioStreamIndex!);
      // 主字幕由会话导入文件占位时不记录服务器轨偏好:该偏好只描述
      // 服务器轨道,会话文件本身不持久化。
      final primaryIsSessionFile = primarySubtitleFileId != null;
      final subtitle = primaryIsSessionFile || subtitleStreamIndex == null
          ? null
          : source.streamByIndex(subtitleStreamIndex!);
      await runtime!.history.savePreference(
        SourcePreference(
          owner: actual.work,
          target: SourceReference(
            account: actual.source.account,
            itemId: itemId,
            mediaSourceId: version,
          ),
          libraryId: actual.libraryId,
          lineId: activeLineId,
          settings: PlayerSeriesPreference(
            mediaSourceId: source.id,
            audioStreamIndex: audioStreamIndex,
            audioLanguage: audio?.language,
            audioTitle: audio?.label,
            subtitleLanguage: subtitle?.language,
            subtitleTitle: subtitle?.displayTitle,
            subtitleOff: !primaryIsSessionFile && subtitleStreamIndex == null,
            maxStreamingBitrate: maxStreamingBitrate,
            mediaSourceName: source.name,
          ),
        ),
        playbackPermit: actual.permit,
      );
      return;
    }
    if (item == null) return;
    final seriesId = item?.seriesId;
    final source = resolved?.mediaSource;
    final audio = audioStreamIndex == null
        ? null
        : source?.streamByIndex(audioStreamIndex!);
    final primaryIsSessionFile = primarySubtitleFileId != null;
    final subtitle = primaryIsSessionFile || subtitleStreamIndex == null
        ? null
        : source?.streamByIndex(subtitleStreamIndex!);
    final hasSubtitles = source?.subtitleStreams.isNotEmpty ?? false;
    _preferredSourceName = _sourceFingerprint(source) ?? _preferredSourceName;
    PlayerSeriesPreference preference({
      bool exactSource = false,
    }) => PlayerSeriesPreference(
      audioStreamIndex: audioStreamIndex,
      audioLanguage: audio?.language,
      audioTitle: audio?.displayTitle ?? audio?.label,
      subtitleStreamIndex: primaryIsSessionFile ? null : subtitleStreamIndex,
      subtitleLanguage: subtitle?.language,
      subtitleTitle: subtitle?.displayTitle ?? subtitle?.label,
      subtitleOff:
          !primaryIsSessionFile && subtitleStreamIndex == null && hasSubtitles,
      maxStreamingBitrate: maxStreamingBitrate,
      mediaSourceName: _preferredSourceName,
      mediaSourceId: exactSource ? source?.id : null,
    );
    final current = preference(exactSource: true);
    _itemPreferences = {..._itemPreferences, _itemPreferenceKey: current};
    _rememberedPreference = current;
    if (seriesId != null && seriesId.isNotEmpty) {
      _seriesPreferences = {..._seriesPreferences, seriesId: preference()};
    }
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
    final rewind = (user?.resumeRewindSeconds ?? 0) * kLegacyTicksPerSecond;
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
    // Widget teardown can run with the element tree locked. Suppress observer
    // emissions before starting synchronous portions of resource retirement;
    // explicit disposeAsync still publishes stopped state while mounted.
    _disposed = true;
    _disposeLineTransactions();
    if (routeLeaseKey != null) runtime?.unmountPlayer(routeLeaseKey!);
    unawaited(_disposing ??= _disposeResources(reportStopped: false));
    runtime?.registry.access.removeRevocationHook(_revokeSource);
    runtime?.registry.access.removeCleanupHook(_closeRevokedSource);
    runtime?.registry.access.removeTerminationHook(_terminateRevokedSource);
    runtime?.registry.removeMembershipCleanup(_membershipRevoked);
    runtime?.registry.removeSourceRevocation(_sourceRevoked);
    window.removeListener(_emit);
    super.dispose();
  }
}

/// Lines of the server whose address matches the current session.
/// Session match wins; otherwise exactly one loaded server may match.
({
  List<ServerLine> lines,
  String? verifiedServerId,
  LineSelection lineSelection,
})?
serverMatchingPlayback(AuthController auth, Uri? baseUrl) {
  if (baseUrl == null) return null;
  bool matches(SavedServer server) {
    for (final line in server.lines) {
      if (Uri.tryParse(line.address) == baseUrl) return true;
    }
    return false;
  }

  final sessionServer = auth.session?.server;
  SavedServer? server;
  if (sessionServer != null && matches(sessionServer)) {
    server = sessionServer;
  } else {
    final found = [...auth.sources.project()].where(matches).toList();
    if (found.length == 1) server = found.single;
  }
  if (server == null) return null;
  return (
    lines: server.lines,
    lineSelection: server.lineSelection,
    verifiedServerId: server.verifiedServerId ?? server.id,
  );
}

String playbackLineLabel(ServerLine line) {
  final nickname = line.nickname?.trim();
  if (nickname != null && nickname.isNotEmpty) return nickname;
  return line.hostLabel;
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
    'media http 403',
    'ffmpeg core error',
    'core playback failed',
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
