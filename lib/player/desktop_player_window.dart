import '../auth/server_entry_coordinator.dart';

import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/provider_registry.dart';
import 'package:rillight/player/playback_persistence.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rillight/app/ui/ui.dart';

import 'playback_runtime.dart';
import '../aggregation/query/same_source_query.dart';
import '../aggregation/query/aggregation_query.dart';
import '../library/episode_mapping_dialog.dart';
import 'playback_resolver.dart';
import '../aggregation/history/history_writer.dart';
import 'player_settings.dart';
import '../auth/server_access.dart';

import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/app/window_geometry.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/playback_metadata.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_process_control.dart';
import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/player/player_startup.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:window_manager/window_manager.dart';

/// 播放进程窗口:隐藏系统标题栏。开窗尺寸按工作区自适应,不写死分辨率。
const WindowOptions kPlayerWindowOptions = WindowOptions(
  minimumSize: kMinPlayerWindowSize,
  center: true,
  titleBarStyle: TitleBarStyle.hidden,
);

class PlayerWindowLaunch {
  static const businessId = 'player';

  const PlayerWindowLaunch({
    required this.request,
    this.serviceType = MediaServerType.emby,
    required this.baseUrl,
    required this.accessToken,
    required this.userId,
    required this.device,
    this.userAgent,
    this.protocol,
    this.accessGeneration,
    this.preparedStartup = false,
    this.entryPending = false,
    this.lines = const [],
    this.verifiedServerId,
    this.startupHandoff,
  });

  final PlayerOpenRequest request;
  final MediaServerType serviceType;
  final String baseUrl;
  final String accessToken;
  final String userId;
  final ClientDeviceInfo device;
  final String? userAgent;
  final PlayerProcessProtocol? protocol;
  final int? accessGeneration;
  final bool preparedStartup;
  final bool entryPending;
  final List<ServerLine> lines;
  final String? verifiedServerId;

  /// Negotiated metadata the parent already holds (item, user, versions).
  /// Embedded in the launch document so the child skips its serial discovery
  /// without waiting on the startup mailbox.
  final Map<String, dynamic>? startupHandoff;

  factory PlayerWindowLaunch.fromAuth({
    required AuthController auth,
    required PlayerOpenRequest request,
    bool preparedStartup = false,
  }) {
    final client = auth.client;
    final baseUrl = client.baseUrl;
    final token = client.accessToken;
    final userId = client.userId;
    if (baseUrl == null || token == null || token.isEmpty || userId == null) {
      throw StateError('没有可用的登录会话，无法打开播放窗口');
    }
    final matched = serverMatchingPlayback(auth, baseUrl);
    return PlayerWindowLaunch(
      request: request,
      baseUrl: baseUrl.toString(),
      accessToken: token,
      userId: userId,
      device: client.device,
      serviceType: client.serviceType,
      userAgent: client.customUserAgent,
      preparedStartup: preparedStartup,
      lines: matched?.lines ?? const [],
      verifiedServerId: matched?.verifiedServerId,
    );
  }

  factory PlayerWindowLaunch.fromArguments(String arguments) {
    if (arguments.trim().isEmpty) {
      throw const FormatException('empty player window arguments');
    }
    return PlayerWindowLaunch.fromJson(
      jsonDecode(arguments) as Map<String, dynamic>,
    );
  }

  factory PlayerWindowLaunch.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('regionGeneration')) {
      throw const FormatException('Obsolete player authorization');
    }
    if (json['schema'] != null && json['schema'] != 2) {
      throw const FormatException('Unknown player launch schema');
    }
    final name = json['serviceType'] as String? ?? 'emby';
    final type = MediaServerType.values
        .where((type) => type.name == name)
        .firstOrNull;
    if (type == null) throw const FormatException('Unknown media service');
    final launch = PlayerWindowLaunch(
      serviceType: type,
      request: PlayerOpenRequest(
        itemId: json['itemId'] as String? ?? '',
        source: json['source'] is Map
            ? decodeAuthorizedSource(
                Map<String, dynamic>.from(json['source'] as Map),
              )
            : null,
        work: json['work'] is Map
            ? decodeAuthorizedSource(
                Map<String, dynamic>.from(json['work'] as Map),
              )
            : null,
        libraryId: json['libraryId'] as String?,
        startPaused: json['startPaused'] == true,
        subtitleOff: json['subtitleOff'] == true,
        maxStreamingBitrate: json['maxStreamingBitrate'] as int?,
        accessGeneration: json['accessGeneration'] as int?,
        autoResume: json['autoResume'] != false,
        mediaSourceId: json['mediaSourceId'] as String?,
        audioStreamIndex: json['audioStreamIndex'] is int
            ? json['audioStreamIndex'] as int
            : int.tryParse('${json['audioStreamIndex'] ?? ''}'),
        subtitleStreamIndex: json['subtitleStreamIndex'] is int
            ? json['subtitleStreamIndex'] as int
            : int.tryParse('${json['subtitleStreamIndex'] ?? ''}'),
        startPosition: json['startUs'] is int
            ? Duration(microseconds: json['startUs'] as int)
            : json['startTimeTicks'] is int
            ? durationFromTicks(json['startTimeTicks'] as int)
            : null,
        secondarySubtitleStreamIndex:
            json['secondarySubtitleStreamIndex'] is int
            ? json['secondarySubtitleStreamIndex'] as int
            : int.tryParse('${json['secondarySubtitleStreamIndex'] ?? ''}'),
      ),
      accessGeneration: json['accessGeneration'] as int?,
      baseUrl: json['baseUrl'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      userAgent: json['userAgent'] as String?,
      preparedStartup: json['preparedStartup'] == true,
      entryPending: json['entryPending'] == true,
      verifiedServerId: json['verifiedServerId'] as String?,
      lines: [
        for (final item in json['lines'] as List? ?? const [])
          if (item is Map) ServerLine.fromJson(Map<String, dynamic>.from(item)),
      ],
      protocol: json['processSessionId'] == null
          ? null
          : PlayerProcessProtocol.fromJson(json),
      startupHandoff: json['startupHandoff'] is Map
          ? Map<String, dynamic>.from(json['startupHandoff'] as Map)
          : null,
      device: ClientDeviceInfo(
        clientName: json['clientName'] as String? ?? kHttpClientName,
        deviceName: json['deviceName'] as String? ?? 'desktop',
        deviceId: json['deviceId'] as String? ?? 'rillight-player',
        version: json['version'] as String? ?? kAppVersion,
      ),
    );
    final account = launch.request.source?.account;
    if (account != null &&
        (account.serviceType != type || account.userId != launch.userId)) {
      throw const FormatException('Player source identity mismatch');
    }
    return launch;
  }

  Map<String, dynamic> toJson() {
    return {
      'businessId': businessId,
      if (request.source != null) 'source': encodeSource(request.source!),
      if (request.work != null) 'work': encodeSource(request.work!),
      if (request.libraryId != null) 'libraryId': request.libraryId,
      if (accessGeneration != null) 'accessGeneration': accessGeneration,
      if (preparedStartup) 'preparedStartup': true,
      if (entryPending) 'entryPending': true,
      ...?protocol?.fields,
      'itemId': request.itemId,
      'autoResume': request.autoResume,
      'startPaused': request.startPaused,
      'subtitleOff': request.subtitleOff,
      if (request.maxStreamingBitrate != null)
        'maxStreamingBitrate': request.maxStreamingBitrate,
      if (request.mediaSourceId != null) 'mediaSourceId': request.mediaSourceId,
      if (request.audioStreamIndex != null)
        'audioStreamIndex': request.audioStreamIndex,
      if (request.subtitleStreamIndex != null)
        'subtitleStreamIndex': request.subtitleStreamIndex,
      if (request.startPosition != null)
        'startUs': request.startPosition!.inMicroseconds,
      'serviceType': serviceType.name,
      'schema': 2,
      if (request.secondarySubtitleStreamIndex != null)
        'secondarySubtitleStreamIndex': request.secondarySubtitleStreamIndex,
      'baseUrl': baseUrl,
      'accessToken': accessToken,
      'userId': userId,
      if (startupHandoff != null) 'startupHandoff': startupHandoff,
      if (verifiedServerId != null) 'verifiedServerId': verifiedServerId,
      if (lines.isNotEmpty) 'lines': [for (final line in lines) line.toJson()],
      if (userAgent != null) 'userAgent': userAgent,
      'clientName': device.clientName,
      'deviceName': device.deviceName,
      'deviceId': device.deviceId,
      'version': device.version,
    };
  }

  String toArguments() => jsonEncode(toJson());
}

/// 按播放进程 pid 定位其会话快照存储。
typedef PlaybackSnapshotStoreLocator = PlaybackSessionSnapshotStore Function(
  int pid,
);

typedef PlayerHostOpenItemConsumer =
    Future<PlayerHostOpenItemCommand?> Function();

/// 独立播放进程宿主。
///
/// 关闭顺序:先 [PlayerProcessControl.requestClose](会话 close 消息,播放进程
/// 自行发 Stopped),超时再 [PlayerProcessControl.kill];进程终止或意外
/// 退出后读取其会话快照,快照仍在(播放进程未能成功发出 Stopped)且归属
/// 当前会话时由主进程代发 Stopped,成功后删除快照,失败则保留并通过
/// [notices] 提示主窗口。
class DesktopPlayerWindowHost extends PlayerWindowHost {
  DesktopPlayerWindowHost({
    required this.auth,
    this.runtime,
    this.requestSourcePassword,
    PlayerProcessControl? processControl,
    this._snapshotStoreForPid,
    this._consumeOpenItem,
    this.closeTimeout = const Duration(seconds: 1),
    this.reportTimeout = const Duration(seconds: 3),
    this.watchInterval = const Duration(milliseconds: 400),
    this.entryOpenTimeout = const Duration(seconds: 150),
  }) : _control = processControl ?? createPlayerProcessControl() {
    auth.addListener(_onAuth);
    auth.serverAccess.addRevocationHook(_revokePrivate);
    auth.serverAccess.addCleanupHook(_closePrivate);
    auth.serverAccess.addTerminationHook(_terminatePrivate);
    runtime?.registry.addMembershipCleanup(_membershipRevoked);
    runtime?.registry.addSourceRevocation(_sourceRevoked);
  }

  final AuthController auth;
  final PlaybackRuntime? runtime;
  final Future<String?> Function(SavedServer server)? requestSourcePassword;
  ServerEntryTicket? _switchEntry;
  PlaybackOrigin? _origin;
  WatchSession? _watchSession;
  bool _privateRevoked = false;
  int _lastIpcEvent = -1;
  int _closingObservationPid = 0;
  Future<void> _observationTail = Future<void>.value();
  int _lastSwitchCommand = -1;
  int? _lastObservationSequence;
  ({
    PlaybackOrigin target,
    PlaybackOrigin original,
    PlaybackSwitchPlan plan,
    PlayerOpenRequest restore,
    String? line,
  })?
  _pendingSwitch;
  ({PlaybackOrigin origin, PlayerOpenRequest request})? _restoreSwitch;
  @override
  String? switchFailure;
  bool _saveSwitchPreference = false;

  /// 播放器进程请求主窗口打开条目详情(如播放结束"查看剧集")。
  void Function(
    String itemId, {
    String? seasonId,
    PlayerHostOpenItemCommand? command,
  })?
  onOpenItemRoute;

  /// 等待播放进程响应会话 close 消息并自行退出的上限。
  final Duration closeTimeout;

  /// 主进程代发 Stopped 的上限。
  final Duration reportTimeout;

  /// 探测播放进程是否仍存活的轮询间隔。
  final Duration watchInterval;
  final Duration entryOpenTimeout;
  ServerEntryTicket? _pendingEntry;
  Timer? _entryOpenTimer;

  final PlayerProcessControl _control;
  final PlaybackSnapshotStoreLocator? _snapshotStoreForPid;
  final PlayerHostOpenItemConsumer? _consumeOpenItem;
  final _notices = StreamController<PlayerHostNotice>.broadcast();
  int _pid = 0;
  Timer? _watch;
  PlayerOpenRequest? _current;
  var _disposed = false;
  var _epoch = 0;
  var _requestRevision = 0;
  int _activeRevision = 0;
  bool _watchBusy = false;
  bool _heartbeatBusy = false;
  bool _urgentLockBusy = false;
  String? _authIdentity;
  PlayerStartupPreparation? _startupPreparation;
  bool _opening = false;
  String get _currentAuthIdentity =>
      '${auth.client.serviceType.name}|${auth.client.baseUrl}|${auth.client.userId}|${auth.client.accessToken}';

  /// 串行化 open/close 与 watcher 代发,避免 close 清掉后开的 pid,
  /// 并让 close() 等到在途 reconcile 结束后再回到登出。
  Future<void> _inFlight = Future<void>.value();

  @override
  PlayerOpenRequest? get current => _current;

  @override
  bool get playbackOccupied => _opening || _pid != 0 || _current != null;

  @override
  bool get embedsPlayerInCaller => false;

  @override
  Stream<PlayerHostNotice> get notices => _notices.stream;

  Future<void> prepare() async {
    if (!Platform.isWindows ||
        _disposed ||
        _opening ||
        _pid != 0 ||
        !auth.isLoggedIn) {
      return;
    }
    await _control.prepare(executable: Platform.resolvedExecutable);
  }

  @override
  Future<void> open(PlayerOpenRequest request) {
    _pendingEntry?.cancel();
    _pendingEntry = null;
    _entryOpenTimer?.cancel();
    _switchEntry?.cancel();
    _switchEntry = null;
    _pendingSwitch = null;
    _restoreSwitch = null;
    switchFailure = null;
    return _openWithOrigin(request);
  }

  Future<void> _openWithOrigin(
    PlayerOpenRequest request, {
    PlaybackOrigin? prepared,
    ServerEntryTicket? entry,
  }) {
    final revision = ++_requestRevision;
    _opening = true;
    if (!_disposed) notifyListeners();
    _control.cancelPendingSpawns();
    return _runInFlight(() async {
      if (_disposed || revision != _requestRevision) return;
      late PlayerWindowLaunch launch;
      PlaybackOrigin? resolvedOrigin;
      Map<String, dynamic>? handoff;
      if (runtime != null && request.source != null) {
        final origin = prepared ?? await runtime!.resolve(request);
        origin.permit.requireValid();
        if (_disposed || revision != _requestRevision) return;
        resolvedOrigin = origin;
        // The child needs the user record for stream preferences; overlap it
        // with version negotiation instead of the child re-fetching serially.
        final userFuture = origin.permit
            .dispatch((_) => origin.client.getUser())
            .then<MediaUser?>((value) => value, onError: (Object _) => null);
        final item = prepared == null && origin.resolvedItem != null
            ? origin.resolvedItem!
            : await origin.permit.dispatch(
                (_) => origin.client.getItem(request.itemId),
              );
        final sourceClient = origin.client;
        var versions = sourceClient is PlaybackMetadataProvider
            ? await origin.permit.dispatch(
                (_) => (sourceClient as PlaybackMetadataProvider)
                    .getPlaybackSources(
                      itemId: request.itemId,
                      position:
                          request.startPosition ??
                          (request.autoResume
                              ? item.resumePosition
                              : Duration.zero),
                    ),
              )
            : playbackSourcesFromItem(item);
        // Emby/Jellyfin detail metadata already contains the versions. Only
        // legacy responses without that metadata need discovery negotiation.
        // The child owns the final negotiated session and selected tracks.
        if (versions.isEmpty && sourceClient is! PlaybackMetadataProvider) {
          final info = await origin.permit.dispatch(
            (_) => sourceClient.getPlaybackInfo(itemId: request.itemId),
          );
          versions = info.mediaSources;
          await info.resources?.release();
        }
        // Hand the negotiated metadata to the child: it skips its own serial
        // item/user/source discovery and only runs PlaybackInfo for tracks.
        MediaUser? handoffUser;
        try {
          handoffUser = await userFuture;
        } catch (_) {}
        if (_disposed || revision != _requestRevision) return;
        handoff = await PlayerStartupPreparation.handoff(
          userId: origin.source.account.userId,
          itemId: request.itemId,
          item: item,
          user: handoffUser,
          versions: versions,
        ).payload;
        if (entry == null) {
          await runtime!.importLegacyPreferences(
            origin,
            item,
            versions,
            await (await openPlayerSettingsStore()).read(),
          );
        }
        if (_disposed || revision != _requestRevision) return;
        final pref = runtime!.preference(origin, item, versions);
        final usePreference =
            request.mediaSourceId == null && pref.failure == null;
        if (request.mediaSourceId == null &&
            pref.failure != null &&
            pref.failure != PreferenceFailure.notConfigured) {
          throw StateError(
            'Source preference requires selection: ${pref.failure}',
          );
        }
        final settings = usePreference ? pref.preference?.settings : null;
        final version =
            request.mediaSourceId ??
            (usePreference ? pref.selected?.source.mediaSourceId : null);
        final sources = versions.where((s) => s.id == version);
        final media = sources.length == 1 ? sources.single : null;
        final lines = runtime!.registry
            .project()
            .firstWhere((s) => s.id == origin.source.account.configuredServerId)
            .lines;
        if (usePreference &&
            pref.preference?.lineId != null &&
            !lines.any(
              (l) =>
                  l.id == pref.preference!.lineId &&
                  Uri.parse(l.address) == origin.client.baseUrl,
            )) {
          throw StateError('Saved line requires explicit switch');
        }
        launch = PlayerWindowLaunch(
          request: PlayerOpenRequest(
            itemId: request.itemId,
            autoResume: request.autoResume,
            source: origin.source,
            work: origin.work,
            libraryId: origin.libraryId,
            mediaSourceId: version,
            audioStreamIndex:
                request.audioStreamIndex ??
                (media == null
                    ? null
                    : matchPreferredStreamIndex(
                        streams: media.audioStreams,
                        preferredIndex: settings?.mediaSourceId == media.id
                            ? settings?.audioStreamIndex
                            : null,
                        exactIndex: settings?.mediaSourceId == media.id,
                        language: settings?.audioLanguage,
                        title: settings?.audioTitle,
                      )),
            subtitleStreamIndex:
                request.subtitleStreamIndex ??
                (media == null
                    ? null
                    : matchPreferredStreamIndex(
                        streams: media.subtitleStreams,
                        language: settings?.subtitleLanguage,
                        title: settings?.subtitleTitle,
                      )),
            startPosition: request.startPosition,
            startPaused: request.startPaused,
            secondarySubtitleStreamIndex: request.secondarySubtitleStreamIndex,
            subtitleOff: request.subtitleOff || settings?.subtitleOff == true,
            maxStreamingBitrate:
                request.maxStreamingBitrate ?? settings?.maxStreamingBitrate,
            accessGeneration: origin.permit.accessGeneration,
          ),
          baseUrl: origin.client.baseUrl!.toString(),
          accessToken: origin.client.accessToken!,
          userId: origin.source.account.userId,
          device: origin.client.device,
          serviceType: origin.client.serviceType,
          userAgent: origin.client.customUserAgent,
          accessGeneration: origin.permit.accessGeneration,
          lines: lines,
          verifiedServerId: origin.source.account.verifiedServerId,
          startupHandoff: handoff,
          entryPending: entry != null,
        );
      } else {
        launch = PlayerWindowLaunch.fromAuth(
          auth: auth,
          request: request,
          preparedStartup: true,
        );
      }
      if (_disposed || revision != _requestRevision) return;
      // Begin closing the previous child now; its exit wait overlaps the
      // startup preparation's network round trips instead of serializing
      // before them.
      final stopping = _stopProcess();
      // Scoped sources keep permission-checked metadata dispatch in the
      // existing runtime path. Do not prefetch them through auth.client.
      // Scoped launches embed their handoff in the launch document instead.
      final preparation = _startupPreparation = resolvedOrigin == null
          ? PlayerStartupPreparation(auth.client, request.itemId)
          : null;
      try {
        await stopping;
        if (_disposed || revision != _requestRevision) {
          preparation?.cancel();
          return;
        }
        // Final observations and snapshot recovery belong to the retiring
        // child until shutdown has completed.
        resolvedOrigin?.permit.requireValid();
        _origin = resolvedOrigin;
        _watchSession = null;
        _lastIpcEvent = -1;
        _lastSwitchCommand = -1;
        _lastObservationSequence = null;
        _privateRevoked = false;
        final pid = await _control.spawn(
          executable: Platform.resolvedExecutable,
          arguments: launch.toArguments(),
          startup: preparation?.payload,
        );
        if (_disposed ||
            revision != _requestRevision ||
            (_origin != null
                ? !_origin!.permit.isValid
                : (auth.client.baseUrl?.toString() != launch.baseUrl ||
                      auth.client.userId != launch.userId ||
                      auth.client.accessToken != launch.accessToken))) {
          preparation?.cancel();
          await _control.kill(pid);
          await _reconcileSnapshot(pid);
          await _control.release(pid);
          return;
        }
        _pid = pid;
        _activeRevision = revision;
        _authIdentity = _currentAuthIdentity;
        _epoch++;
        _current = launch.request;
        _pendingEntry = entry;
        _entryOpenTimer?.cancel();
        if (entry != null) {
          _entryOpenTimer = Timer(entryOpenTimeout, () {
            if (identical(_pendingEntry, entry) && _pid == pid) {
              unawaited(_rejectPendingEntry('Target playback open timed out'));
            }
          });
        }
        notifyListeners();
        _startWatch(pid);
      } catch (error) {
        entry?.cancel();
        preparation?.cancel();
        if (error is PlayerProcessStartupException) {
          await _reconcileSnapshot(error.pid);
          await _control.release(error.pid);
        }
        if (!_disposed && revision == _requestRevision) _clearWindow();
        rethrow;
      }
    }).whenComplete(() {
      if (revision == _requestRevision) {
        _opening = false;
        if (!_disposed) notifyListeners();
      }
    });
  }

  Future<void> _rejectPendingEntry(String message) async {
    final entry = _pendingEntry;
    if (entry == null) return;
    _pendingEntry = null;
    _entryOpenTimer?.cancel();
    entry.cancel();
    await _runInFlight(_stopProcess);
    if (!_disposed && _restoreSwitch?.origin.permit.isValid == true) {
      try {
        await restoreOriginalSource();
      } catch (_) {
        /* Keep retryable A. */
      }
    }
    if (!_disposed) {
      switchFailure = message;
      notifyListeners();
    }
  }

  @override
  bool get canRestoreOriginal =>
      _restoreSwitch?.origin.permit.isValid == true && !_privateRevoked;
  @override
  Future<void> restoreOriginalSource() async {
    final original = _restoreSwitch;
    if (original == null || !canRestoreOriginal) {
      throw StateError('Original source unavailable');
    }
    original.origin.permit.requireValid();
    try {
      await _openWithOrigin(original.request, prepared: original.origin);
      if (!identical(_restoreSwitch, original) || _privateRevoked) return;
      switchFailure = null;
      _restoreSwitch = null;
      notifyListeners();
    } catch (error) {
      if (identical(_restoreSwitch, original) && !_privateRevoked) {
        switchFailure = '$error';
        notifyListeners();
      }
      rethrow;
    }
  }

  @override
  Future<void> close() {
    _pendingEntry?.cancel();
    _pendingEntry = null;
    _switchEntry?.cancel();
    _switchEntry = null;
    _entryOpenTimer?.cancel();
    final revision = ++_requestRevision;
    _control.cancelPendingSpawns(includePrepared: true);
    return _runInFlight(() async {
      final epoch = _epoch;
      await _stopProcess();
      await _control.discardPrepared();
      if (revision == _requestRevision) _opening = false;
      if (_epoch == epoch) _clearWindow();
      if (!_disposed) notifyListeners();
    });
  }

  @override
  Future<void> forceClose() async {
    _pendingEntry?.cancel();
    _pendingEntry = null;
    _switchEntry?.cancel();
    _switchEntry = null;
    _entryOpenTimer?.cancel();
    _startupPreparation?.cancel();
    _startupPreparation = null;
    _requestRevision++;
    _control.cancelPendingSpawns(includePrepared: true);
    _watch?.cancel();
    await _control.terminateAll();
    for (final pid in _control.activePids.toList()) {
      await _reconcileSnapshot(pid);
      await _control.release(pid);
    }
    _opening = false;
    _clearWindow();
    if (!_disposed) notifyListeners();
  }

  Future<void> _runInFlight(Future<void> Function() action) {
    final run = _inFlight.then((_) => action());
    _inFlight = run.then((_) {}, onError: (_, _) {});
    return run;
  }

  void _onAuth() {
    if (runtime != null && _origin != null) {
      if (!_origin!.permit.isValid) unawaited(close());
      return;
    }
    if (!auth.isLoggedIn ||
        (_authIdentity != null && _authIdentity != _currentAuthIdentity)) {
      unawaited(close());
    } else if (_pid == 0) {
      unawaited(prepare());
    }
  }

  void _startWatch(int pid) {
    _watch?.cancel();
    final epoch = _epoch;
    _watch = Timer.periodic(watchInterval, (timer) {
      if (_disposed) return;
      // This mailbox bypasses a potentially stalled catalogue/preflight watch.
      if (!_urgentLockBusy) unawaited(_consumeUrgentLock(pid));
      // Server verification may outlast the child's heartbeat deadline. Keep
      // liveness independent of the serialized observation/command queue.
      if (!_heartbeatBusy) {
        _heartbeatBusy = true;
        unawaited(() async {
          try {
            await _control.heartbeat(pid);
          } catch (_) {
            // Close may remove the endpoint while this write is in flight.
          } finally {
            _heartbeatBusy = false;
          }
        }());
      }
      if (_watchBusy) return;
      _watchBusy = true;
      unawaited(() async {
        try {
          await _consumeObservation(pid);
          await _consumeReportOutcome(pid);
          await _consumeSwitchCommand(pid);
          await _deliverOpenItem(pid, epoch);
          if (_control.isAlive(pid)) return;
          timer.cancel();
          if (_watch == timer) _watch = null;
          await _runInFlight(() async {
            if (_pid != pid || _epoch != epoch) return;
            // The process is already gone. Clear presentation immediately,
            // but retain its origin until the serialized reconciliation ends.
            _current = null;
            await _reconcileSnapshot(pid);
            await _control.release(pid);
            final watch = _watchSession;
            if (watch != null) runtime?.history.endSession(watch);
            _watchSession = null;
            _clearWindow();
            if (_pendingEntry == null) unawaited(prepare());
          });
          if (_pendingEntry != null) {
            await _rejectPendingEntry(
              'Target player exited before successful open',
            );
          }
        } catch (_) {
          // A close may remove the mailbox while a watcher read is in flight.
        } finally {
          _watchBusy = false;
        }
      }());
    });
  }

  Future<void> _stopProcess() async {
    _startupPreparation?.cancel();
    _startupPreparation = null;
    _watch?.cancel();
    _watch = null;
    final pid = _pid;
    final epoch = _epoch;
    _pid = 0;
    if (pid == 0) return;
    _closingObservationPid = pid;
    var closed = false;
    try {
      if (runtime == null || _control is! PlayerHistoryProcessControl) {
        closed = await _control.requestClose(pid, closeTimeout);
      } else {
        var finished = false;
        final closing = _control
            .requestClose(pid, closeTimeout)
            .timeout(closeTimeout + const Duration(milliseconds: 100))
            .then((value) {
              closed = value;
            }, onError: (Object _) {})
            .whenComplete(() {
              finished = true;
            });
        while (!finished) {
          await _consumeObservation(pid);
          if (!finished) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        await closing;
      }
    } catch (_) {}
    if (!closed) await _control.kill(pid);
    await _observationTail.timeout(reportTimeout);
    await _deliverOpenItem(pid, epoch);
    await _reconcileSnapshot(pid);
    await _control.release(pid);
    final watch = _watchSession;
    if (watch != null) runtime?.history.endSession(watch);
    _watchSession = null;
    _closingObservationPid = 0;
  }

  Future<void> _deliverOpenItem(int pid, int epoch) async {
    final command =
        await (_consumeOpenItem?.call() ?? _control.consumeOpenItem(pid));
    if (command == null ||
        command.itemId.isEmpty ||
        _disposed ||
        epoch != _epoch ||
        _activeRevision != _requestRevision ||
        (_pid != 0 && _pid != pid)) {
      return;
    }
    final actual = _origin;
    if (actual != null) {
      final account = command.source?.account;
      // 库 id 和普通区代数可以和正在播放的来源不一致。私有区代数仍必须相同，
      // 失效的播放许可也不能把详情交回主窗口。
      final privateGenerationRejected =
          account != null &&
          auth.serverAccess.isProtected(account.configuredServerId) &&
          command.accessGeneration != actual.permit.accessGeneration;
      if (!actual.permit.isValid ||
          account != actual.source.account ||
          privateGenerationRejected ||
          command.itemId != actual.work.itemId) {
        return;
      }
    } else if (command.source != null) {
      return;
    }
    onOpenItemRoute?.call(
      command.itemId,
      seasonId: command.seasonId,
      command: command,
    );
  }

  /// 播放进程已终止:快照仍在时用主进程会话代发 Stopped。
  ///
  /// 播放进程成功发出 Stopped 后删除快照可能仍在途,此处重复代发是
  /// 幂等的,不视为错误。快照归属其他服务器/用户时不代发。
  Future<void> _reconcileSnapshot(int pid) async {
    if (_snapshotStoreForPid == null && !_control.activePids.contains(pid)) {
      return;
    }
    final store =
        _snapshotStoreForPid?.call(pid) ?? _control.snapshotStore(pid);
    final snapshot = await store.read();
    if (snapshot == null) {
      return;
    }
    if (runtime != null && (snapshot.source != null || _origin != null)) {
      if (_privateRevoked ||
          snapshot.source == null ||
          snapshot.source!.account != _origin?.source.account ||
          snapshot.accessGeneration != _origin?.permit.accessGeneration) {
        if (snapshot.pendingCleanups.isEmpty) await store.delete();
        return;
      }
      await runtime!.recoverSnapshot(snapshot, persistRetry: store.write);
      await store.delete();
      return;
    }
    final client = auth.client;
    if (snapshot.serviceType != client.serviceType ||
        snapshot.baseUrl != client.baseUrl?.toString() ||
        snapshot.userId != client.userId) {
      return;
    }
    final token = client.accessToken;
    if (token == null || token.isEmpty) return;
    final frozen = client.withRequestGuard(() {
      if (client.serviceType != snapshot.serviceType ||
          client.baseUrl?.toString() != snapshot.baseUrl ||
          client.userId != snapshot.userId ||
          client.accessToken != token) {
        throw StateError('Playback compensation identity revoked');
      }
    });
    try {
      for (final pending in snapshot.validatedPendingCleanups) {
        if (pending.serviceType != snapshot.serviceType ||
            pending.baseUrl != snapshot.baseUrl ||
            pending.userId != snapshot.userId) {
          throw StateError(
            'Pending playback cleanup needs its source authority',
          );
        }
        await frozen
            .releasePlayback(playbackReportFromSnapshot(pending))
            .timeout(reportTimeout);
      }
      final report = playbackReportFromSnapshot(snapshot);
      await (snapshot.cleanupOnly
              ? frozen.releasePlayback(report)
              : frozen.stopPlayback(report))
          .timeout(reportTimeout);
    } catch (_) {
      _notify(PlayerHostNotice.progressSyncFailed);
      return;
    } finally {
      frozen.clearSession();
    }
    if (client.accessToken == token &&
        snapshot.baseUrl == client.baseUrl?.toString() &&
        snapshot.userId == client.userId) {
      await store.delete();
    }
  }

  Future<void> _consumeObservation(int pid) {
    final next = _observationTail.then((_) => _doConsumeObservation(pid));
    _observationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _doConsumeObservation(int pid) async {
    final control = _control;
    final origin = _origin;
    if (control is! PlayerHistoryProcessControl ||
        runtime == null ||
        origin == null) {
      return;
    }
    if (pid != _pid && pid != _closingObservationPid) return;
    final historyControl = control as PlayerHistoryProcessControl;
    final event = await historyControl.consumeWatchEvent(pid);
    if (event == null) return;
    final sequence = event['sequence'];
    var accepted = false;
    try {
      if (sequence is! int ||
          sequence <= _lastIpcEvent ||
          event['pid'] != pid ||
          event['generation'] != origin.permit.accessGeneration ||
          event['source'] is! Map ||
          decodeAuthorizedSource(
                Map<String, dynamic>.from(event['source'] as Map),
              ).account !=
              origin.source.account ||
          event['item'] !=
              decodeAuthorizedSource(
                Map<String, dynamic>.from(event['source'] as Map),
              ).itemId ||
          _privateRevoked) {
        throw StateError('Stale or foreign playback event');
      }
      origin.permit.requireValid();
      if (_pendingEntry != null) {
        throw StateError('Target has not opened successfully');
      }
      final version = event['version'] as String;
      if (_watchSession?.source.mediaSourceId != version ||
          _watchSession?.source.itemId != event['item']) {
        // A new episode/version needs authoritative server reads. Receiving
        // the event is not acceptance, but lets the child wait for that work.
        await historyControl.acknowledgeWatchEvent(pid, {
          'sequence': sequence,
          'pending': true,
        });
        final actual = await runtime!.resolveItem(
          origin,
          event['item'] as String,
          mediaSourceId: version,
        );
        final info = await actual.permit.dispatch(
          (_) => origin.client.getPlaybackInfo(itemId: actual.source.itemId),
        );
        if (!info.mediaSources.any((s) => s.id == version)) {
          throw StateError('Unknown actual version');
        }
        if (!identical(_origin, origin) ||
            (pid != _pid && pid != _closingObservationPid)) {
          throw StateError('Player process superseded');
        }
        _watchSession = await runtime!.begin(actual, version);
      }
      final record = await runtime!.history.observe(
        session: _watchSession!,
        eventSequence: sequence,
        positionTicks: event['position'] as int,
        actuallyPlaying: event['actuallyPlaying'] == true,
        played: event['played'] == true,
        timeline: WatchTimeline.fromJson(
          Map<String, dynamic>.from(event['timeline'] as Map),
        ),
      );
      accepted =
          record != null &&
          origin.permit.isValid &&
          !_privateRevoked &&
          identical(_origin, origin) &&
          (pid == _pid || pid == _closingObservationPid);
      if (accepted &&
          (event['savePreference'] == true || _saveSwitchPreference)) {
        final settings = PlayerSeriesPreference.fromJson(
          Map<String, dynamic>.from(event['settings'] as Map),
        );
        final lines = runtime!.registry
            .project()
            .firstWhere((s) => s.id == origin.source.account.configuredServerId)
            .lines;
        final currentLines = lines.where(
          (l) => Uri.parse(l.address) == origin.client.baseUrl,
        );
        await runtime!.history.savePreference(
          SourcePreference(
            owner: origin.work,
            target: _watchSession!.source,
            libraryId: origin.libraryId,
            lineId: currentLines.length == 1 ? currentLines.single.id : null,
            settings: settings,
          ),
          playbackPermit: origin.permit,
        );
        _saveSwitchPreference = false;
      }
      if (accepted) {
        _lastIpcEvent = sequence;
        _lastObservationSequence = event['observationSequence'] as int?;
      }
    } catch (_) {
      /* No remote report on rejected observation. */
    }
    await historyControl.acknowledgeWatchEvent(pid, {
      'sequence': sequence,
      'accepted': accepted,
    });
  }

  Future<void> _consumeReportOutcome(int pid) async {
    final control = _control;
    final origin = _origin;
    final session = _watchSession;
    if (control is! PlayerHistoryProcessControl ||
        runtime == null ||
        origin == null ||
        session == null ||
        pid != _pid ||
        _privateRevoked) {
      return;
    }
    final outcome = await (control as PlayerHistoryProcessControl)
        .consumeReportOutcome(pid);
    if (outcome == null ||
        !origin.permit.isValid ||
        outcome['pid'] != pid ||
        outcome['generation'] != origin.permit.accessGeneration ||
        outcome['sequence'] != _lastObservationSequence ||
        outcome['item'] != session.source.itemId ||
        outcome['version'] != session.source.mediaSourceId) {
      return;
    }
    final records = runtime!.history.records().where(
      (r) => r.sessionId == session.id && r.source == session.source,
    );
    if (records.length != 1) return;
    await runtime!.history.synchronize(records.single, (_, _) async {
      // The helper already dispatched the report. Never send it twice.
      if (outcome['succeeded'] != true) {
        throw StateError('Helper report failed');
      }
    });
  }

  Future<void> _consumeUrgentLock(int pid) async {
    final control = _control;
    if (_urgentLockBusy || control is! PlayerUrgentLockProcessControl) return;
    final ipc = control as PlayerUrgentLockProcessControl;
    _urgentLockBusy = true;
    try {
      final command = await ipc.consumeLockCommand(pid);
      if (command == null) return;
      final actual = _origin;
      final sequence = command['sequence'];
      var accepted = false;
      try {
        if (actual == null ||
            runtime == null ||
            pid != _pid ||
            command['pid'] != pid ||
            sequence is! int ||
            sequence <= _lastSwitchCommand ||
            _privateRevoked ||
            command['action'] != 'lock' ||
            !auth.serverAccess.isProtected(
              actual.source.account.configuredServerId,
            ) ||
            command['generation'] != actual.permit.accessGeneration ||
            command['source'] is! Map ||
            decodeAuthorizedSource(
                  Map<String, dynamic>.from(command['source'] as Map),
                ).account !=
                actual.source.account) {
          throw StateError('Stale or unauthorized private lock');
        }
        actual.permit.requireValid();
        _lastSwitchCommand = sequence;
        accepted = true;
      } catch (_) {
        // Invalid ordinary/cross-account/old-generation RPC cannot lock.
      }
      await ipc.replyLockCommand(pid, {
        'sequence': sequence,
        'accepted': accepted,
      });
      if (accepted) {
        await auth.serverAccess.lock(actual!.source.account.configuredServerId);
      }
    } catch (_) {
      // Revocation may remove the endpoint while this read/reply is in flight.
    } finally {
      _urgentLockBusy = false;
    }
  }

  Future<void> _consumeSwitchCommand(int pid) async {
    final control = _control;
    final actual = _origin;
    if (control is! PlayerHistoryProcessControl ||
        runtime == null ||
        actual == null) {
      return;
    }
    final ipc = control as PlayerHistoryProcessControl;
    final command = await ipc.consumeSwitchCommand(pid);
    if (command == null) return;
    final sequence = command['sequence'];
    final receipt = <String, dynamic>{'sequence': sequence};
    Future<void> Function()? commit;
    try {
      if (sequence is! int ||
          sequence <= _lastSwitchCommand ||
          pid != _pid ||
          command['pid'] != pid ||
          command['generation'] != actual.permit.accessGeneration ||
          command['source'] is! Map ||
          decodeAuthorizedSource(
                Map<String, dynamic>.from(command['source'] as Map),
              ).account !=
              actual.source.account ||
          _privateRevoked) {
        throw StateError('Stale playback switch command');
      }
      actual.permit.requireValid();
      _lastSwitchCommand = sequence;
      switch (command['action']) {
        case 'opened':
          final entry = _pendingEntry;
          if (entry == null ||
              command['item'] != _current?.itemId ||
              command['version'] != _current?.mediaSourceId) {
            throw StateError('No matching target open transaction');
          }
          final target = await runtime!.resolveItem(
            actual,
            command['item'] as String,
            mediaSourceId: command['version'] as String,
          );
          final info = await target.permit.dispatch(
            (c) => c.inspectPlaybackInfo(
              itemId: target.source.itemId,
              mediaSourceId: command['version'] as String,
            ),
          );
          if (!info.mediaSources.any((v) => v.id == command['version'])) {
            throw StateError('Unknown opened target version');
          }
          await entry.prepareCommit();
          if (!identical(_pendingEntry, entry) || _pid != pid || _disposed) {
            throw StateError('Target open superseded');
          }
          if (!entry.commit()) throw StateError('Source entry commit failed');
          _pendingEntry = null;
          _entryOpenTimer?.cancel();
          _restoreSwitch = null;
          _saveSwitchPreference = true;
          switchFailure = null;
        case 'openFailed':
          if (_pendingEntry == null || command['item'] != _current?.itemId) {
            throw StateError('No matching target open transaction');
          }
          commit = () => _rejectPendingEntry('Target playback failed to open');

        case 'lock':
          if (!auth.serverAccess.isProtected(
            actual.source.account.configuredServerId,
          )) {
            throw StateError('Private playback required');
          }
          commit = () async {
            await auth.serverAccess.lock(
              actual.source.account.configuredServerId,
            );
          };
        case 'catalogue':
          final server = runtime!.registry.project().firstWhere(
            (s) => s.id == actual.source.account.configuredServerId,
          );
          receipt['serverName'] = server.displayName;
          receipt['lines'] = [
            for (final line in server.lines)
              {'id': line.id, 'label': line.nickname ?? line.hostLabel},
          ];
          final dto = await actual.permit.dispatch(
            (c) => c.getItem(actual.work.itemId),
          );
          final query = SameSourceQueryController(
            registry: runtime!.registry,
            history: runtime!.history,
          );
          try {
            await query.start(
              origin: QueryItem(actual.work, actual.libraryId, dto),
              scope: QueryScope(),
            );
            actual.permit.requireValid();
            final current = await runtime!.resolveItem(
              actual,
              command['item'] as String? ?? actual.source.itemId,
            );
            final currentDto = await current.permit.dispatch(
              (c) => c.getItem(current.source.itemId),
            );
            final mappedTarget = command['mapTarget'] is Map
                ? decodeAuthorizedSource(
                    Map<String, dynamic>.from(command['mapTarget'] as Map),
                  )
                : null;
            final rows = <Map<String, dynamic>>[];
            for (final candidate in query.comparisons) {
              var targetRef = candidate.source.reference;
              var reason = candidate.decision.reason.name;
              final label =
                  '${candidate.source.item.name} · ${targetRef.account.configuredServerId}';
              String? numbering;
              if (currentDto.isEpisode && candidate.decision.confirmed) {
                if (mappedTarget == targetRef) {
                  final original = EpisodeSource.fromMediaItem(
                    current.source,
                    currentDto,
                  );
                  final verified = command['mappingAccepted'] == true;
                  await query.lookupEpisode(
                    target: candidate.source,
                    episode: verified
                        ? withConfirmedEpisodeMapping(original)
                        : original,
                    verifiedNumberingScheme: verified
                        ? userConfirmedEpisodeNumbering
                        : null,
                  );
                  final result = query.episodes
                      .where((e) => e.target == targetRef)
                      .single;
                  reason = result.lookup.status.name;
                  if (result.lookup.status == EpisodeLookupStatus.confirmed) {
                    targetRef = result.lookup.source!.reference;
                    numbering = result.lookup.source!.numberingScheme;
                  }
                }
                if (numbering == null) {
                  rows.add({
                    'target': encodeSource(candidate.source.reference),
                    'label': label,
                    'confirmed': false,
                    'canMap': true,
                    'reason': reason,
                  });
                  continue;
                }
              }
              if (!candidate.decision.confirmed) {
                rows.add({
                  'label': label,
                  'confirmed': false,
                  'reason': reason,
                });
                continue;
              }
              try {
                final target = await runtime!.resolve(
                  PlayerOpenRequest(
                    itemId: targetRef.itemId,
                    source: targetRef,
                    work: candidate.source.reference.item,
                    libraryId: candidate.source.libraryId,
                    accessGeneration: actual.permit.accessGeneration,
                  ),
                );
                final info = await target.permit.dispatch(
                  (c) => c.getPlaybackInfo(itemId: targetRef.itemId),
                );
                for (final version in info.mediaSources) {
                  rows.add({
                    'target': encodeSource(targetRef),
                    'work': encodeSource(candidate.source.reference.item),
                    'library': candidate.source.libraryId,
                    'targetVersion': version.id,
                    'label': '$label · ${version.name ?? version.id}',
                    'key':
                        '${targetRef.account.configuredServerId}-${version.id}',
                    'confirmed': true,
                    'numbering': numbering,
                    'reason': reason,
                  });
                }
                if (info.mediaSources.isEmpty) {
                  rows.add({
                    'label': label,
                    'confirmed': false,
                    'reason': 'unknownVersion',
                  });
                }
              } catch (_) {
                rows.add({
                  'label': label,
                  'confirmed': false,
                  'reason': 'versionQueryFailed',
                });
              }
            }
            actual.permit.requireValid();
            receipt['targets'] = rows;
          } finally {
            query.dispose();
          }
        case 'authorizeItem':
          await runtime!.resolveItem(actual, command['item'] as String);
          actual.permit.requireValid();
        case 'inspect':
          final itemId = command['item'] as String;
          final original = await runtime!.resolveItem(actual, itemId);
          final old = PlaybackOrigin(
            source: original.source,
            work: original.work,
            libraryId: original.libraryId,
            permit: original.permit,
            client: actual.client,
          );
          final line = command['line'] as String?;
          final oldVersion = command['version'] as String;
          _switchEntry?.cancel();
          _switchEntry = null;
          if (line == null) {
            final reference = decodeAuthorizedSource(
              Map<String, dynamic>.from(command['target'] as Map),
            );
            _switchEntry = await runtime!.prepareSourceEntry(
              reference.account.configuredServerId,
              requestPassword: requestSourcePassword,
            );
            if (_switchEntry == null) {
              throw StateError('Source entry cancelled');
            }
          }
          final target = line != null
              ? await runtime!.resolveLine(old, line, oldVersion)
              : await runtime!.resolve(
                  PlayerOpenRequest(
                    itemId: decodeAuthorizedSource(
                      Map<String, dynamic>.from(command['target'] as Map),
                    ).itemId,
                    source: decodeAuthorizedSource(
                      Map<String, dynamic>.from(command['target'] as Map),
                    ),
                    work: decodeAuthorizedSource(
                      Map<String, dynamic>.from(command['work'] as Map),
                    ),
                    libraryId: command['library'] as String,
                    accessGeneration: _switchEntry!.generation,
                  ),
                  entry: _switchEntry,
                );
          if (line == null) {
            await runtime!.requireEquivalent(
              old,
              target,
              numberingScheme: command['numbering'] as String?,
            );
          }
          final oldInfo = await old.permit.dispatch(
            (_) => old.client.inspectPlaybackInfo(itemId: itemId),
          );
          final newInfo = await target.permit.dispatch(
            (_) => target.client.inspectPlaybackInfo(
              itemId: target.source.itemId,
              maxStreamingBitrate: command['bitrate'] as int,
            ),
          );
          final newVersion = line == null
              ? command['targetVersion'] as String
              : oldVersion;
          final plan = PlaybackSwitchPlan.inspect(
            original: oldInfo.mediaSources.singleWhere(
              (s) => s.id == oldVersion,
            ),
            target: newInfo.mediaSources.singleWhere((s) => s.id == newVersion),
            positionTicks: command['position'] as int,
            paused: command['paused'] as bool,
            maxStreamingBitrate: command['bitrate'] as int,
            audioIndex: command['audio'] as int?,
            subtitleIndex: command['subtitle'] as int?,
            sameVersion: line != null,
          );
          actual.permit.requireValid();
          target.permit.requireValid();
          if (_pid != pid || !identical(_origin, actual) || _privateRevoked) {
            throw StateError('CupertinoSwitch superseded');
          }
          _pendingSwitch = (
            target: target,
            original: old,
            plan: plan,
            line: line,
            restore: PlayerOpenRequest(
              itemId: itemId,
              source: old.source,
              work: old.work,
              libraryId: old.libraryId,
              mediaSourceId: oldVersion,
              autoResume: false,
              startPosition: durationFromTicks(plan.positionTicks),
              startPaused: plan.paused,
              audioStreamIndex: command['audio'] as int?,
              subtitleStreamIndex: command['subtitle'] as int?,
              subtitleOff: command['subtitle'] == null,
              maxStreamingBitrate: plan.maxStreamingBitrate,
            ),
          );
          receipt['plan'] = plan.toJson();
        case 'cancel':
          _switchEntry?.cancel();
          _switchEntry = null;
          _pendingSwitch = null;
        case 'confirm':
          final pending = _pendingSwitch;
          if (pending == null) throw StateError('No pending switch');
          pending.original.permit.requireValid();
          pending.target.permit.requireValid();
          final choice = SwitchResumeChoice.values.byName(
            command['choice'] as String,
          );
          final audio = command['audio'] as int?;
          final subtitle = command['subtitle'] as int?;
          pending.plan.requireSelection(
            choice,
            audio: audio,
            subtitle: subtitle,
            acceptDefaultAudio: command['acceptDefaultAudio'] == true,
            turnSubtitlesOff: command['turnSubtitlesOff'] == true,
          );
          if (choice == SwitchResumeChoice.cancel) {
            _switchEntry?.cancel();
            _switchEntry = null;
            _pendingSwitch = null;
            break;
          }
          final target = pending.target;
          final request = PlayerOpenRequest(
            itemId: target.source.itemId,
            source: target.source,
            work: target.work,
            libraryId: target.libraryId,
            mediaSourceId: pending.plan.sourceId,
            startPosition: choice == SwitchResumeChoice.beginning
                ? Duration.zero
                : durationFromTicks(pending.plan.positionTicks),
            autoResume: false,
            startPaused: pending.plan.paused,
            maxStreamingBitrate: pending.plan.maxStreamingBitrate,
            audioStreamIndex: audio ?? pending.plan.audioIndex,
            subtitleStreamIndex: command['turnSubtitlesOff'] == true
                ? null
                : (subtitle ?? pending.plan.subtitleIndex),
            subtitleOff:
                command['turnSubtitlesOff'] == true ||
                (subtitle ?? pending.plan.subtitleIndex) == null,
          );
          _restoreSwitch = (origin: pending.original, request: pending.restore);
          _pendingSwitch = null;
          final entry = _switchEntry;
          _switchEntry = null;
          commit = () =>
              _openWithOrigin(request, prepared: target, entry: entry);
        case 'restore':
          final restore = _restoreSwitch;
          if (restore == null) {
            throw StateError('No original source to restore');
          }
          restore.origin.permit.requireValid();
          commit = () =>
              _openWithOrigin(restore.request, prepared: restore.origin);
        default:
          throw StateError('Unknown playback switch command');
      }
      receipt['accepted'] = true;
    } catch (error) {
      if (command['action'] == 'inspect') {
        _switchEntry?.cancel();
        _switchEntry = null;
      }
      receipt['accepted'] = false;
      receipt['error'] = '$error';
    }
    await ipc.replySwitchCommand(pid, receipt);
    if (commit != null) {
      // Let the helper receive its receipt before asking it to close. It drains
      // its last observation/Stopped before the main process launches target.
      final run = commit;
      final transaction = _restoreSwitch;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 100), () async {
          try {
            if (_pid != pid || _privateRevoked || _disposed) return;
            actual.permit.requireValid();
            await run();
            if (!identical(_restoreSwitch, transaction) || _privateRevoked) {
              return;
            }
            _saveSwitchPreference = true;
            switchFailure = null;
          } catch (error) {
            if (_disposed ||
                _privateRevoked ||
                !identical(_restoreSwitch, transaction)) {
              return;
            }
            final targetEntry = _origin?.permit.entry;
            if (targetEntry != null &&
                !targetEntry.isCommitted &&
                transaction?.origin.permit.isValid == true) {
              try {
                await restoreOriginalSource();
              } catch (_) {
                /* A remains retryable. */
              }
            }
            switchFailure = '$error';
            notifyListeners();
          }
        }),
      );
    }
  }

  Future<void> _membershipRevoked(
    SourceAccount? account,
    String serverId,
  ) async {
    _invalidateOriginal(serverId);
    if (_origin?.source.account.configuredServerId != serverId) return;
    _revokeWindow();
    try {
      await close().timeout(closeTimeout + reportTimeout);
    } catch (_) {
      await forceClose();
    } finally {
      _origin?.client.clearSession();
    }
  }

  void _revokePrivate() {
    if (_restoreSwitch?.origin.permit.isValid == false) {
      _restoreSwitch = null;
      switchFailure = null;
      notifyListeners();
    }
    if (_origin?.permit.isValid != false) return;
    _revokeWindow();
  }

  void _invalidateOriginal(String serverId) {
    if (_restoreSwitch?.origin.source.account.configuredServerId != serverId) {
      return;
    }
    final private = auth.serverAccess.isProtected(
      _restoreSwitch!.origin.source.account.configuredServerId,
    );
    _restoreSwitch = null;
    if (private) switchFailure = null;
    notifyListeners();
  }

  void _sourceRevoked(String serverId) {
    if (_origin?.permit.isValid == true &&
        (_restoreSwitch == null || _restoreSwitch!.origin.permit.isValid)) {
      return;
    }
    _invalidateOriginal(serverId);
    if (_origin?.source.account.configuredServerId != serverId) return;
    _revokeWindow();
    unawaited(
      close()
          .timeout(closeTimeout + reportTimeout)
          .catchError((Object _) => forceClose()),
    );
  }

  void _revokeWindow() {
    if (_privateRevoked) return;
    _privateRevoked = true;
    _pendingSwitch = null;
    _restoreSwitch = null;
    switchFailure = null;
    _requestRevision++;
    _control.cancelPendingSpawns();
    _watch?.cancel();
    _current = null;
    notifyListeners();
    final control = _control;
    if (control is PlayerHistoryProcessControl && _pid != 0) {
      unawaited(
        (control as PlayerHistoryProcessControl).revoke(
          _pid,
          auth.serverAccess.generation(
            _origin?.source.account.configuredServerId ?? '',
          ),
          reportStopped:
              _origin != null &&
              !auth.serverAccess.allows(
                _origin!.source.account.configuredServerId,
              ),
        ),
      );
    }
  }

  Future<void> _closePrivate(ServerStopPermit permit) async {
    if (_privateRevoked) await close().timeout(closeTimeout + reportTimeout);
  }

  void _terminatePrivate() {
    if (_privateRevoked) unawaited(forceClose());
  }

  void _notify(PlayerHostNotice notice) {
    if (_disposed || _notices.isClosed) {
      return;
    }
    _notices.add(notice);
  }

  void _clearWindow() {
    if (_pid == 0 && _current == null) {
      return;
    }
    _watch?.cancel();
    _watch = null;
    _pid = 0;
    _current = null;
    _authIdentity = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _pendingEntry?.cancel();
    _pendingEntry = null;
    _entryOpenTimer?.cancel();
    _switchEntry?.cancel();
    _switchEntry = null;
    _disposed = true;
    _requestRevision++;
    _control.cancelPendingSpawns(includePrepared: true);
    auth.removeListener(_onAuth);
    auth.serverAccess.removeRevocationHook(_revokePrivate);
    auth.serverAccess.removeCleanupHook(_closePrivate);
    auth.serverAccess.removeTerminationHook(_terminatePrivate);
    runtime?.registry.removeMembershipCleanup(_membershipRevoked);
    runtime?.registry.removeSourceRevocation(_sourceRevoked);
    unawaited(
      _runInFlight(() async {
        await _stopProcess();
        await _control.discardPrepared();
      }).whenComplete(_notices.close),
    );
    super.dispose();
  }
}

Future<void> runPlayerWindow({String? argumentFallback}) async {
  PlayerWindowLaunch launch;
  try {
    var raw = argumentFallback ?? '';
    final file = File(raw);
    if (raw.isNotEmpty && file.existsSync()) {
      raw = await file.readAsString();
      await file.delete();
    }
    final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (payload['warmPlayer'] == true) {
      await _runPreparedPlayer(PlayerProcessProtocol.fromJson(payload));
      return;
    }
    launch = PlayerWindowLaunch.fromJson(payload);
    if (launch.protocol == null) {
      throw const FormatException('Missing player process endpoint');
    }
  } catch (_) {
    exitCode = 1;
    exit(1);
  }
  runApp(PlayerWindowApp(launch: launch));
}

Future<void> _runPreparedPlayer(PlayerProcessProtocol protocol) async {
  // Rasterize offscreen with the normal renderer (including Impeller). No
  // player/controller or credentials exist until a user requests playback.
  runApp(const ColoredBox(color: Color(0xFF000000)));
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await protocol.write('ready');
  while (true) {
    if (await protocol.read('close') != null ||
        await protocol.parentExpired()) {
      exit(0);
    }
    if (await protocol.read('start') != null) {
      await runPlayerWindow(argumentFallback: protocol.launchFile.path);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class PlayerWindowApp extends StatefulWidget {
  const PlayerWindowApp({super.key, required this.launch})
    : _client = null,
      _bindings = null,
      _onExit = null,
      _clock = null;

  /// Exercises the helper's command, observation and shutdown paths without
  /// configuring a native window or terminating the test process.
  @visibleForTesting
  const PlayerWindowApp.testing({
    super.key,
    required this.launch,
    required MediaServerClient this._client,
    required PlayerBindings this._bindings,
    required VoidCallback this._onExit,
    this._clock,
  });

  final PlayerWindowLaunch launch;
  final MediaServerClient? _client;
  final PlayerBindings? _bindings;
  final VoidCallback? _onExit;
  final DateTime Function()? _clock;

  @override
  State<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends State<PlayerWindowApp> with WindowListener {
  late PlayerWindowLaunch _launch;
  bool _entryResultSent = false;
  late AuthController _auth;
  var _playerKey = GlobalKey<PlayerPageState>();
  Future<void>? _closing;
  Timer? _commands;
  bool _readingCommand = false;
  int _ipcSequence = 0;
  int _launchRevision = 0;
  Future<PlayerStartupData?>? _startup;

  @override
  void initState() {
    super.initState();
    _launch = widget.launch;
    _auth = _authFor(_launch);
    if (_launch.startupHandoff != null) {
      // Scoped launches embed the parent's negotiated metadata; decoding is
      // synchronous, so startup never waits on a mailbox.
      _startup = Future.value(
        PlayerStartupData.decode(
          _launch.startupHandoff!,
          itemId: _launch.request.itemId,
          userId: _launch.userId,
        ),
      );
    } else if (_launch.preparedStartup && _launch.protocol != null) {
      // Start polling before window configuration; both proceed independently.
      _startup = PlayerStartupData.receive(
        _launch.protocol!,
        itemId: _launch.request.itemId,
        userId: _launch.userId,
      );
      unawaited(_startup!.then<void>((_) {}, onError: (Object _) {}));
    }
    windowManager.addListener(this);
    if (widget._onExit == null) {
      unawaited(_configureWindow());
    }
    _commands = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_readingCommand || _closing != null) return;
      _readingCommand = true;
      unawaited(() async {
        try {
          final endpoint = _launch.protocol;
          final revoked = await endpoint?.read('revoke');
          if (revoked != null) {
            await _playerKey.currentState?.controller?.revokeFromHost(
              reportStopped: revoked['reportStopped'] == true,
            );
            await _closeWindow();
            return;
          }
          if (endpoint != null &&
              (await endpoint.read('close') != null ||
                  await endpoint.parentExpired())) {
            await _closeWindow();
          }
        } finally {
          _readingCommand = false;
        }
      }());
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _commands?.cancel();
    _auth.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(_closeWindow());
  }

  @override
  void onWindowFocus() {
    if (_closing == null) {
      _playerKey.currentState?.restoreWindowInteraction();
    }
  }

  AuthController _authFor(PlayerWindowLaunch launch) {
    final client =
        widget._client ??
        MediaServerProviders.create(launch.serviceType, launch.device);
    client.attachSession(
      baseUrl: Uri.parse(launch.baseUrl),
      accessToken: launch.accessToken,
      userId: launch.userId,
      userAgent: launch.userAgent,
    );
    return AuthController(
      client: client,
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
  }

  Future<void> _applyLaunch(PlayerWindowLaunch launch) async {
    if (!mounted || _closing != null) {
      return;
    }
    final revision = ++_launchRevision;
    if (_launch.request.source != null) {
      await _dispatchSwitch({
        'action': 'authorizeItem',
        'item': launch.request.itemId,
      });
      if (_closing != null || !mounted || revision != _launchRevision) return;
    }
    await _playerKey.currentState?.controller?.disposeAsync();
    if (!mounted || _closing != null || revision != _launchRevision) return;
    _playerKey = GlobalKey<PlayerPageState>();
    final previousAuth = _auth;
    final nextAuth = _authFor(launch);
    setState(() {
      _launch = launch;
      _startup = null;
      _auth = nextAuth;
    });
    previousAuth.dispose();
  }

  Future<void> _configureWindow() async {
    try {
      await windowManager.setPreventClose(true);
      await windowManager.waitUntilReadyToShow();
      await windowManager.hide();
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await applyAdaptiveWindowSize(
        minimumSize: kMinPlayerWindowSize,
        maximumSize: kMaxPlayerWindowSize,
        playerWindow: true,
      );
      await windowManager.setTitle(_playerWindowTitle);
      await windowManager.show();
      await windowManager.focus();
      await _launch.protocol?.write('ready');
    } catch (_) {
      await _launch.protocol?.write('failed');
      await _closeWindow();
    }
  }

  Future<Map<String, dynamic>> _dispatchSwitch(
    Map<String, dynamic> command,
  ) async {
    final endpoint = _launch.protocol;
    final source = _launch.request.source;
    if (endpoint == null || source == null || _closing != null) {
      throw StateError('Playback IPC unavailable');
    }
    final sequence = ++_ipcSequence;
    final urgentLock = command['action'] == 'lock';
    await endpoint.write(urgentLock ? 'lock-request' : 'switch-request', {
      ...command,
      'source': encodeSource(source),
      'generation': _launch.accessGeneration,
      'sequence': sequence,
    });
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline) && _closing == null) {
      final reply = await endpoint.read(
        urgentLock ? 'lock-reply' : 'switch-reply',
      );
      if (reply?['sequence'] == sequence) {
        if (reply?['accepted'] != true) throw StateError('${reply?['error']}');
        return reply!;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('Playback switch authority did not respond');
  }

  Future<bool> _observe(
    PlaybackReport report,
    WatchTimeline timeline,
    int sequence, {
    bool played = false,
  }) async {
    final endpoint = _launch.protocol;
    final source = _launch.request.source;
    if (endpoint == null ||
        source == null ||
        _playerKey.currentState?.controller?.permissionRevoked == true) {
      return false;
    }
    final observationSequence = sequence;
    sequence = ++_ipcSequence;
    final controller = _playerKey.currentState?.controller;
    final media = controller?.resolved?.mediaSource;
    final audio = controller?.audioStreamIndex == null
        ? null
        : media?.streamByIndex(controller!.audioStreamIndex!);
    final subtitle = controller?.subtitleStreamIndex == null
        ? null
        : media?.streamByIndex(controller!.subtitleStreamIndex!);
    final settings = PlayerSeriesPreference(
      mediaSourceName: media?.name,
      mediaSourceId: media?.id,
      audioStreamIndex: controller?.audioStreamIndex,
      audioLanguage: audio?.language,
      audioTitle: audio?.label,
      subtitleLanguage: subtitle?.language,
      subtitleTitle: subtitle?.displayTitle,
      subtitleOff: controller?.subtitleStreamIndex == null,
      maxStreamingBitrate: controller?.maxStreamingBitrate,
    );
    await endpoint.write('watch-event', {
      'source': encodeSource(
        SourceReference(
          account: source.account,
          itemId: report.itemId,
          mediaSourceId: report.mediaSourceId,
        ),
      ),
      'generation': _launch.accessGeneration,
      'sequence': sequence,
      'observationSequence': observationSequence,
      'item': report.itemId,
      'version': report.mediaSourceId,
      'position': report.position.inMicroseconds * 10,
      'actuallyPlaying': true,
      'played': played,
      'timeline': timeline.toJson(),
      'savePreference': controller?.scopedPreferencePending == true,
      'settings': settings.toJson(),
    });
    final now = widget._clock ?? DateTime.now;
    final started = now();
    var deadline = started.add(const Duration(seconds: 3));
    final verificationDeadline = started.add(const Duration(seconds: 30));
    // Graceful close drains final observations and their acknowledgements.
    // Revocation alone cancels this channel, including while draining close.
    while (now().isBefore(deadline) &&
        _playerKey.currentState?.controller?.permissionRevoked != true) {
      final pending = await endpoint.read('watch-pending');
      if (pending?['sequence'] == sequence) {
        deadline = verificationDeadline;
      }
      final receipt = await endpoint.read('watch-ack');
      if (receipt?['sequence'] == sequence) {
        final accepted = receipt?['accepted'] == true;
        if (accepted) controller?.acknowledgeScopedPreference();
        return accepted;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }

  Future<void> _reportOutcome(
    PlaybackReport report,
    int sequence,
    bool succeeded,
  ) async {
    final endpoint = _launch.protocol;
    if (endpoint == null || _closing != null) return;
    await endpoint.write('watch-sync', {
      'sequence': sequence,
      'generation': _launch.accessGeneration,
      'item': report.itemId,
      'version': report.mediaSourceId,
      'succeeded': succeeded,
    });
  }

  Future<void> _openItemInHost(
    String itemId, {
    String? seasonId,
    PlayerHostOpenItemCommand? command,
  }) async {
    try {
      final protocol = _launch.protocol;
      if (protocol != null) {
        await PlayerHostOpenItem.write(
          itemId,
          protocol: protocol,
          seasonId: seasonId,
          command: command,
        );
      }
    } catch (_) {}
    await _closeWindow();
  }

  Future<void> _closeWindow() => _closing ??= _disposeAndExit();

  Future<void> _disposeAndExit() async {
    _commands?.cancel();
    try {
      await _playerKey.currentState?.controller?.disposeAsync().timeout(
        PlayerController.stoppedDeadline,
      );
    } catch (_) {}
    final onExit = widget._onExit;
    if (onExit == null) {
      exit(0);
    } else {
      onExit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _launch.request;
    return AuthScope(
      controller: _auth,
      child: PlayerScope(
        bindings: PlayerBindings(
          createBackend: widget._bindings?.createBackend,
          window: widget._bindings?.window,
          settingsStore: widget._bindings?.settingsStore,
          danmakuClient: widget._bindings?.danmakuClient,
          progressInterval:
              widget._bindings?.progressInterval ?? const Duration(seconds: 10),
          observationSink: _launch.request.source == null ? null : _observe,
          sourceOpenResult: !_launch.entryPending
              ? null
              : (item, version, succeeded) async {
                  if (_entryResultSent) return;
                  _entryResultSent = true;
                  await _dispatchSwitch({
                    'action': succeeded ? 'opened' : 'openFailed',
                    'item': item,
                    'version': version,
                  });
                },
          reportOutcomeSink: _launch.request.source == null
              ? null
              : _reportOutcome,
          switchDispatcher: _launch.request.source == null
              ? null
              : _dispatchSwitch,
          startupData: _startup,
          snapshotStore:
              widget._bindings?.snapshotStore ??
              (_launch.protocol == null
                  ? null
                  : FilePlaybackSessionSnapshotStore(
                      File('${_launch.protocol!.directory.path}/snapshot.json'),
                    )),
        ),
        child: CupertinoApp(
          title: _playerWindowTitle,
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          theme: AppUiTheme.dark().cupertino,
          builder: (context, child) =>
              AppUiTheme(data: AppUiTheme.dark(), child: child!),

          home: PlayerPage(
            key: _playerKey,
            itemId: request.itemId,
            sourceRequest: request,
            playbackLines: _launch.lines,
            verifiedPlaybackServerId: _launch.verifiedServerId,
            autoResume: request.autoResume,
            mediaSourceId: request.mediaSourceId,
            audioStreamIndex: request.audioStreamIndex,
            subtitleStreamIndex: request.subtitleStreamIndex,
            startPosition: request.startPosition,
            secondarySubtitleStreamIndex: request.secondarySubtitleStreamIndex,
            onClosed: () {
              unawaited(_closeWindow());
            },
            onOpenItem: (itemId) {
              _applyLaunch(
                PlayerWindowLaunch(
                  request: PlayerOpenRequest(
                    itemId: itemId,
                    autoResume: false,
                    source: request.source == null
                        ? null
                        : SourceReference(
                            account: request.source!.account,
                            itemId: itemId,
                          ),
                    work: request.work,
                    libraryId: request.libraryId,
                    accessGeneration: _launch.accessGeneration,
                  ),
                  baseUrl: _auth.client.baseUrl?.toString() ?? _launch.baseUrl,
                  accessToken: _auth.client.accessToken ?? _launch.accessToken,
                  userId: _auth.client.userId ?? _launch.userId,
                  device: _launch.device,
                  serviceType: _launch.serviceType,
                  userAgent: _auth.client.customUserAgent ?? _launch.userAgent,
                  protocol: _launch.protocol,
                  accessGeneration: _launch.accessGeneration,
                  lines: _launch.lines,
                  verifiedServerId: _launch.verifiedServerId,
                ),
              );
            },
            // 播放结束"查看剧集":写临时文件请主窗口打开详情,再关播放器。
            // 独立 CreateProcess 没有可用的 WindowMethodChannel,等待它
            // 只会误判成功或卡住;绝不能把剧集 id 当片源重开。
            onOpenItemDetail: (itemId, {seasonId, command}) {
              unawaited(
                _openItemInHost(itemId, seasonId: seasonId, command: command),
              );
            },
          ),
        ),
      ),
    );
  }
}

String get _playerWindowTitle => '播放 - $kProductName';
