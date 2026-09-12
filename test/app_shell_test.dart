import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
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
import 'package:rillight/search/search_page.dart';

import 'emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'device-app-shell',
  version: '0.1.0',
);

void main() {
  testWidgets('connect page shell hides the navigation rail', (tester) async {
    await tester.pumpWidget(RillightApp());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(SessionActions.serverMenuKey), findsNothing);
    expect(find.text('连接服务器'), findsOneWidget);
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

      expect(find.byType(NavigationRail), findsOneWidget);
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
      expect(find.byType(NavigationRail), findsOneWidget);
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
  testWidgets('rail switches between home, library and search directly', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final adapter = FakeEmbyAdapter([server]);
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await tester.runAsync(() async {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });

    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();

    final rail = find.byType(NavigationRail);
    expect(rail, findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: rail,
        matching: find.byIcon(Icons.video_library_outlined),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);

    await tester.tap(
      find.descendant(of: rail, matching: find.byIcon(Icons.search)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);

    // 已在搜索页时再次点击不重复入栈。
    await tester.tap(
      find.descendant(of: rail, matching: find.byIcon(Icons.search)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);

    await tester.tap(
      find.descendant(of: rail, matching: find.byIcon(Icons.home_outlined)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('navigation rail collapses and expands via toggle', (
    tester,
  ) async {
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
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);

    await tester.tap(find.byKey(AppShell.railToggle));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(AppShell.railToggle), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget);

    await tester.tap(find.byKey(AppShell.railToggle));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
  });
}

Widget _l10nApp(Widget home) {
  return MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: home,
  );
}
