import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/auth/auth_controller.dart';
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

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_syncNavServer);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.auth.isLoggedIn) {
        _catalog.reload();
        _syncNavServer();
      }
    });
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
