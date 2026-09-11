import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child, this.actions});

  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appName), actions: actions),
      body: child,
    );
  }
}
