import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'playback_runtime.dart';
import 'playback_resolver.dart';
import '../aggregation/history/history_writer.dart';
import '../aggregation/identity/media_identity.dart';
import 'player_settings.dart';
import '../auth/region_access.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/app/window_geometry.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_process_control.dart';
import 'package:rillight/player/player_process_protocol.dart';
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
    required this.baseUrl,
    required this.accessToken,
    required this.userId,
    required this.device,
    this.userAgent,
    this.protocol,
    this.regionGeneration,
  });

  final PlayerOpenRequest request;
  final String baseUrl;
  final String accessToken;
  final String userId;
  final EmbyDeviceInfo device;
  final String? userAgent;
  final PlayerProcessProtocol? protocol;
  final int? regionGeneration;

  factory PlayerWindowLaunch.fromAuth({
    required AuthController auth,
    required PlayerOpenRequest request,
  }) {
    final client = auth.client;
    final baseUrl = client.baseUrl;
    final token = client.accessToken;
    final userId = client.userId;
    if (baseUrl == null || token == null || token.isEmpty || userId == null) {
      throw StateError('没有可用的登录会话，无法打开播放窗口');
    }
    return PlayerWindowLaunch(
      request: request,
      baseUrl: baseUrl.toString(),
      accessToken: token,
      userId: userId,
      device: client.device,
      userAgent: client.customUserAgent,
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
    return PlayerWindowLaunch(
      request: PlayerOpenRequest(
        itemId: json['itemId'] as String? ?? '',
        source: json['source'] is Map
            ? decodeSource(Map<String, dynamic>.from(json['source'] as Map))
            : null,
        work: json['work'] is Map
            ? decodeSource(Map<String, dynamic>.from(json['work'] as Map))
            : null,
        libraryId: json['libraryId'] as String?,
        startPaused: json['startPaused'] == true,
        subtitleOff: json['subtitleOff'] == true,
        maxStreamingBitrate: json['maxStreamingBitrate'] as int?,
        regionGeneration: json['regionGeneration'] as int?,
        autoResume: json['autoResume'] != false,
        mediaSourceId: json['mediaSourceId'] as String?,
        audioStreamIndex: json['audioStreamIndex'] is int
            ? json['audioStreamIndex'] as int
            : int.tryParse('${json['audioStreamIndex'] ?? ''}'),
        subtitleStreamIndex: json['subtitleStreamIndex'] is int
            ? json['subtitleStreamIndex'] as int
            : int.tryParse('${json['subtitleStreamIndex'] ?? ''}'),
        startTimeTicks: json['startTimeTicks'] is int
            ? json['startTimeTicks'] as int
            : int.tryParse('${json['startTimeTicks'] ?? ''}'),
      ),
      regionGeneration: json['regionGeneration'] as int?,
      baseUrl: json['baseUrl'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      userAgent: json['userAgent'] as String?,
      protocol: json['processSessionId'] == null
          ? null
          : PlayerProcessProtocol.fromJson(json),
      device: EmbyDeviceInfo(
        clientName: json['clientName'] as String? ?? kHttpClientName,
        deviceName: json['deviceName'] as String? ?? 'desktop',
        deviceId: json['deviceId'] as String? ?? 'rillight-player',
        version: json['version'] as String? ?? kAppVersion,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'businessId': businessId,
      if (request.source != null) 'source': encodeSource(request.source!),
      if (request.work != null) 'work': encodeSource(request.work!),
      if (request.libraryId != null) 'libraryId': request.libraryId,
      if (regionGeneration != null) 'regionGeneration': regionGeneration,
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
      if (request.startTimeTicks != null)
        'startTimeTicks': request.startTimeTicks,
      'baseUrl': baseUrl,
      'accessToken': accessToken,
      'userId': userId,
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
typedef PlaybackSnapshotStoreLocator =
    PlaybackSessionSnapshotStore Function(int pid);

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
    PlayerProcessControl? processControl,
    PlaybackSnapshotStoreLocator? snapshotStoreForPid,
    PlayerHostOpenItemConsumer? consumeOpenItem,
    this.closeTimeout = const Duration(seconds: 1),
    this.reportTimeout = const Duration(seconds: 3),
    this.watchInterval = const Duration(milliseconds: 400),
  }) : _control = processControl ?? createPlayerProcessControl(),
       _snapshotStoreForPid = snapshotStoreForPid,
       _consumeOpenItem = consumeOpenItem {
    auth.addListener(_onAuth);
    auth.regionAccess.addRevocationHook(_revokePrivate);
    auth.regionAccess.addCleanupHook(_closePrivate);
    auth.regionAccess.addTerminationHook(_terminatePrivate);
    runtime?.registry.addMembershipCleanup(_membershipRevoked);
    runtime?.registry.addSourceRevocation(_sourceRevoked);
  }

  final AuthController auth;
  final PlaybackRuntime? runtime;
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
  String? switchFailure;
  bool _saveSwitchPreference = false;

  /// 播放器进程请求主窗口打开条目详情(如播放结束"查看剧集")。
  void Function(String itemId, {String? seasonId})? onOpenItemRoute;

  /// 等待播放进程响应会话 close 消息并自行退出的上限。
  final Duration closeTimeout;

  /// 主进程代发 Stopped 的上限。
  final Duration reportTimeout;

  /// 探测播放进程是否仍存活的轮询间隔。
  final Duration watchInterval;

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
  String? _authIdentity;
  String get _currentAuthIdentity =>
      '${auth.client.baseUrl}|${auth.client.userId}|${auth.client.accessToken}';

  /// 串行化 open/close 与 watcher 代发,避免 close 清掉后开的 pid,
  /// 并让 close() 等到在途 reconcile 结束后再回到登出。
  Future<void> _inFlight = Future<void>.value();

  @override
  PlayerOpenRequest? get current => _current;

  @override
  bool get embedsPlayerInCaller => false;

  @override
  Stream<PlayerHostNotice> get notices => _notices.stream;

  @override
  Future<void> open(PlayerOpenRequest request) => _openWithOrigin(request);

  Future<void> _openWithOrigin(
    PlayerOpenRequest request, {
    PlaybackOrigin? prepared,
  }) {
    final revision = ++_requestRevision;
    _control.cancelPendingSpawns();
    return _runInFlight(() async {
      if (_disposed || revision != _requestRevision) return;
      late PlayerWindowLaunch launch;
      PlaybackOrigin? resolvedOrigin;
      if (runtime != null) {
        final origin = prepared ?? await runtime!.resolve(request);
        origin.permit.requireValid();
        if (_disposed || revision != _requestRevision) return;
        resolvedOrigin = origin;
        final item = await origin.permit.dispatch(
          (_) => origin.client.getItem(request.itemId),
        );
        final info = await origin.permit.dispatch(
          (_) => origin.client.getPlaybackInfo(itemId: request.itemId),
        );
        final pref = runtime!.preference(origin, item, info.mediaSources);
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
        final sources = info.mediaSources.where((s) => s.id == version);
        final media = sources.length == 1 ? sources.single : null;
        final lines = runtime!.registry
            .project(origin.source.account.region)
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
            startTimeTicks: request.startTimeTicks,
            startPaused: request.startPaused,
            subtitleOff: request.subtitleOff || settings?.subtitleOff == true,
            maxStreamingBitrate:
                request.maxStreamingBitrate ?? settings?.maxStreamingBitrate,
            regionGeneration: origin.permit.regionGeneration,
          ),
          baseUrl: origin.client.baseUrl!.toString(),
          accessToken: origin.client.accessToken!,
          userId: origin.source.account.userId,
          device: origin.client.device,
          userAgent: origin.client.customUserAgent,
          regionGeneration: origin.permit.regionGeneration,
        );
      } else {
        launch = PlayerWindowLaunch.fromAuth(auth: auth, request: request);
      }
      if (_disposed || revision != _requestRevision) return;
      await _stopProcess();
      if (_disposed || revision != _requestRevision) return;
      resolvedOrigin?.permit.requireValid();
      _origin = resolvedOrigin;
      _watchSession = null;
      _lastIpcEvent = -1;
      _lastSwitchCommand = -1;
      _lastObservationSequence = null;
      _privateRevoked = false;
      try {
        final pid = await _control.spawn(
          executable: Platform.resolvedExecutable,
          arguments: launch.toArguments(),
        );
        if (_disposed ||
            revision != _requestRevision ||
            (_origin != null
                ? !_origin!.permit.isValid
                : (auth.client.baseUrl?.toString() != launch.baseUrl ||
                      auth.client.userId != launch.userId ||
                      auth.client.accessToken != launch.accessToken))) {
          await _control.kill(pid);
          await _reconcileSnapshot(pid);
          await _control.release(pid);
          return;
        }
        _pid = pid;
        _activeRevision = revision;
        _authIdentity = _currentAuthIdentity;
        _epoch++;
        _current = runtime == null ? request : launch.request;
        notifyListeners();
        _startWatch(pid);
      } catch (error) {
        if (error is PlayerProcessStartupException) {
          await _reconcileSnapshot(error.pid);
          await _control.release(error.pid);
        }
        if (!_disposed && revision == _requestRevision) _clearWindow();
        rethrow;
      }
    });
  }

  bool get canRestoreOriginal =>
      _restoreSwitch?.origin.permit.isValid == true && !_privateRevoked;
  Future<void> restoreOriginalSource() async {
    final original = _restoreSwitch;
    if (original == null || !canRestoreOriginal) {
      throw StateError('Original source unavailable');
    }
    await _openWithOrigin(original.request, prepared: original.origin);
    switchFailure = null;
  }

  @override
  Future<void> close() {
    _requestRevision++;
    _control.cancelPendingSpawns();
    return _runInFlight(() async {
      final epoch = _epoch;
      await _stopProcess();
      if (_epoch == epoch) _clearWindow();
    });
  }

  @override
  Future<void> forceClose() async {
    _requestRevision++;
    _control.cancelPendingSpawns();
    _watch?.cancel();
    await _control.terminateAll();
    for (final pid in _control.activePids.toList()) {
      await _reconcileSnapshot(pid);
      await _control.release(pid);
    }
    _clearWindow();
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
    }
  }

  void _startWatch(int pid) {
    _watch?.cancel();
    final epoch = _epoch;
    _watch = Timer.periodic(watchInterval, (timer) {
      if (_watchBusy || _disposed) return;
      _watchBusy = true;
      unawaited(() async {
        try {
          await _control.heartbeat(pid);
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
          });
        } catch (_) {
          // A close may remove the mailbox while a watcher read is in flight.
        } finally {
          _watchBusy = false;
        }
      }());
    });
  }

  Future<void> _stopProcess() async {
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
    onOpenItemRoute?.call(command.itemId, seasonId: command.seasonId);
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
    if (runtime != null) {
      if (_privateRevoked ||
          snapshot.source == null ||
          snapshot.source!.account != _origin?.source.account ||
          snapshot.regionGeneration != _origin?.permit.regionGeneration) {
        await store.delete();
        return;
      }
      if (await runtime!.recoverSnapshot(snapshot)) await store.delete();
      return;
    }
    final client = auth.client;
    if (snapshot.baseUrl != client.baseUrl?.toString() ||
        snapshot.userId != client.userId) {
      return;
    }
    final token = client.accessToken;
    try {
      await client
          .reportStopped(PlaybackReport.fromSnapshot(snapshot))
          .timeout(reportTimeout);
    } catch (_) {
      _notify(PlayerHostNotice.progressSyncFailed);
      return;
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
          event['generation'] != origin.permit.regionGeneration ||
          event['source'] is! Map ||
          decodeSource(
                Map<String, dynamic>.from(event['source'] as Map),
              ).account !=
              origin.source.account ||
          event['item'] !=
              decodeSource(
                Map<String, dynamic>.from(event['source'] as Map),
              ).itemId ||
          _privateRevoked) {
        throw StateError('Stale or foreign playback event');
      }
      origin.permit.requireValid();
      final version = event['version'] as String;
      if (_watchSession?.source.mediaSourceId != version ||
          _watchSession?.source.itemId != event['item']) {
        final actual = await runtime!.resolve(
          PlayerOpenRequest(
            itemId: event['item'] as String,
            source: decodeSource(
              Map<String, dynamic>.from(event['source'] as Map),
            ),
            work: origin.work,
            libraryId: origin.libraryId,
          ),
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
            .project(origin.source.account.region)
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
        outcome['generation'] != origin.permit.regionGeneration ||
        outcome['sequence'] != _lastObservationSequence ||
        outcome['item'] != session.source.itemId ||
        outcome['version'] != session.source.mediaSourceId) {
      return;
    }
    final records = runtime!.history
        .records(session.source.account.region)
        .where((r) => r.sessionId == session.id && r.source == session.source);
    if (records.length != 1) return;
    await runtime!.history.synchronize(records.single, (_, _) async {
      // The helper already dispatched the report. Never send it twice.
      if (outcome['succeeded'] != true) {
        throw StateError('Helper report failed');
      }
    });
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
          command['generation'] != actual.permit.regionGeneration ||
          command['source'] is! Map ||
          decodeSource(
                Map<String, dynamic>.from(command['source'] as Map),
              ).account !=
              actual.source.account ||
          _privateRevoked) {
        throw StateError('Stale playback switch command');
      }
      actual.permit.requireValid();
      _lastSwitchCommand = sequence;
      switch (command['action']) {
        case 'authorizeItem':
          await runtime!.resolve(
            PlayerOpenRequest(
              itemId: command['item'] as String,
              source: SourceReference(
                account: actual.source.account,
                itemId: command['item'] as String,
              ),
              work: actual.work,
              libraryId: actual.libraryId,
            ),
          );
          actual.permit.requireValid();
        case 'inspect':
          final itemId = command['item'] as String;
          final original = await runtime!.resolve(
            PlayerOpenRequest(
              itemId: itemId,
              source: SourceReference(
                account: actual.source.account,
                itemId: itemId,
              ),
              work: actual.work,
              libraryId: actual.libraryId,
            ),
          );
          final old = PlaybackOrigin(
            source: original.source,
            work: original.work,
            libraryId: original.libraryId,
            permit: original.permit,
            client: actual.client,
          );
          final line = command['line'] as String?;
          final oldVersion = command['version'] as String;
          final target = line != null
              ? await runtime!.resolveLine(old, line, oldVersion)
              : await runtime!.resolve(
                  PlayerOpenRequest(
                    itemId: decodeSource(
                      Map<String, dynamic>.from(command['target'] as Map),
                    ).itemId,
                    source: decodeSource(
                      Map<String, dynamic>.from(command['target'] as Map),
                    ),
                    work: decodeSource(
                      Map<String, dynamic>.from(command['work'] as Map),
                    ),
                    libraryId: command['library'] as String,
                  ),
                );
          if (line == null) {
            await runtime!.requireEquivalent(
              old,
              target,
              numberingScheme: command['numbering'] as String?,
            );
          }
          final oldInfo = await old.permit.dispatch(
            (_) => old.client.getPlaybackInfo(itemId: itemId),
          );
          final newInfo = await target.permit.dispatch(
            (_) => target.client.getPlaybackInfo(
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
            throw StateError('Switch superseded');
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
              startTimeTicks: plan.positionTicks,
              startPaused: plan.paused,
              audioStreamIndex: command['audio'] as int?,
              subtitleStreamIndex: command['subtitle'] as int?,
              subtitleOff: command['subtitle'] == null,
              maxStreamingBitrate: plan.maxStreamingBitrate,
            ),
          );
          receipt['plan'] = plan.toJson();
        case 'cancel':
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
            startTimeTicks: choice == SwitchResumeChoice.beginning
                ? 0
                : pending.plan.positionTicks,
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
          commit = () => _openWithOrigin(request, prepared: target);
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
      receipt['accepted'] = false;
      receipt['error'] = '$error';
    }
    await ipc.replySwitchCommand(pid, receipt);
    if (commit != null) {
      // Let the helper receive its receipt before asking it to close. It drains
      // its last observation/Stopped before the main process launches target.
      final run = commit;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 100), () async {
          try {
            if (_pid != pid || _privateRevoked || _disposed) return;
            actual.permit.requireValid();
            await run();
            _saveSwitchPreference = true;
            switchFailure = null;
          } catch (error) {
            switchFailure = '$error';
            _notify(PlayerHostNotice.progressSyncFailed);
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
    if (_origin?.source.account.region != AccessRegion.private) return;
    _revokeWindow();
  }

  void _sourceRevoked(String serverId) {
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
          auth.regionAccess.generation,
          reportStopped:
              _origin?.source.account.region == AccessRegion.private &&
              auth.regionAccess.state == PrivateAccessState.locking,
        ),
      );
    }
  }

  Future<void> _closePrivate(RestrictedStopPermit permit) async {
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
    _disposed = true;
    _requestRevision++;
    _control.cancelPendingSpawns();
    auth.removeListener(_onAuth);
    auth.regionAccess.removeRevocationHook(_revokePrivate);
    auth.regionAccess.removeCleanupHook(_closePrivate);
    auth.regionAccess.removeTerminationHook(_terminatePrivate);
    runtime?.registry.removeMembershipCleanup(_membershipRevoked);
    runtime?.registry.removeSourceRevocation(_sourceRevoked);
    unawaited(_runInFlight(_stopProcess).whenComplete(_notices.close));
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
    launch = PlayerWindowLaunch.fromArguments(raw);
    if (launch.protocol == null) {
      throw const FormatException('Missing player process endpoint');
    }
  } catch (_) {
    exitCode = 1;
    exit(1);
  }
  runApp(PlayerWindowApp(launch: launch));
}

class PlayerWindowApp extends StatefulWidget {
  const PlayerWindowApp({super.key, required this.launch});
  final PlayerWindowLaunch launch;

  @override
  State<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends State<PlayerWindowApp> with WindowListener {
  late PlayerWindowLaunch _launch;
  late final AuthController _auth;
  var _playerKey = GlobalKey<PlayerPageState>();
  Future<void>? _closing;
  Timer? _commands;
  bool _readingCommand = false;
  int _ipcSequence = 0;
  int _launchRevision = 0;

  @override
  void initState() {
    super.initState();
    _launch = widget.launch;
    _auth = _authFor(_launch);
    windowManager.addListener(this);
    unawaited(_configureWindow());
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
    final client = EmbyClient(device: launch.device);
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
    setState(() {
      _launch = launch;
      _auth.client.attachSession(
        baseUrl: Uri.parse(launch.baseUrl),
        accessToken: launch.accessToken,
        userId: launch.userId,
        userAgent: launch.userAgent,
      );
    });
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
    await endpoint.write('switch-request', {
      ...command,
      'source': encodeSource(source),
      'generation': _launch.regionGeneration,
      'sequence': sequence,
    });
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline) && _closing == null) {
      final reply = await endpoint.read('switch-reply');
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
    int sequence,
  ) async {
    final endpoint = _launch.protocol;
    final source = _launch.request.source;
    if (endpoint == null || source == null || _closing != null) return false;
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
      audioLanguage: audio?.language,
      audioTitle: audio?.displayTitle,
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
      'generation': _launch.regionGeneration,
      'sequence': sequence,
      'observationSequence': observationSequence,
      'item': report.itemId,
      'version': report.mediaSourceId,
      'position': report.positionTicks,
      'actuallyPlaying': true,
      'timeline': timeline.toJson(),
      'savePreference': controller?.scopedPreferencePending == true,
      'settings': settings.toJson(),
    });
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline) && _closing == null) {
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
      'generation': _launch.regionGeneration,
      'item': report.itemId,
      'version': report.mediaSourceId,
      'succeeded': succeeded,
    });
  }

  Future<void> _openItemInHost(String itemId, {String? seasonId}) async {
    try {
      final protocol = _launch.protocol;
      if (protocol != null) {
        await PlayerHostOpenItem.write(
          itemId,
          protocol: protocol,
          seasonId: seasonId,
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
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final request = _launch.request;
    return AuthScope(
      controller: _auth,
      child: PlayerScope(
        bindings: PlayerBindings(
          observationSink: _launch.request.source == null ? null : _observe,
          reportOutcomeSink: _launch.request.source == null
              ? null
              : _reportOutcome,
          switchDispatcher: _launch.request.source == null
              ? null
              : _dispatchSwitch,
          snapshotStore: _launch.protocol == null
              ? null
              : FilePlaybackSessionSnapshotStore(
                  File('${_launch.protocol!.directory.path}/snapshot.json'),
                ),
        ),
        child: MaterialApp(
          title: _playerWindowTitle,
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.dark(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          home: PlayerPage(
            key: _playerKey,
            itemId: request.itemId,
            sourceRequest: request,
            autoResume: request.autoResume,
            mediaSourceId: request.mediaSourceId,
            audioStreamIndex: request.audioStreamIndex,
            subtitleStreamIndex: request.subtitleStreamIndex,
            startTimeTicks: request.startTimeTicks,
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
                    regionGeneration: _launch.regionGeneration,
                  ),
                  baseUrl: _launch.baseUrl,
                  accessToken: _launch.accessToken,
                  userId: _launch.userId,
                  device: _launch.device,
                  userAgent: _launch.userAgent,
                  protocol: _launch.protocol,
                  regionGeneration: _launch.regionGeneration,
                ),
              );
            },
            // 播放结束"查看剧集":写临时文件请主窗口打开详情,再关播放器。
            // 独立 CreateProcess 没有可用的 WindowMethodChannel,等待它
            // 只会误判成功或卡住;绝不能把剧集 id 当片源重开。
            onOpenItemDetail: (itemId, {seasonId}) {
              unawaited(_openItemInHost(itemId, seasonId: seasonId));
            },
          ),
        ),
      ),
    );
  }
}

String get _playerWindowTitle => '播放 - $kProductName';
