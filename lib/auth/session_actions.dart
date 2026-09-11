import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_scope.dart';

class SessionActions extends StatelessWidget {
  const SessionActions({super.key});

  static const logoutValue = '__logout__';

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
          tooltip: l10n.switchServer,
          icon: const Icon(Icons.account_circle_outlined),
          onSelected: (value) {
            if (value == logoutValue) {
              auth.logout();
              return;
            }
            auth.switchTo(value);
          },
          itemBuilder: (context) => [
            for (final server in auth.savedServers)
              PopupMenuItem(value: server.id, child: Text(server.name)),
            const PopupMenuDivider(),
            PopupMenuItem(value: logoutValue, child: Text(l10n.logout)),
          ],
        );
      },
    );
  }
}
