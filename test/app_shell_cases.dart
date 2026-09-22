import 'helpers/image_cache_fixture.dart';
import 'helpers/settle.dart';
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
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/item_detail_page.dart';
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
  setUp(isolateImageCache);
  group('app shell integration', () {
    testWidgets('unsigned connect shell, theme, and deep link', (tester) async {
      final app = RillightApp();
      await tester.pumpWidget(app);
      await settle(tester);

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(AppShell.topBarKey), findsNothing);
      expect(find.byKey(SessionActions.serverMenuKey), findsNothing);
      expect(find.text('连接服务器'), findsOneWidget);

      final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(material.themeMode, ThemeMode.dark);
      expect(material.theme?.brightness, Brightness.dark);
      expect(material.darkTheme?.brightness, Brightness.dark);
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark,
      );

      app.router.go('/library/view-movies');
      await settle(tester);
      expect(find.text('连接服务器'), findsOneWidget);
      expect(find.byKey(AppShell.topBarKey), findsNothing);
      expect(find.byType(LibraryPage), findsNothing);
    }, tags: ['integration']);
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
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
    expect(find.bySemanticsLabel('封面不可用'), findsOneWidget);
  });

  group('app shell logged-in', () {
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

        await tester.tap(find.byKey(AppShell.libraryNavKey('view-movies')));
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
        expect(
          find.byKey(AppShell.libraryNavKey('view-movies')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(AppShell.libraryNavKey('view-movies')));
        await settle(tester);
        expect(find.byType(LibraryPage), findsOneWidget);
        expect(find.byKey(AppShell.libraryNavKey('view-movies')), findsNothing);
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

    testWidgets('top bar keeps five libraries and puts the rest in overflow', (
      tester,
    ) async {
      final auth = await _connect(
        tester,
        server: FakeEmbyServer(
          views: [
            for (var i = 0; i < 8; i++)
              FakeEmbyItem(
                id: 'view-lib-$i',
                name: '电视-$i',
                type: 'CollectionFolder',
                collectionType: 'tvshows',
              ),
          ],
        ),
      );
      await tester.pumpWidget(RillightApp(auth: auth));
      await settle(tester);

      expect(find.byKey(AppShell.libraryNavKey('view-lib-0')), findsOneWidget);
      expect(find.byKey(AppShell.overflowNavKey), findsOneWidget);
      expect(find.byKey(AppShell.libraryNavKey('view-lib-7')), findsNothing);

      await tester.tap(find.byKey(AppShell.overflowNavKey));
      await settle(tester);
      expect(find.text('电视-7'), findsOneWidget);
      expect(find.text('自定义导航'), findsOneWidget);

      await tester.tap(find.text('自定义导航'));
      await settle(tester);
      expect(find.text('自定义导航'), findsWidgets);
      expect(find.text('保存'), findsOneWidget);

      Finder dialogText(String label) {
        return find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(label),
        );
      }

      expect(dialogText('电视-5'), findsOneWidget);
      expect(
        tester.getTopLeft(dialogText('电视-0')).dy,
        lessThan(tester.getTopLeft(dialogText('电视-5')).dy),
      );
      expect(
        tester.getTopLeft(dialogText('电视-4')).dy,
        lessThan(tester.getTopLeft(dialogText('电视-5')).dy),
      );

      await tester.tap(find.byKey(const Key('nav-pin-down-view-lib-0')));
      await tester.pump();
      expect(
        tester.getTopLeft(dialogText('电视-1')).dy,
        lessThan(tester.getTopLeft(dialogText('电视-0')).dy),
      );
    }, tags: ['integration']);
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
