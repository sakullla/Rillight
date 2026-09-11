import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/spawn_player_process.dart';
import 'package:window_manager/window_manager.dart';

const _hostChannel = WindowMethodChannel(
  'rillight/player_host',
  mode: ChannelMode.unidirectional,
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
      userAgent: auth.session?.server.activeLine?.userAgent,
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
        autoResume: json['autoResume'] == true,
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

class DesktopPlayerWindowHost extends PlayerWindowHost {
  DesktopPlayerWindowHost({required this.auth}) {
    auth.addListener(_onAuth);
  }

  final AuthController auth;
  int _pid = 0;
  Timer? _watch;
  PlayerOpenRequest? _current;

  @override
  PlayerOpenRequest? get current => _current;

  @override
  bool get embedsPlayerInCaller => false;

  @override
  Future<void> open(PlayerOpenRequest request) async {
    final launch = PlayerWindowLaunch.fromAuth(auth: auth, request: request);
    await _stopProcess();
    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}rillight-player-launch.json',
      );
      await file.writeAsString(launch.toArguments());
      final pid = spawnStandalonePlayer(
        executable: Platform.resolvedExecutable,
        payloadPath: file.path,
      );
      _pid = pid;
      _current = request;
      notifyListeners();
      _watch?.cancel();
      _watch = Timer.periodic(const Duration(milliseconds: 400), (timer) {
        if (!isPidAlive(pid)) {
          timer.cancel();
          if (_pid == pid) {
            _clearWindow();
          }
        }
      });
    } catch (error) {
      _pid = 0;
      _current = null;
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await _stopProcess();
    _clearWindow();
  }

  void _onAuth() {
    if (!auth.isLoggedIn) {
      unawaited(close());
    }
  }

  Future<void> _stopProcess() async {
    _watch?.cancel();
    _watch = null;
    final pid = _pid;
    _pid = 0;
    if (pid != 0) {
      killPid(pid);
    }
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
    auth.removeListener(_onAuth);
    unawaited(_stopProcess());
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
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1600, 900),
          minimumSize: Size(960, 540),
          center: true,
        ),
      );
      await windowManager.setTitle(_playerWindowTitle);
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      try {
        await windowManager.setMinimumSize(const Size(960, 540));
        await windowManager.setSize(const Size(1600, 900));
        await windowManager.center();
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
                  request: PlayerOpenRequest(itemId: itemId),
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
