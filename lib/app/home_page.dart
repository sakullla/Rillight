import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';

class AppHomePage extends StatelessWidget {
  const AppHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Center(
      child: Text(
        l10n.appName,
        style: Theme.of(context).textTheme.headlineMedium,
      ),
    );
  }
}
