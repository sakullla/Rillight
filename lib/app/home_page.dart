import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_scope.dart';

class AppHomePage extends StatelessWidget {
  const AppHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = AuthScope.maybeOf(context)?.session;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.appName, style: Theme.of(context).textTheme.headlineMedium),
          if (session != null) ...[
            const SizedBox(height: 12),
            Text(l10n.connectedTo(session.server.name)),
          ],
        ],
      ),
    );
  }
}
