import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/home/catalog_scope.dart';

class SessionActions extends StatelessWidget {
  const SessionActions({super.key});

  static const logoutValue = '__logout__';
  static const addServerValue = '__add_server__';
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
        return PopupMenuButton<String>(
          key: serverMenuKey,
          tooltip: '${_chipLabel(auth.session!.server)}\n${l10n.switchServer}',
          icon: const Icon(Icons.dns_outlined),
          onSelected: (value) {
            if (value == logoutValue) {
              auth.logout();
              return;
            }
            if (value == addServerValue) {
              GoRouter.of(context).push('${AppRoutes.connect}?add=1');
              return;
            }
            final parsed = _parseMenuValue(value);
            if (parsed == null) {
              return;
            }
            final current = auth.session?.server;
            if (parsed.serverId == current?.id &&
                parsed.lineId == current?.activeLineId) {
              return;
            }
            final catalog = CatalogScope.maybeOf(context);
            final router = GoRouter.of(context);
            auth.switchTo(parsed.serverId, lineId: parsed.lineId).then((_) {
              catalog?.reload();
              router.go(AppRoutes.home);
            });
          },
          itemBuilder: (context) => [
            for (final server in auth.savedServers)
              for (final line in server.lines)
                PopupMenuItem(
                  value: _menuValue(server.id, line.id),
                  child: Text(_lineMenuLabel(server, line)),
                ),
            const PopupMenuDivider(),
            PopupMenuItem(
              key: addServerKey,
              value: addServerValue,
              child: Text(l10n.addServer),
            ),
            PopupMenuItem(value: logoutValue, child: Text(l10n.logout)),
          ],
        );
      },
    );
  }
}

const _menuSep = '\u001f';

String _menuValue(String serverId, String lineId) =>
    '$serverId$_menuSep$lineId';

({String serverId, String lineId})? _parseMenuValue(String value) {
  final index = value.indexOf(_menuSep);
  if (index <= 0 || index == value.length - 1) {
    return null;
  }
  return (
    serverId: value.substring(0, index),
    lineId: value.substring(index + 1),
  );
}

String _chipLabel(SavedServer server) {
  final line = server.activeLine;
  if (line == null || server.lines.length < 2) {
    return server.name;
  }
  return '${server.name} · ${line.hostLabel}';
}

String _lineMenuLabel(SavedServer server, ServerLine line) {
  return '${server.name} · ${line.hostLabel}';
}
