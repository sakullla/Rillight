import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/player_bindings.dart';

class RillightApp extends StatelessWidget {
  RillightApp({
    super.key,
    AuthController? auth,
    GoRouter? router,
    this.playerBindings = const PlayerBindings(),
  }) : auth = auth ?? AuthController.memory() {
    this.router = router ?? createAppRouter(auth: this.auth);
  }

  final AuthController auth;
  final PlayerBindings playerBindings;
  late final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return AuthScope(
      controller: auth,
      child: PlayerScope(
        bindings: playerBindings,
        child: MaterialApp.router(
          title: kProductName,
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.dark(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          routerConfig: router,
          builder: (context, child) {
            return PlayerScope(
              bindings: playerBindings,
              child: child ?? const SizedBox.shrink(),
            );
          },
        ),
      ),
    );
  }
}
