import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/search/search_overlay.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import '../helpers/top_bar_hit.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-catalog-ui',
  version: '0.1.0',
);

void main() {
  setUp(isolateImageCache);
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
  });

  Future<AuthController> pumpLoggedIn(WidgetTester tester) async {
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
    expect(auth.isLoggedIn, isTrue);
    await tester.pumpWidget(RillightApp(auth: auth));
    await settle(tester);
    return auth;
  }

  Future<void> goHome(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      final home = find.byKey(AppShell.homeNavKey);
      if (home.evaluate().isNotEmpty) {
        await tester.tap(home);
        await settle(tester);
        break;
      }
      final back = find.byKey(CatalogKeys.back);
      if (back.evaluate().isEmpty) {
        return;
      }
      await tester.tap(back);
      await settle(tester);
    }
    final vertical = find.descendant(
      of: find.byKey(const PageStorageKey<String>('home-scroll')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    if (vertical.evaluate().isEmpty) {
      return;
    }
    tester.state<ScrollableState>(vertical).position.jumpTo(0);
    await tester.pump();
  }

  /// 首页只构建视口附近的分栏，片库行也只构建露出的卡片。
  Future<void> revealHome(WidgetTester tester, Finder finder) async {
    Future<void> show() async {
      await tester.ensureVisible(finder);
      await settle(tester);
    }

    if (finder.evaluate().isNotEmpty) {
      await show();
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
    final rail = find.descendant(
      of: find.byKey(CatalogKeys.librariesMenu),
      matching: find.byType(Scrollable),
    );
    if (finder.evaluate().isEmpty && rail.evaluate().isNotEmpty) {
      try {
        await tester.scrollUntilVisible(
          finder,
          240,
          scrollable: rail.first,
          maxScrolls: 12,
        );
      } catch (_) {
        // 目标在片库行下面，不在这一条横滑里。
      }
    }
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(finder, 320, scrollable: vertical);
    }
    await show();
  }

  Future<void> openLibrary(WidgetTester tester, String viewId) async {
    await goHome(tester);
    final tile = find.byKey(CatalogKeys.library(viewId));
    await revealHome(tester, tile);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await settle(tester);
  }

  testWidgets(
    'home, library details, mark played, and search share one logged-in pump',
    (tester) async {
      await pumpLoggedIn(tester);

      expect(find.byTooltip('灯川测试\n切换服务器'), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(AppShell.topBarKey), findsOneWidget);
      expect(find.byKey(AppShell.homeNavKey), findsOneWidget);
      expect(find.byKey(AppShell.overflowNavKey), findsOneWidget);
      expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);
      expect(find.byKey(CatalogKeys.nextUpRow), findsNothing);
      final resumeTop = tester.getTopLeft(find.byKey(CatalogKeys.resumeRow)).dy;
      expect(find.text('Inception'), findsWidgets);
      expect(find.byKey(CatalogKeys.resumeProgress), findsWidgets);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.resumeRow),
          matching: find.text('老友记'),
        ),
        findsOneWidget,
      );
      expect(find.text('最近更新的电影'), findsNothing);
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfResume)),
        findsOneWidget,
      );
      await revealHome(tester, find.byKey(CatalogKeys.librariesMenu));
      final homeList = find.byKey(const PageStorageKey<String>('home-scroll'));
      final scrolled = tester
          .state<ScrollableState>(
            find
                .descendant(of: homeList, matching: find.byType(Scrollable))
                .first,
          )
          .position
          .pixels;
      expect(
        resumeTop,
        lessThan(
          tester.getTopLeft(find.byKey(CatalogKeys.librariesMenu)).dy +
              scrolled,
        ),
      );
      expect(find.byKey(CatalogKeys.library('view-movies')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.librariesMenu),
          matching: find.text('片库'),
        ),
        findsOneWidget,
      );
      await revealHome(tester, find.byKey(CatalogKeys.library('view-tv')));
      expect(find.byKey(CatalogKeys.library('view-tv')), findsOneWidget);
      expect(find.text('音乐'), findsNothing);
      await revealHome(tester, find.byKey(CatalogKeys.library('view-photos')));
      expect(find.byKey(CatalogKeys.library('view-photos')), findsOneWidget);
      expect(find.text('混合媒体'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.librariesMenu),
          matching: find.text('未分类影视'),
        ),
        findsOneWidget,
      );
      await revealHome(
        tester,
        find.byKey(CatalogKeys.shelfMore('library-view-movies')),
      );
      expect(find.text('飞屋环游记'), findsWidgets);
      expect(find.text('最近更新的剧集'), findsNothing);
      expect(find.text('老友记'), findsWidgets);
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfNextUp)),
        findsNothing,
      );
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies)),
        findsNothing,
      );
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestSeries)),
        findsNothing,
      );
      expect(
        find.byKey(CatalogKeys.shelfMore('library-view-movies')),
        findsOneWidget,
      );
      expect(
        find.byKey(CatalogKeys.shelfMore('library-view-tv')),
        findsOneWidget,
      );
      expect(find.text('更多'), findsWidgets);

      await openLibrary(tester, 'view-movies');
      expect(find.byKey(CatalogKeys.library('view-movies')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.text('电影'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(CatalogKeys.item('movie-inception')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('movie-up')), findsOneWidget);

      await tester.tap(find.byKey(CatalogKeys.item('movie-inception')));
      await settle(tester);
      expect(find.text('Inception (2010)'), findsOneWidget);
      expect(
        find.text(
          'A thief who steals corporate secrets through dream-sharing.',
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: find.byKey(ItemDetailPage.posterKey),
          matching: find.text(
            'A thief who steals corporate secrets through dream-sharing.',
          ),
        ),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.byKey(EpisodeOverviewSection.textKey)).data,
        'A thief who steals corporate secrets through dream-sharing.',
      );
      expect(find.text('已看 40%'), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);
      expect(find.text('章节'), findsOneWidget);
      expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);

      await _tapDetailBack(tester);
      await settle(tester);
      await openLibrary(tester, 'view-tv');
      await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
      await settle(tester);
      expect(find.text('老友记 (1994)'), findsOneWidget);
      expect(find.byKey(EpisodeOverviewSection.textKey), findsOneWidget);
      expect(find.text('简介'), findsNothing);
      expect(find.text('Six friends living in New York.'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ItemDetailPage.posterKey),
          matching: find.text('Six friends living in New York.'),
        ),
        findsNothing,
      );
      final row = find.byKey(CatalogKeys.episodesRow);
      expect(
        find.descendant(of: row, matching: find.text('1. The Pilot')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('Monica gets a new apartment.'),
        ),
        findsOneWidget,
      );
      final episode = find.byKey(CatalogKeys.episode('episode-friends-s1e1'));
      await tester.ensureVisible(episode);
      await tester.tap(episode);
      await settle(tester);
      expect(find.textContaining('The Pilot'), findsWidgets);
      expect(find.byKey(CatalogKeys.overview), findsNothing);
      expect(find.text('简介'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(ItemDetailPage.posterKey),
          matching: find.text('Monica gets a new apartment.'),
        ),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.byKey(EpisodeOverviewSection.textKey)).data,
        'Monica gets a new apartment.',
      );
      expect(find.byKey(CatalogKeys.seriesLink), findsOneWidget);
      expect(find.byKey(CatalogKeys.viewSeries), findsNothing);
      expect(find.byKey(CatalogKeys.episodesRow), findsNothing);
      await ensureVisibleBelowTopBar(
        tester,
        find.byKey(CatalogKeys.seriesLink),
      );
      await tapBelowTopBar(tester, find.byKey(CatalogKeys.seriesLink));
      await settle(tester);
      expect(find.text('老友记 (1994)'), findsOneWidget);

      await goHome(tester);
      expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);
      final resumeItem = find.byKey(CatalogKeys.item('movie-inception')).first;
      await tester.ensureVisible(resumeItem);
      await tester.tap(resumeItem);
      await settle(tester);
      await tapBelowTopBar(tester, find.byKey(CatalogKeys.playedToggle));
      await settle(tester);
      await _tapDetailBack(tester);
      await settle(tester);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.resumeRow),
          matching: find.byKey(CatalogKeys.item('movie-inception')),
        ),
        findsNothing,
      );
      expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(CatalogKeys.item('movie-inception')),
      );
      expect(find.byKey(CatalogKeys.item('movie-inception')), findsWidgets);

      final beforeSearch = server.requests
          .where((request) => request.contains('SearchTerm='))
          .length;
      await tester.tap(find.byTooltip('搜索'));
      await settle(tester);
      await tester.tap(find.byKey(CatalogKeys.searchSubmit));
      await settle(tester);
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.text('没有结果'), findsNothing);
      expect(
        server.requests
            .where((request) => request.contains('SearchTerm='))
            .length,
        beforeSearch,
      );

      await tester.enterText(find.byKey(CatalogKeys.searchField), 'Inception');
      await tester.tap(find.byKey(CatalogKeys.searchSubmit));
      await settle(tester);
      final overlayHit = find.descendant(
        of: find.byType(SearchOverlay),
        matching: find.byKey(CatalogKeys.item('movie-inception')),
      );
      expect(overlayHit, findsOneWidget);
      await tester.tap(overlayHit);
      await settle(tester);
      expect(find.byType(SearchOverlay), findsNothing);
      expect(find.text('Inception (2010)'), findsOneWidget);

      await _tapDetailBack(tester);
      await settle(tester);
      server.searchStatus = 500;
      await tester.tap(find.byTooltip('搜索'));
      await settle(tester);
      await tester.enterText(find.byKey(CatalogKeys.searchField), 'Inception');
      await tester.tap(find.byKey(CatalogKeys.searchSubmit));
      await settle(tester);
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('HTTP 500: search failed'), findsOneWidget);
      expect(find.text('没有结果'), findsNothing);
      expect(find.byKey(CatalogKeys.searchNoResults), findsNothing);
    },
    tags: ['integration'],
  );

  test('grid column max extent is at least 180/200/220', () {
    expect(
      ShelfGridPage.maxCrossAxisExtentFor(AppBreakpoints.compact - 1),
      greaterThanOrEqualTo(180),
    );
    expect(
      ShelfGridPage.maxCrossAxisExtentFor(AppBreakpoints.compact),
      greaterThanOrEqualTo(200),
    );
    expect(
      ShelfGridPage.maxCrossAxisExtentFor(AppBreakpoints.large),
      greaterThanOrEqualTo(200),
    );
    expect(
      ShelfGridPage.maxCrossAxisExtentFor(AppBreakpoints.large + 1),
      greaterThanOrEqualTo(220),
    );
  });
}

/// 返回钮在顶栏内,与首页导航并列。
Future<void> _tapDetailBack(WidgetTester tester) async {
  final back = find.byKey(CatalogKeys.back);
  expect(back, findsOneWidget);
  await tester.tap(back);
}
