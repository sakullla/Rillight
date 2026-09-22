import 'package:flutter/material.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_bootstrap.dart';
import 'package:rillight/auth/auth_controller.dart';

/// Owns startup retries and production auth. No desktop services are created.
class AndroidBootstrap extends StatefulWidget {
  const AndroidBootstrap({super.key, this.resolveEnvironment, this.createAuth});

  final Future<PresentationEnvironment> Function()? resolveEnvironment;
  final Future<AuthController> Function()? createAuth;

  @override
  State<AndroidBootstrap> createState() => _AndroidBootstrapState();
}

class _AndroidBootstrapState extends State<AndroidBootstrap> {
  RillightApp? _app;
  bool _failed = false;
  bool _detectionFailed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize({bool usePhone = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
      _detectionFailed = false;
    });
    try {
      final environment = usePhone
          ? PresentationEnvironment.phone
          : await (widget.resolveEnvironment ??
                () => PresentationEnvironment.resolve(isAndroid: true))();
      if (!mounted) return;
      if (environment.detectionFailed || environment.isDesktop) {
        setState(() => _detectionFailed = true);
        return;
      }
      final auth = await (widget.createAuth ?? createProductionAuth)();
      if (!mounted) {
        auth.dispose();
        return;
      }
      setState(() => _app = RillightApp(auth: auth, environment: environment));
    } catch (_) {
      // Startup failures can contain private paths or credentials. Present a
      // recoverable message without dumping exception text into the UI.
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _app?.router.dispose();
    _app?.auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _app ??
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context);
            return Scaffold(
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_busy) const CircularProgressIndicator(),
                        if (_failed || _detectionFailed) ...[
                          Text(
                            _detectionFailed
                                ? l10n.deviceDetectionFailed
                                : l10n.appInitializationFailed,
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            autofocus: true,
                            onPressed: () => _initialize(),
                            child: Text(l10n.retry),
                          ),
                          if (_detectionFailed)
                            TextButton(
                              onPressed: () => _initialize(usePhone: true),
                              child: Text(l10n.continueAsPhone),
                            ),
                        ],
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
