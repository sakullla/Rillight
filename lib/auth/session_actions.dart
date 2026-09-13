import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_action.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/home/catalog_scope.dart';

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
                _switchTo(context, auth, serverId, lineId);
              },
              onAddServer: () {
                Navigator.of(dialogContext).pop();
                GoRouter.of(context).push('${AppRoutes.connect}?add=1');
              },
              onLogout: () {
                Navigator.of(dialogContext).pop();
                auth.logout();
              },
            );
          },
        );
      },
    );
  }

  void _switchTo(
    BuildContext context,
    AuthController auth,
    String serverId,
    String lineId,
  ) {
    final current = auth.session?.server;
    if (serverId == current?.id && lineId == current?.activeLineId) {
      return;
    }
    final catalog = CatalogScope.maybeOf(context);
    final router = GoRouter.of(context);
    auth.switchTo(serverId, lineId: lineId).then((_) {
      catalog?.reload();
      router.go(AppRoutes.home);
    });
  }
}

String _chipLabel(SavedServer server) {
  final line = server.activeLine;
  if (line == null || server.lines.length < 2) {
    return server.name;
  }
  return '${server.name} · ${line.hostLabel}';
}
