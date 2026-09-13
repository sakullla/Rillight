import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_socket.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/library_nav_prefs.dart';
import 'package:rillight/player/player_window_host.dart';

class CatalogShell extends StatefulWidget {
  const CatalogShell({super.key, required this.auth, required this.child});

  final AuthController auth;
  final Widget child;

  @override
  State<CatalogShell> createState() => _CatalogShellState();
}

class _CatalogShellState extends State<CatalogShell> {
  late final CatalogController _catalog = CatalogController(auth: widget.auth);
  late final LibraryNavController _nav = LibraryNavController();
  PlayerWindowHost? _playerHost;
  PlayerOpenRequest? _playerRequest;

  // WebSocket 增强通道:登录会话(服务器/线路/令牌)变化时重连,
  // 登出/销毁时断开。仅为可选通知推送,失败静默降级。
  EmbySocket? _socket;
  Uri? _socketBase;
  String? _socketToken;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_syncNavServer);
    widget.auth.addListener(_syncSocket);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.auth.isLoggedIn) {
        _catalog.reload();
        _syncNavServer();
        _syncSocket();
      }
    });
  }

  void _syncSocket() {
    final base = widget.auth.client.baseUrl;
    final token = widget.auth.client.accessToken;
    if (!widget.auth.isLoggedIn ||
        base == null ||
        token == null ||
        token.isEmpty) {
      _teardownSocket();
      return;
    }
    if (base == _socketBase && token == _socketToken) {
      return;
    }
    _teardownSocket();
    _socketBase = base;
    _socketToken = token;
    _socket = EmbySocket(
      baseUrl: base,
      apiKey: token,
      cache: _catalog.cache,
      onUserDataChanged: () async {
        if (widget.auth.isLoggedIn) {
          await _catalog.reloadHomeRows();
        }
      },
      onLibraryChanged: () async {
        if (widget.auth.isLoggedIn) {
          await _catalog.reload();
        }
      },
    )..start();
  }

  void _teardownSocket() {
    unawaited(_socket?.stop());
    _socket = null;
    _socketBase = null;
    _socketToken = null;
  }

  void _syncNavServer() {
    final serverId = widget.auth.session?.server.id;
    if (serverId == null) {
      return;
    }
    unawaited(_nav.load(serverId));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = PlayerWindowScope.maybeOf(context);
    if (!identical(host, _playerHost)) {
      _playerHost?.removeListener(_onPlayerWindow);
      _playerHost = host;
      _playerHost?.addListener(_onPlayerWindow);
      _playerRequest = host?.current;
    }
  }

  void _onPlayerWindow() {
    final current = _playerHost?.current;
    if (_playerRequest != null && current == null && widget.auth.isLoggedIn) {
      unawaited(_catalog.reloadHomeRows());
    }
    _playerRequest = current;
  }

  @override
  void dispose() {
    widget.auth.removeListener(_syncNavServer);
    widget.auth.removeListener(_syncSocket);
    _teardownSocket();
    _playerHost?.removeListener(_onPlayerWindow);
    _catalog.dispose();
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = PlayerWindowScope.maybeOf(context);
    if (!identical(host, _playerHost)) {
      _playerHost?.removeListener(_onPlayerWindow);
      _playerHost = host;
      _playerHost?.addListener(_onPlayerWindow);
      _playerRequest = host?.current;
    }
    return CatalogScope(
      controller: _catalog,
      child: LibraryNavScope(controller: _nav, child: widget.child),
    );
  }
}
