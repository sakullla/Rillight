import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child, this.actions});

  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final onConnect =
        GoRouterState.of(context).matchedLocation == AppRoutes.connect;

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: onConnect ? null : () => context.go(AppRoutes.home),
          child: Text(l10n.appName),
        ),
        actions: actions,
      ),
      body: child,
    );
  }
}
