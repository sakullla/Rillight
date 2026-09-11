import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window_host.dart';

class RillightApp extends StatelessWidget {
  RillightApp({
    super.key,
    AuthController? auth,
    GoRouter? router,
    this.playerBindings = const PlayerBindings(),
  }) : auth = auth ?? AuthController.memory(),
       windowHost = playerBindings.windowHost ?? OverlayPlayerWindowHost() {
    this.router = router ?? createAppRouter(auth: this.auth);
  }

  final AuthController auth;
  final PlayerBindings playerBindings;
  final PlayerWindowHost windowHost;
  late final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return AuthScope(
      controller: auth,
      child: PlayerScope(
        bindings: playerBindings,
        child: PlayerWindowScope(
          host: windowHost,
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
                child: PlayerWindowScope(
                  host: windowHost,
                  child: _PlayerWindowLayer(
                    host: windowHost,
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PlayerWindowLayer extends StatelessWidget {
  const _PlayerWindowLayer({required this.host, required this.child});

  final PlayerWindowHost host;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final request = host.current;
        if (!host.embedsPlayerInCaller || request == null) {
          return child;
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned.fill(
              child: FocusScope(
                autofocus: true,
                child: Navigator(
                  key: ObjectKey(request),
                  onGenerateRoute: (settings) {
                    return PageRouteBuilder<void>(
                      settings: settings,
                      pageBuilder: (context, animation, secondaryAnimation) {
                        return PlayerPage(
                          itemId: request.itemId,
                          autoResume: request.autoResume,
                          mediaSourceId: request.mediaSourceId,
                          audioStreamIndex: request.audioStreamIndex,
                          subtitleStreamIndex: request.subtitleStreamIndex,
                          startTimeTicks: request.startTimeTicks,
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
