import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    String location, {
    bool light = false,
  }) async {
    final auth = AuthController.memory();
    addTearDown(auth.dispose);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) =>
                  const ColoredBox(color: Colors.black),
            ),
            GoRoute(
              path: AppRoutes.aggregation,
              builder: (context, state) =>
                  const ColoredBox(color: Colors.black),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: light ? AppTheme.light() : AppTheme.dark(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
        builder: (context, child) => AuthScope(controller: auth, child: child!),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder barStack() => find
      .ancestor(
        of: find.byKey(AppShell.topBarKey),
        matching: find.byType(Stack),
      )
      .first;

  testWidgets('aggregation navigation blends into the page background', (
    tester,
  ) async {
    await pump(tester, AppRoutes.aggregation);
    final stack = barStack();
    expect(
      find.descendant(
        of: stack,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null,
        ),
      ),
      findsNothing,
    );
    final fill = tester.widget<ColoredBox>(
      find.descendant(of: stack, matching: find.byType(ColoredBox)),
    );
    expect(
      fill.color,
      Theme.of(
        tester.element(find.byKey(AppShell.topBarKey)),
      ).scaffoldBackgroundColor,
    );
  });

  testWidgets('light home bar is solid instead of fogging the hero', (
    tester,
  ) async {
    await pump(tester, AppRoutes.home, light: true);
    final stack = barStack();
    expect(
      find.descendant(
        of: stack,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null,
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: stack, matching: find.byType(ColoredBox)),
      findsOneWidget,
    );
  });

  testWidgets('home keeps the fading top scrim', (tester) async {
    await pump(tester, AppRoutes.home);
    expect(
      find.descendant(
        of: barStack(),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null,
        ),
      ),
      findsOneWidget,
    );
  });
}
