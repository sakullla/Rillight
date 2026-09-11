import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';

class SessionActions extends StatelessWidget {
  const SessionActions({super.key});

  static const logoutValue = '__logout__';
  static const serverMenuKey = Key('session-current-server');

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
        final serverName = auth.session!.server.name;
        return PopupMenuButton<String>(
          key: serverMenuKey,
          tooltip: l10n.switchServer,
          onSelected: (value) {
            if (value == logoutValue) {
              auth.logout();
              return;
            }
            if (value == auth.session?.server.id) {
              return;
            }
            final catalog = CatalogScope.maybeOf(context);
            final router = GoRouter.of(context);
            auth.switchTo(value).then((_) {
              catalog?.reload();
              router.go(AppRoutes.home);
            });
          },
          itemBuilder: (context) => [
            for (final server in auth.savedServers)
              PopupMenuItem(value: server.id, child: Text(server.name)),
            const PopupMenuDivider(),
            PopupMenuItem(value: logoutValue, child: Text(l10n.logout)),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.dns_outlined, size: 18),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(serverName, overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        );
      },
    );
  }
}
