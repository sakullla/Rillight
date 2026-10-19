import '../emby/fake_emby_server.dart';
import '../helpers/cupertino_test_app.dart';
import '../helpers/synthetic_source_fixture.dart';
import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:flutter/services.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/widgets/browse_menu_button.dart';
import 'package:rillight/app/widgets/desktop_back_button.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/top_bar_backdrop.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/media_server/device.dart';

double _contrast(Color a, Color b) {
  final values = [a.computeLuminance(), b.computeLuminance()]..sort();
  return (values.last + .05) / (values.first + .05);
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    String location, {
    bool light = false,
    bool loggedIn = false,
  }) async {
    final AuthController auth;
    if (loggedIn) {
      final emby = FakeEmbyServer();
      final connected = SyntheticSourceAuth(
        adapter: FakeEmbyAdapter([emby]),
        device: const ClientDeviceInfo(
          clientName: 'Rillight',
          deviceName: 'test',
          deviceId: 'device-top-bar',
          version: '0.1.0',
        ),
        libraryIds: const {'view-movies'},
      );
      await tester.runAsync(
        () => connected.connect(
          address: emby.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        ),
      );
      auth = connected;
    } else {
      auth = AuthController.memory();
    }
    addTearDown(auth.dispose);
    final catalog = CatalogController(
      auth: auth,
      cache: CatalogCache()..debugSetDiskStore(null),
    );
    addTearDown(catalog.dispose);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) =>
                  const ColoredBox(color: Color(0xff000000)),
            ),
            GoRoute(
              path: AppRoutes.aggregation,
              builder: (context, state) =>
                  const ColoredBox(color: Color(0xff000000)),
            ),
            GoRoute(
              path: '/library/:id',
              builder: (context, state) => Builder(
                builder: (context) => AppButton(
                  key: const Key('scroll-under-bar'),
                  onPressed: () =>
                      const HomeScrollNotification(true).dispatch(context),
                  variant: AppButtonVariant.plain,
                  child: const Text('scroll'),
                ),
              ),
            ),
            GoRoute(
              path: '/item/:id',
              builder: (context, state) =>
                  const ColoredBox(color: Color(0xff000000)),
            ),
            GoRoute(
              path: '/shelf/:id',
              builder: (context, state) =>
                  const ColoredBox(color: Color(0xff000000)),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      CupertinoTestApp.router(
        theme: light ? AppUiTheme.light() : AppUiTheme.dark(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        routerConfig: router,
        builder: (context, child) => PresentationScope(
          environment: PresentationEnvironment.desktop,
          child: AuthScope(
            controller: auth,
            child: CatalogScope(controller: catalog, child: child!),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder barStack() => find
      .ancestor(
        of: find.byKey(AppShell.topBarKey),
        matching: find.byType(Stack),
      )
      .first;

  TopBarBackdrop backdrop(WidgetTester tester) => tester.widget<TopBarBackdrop>(
    find.descendant(of: barStack(), matching: find.byType(TopBarBackdrop)),
  );

  Finder fadeGradient() => find.descendant(
    of: barStack(),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).gradient != null,
    ),
  );

  testWidgets('aggregation bar uses the near-solid surface band', (
    tester,
  ) async {
    await pump(tester, AppRoutes.aggregation);
    expect(AppShell.topBarHeight, 56);
    expect(AppShell.topFadeHeight, 36);
    expect(backdrop(tester).height, AppShell.topBarHeight);
    expect(backdrop(tester).blur, isFalse);
    expect(fadeGradient(), findsOneWidget);
  });

  testWidgets('light home bar is solid instead of fogging the hero', (
    tester,
  ) async {
    await pump(tester, AppRoutes.home, light: true);
    expect(backdrop(tester).blur, isFalse);
    expect(fadeGradient(), findsOneWidget);
  });

  testWidgets('home keeps the fading top scrim', (tester) async {
    await pump(tester, AppRoutes.home);
    expect(backdrop(tester).blur, isTrue);
    expect(fadeGradient(), findsOneWidget);
  });

  testWidgets('detail and shelf pages share the same backdrop', (tester) async {
    await pump(tester, AppRoutes.item('movie-inception'));
    expect(backdrop(tester).blur, isTrue);
    expect(fadeGradient(), findsOneWidget);
  });

  testWidgets('library pages hand their heading to the bar after scrolling', (
    tester,
  ) async {
    await pump(tester, AppRoutes.library('movies'));
    double titleOpacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(AppShell.topBarKey),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    // 页内已有大标题,未滚动时顶栏不重复显示。
    expect(titleOpacity(), 0);
    // 实心顶栏上的返回是胶囊,不再压深色圆底。
    expect(find.byType(ScrimIconButton), findsNothing);
    expect(find.byType(DesktopBackButton), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scroll-under-bar')));
    await settle(tester);
    expect(titleOpacity(), 1);
  });

  testWidgets('browse menu appears off browse pages only', (tester) async {
    await pump(tester, AppRoutes.home);
    expect(find.byKey(BrowseMenuButton.buttonKey), findsNothing);
    await pump(tester, AppRoutes.aggregation);
    expect(find.byKey(BrowseMenuButton.buttonKey), findsNothing);
    await pump(tester, AppRoutes.library('movies'));
    expect(find.byKey(BrowseMenuButton.buttonKey), findsOneWidget);
  });

  testWidgets('closing search returns focus to the search trigger', (
    tester,
  ) async {
    await pump(tester, AppRoutes.library('movies'), loggedIn: true);
    final searchButton = find.widgetWithIcon(AppIconButton, AppIcons.search);
    await tester.tap(searchButton);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(
      tester.widget<AppIconButton>(searchButton).focusNode?.hasFocus,
      isTrue,
    );
  });

  for (final (name, theme) in [
    ('dark', AppUiTheme.dark()),
    ('light', AppUiTheme.light()),
  ]) {
    test('$name top bar foregrounds stay readable over white and black', () {
      final scheme = theme.colorScheme;
      final tint = TopBarBackdrop.tintFor(scheme);
      final foregrounds = [
        ('onSurface', scheme.onSurface),
        ('onSurfaceVariant', scheme.onSurfaceVariant),
        ('primary', scheme.primary),
        ('secondary', scheme.secondary),
        ('error', scheme.error),
      ];
      for (final base in [const Color(0xffffffff), const Color(0xff000000)]) {
        final background = Color.alphaBlend(tint, base);
        for (final (label, foreground) in foregrounds) {
          expect(
            _contrast(foreground, background),
            greaterThanOrEqualTo(4.5),
            reason: '$label over $background',
          );
        }
        expect(
          _contrast(scheme.outline, background),
          greaterThanOrEqualTo(3),
          reason: 'icon boundary over $background',
        );
      }
    });
  }
}
