import '../helpers/cupertino_test_app.dart';
import '../helpers/settle.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/browse_menu_button.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/media_server/models.dart';

const _movies = MediaItem(
  id: 'view-movies',
  name: '电影',
  type: 'CollectionFolder',
  collectionType: 'movies',
);
const _shows = MediaItem(
  id: 'view-shows',
  name: '剧集',
  type: 'CollectionFolder',
  collectionType: 'tvshows',
);

void main() {
  Future<GoRouter> pump(
    WidgetTester tester,
    String location, {
    List<MediaItem> libraries = const [_movies, _shows],
    double width = 1024,
    bool light = false,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final auth = AuthController.memory();
    addTearDown(auth.dispose);
    final catalog = CatalogController(
      auth: auth,
      cache: CatalogCache()..debugSetDiskStore(null),
    );
    catalog.libraries = libraries;
    catalog.librariesLoading = false;
    addTearDown(catalog.dispose);

    final router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const Text('home-page'),
            ),
            GoRoute(
              path: AppRoutes.aggregation,
              builder: (context, state) => const Text('aggregation-page'),
            ),
            GoRoute(
              path: '/library/:id',
              builder: (context, state) =>
                  Text('library-${state.pathParameters['id']}'),
            ),
            GoRoute(
              path: '/shelf/:id',
              builder: (context, state) => const Text('shelf-page'),
            ),
            GoRoute(
              path: '/item/:id',
              builder: (context, state) =>
                  Text('item-${state.pathParameters['id']}'),
            ),
            GoRoute(
              path: '/person/:id',
              builder: (context, state) =>
                  Text('person-${state.pathParameters['id']}'),
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
        builder: (context, child) => AuthScope(
          controller: auth,
          child: CatalogScope(controller: catalog, child: child!),
        ),
      ),
    );
    await settle(tester);
    return router;
  }

  String path(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(AppShell))).state.uri.path;

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(BrowseMenuButton.buttonKey));
    await settle(tester);
  }

  testWidgets('browse menu reaches home, aggregation and libraries', (
    tester,
  ) async {
    final router = await pump(tester, AppRoutes.library('view-movies'));
    await openMenu(tester);

    expect(find.byKey(BrowseMenuButton.homeEntryKey), findsOneWidget);
    expect(find.byKey(BrowseMenuButton.aggregationEntryKey), findsOneWidget);
    expect(find.byKey(BrowseMenuButton.dividerKey), findsOneWidget);
    expect(
      find.byKey(BrowseMenuButton.libraryEntryKey('view-shows')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(BrowseMenuButton.homeEntryKey));
    await settle(tester);
    expect(path(tester), AppRoutes.home);
    expect(find.text('home-page'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('browse menu opens aggregation from a library', (tester) async {
    await pump(tester, AppRoutes.library('view-movies'));
    await openMenu(tester);
    await tester.tap(find.byKey(BrowseMenuButton.aggregationEntryKey));
    await settle(tester);
    expect(path(tester), AppRoutes.aggregation);
    expect(find.text('aggregation-page'), findsOneWidget);
  });

  testWidgets('library to library replaces the current page', (tester) async {
    final router = await pump(tester, AppRoutes.library('view-movies'));
    await openMenu(tester);
    await tester.tap(
      find.byKey(BrowseMenuButton.libraryEntryKey('view-shows')),
    );
    await settle(tester);

    expect(path(tester), AppRoutes.library('view-shows'));
    expect(find.text('library-view-shows'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('shelf to library also replaces instead of stacking', (
    tester,
  ) async {
    await pump(tester, AppRoutes.shelfResume);
    await openMenu(tester);
    await tester.tap(
      find.byKey(BrowseMenuButton.libraryEntryKey('view-movies')),
    );
    await settle(tester);
    expect(path(tester), AppRoutes.library('view-movies'));
  });

  testWidgets('person to library pushes, keeping person on the back stack', (
    tester,
  ) async {
    final router = await pump(tester, AppRoutes.person('person-1'));
    await openMenu(tester);
    await tester.tap(
      find.byKey(BrowseMenuButton.libraryEntryKey('view-movies')),
    );
    await settle(tester);

    expect(path(tester), AppRoutes.library('view-movies'));
    expect(router.canPop(), isTrue);
    router.pop();
    await settle(tester);
    expect(path(tester), AppRoutes.person('person-1'));
  });

  testWidgets('closing the menu returns focus to its trigger', (tester) async {
    await pump(tester, AppRoutes.library('view-movies'));
    await openMenu(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(
      tester
          .widget<AppButton>(
            find.descendant(
              of: find.byKey(BrowseMenuButton.buttonKey),
              matching: find.byType(AppButton),
            ),
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('empty libraries still expose home and aggregation', (
    tester,
  ) async {
    await pump(tester, AppRoutes.library('view-movies'), libraries: const []);
    await openMenu(tester);
    expect(find.byKey(BrowseMenuButton.homeEntryKey), findsOneWidget);
    expect(find.byKey(BrowseMenuButton.aggregationEntryKey), findsOneWidget);
    expect(find.byKey(BrowseMenuButton.dividerKey), findsNothing);
  });

  testWidgets('the label collapses to an icon below 1200', (tester) async {
    await pump(tester, AppRoutes.library('view-movies'), width: 1199);
    expect(find.text(BrowseMenuButton.label), findsNothing);
    expect(find.byKey(BrowseMenuButton.buttonKey), findsOneWidget);
  });

  testWidgets('the label appears at 1200', (tester) async {
    await pump(tester, AppRoutes.library('view-movies'), width: 1200);
    expect(find.text(BrowseMenuButton.label), findsOneWidget);
  });
}
