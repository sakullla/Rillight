import 'dart:async';
import 'dart:convert';

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
    unawaited(
      _hostChannel.setMethodCallHandler((call) async {
        if (call.method == 'closed') {
          _clearWindow();
        }
      }),
    );
    _windowsChanged = onWindowsChanged.listen((_) {
      unawaited(_syncFromSystem());
    });
    auth.addListener(_onAuth);
  }

  final AuthController auth;
  WindowController? _window;
  PlayerOpenRequest? _current;
  StreamSubscription<dynamic>? _windowsChanged;

  @override
  PlayerOpenRequest? get current => _current;

  @override
  bool get embedsPlayerInCaller => false;

  @override
  Future<void> open(PlayerOpenRequest request) async {
    final launch = PlayerWindowLaunch.fromAuth(auth: auth, request: request);
    final existing = _window;
    if (existing != null) {
      try {
        await existing.invokeMethod('open', launch.toJson());
        await existing.show();
        _current = request;
        notifyListeners();
        return;
      } catch (_) {
        _window = null;
      }
    }
    try {
      final window = await WindowController.create(
        WindowConfiguration(
          hiddenAtLaunch: true,
          arguments: launch.toArguments(),
        ),
      );
      await window.show();
      _window = window;
      _current = request;
      notifyListeners();
    } catch (error) {
      _window = null;
      _current = null;
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    final window = _window;
    _clearWindow();
    if (window == null) {
      return;
    }
    try {
      await window.invokeMethod('window_close');
    } catch (_) {}
  }

  void _onAuth() {
    if (!auth.isLoggedIn) {
      unawaited(close());
    }
  }

  Future<void> _syncFromSystem() async {
    final window = _window;
    if (window == null) {
      return;
    }
    try {
      final all = await WindowController.getAll();
      for (final item in all) {
        if (item.windowId == window.windowId) {
          return;
        }
      }
    } catch (_) {}
    _clearWindow();
  }

  void _clearWindow() {
    if (_window == null && _current == null) {
      return;
    }
    _window = null;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    auth.removeListener(_onAuth);
    unawaited(_windowsChanged?.cancel());
    unawaited(_hostChannel.setMethodCallHandler(null));
    super.dispose();
  }
}

Future<void> runPlayerWindow({
  required WindowController controller,
  String? argumentFallback,
}) async {
  PlayerWindowLaunch launch;
  try {
    final arguments = controller.arguments.trim().isEmpty
        ? (argumentFallback ?? '')
        : controller.arguments;
    launch = PlayerWindowLaunch.fromArguments(arguments);
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
  const PlayerWindowApp({
    super.key,
    required this.controller,
    required this.launch,
  });

  final WindowController controller;
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
    unawaited(
      widget.controller.setWindowMethodHandler((call) async {
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
      await windowManager.setTitle(_playerWindowTitle);
      await windowManager.setMinimumSize(const Size(640, 360));
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _closeWindow() async {
    if (_closing) {
      return;
    }
    _closing = true;
    await _playerKey.currentState?.controller?.shutdownSession();
    await _notifyHostClosed();
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
