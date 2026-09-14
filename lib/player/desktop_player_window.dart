import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_process_control.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:window_manager/window_manager.dart';

const _hostChannel = WindowMethodChannel(
  'rillight/player_host',
  mode: ChannelMode.unidirectional,
);

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
  });

  final PlayerOpenRequest request;
  final String baseUrl;
  final String accessToken;
  final String userId;
  final EmbyDeviceInfo device;
  final String? userAgent;

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

/// 独立播放进程宿主。
///
/// 关闭顺序:先 [PlayerProcessControl.requestClose](WM_CLOSE,播放进程
/// 自行发 Stopped),超时再 [PlayerProcessControl.kill];进程终止或意外
/// 退出后读取其会话快照,快照仍在(播放进程未能成功发出 Stopped)且归属
/// 当前会话时由主进程代发 Stopped,成功后删除快照,失败则保留并通过
/// [notices] 提示主窗口。
class DesktopPlayerWindowHost extends PlayerWindowHost {
  DesktopPlayerWindowHost({
    required this.auth,
    PlayerProcessControl? processControl,
    PlaybackSnapshotStoreLocator? snapshotStoreForPid,
    this.closeTimeout = const Duration(seconds: 4),
    this.reportTimeout = const Duration(seconds: 3),
    this.watchInterval = const Duration(milliseconds: 400),
  }) : _control = processControl ?? const WindowsPlayerProcessControl(),
       _snapshotStoreForPid =
           snapshotStoreForPid ?? FilePlaybackSessionSnapshotStore.forPid {
    auth.addListener(_onAuth);
  }

  final AuthController auth;

  /// 等待播放进程响应 WM_CLOSE 自行退出的上限。
  final Duration closeTimeout;

  /// 主进程代发 Stopped 的上限。
  final Duration reportTimeout;

  /// 探测播放进程是否仍存活的轮询间隔。
  final Duration watchInterval;

  final PlayerProcessControl _control;
  final PlaybackSnapshotStoreLocator _snapshotStoreForPid;
  final _notices = StreamController<PlayerHostNotice>.broadcast();
  int _pid = 0;
  Timer? _watch;
  PlayerOpenRequest? _current;
  var _disposed = false;
  var _epoch = 0;

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
    return _runInFlight(() async {
      final launch = PlayerWindowLaunch.fromAuth(auth: auth, request: request);
      await _stopProcess();
      try {
        final pid = await _control.spawn(
          executable: Platform.resolvedExecutable,
          arguments: launch.toArguments(),
        );
        _pid = pid;
        _epoch++;
        _current = request;
        notifyListeners();
        _startWatch(pid);
      } catch (error) {
        _pid = 0;
        _current = null;
        notifyListeners();
        rethrow;
      }
    });
  }

  @override
  Future<void> close() {
    return _runInFlight(() async {
      final epoch = _epoch;
      await _stopProcess();
      if (_epoch == epoch) {
        _clearWindow();
      }
    });
  }

  Future<void> _runInFlight(Future<void> Function() action) {
    final run = _inFlight.then((_) => action());
    _inFlight = run.then((_) {}, onError: (_, _) {});
    return run;
  }

  void _onAuth() {
    if (!auth.isLoggedIn) {
      unawaited(close());
    }
  }

  void _startWatch(int pid) {
    _watch?.cancel();
    _watch = Timer.periodic(watchInterval, (timer) {
      if (_control.isAlive(pid)) {
        return;
      }
      timer.cancel();
      if (_watch == timer) {
        _watch = null;
      }
      unawaited(
        _runInFlight(() async {
          if (_pid != pid) {
            return;
          }
          _clearWindow();
          await _reconcileSnapshot(pid);
        }),
      );
    });
  }

  Future<void> _stopProcess() async {
    _watch?.cancel();
    _watch = null;
    final pid = _pid;
    _pid = 0;
    if (pid == 0) {
      return;
    }
    final closed = await _control.requestClose(pid, closeTimeout);
    if (!closed) {
      _control.kill(pid);
    }
    await _reconcileSnapshot(pid);
  }

  /// 播放进程已终止:快照仍在时用主进程会话代发 Stopped。
  ///
  /// 播放进程成功发出 Stopped 后删除快照可能仍在途,此处重复代发是
  /// 幂等的,不视为错误。快照归属其他服务器/用户时不代发。
  Future<void> _reconcileSnapshot(int pid) async {
    final store = _snapshotStoreForPid(pid);
    final snapshot = await store.read();
    if (snapshot == null) {
      return;
    }
    final client = auth.client;
    if (snapshot.baseUrl != client.baseUrl?.toString() ||
        snapshot.userId != client.userId) {
      return;
    }
    try {
      await client
          .reportStopped(PlaybackReport.fromSnapshot(snapshot))
          .timeout(reportTimeout);
    } catch (_) {
      _notify(PlayerHostNotice.progressSyncFailed);
      return;
    }
    await store.delete();
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
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    auth.removeListener(_onAuth);
    unawaited(_runInFlight(_stopProcess).whenComplete(_notices.close));
    super.dispose();
  }
}

Future<void> runPlayerWindow({
  WindowController? controller,
  String? argumentFallback,
}) async {
  PlayerWindowLaunch launch;
  try {
    var raw = controller?.arguments.trim() ?? '';
    if (raw.isEmpty) {
      raw = argumentFallback ?? '';
    }
    final file = File(raw);
    if (raw.isNotEmpty && file.existsSync()) {
      raw = file.readAsStringSync();
    }
    launch = PlayerWindowLaunch.fromArguments(raw);
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(body: Center(child: Text(error.toString()))),
      ),
    );
    return;
  }
  runApp(PlayerWindowApp(controller: controller, launch: launch));
}

class PlayerWindowApp extends StatefulWidget {
  const PlayerWindowApp({super.key, this.controller, required this.launch});

  final WindowController? controller;
  final PlayerWindowLaunch launch;

  @override
  State<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends State<PlayerWindowApp> with WindowListener {
  late PlayerWindowLaunch _launch;
  late final AuthController _auth;
  var _playerKey = GlobalKey<PlayerPageState>();
  var _closing = false;

  @override
  void initState() {
    super.initState();
    _launch = widget.launch;
    _auth = _authFor(_launch);
    windowManager.addListener(this);
    unawaited(_configureWindow());
    final controller = widget.controller;
    if (controller != null) {
      unawaited(
        controller.setWindowMethodHandler((call) async {
          switch (call.method) {
            case 'open':
              _applyLaunch(_asLaunch(call.arguments));
              return null;
            case 'window_close':
              await _closeWindow();
              return null;
            default:
              throw MissingPluginException('Not implemented: ${call.method}');
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    unawaited(_notifyHostClosed());
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

  void _applyLaunch(PlayerWindowLaunch launch) {
    if (!mounted) {
      return;
    }
    unawaited(_playerKey.currentState?.controller?.shutdownSession());
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

  PlayerWindowLaunch _asLaunch(dynamic arguments) {
    if (arguments is String) {
      return PlayerWindowLaunch.fromArguments(arguments);
    }
    if (arguments is Map) {
      return PlayerWindowLaunch.fromJson(Map<String, dynamic>.from(arguments));
    }
    throw FormatException('unsupported player window payload: $arguments');
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
    } catch (_) {
      try {
        await windowManager.hide();
        await applyAdaptiveWindowSize(
          minimumSize: kMinPlayerWindowSize,
          maximumSize: kMaxPlayerWindowSize,
        );
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        await windowManager.show();
      } catch (_) {}
    }
  }

  Future<void> _closeWindow() async {
    if (_closing) {
      return;
    }
    _closing = true;
    await _playerKey.currentState?.controller?.shutdownSession();
    await _reclaimDiskCache();
    await _notifyHostClosed();
    if (widget.controller == null) {
      exit(0);
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      try {
        await windowManager.close();
      } catch (_) {}
    }
  }

  Future<void> _notifyHostClosed() async {
    try {
      await _hostChannel.invokeMethod('closed');
    } catch (_) {}
  }

  /// 关窗时按设置的上限回收 mpv 磁盘缓冲目录,避免长期占用增长。
  Future<void> _reclaimDiskCache() async {
    try {
      final store = await openPlayerSettingsStore();
      final settings = await store.read();
      await PlayerDiskCache.reclaim(
        PlayerDiskCache.defaultDirectory(),
        PlayerRuntimeOptions.effectiveDiskCacheLimitBytes(settings),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final request = _launch.request;
    return AuthScope(
      controller: _auth,
      child: PlayerScope(
        bindings: const PlayerBindings(),
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
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

String get _playerWindowTitle => '播放 - $kProductName';
