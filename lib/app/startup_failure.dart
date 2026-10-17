import 'ui/ui.dart';
import 'l10n/app_localizations.dart';
import '../auth/auth_bootstrap.dart';

/// Keep failed upgrades recoverable without starting an empty configuration.
class StartupFailureApp extends StatefulWidget {
  const StartupFailureApp({super.key, required this.retry, this.upgrade});
  final Future<void> Function() retry;
  final ConfigurationUpgradeFailure? upgrade;
  @override
  State<StartupFailureApp> createState() => _StartupFailureAppState();
}

class _StartupFailureAppState extends State<StartupFailureApp> {
  bool busy = false;
  @override
  Widget build(BuildContext context) => CupertinoApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) {
        final l = AppLocalizations.of(context);
        return CupertinoPageScaffold(
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.upgrade == null
                          ? l.appInitializationFailed
                          : l.configurationUpgradeFailed,
                    ),
                    if (widget.upgrade != null) ...[
                      const SizedBox(height: 12),
                      Text(l.configurationRecoveryHint),
                      const SizedBox(height: 8),
                      AppSelectableText(widget.upgrade!.directory),
                    ],
                    const SizedBox(height: 24),
                    if (busy)
                      const CupertinoActivityIndicator()
                    else
                      CupertinoButton.filled(
                        onPressed: () async {
                          setState(() => busy = true);
                          try {
                            await widget.retry();
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                        child: Text(l.retry),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
