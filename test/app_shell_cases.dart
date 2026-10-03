import 'helpers/image_cache_fixture.dart';
import 'helpers/settle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/search/search_page.dart';

import 'emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'device-app-shell',
  version: '0.1.0',
);

/// 桌面首页只构建视口附近的分栏，片库入口要先滚进列表才会挂上。
Future<void> revealHomeLibrary(WidgetTester tester, String viewId) async {
  final tile = find.byKey(CatalogKeys.library(viewId));
  if (tile.evaluate().isNotEmpty) {
    await tester.ensureVisible(tile);
    return;
  }
  final vertical = find.descendant(
    of: find.byKey(const PageStorageKey<String>('home-scroll')),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    ),
  );
  final position = tester.state<ScrollableState>(vertical).position;
  position.jumpTo(0);
  await tester.pump();
  final menu = find.byKey(CatalogKeys.librariesMenu);
  if (menu.evaluate().isEmpty) {
    await tester.scrollUntilVisible(menu, 320, scrollable: vertical);
  }
  if (tile.evaluate().isEmpty) {
    final rail = find.descendant(of: menu, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(
      tile,
      240,
      scrollable: rail.first,
      maxScrolls: 12,
    );
  }
  await tester.ensureVisible(tile);
}

void main() {
  setUp(isolateImageCache);
  group('app shell integration', () {});

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
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
    expect(find.bySemanticsLabel('封面不可用'), findsOneWidget);
  });

  group('app shell logged-in', () {
    testWidgets(
      'stored appearance applies on startup and switching keeps the login '
      'page and its inputs',
      (tester) async {
        final auth = AuthController.memory();
        final appearance = AppearanceController(
          store: MemoryPlayerSettingsStore(
            const PlayerSettings(appearanceStyle: 'light'),
          ),
        );
        await tester.pumpWidget(
          RillightApp(auth: auth, appearance: appearance),
        );
        await settle(tester);

        // 重启后保持上次选择:持久化的 light 在首屏生效。
        expect(appearance.style, AppearanceStyle.light);
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
          ThemeMode.light,
        );
        expect(find.byType(ConnectPage), findsOneWidget);
        expect(find.byKey(ConnectFormKeys.address), findsOneWidget);

        await tester.enterText(
          find.byKey(ConnectFormKeys.address),
          'http://emby.test:8096',
        );
        await settle(tester);

        await appearance.setStyle(AppearanceStyle.dark);
        await settle(tester);

        // 切换外观:登录页与已输入内容保持不变,只有亮度变化。
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
          ThemeMode.dark,
        );
        expect(find.byType(ConnectPage), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(ConnectFormKeys.address))
              .controller
              ?.text,
          'http://emby.test:8096',
        );
      },
      tags: ['integration'],
    );

    testWidgets('switching appearance keeps the logged-in home page mounted', (
      tester,
    ) async {
      final auth = await _connect(tester);
      final appearance = AppearanceController(
        store: MemoryPlayerSettingsStore(),
      );
      await tester.pumpWidget(RillightApp(auth: auth, appearance: appearance));
      await settle(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.text('Inception'), findsWidgets);

      await appearance.setStyle(AppearanceStyle.dark);
      await settle(tester);

      // 页面不因外观切换重建/丢状态,首页内容原样保留。
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.text('Inception'), findsWidgets);
    }, tags: ['integration']);

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
        await settle(tester);

        expect(find.byType(NavigationRail), findsNothing);
        expect(find.byKey(AppShell.topBarKey), findsOneWidget);
        expect(find.byKey(AppShell.homeNavKey), findsOneWidget);
        expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
        expect(find.text('第二台电影'), findsWidgets);

        await revealHomeLibrary(tester, 'view-movies');
        await tester.tap(find.byKey(CatalogKeys.library('view-movies')));
        await settle(tester);

        bool isHomeCatalog(String request) {
          return request.contains('Items/Resume') ||
              request.contains('Items/Latest') ||
              request.contains('Views') ||
              request.contains('NextUp');
        }

        final firstHomeBefore = first.requests.where(isHomeCatalog).length;

        await tester.tap(find.byKey(SessionActions.serverMenuKey));
        await settle(tester);
        await tester.tap(find.textContaining('灯川测试').last);
        await settle(tester);

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
      tags: ['integration'],
    );

    testWidgets(
      'a failed line switch keeps the current page and explains the reason',
      (tester) async {
        final lineA = FakeEmbyServer(
          serverName: '家庭影院',
          baseUrl: Uri.parse('http://line-a.test:8096'),
        );
        final lineB = FakeEmbyServer(
          serverId: lineA.serverId,
          serverName: lineA.serverName,
          baseUrl: Uri.parse('http://line-b.test:8096'),
        );
        final adapter = FakeEmbyAdapter([lineA, lineB]);
        final auth = AuthController(
          client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
          credentials: MemoryCredentialStore(),
          servers: MemoryServerListStore(),
        );
        await tester.runAsync(() async {
          await auth.connect(
            address: lineA.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
          await auth.connect(
            address: lineB.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
        });
        expect(auth.client.baseUrl, lineB.baseUrl);

        await tester.pumpWidget(RillightApp(auth: auth));
        await settle(tester);

        // 离开首页:失败的切换不应把用户带回首页。
        await revealHomeLibrary(tester, 'view-movies');
        await tester.tap(find.byKey(CatalogKeys.library('view-movies')));
        await settle(tester);
        expect(find.byType(LibraryPage), findsOneWidget);

        bool isHomeCatalog(String request) {
          return request.contains('Items/Resume') ||
              request.contains('Items/Latest') ||
              request.contains('Views') ||
              request.contains('NextUp');
        }

        lineA.publicInfoStatus = 500;
        lineA.publicInfoRawBody = 'upstream timeout';
        final homeBefore = lineB.requests.where(isHomeCatalog).length;

        await tester.tap(find.byKey(SessionActions.serverMenuKey));
        await settle(tester);
        final server = auth.savedServers.single;
        final lineATarget = server.lines.firstWhere(
          (line) => line.address == lineA.baseUrl.toString(),
        );
        await tester.tap(
          find.byKey(
            ServerSwitcherDialog.lineOptionKey(server.id, lineATarget.id),
          ),
        );
        await settle(tester);

        // 原线路、原会话、当前页面与已加载目录都保持。
        expect(auth.lineSwitchFailure?.detail, 'HTTP 500: upstream timeout');
        expect(auth.client.baseUrl, lineB.baseUrl);
        expect(
          auth.session?.server.activeLine?.address,
          lineB.baseUrl.toString(),
        );
        expect(find.byType(LibraryPage), findsOneWidget);
        expect(find.byType(HomePage), findsNothing);
        expect(lineB.requests.where(isHomeCatalog).length, homeBefore);
        // 失败原因以 SnackBar 可见。
        expect(find.byKey(SessionActions.lineSwitchFailureKey), findsOneWidget);
        expect(find.textContaining('切换线路失败'), findsOneWidget);
        expect(
          find.textContaining('HTTP 500: upstream timeout'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets(
      'top bar switches home, library, search overlay, and detail back',
      (tester) async {
        final auth = await _connect(tester);
        final app = RillightApp(auth: auth);
        await tester.pumpWidget(app);
        await settle(tester);

        expect(find.byType(NavigationRail), findsNothing);
        expect(find.byKey(AppShell.topBarKey), findsOneWidget);
        expect(find.byType(HomePage), findsOneWidget);
        expect(tester.getTopLeft(find.byType(HomePage)).dy, 0);
        expect(tester.getTopLeft(find.byKey(AppShell.topBarKey)).dy, 0);
        await revealHomeLibrary(tester, 'view-movies');
        expect(find.byKey(CatalogKeys.library('view-movies')), findsOneWidget);
        await tester.tap(find.byKey(AppShell.overflowNavKey));
        await settle(tester);
        expect(find.text('轮播图'), findsOneWidget);
        expect(find.text('下一集'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);

        await revealHomeLibrary(tester, 'view-movies');
        await tester.tap(find.byKey(CatalogKeys.library('view-movies')));
        await settle(tester);
        expect(find.byType(LibraryPage), findsOneWidget);
        expect(find.byKey(CatalogKeys.library('view-movies')), findsNothing);
        expect(find.byKey(AppShell.homeNavKey), findsNothing);
        expect(
          GoRouter.of(tester.element(find.byType(LibraryPage))).state.uri.path,
          AppRoutes.library('view-movies'),
        );

        await tester.tap(find.byTooltip('搜索'));
        await settle(tester);
        expect(find.byType(SearchOverlay), findsOneWidget);
        expect(find.byType(SearchPage), findsOneWidget);
        expect(find.byType(LibraryPage), findsOneWidget);
        expect(
          GoRouter.of(
            tester.element(find.byType(SearchOverlay)),
          ).state.uri.path,
          AppRoutes.library('view-movies'),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.byType(SearchOverlay), findsNothing);
        expect(find.byType(LibraryPage), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.search))
              .focusNode
              ?.hasFocus,
          isTrue,
        );

        await tester.tap(find.byTooltip('搜索'));
        await settle(tester);
        expect(find.byType(SearchOverlay), findsOneWidget);

        await tester.tap(find.byKey(SearchOverlay.closeKey));
        await settle(tester);
        expect(find.byType(SearchOverlay), findsNothing);

        await tester.tap(find.byKey(CatalogKeys.back));
        await settle(tester);
        expect(find.byType(HomePage), findsOneWidget);

        app.router.push(AppRoutes.item('movie-inception'));
        await settle(tester);
        expect(find.byType(ItemDetailPage), findsOneWidget);

        final back = find.byKey(CatalogKeys.back);
        expect(back, findsOneWidget);
        final button = tester.widget<ScrimIconButton>(back);
        final expectedTooltip = MaterialLocalizations.of(
          tester.element(back),
        ).backButtonTooltip;
        expect(button.tooltip, expectedTooltip);
        expect(find.byTooltip(expectedTooltip), findsOneWidget);
        expect(
          find.descendant(of: back, matching: find.byType(IconButton)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(AppShell.topBarKey),
            matching: find.byType(ScrimIconButton),
          ),
          findsOneWidget,
        );
        expect(tester.getSize(back), const Size(40, 40));
        expect(
          find.descendant(
            of: find.byKey(AppShell.topBarKey),
            matching: find.text('详情'),
          ),
          findsNothing,
        );

        await tester.tap(back);
        await settle(tester);
        expect(find.byType(ItemDetailPage), findsNothing);
        expect(find.byType(HomePage), findsOneWidget);
        expect(find.byKey(CatalogKeys.back), findsNothing);
      },
      tags: ['integration'],
    );
  });
}

Future<AuthController> _connect(
  WidgetTester tester, {
  FakeEmbyServer? server,
}) async {
  final emby = server ?? FakeEmbyServer();
  final adapter = FakeEmbyAdapter([emby]);
  final auth = AuthController(
    client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
    credentials: MemoryCredentialStore(),
    servers: MemoryServerListStore(),
  );
  await tester.runAsync(() {
    return auth.connect(
      address: emby.baseUrl.toString(),
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
