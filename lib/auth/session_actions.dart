import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_action.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/player/player_window_host.dart';

class SessionActions extends StatelessWidget {
  const SessionActions({super.key});

  static const serverMenuKey = Key('session-current-server');
  static const addServerKey = Key('session-add-server');

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.maybeOf(context);
    if (auth == null) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (!auth.isLoggedIn) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        final server = auth.session!.server;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SettingsAction(),
            IconButton(
              key: serverMenuKey,
              tooltip: '${_chipLabel(server)}\n${l10n.switchServer}',
              padding: EdgeInsets.zero,
              constraints: kTitleBarIconConstraints,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.person_outline),
              onPressed: () => _openSwitcher(context, auth),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSwitcher(BuildContext context, AuthController auth) async {
    final playerHost = PlayerWindowScope.maybeOf(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return ListenableBuilder(
          listenable: auth,
          builder: (context, _) {
            return ServerSwitcherDialog(
              servers: auth.savedServers,
              activeServerId: auth.session?.server.id,
              activeLineId: auth.session?.server.activeLineId,
              onSelect: (serverId, lineId) {
                Navigator.of(dialogContext).pop();
                unawaited(
                  _switchTo(context, auth, playerHost, serverId, lineId),
                );
              },
              onAddServer: () {
                Navigator.of(dialogContext).pop();
                GoRouter.of(context).push('${AppRoutes.connect}?add=1');
              },
              onLogout: () {
                Navigator.of(dialogContext).pop();
                unawaited(_logout(auth, playerHost));
              },
            );
          },
        );
      },
    );
  }

  /// 登出前先关闭播放窗口:此时主进程会话仍有效,宿主才能代发 Stopped。
  Future<void> _logout(
    AuthController auth,
    PlayerWindowHost? playerHost,
  ) async {
    await _closePlayer(playerHost);
    await auth.logout();
  }

  Future<void> _switchTo(
    BuildContext context,
    AuthController auth,
    PlayerWindowHost? playerHost,
    String serverId,
    String lineId,
  ) async {
    final current = auth.session?.server;
    if (serverId == current?.id && lineId == current?.activeLineId) {
      return;
    }
    final catalog = CatalogScope.maybeOf(context);
    final router = GoRouter.of(context);
    await _closePlayer(playerHost);
    await auth.switchTo(serverId, lineId: lineId);
    catalog?.reload();
    router.go(AppRoutes.home);
  }

  Future<void> _closePlayer(PlayerWindowHost? playerHost) async {
    if (playerHost == null) {
      return;
    }
    try {
      await playerHost.close();
    } catch (_) {
      // 播放窗口关闭失败不应阻断登出/切换。
    }
  }
}

String _chipLabel(SavedServer server) {
  final line = server.activeLine;
  if (line == null || server.lines.length < 2) {
    return server.name;
  }
  return '${server.name} · ${line.hostLabel}';
}
