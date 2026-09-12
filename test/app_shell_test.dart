import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/search/search_page.dart';

import 'emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'device-app-shell',
  version: '0.1.0',
);

void main() {
  testWidgets('connect page shell hides the top bar', (tester) async {
    await tester.pumpWidget(RillightApp());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(AppShell.topBarKey), findsNothing);
    expect(find.byKey(SessionActions.serverMenuKey), findsNothing);
    expect(find.text('连接服务器'), findsOneWidget);
  });

  testWidgets('unsigned deep link to a library redirects to connect', (
    tester,
  ) async {
    final app = RillightApp();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    app.router.go('/library/view-movies');
    await tester.pumpAndSettle();

    expect(find.text('连接服务器'), findsOneWidget);
    expect(find.byKey(AppShell.topBarKey), findsNothing);
    expect(find.byType(LibraryPage), findsNothing);
  });

  testWidgets('app forces cinematic dark ThemeMode', (tester) async {
    await tester.pumpWidget(RillightApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.theme?.brightness, Brightness.dark);
    expect(app.darkTheme?.brightness, Brightness.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
  });

  testWidgets('AppErrorView shows failure message and retry', (tester) async {
    var retried = false;

    await tester.pumpWidget(
      _l10nApp(AppErrorView(message: '无法连接服务器', onRetry: () => retried = true)),
    );

    expect(find.text('无法连接服务器'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
  });

  testWidgets('PosterPlaceholder remains available after image failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _l10nApp(
        const SizedBox(width: 120, height: 180, child: PosterPlaceholder()),
      ),
    );

    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(find.bySemanticsLabel('封面不可用'), findsOneWidget);
  });

  testWidgets(
    'logged-in shell is full-width and switching servers reloads home',
    (tester) async {
      final first = FakeEmbyServer();
      final second = FakeEmbyServer(
        serverId: 'server-id-2',
        serverName: '第二台',
        baseUrl: Uri.parse('http://emby-two.test:8096'),
        items: [
          FakeEmbyItem(
            id: 'movie-second',
            name: '第二台电影',
            type: 'Movie',
            parentId: 'view-movies',
            primaryImageTag: 'tag-second',
          ),
        ],
      );
      final adapter = FakeEmbyAdapter([first, second]);
      final auth = AuthController(
        client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
      await tester.runAsync(() async {
        await auth.connect(
          address: first.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        await auth.connect(
          address: second.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
      });
      expect(auth.session?.server.name, '第二台');

      await tester.pumpWidget(RillightApp(auth: auth));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(AppShell.topBarKey), findsOneWidget);
      expect(find.byKey(AppShell.homeNavKey), findsOneWidget);
      expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
      expect(find.text('第二台电影'), findsWidgets);

      await tester.ensureVisible(
        find.byKey(CatalogKeys.library('view-movies')),
      );
      await tester.tap(find.byKey(CatalogKeys.library('view-movies')));
      await tester.pumpAndSettle();

      bool isHomeCatalog(String request) {
        return request.contains('Items/Resume') ||
            request.contains('Items/Latest') ||
            request.contains('Views') ||
            request.contains('NextUp');
      }

      final firstHomeBefore = first.requests.where(isHomeCatalog).length;

      await tester.tap(find.byKey(SessionActions.serverMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('灯川测试').last);
      await tester.pumpAndSettle();

      expect(auth.session?.server.name, '灯川测试');
      expect(find.text('Inception'), findsWidgets);
      expect(find.text('第二台电影'), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(AppShell.topBarKey), findsOneWidget);
      expect(
        first.requests.where(isHomeCatalog).length,
        greaterThan(firstHomeBefore),
      );
    },
  );

  testWidgets('server menu lists lines and switching a line reloads home', (
    tester,
  ) async {
    final lan = FakeEmbyServer();
    final wan = FakeEmbyServer(
      serverId: lan.serverId,
      serverName: lan.serverName,
      baseUrl: Uri.parse('http://emby-wan.test:8096'),
      items: [
        FakeEmbyItem(
          id: 'movie-wan',
          name: '外网电影',
          type: 'Movie',
          parentId: 'view-movies',
          primaryImageTag: 'tag-wan',
        ),
      ],
    );
    final adapter = FakeEmbyAdapter([lan, wan]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await tester.runAsync(() async {
      await auth.connect(
        address: lan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.savedServers.single.lines, hasLength(2));
    expect(auth.session?.server.activeLine?.address, wan.baseUrl.toString());

    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    final lanResumeBefore = lan.requests
        .where((request) => request.contains('Items/Resume'))
        .length;

    await tester.tap(find.byKey(SessionActions.serverMenuKey));
    await tester.pumpAndSettle();
    expect(find.text('灯川测试 · emby-wan.test:8096'), findsOneWidget);
    await tester.tap(find.text('灯川测试 · emby.test:8096'));
    await tester.pumpAndSettle();

    expect(auth.session?.server.activeLine?.address, lan.baseUrl.toString());
    expect(
      lan.requests.where((request) => request.contains('Items/Resume')).length,
      greaterThan(lanResumeBefore),
    );
  });

  testWidgets('logged-in add=1 stays on connect without the top bar', (
    tester,
  ) async {
    final auth = await _connect(tester);
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(SessionActions.serverMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SessionActions.addServerKey));
    await tester.pumpAndSettle();

    expect(find.text('连接服务器'), findsOneWidget);
    expect(find.byKey(AppShell.topBarKey), findsNothing);
    expect(find.byType(HomePage), findsNothing);
    expect(
      GoRouter.of(tester.element(find.text('连接服务器'))).state.uri.toString(),
      '${AppRoutes.connect}?add=1',
    );
  });

  testWidgets('top bar switches home and a library; search is an overlay', (
    tester,
  ) async {
    final auth = await _connect(tester);
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(AppShell.topBarKey), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byKey(AppShell.libraryNavKey('view-movies')), findsOneWidget);

    await tester.tap(find.byKey(AppShell.libraryNavKey('view-movies')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(
      GoRouter.of(tester.element(find.byType(LibraryPage))).state.uri.path,
      AppRoutes.library('view-movies'),
    );

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchOverlay), findsOneWidget);
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(
      GoRouter.of(tester.element(find.byType(SearchOverlay))).state.uri.path,
      AppRoutes.library('view-movies'),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SearchOverlay), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchOverlay), findsOneWidget);

    await tester.tap(find.byKey(SearchOverlay.closeKey));
    await tester.pumpAndSettle();
    expect(find.byType(SearchOverlay), findsNothing);

    await tester.tap(find.byKey(AppShell.homeNavKey));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('search shortcut opens overlay without pushing /search', (
    tester,
  ) async {
    final auth = await _connect(tester);
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(HomePage));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(SearchOverlay), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
    expect(
      GoRouter.of(tester.element(find.byType(SearchOverlay))).state.uri.path,
      AppRoutes.home,
    );
  });

  testWidgets('deep link /search has no left rail', (tester) async {
    final auth = await _connect(tester);
    final app = RillightApp(auth: auth);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    app.router.go(AppRoutes.search);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(AppShell.topBarKey), findsOneWidget);
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.byType(SearchOverlay), findsNothing);
  });
}

Future<AuthController> _connect(WidgetTester tester) async {
  final server = FakeEmbyServer();
  final adapter = FakeEmbyAdapter([server]);
  final auth = AuthController(
    client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
    credentials: MemoryCredentialStore(),
    servers: MemoryServerListStore(),
  );
  await tester.runAsync(() {
    return auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
  });
  return auth;
}

Widget _l10nApp(Widget home) {
  return MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: home,
  );
}
