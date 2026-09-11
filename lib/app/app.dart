import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';

class RillightApp extends StatelessWidget {
  RillightApp({super.key, AuthController? auth, GoRouter? router})
    : auth = auth ?? AuthController.memory() {
    this.router = router ?? createAppRouter(auth: this.auth);
  }

  final AuthController auth;
  late final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return AuthScope(
      controller: auth,
      child: MaterialApp.router(
        title: kProductName,
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: router,
      ),
    );
  }
}
