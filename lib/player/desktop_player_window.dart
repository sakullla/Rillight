import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
  });

  final PlayerOpenRequest request;
  final String baseUrl;
  final String accessToken;
  final String userId;
  final EmbyDeviceInfo device;
  final String? userAgent;
  final PlayerProcessProtocol? protocol;

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
      ...?protocol?.fields,
      'itemId': request.itemId,
      'autoResume': request.autoResume,
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
  }

  final AuthController auth;

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
  Future<void> open(PlayerOpenRequest request) {
    final revision = ++_requestRevision;
    _control.cancelPendingSpawns();
    return _runInFlight(() async {
      if (_disposed || revision != _requestRevision) return;
      await _stopProcess();
      if (_disposed || revision != _requestRevision) return;
      final launch = PlayerWindowLaunch.fromAuth(auth: auth, request: request);
      try {
        final pid = await _control.spawn(
          executable: Platform.resolvedExecutable,
          arguments: launch.toArguments(),
        );
        if (_disposed ||
            revision != _requestRevision ||
            auth.client.baseUrl?.toString() != launch.baseUrl ||
            auth.client.userId != launch.userId ||
            auth.client.accessToken != launch.accessToken) {
          await _control.kill(pid);
          await _reconcileSnapshot(pid);
          await _control.release(pid);
          return;
        }
        _pid = pid;
        _activeRevision = revision;
        _authIdentity = _currentAuthIdentity;
        _epoch++;
        _current = request;
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
          await _deliverOpenItem(pid, epoch);
          if (_control.isAlive(pid)) return;
          timer.cancel();
          if (_watch == timer) _watch = null;
          await _runInFlight(() async {
            if (_pid != pid || _epoch != epoch) return;
            _clearWindow();
            await _reconcileSnapshot(pid);
            await _control.release(pid);
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
    var closed = false;
    try {
      closed = await _control.requestClose(pid, closeTimeout);
    } catch (_) {}
    if (!closed) await _control.kill(pid);
    await _deliverOpenItem(pid, epoch);
    await _reconcileSnapshot(pid);
    await _control.release(pid);
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
                  request: PlayerOpenRequest(itemId: itemId, autoResume: false),
                  baseUrl: _launch.baseUrl,
                  accessToken: _launch.accessToken,
                  userId: _launch.userId,
                  device: _launch.device,
                  userAgent: _launch.userAgent,
                  protocol: _launch.protocol,
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
