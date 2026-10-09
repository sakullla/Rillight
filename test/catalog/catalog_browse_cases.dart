import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import '../helpers/synthetic_source_fixture.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/library/aggregation_page.dart';
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
    final auth = SyntheticSourceAuth(
      adapter: adapter,
      device: _device,
      libraryIds: {'view-movies', 'view-tv', 'view-photos', 'view-mixed'},
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    final runtime = (await tester.runAsync(auth.runtime))!;
    final app = RillightApp(
      auth: auth,
      playerBindings: PlayerBindings(runtime: runtime),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      await tester.runAsync(
        () => runtime.history.close().timeout(const Duration(seconds: 5)),
      );
      auth.dispose();
    });
    await tester.pumpWidget(app);
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
          matching: find.text('媒体库'),
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
      expect(find.byType(ShelfGridPage), findsOneWidget);
      expect(find.text('Inception'), findsOneWidget);
      final libraryScroll = find
          .descendant(
            of: find.byType(ShelfGridPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('飞屋环游记'),
        250,
        scrollable: libraryScroll,
      );
      expect(find.text('飞屋环游记'), findsOneWidget);
      final movie = find.text('Inception');
      await tester.scrollUntilVisible(movie, -250, scrollable: libraryScroll);
      await tester.ensureVisible(movie);
      await tester.tap(movie);
      await settle(tester);
      expect(
        tester.widget<SelectableText>(find.byKey(ItemDetailPage.titleKey)).data,
        'Inception',
      );
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
      expect(find.textContaining('已看 40%'), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);
      expect(find.text('章节'), findsOneWidget);
      expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);

      await _tapDetailBack(tester);
      await settle(tester);
      await openLibrary(tester, 'view-tv');
      await Scrollable.ensureVisible(
        tester.element(find.text('老友记')),
        alignment: .5,
      );
      await settle(tester);
      await tester.tap(find.text('老友记'));
      await settle(tester);
      expect(
        tester.widget<SelectableText>(find.byKey(ItemDetailPage.titleKey)).data,
        '老友记',
      );
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
      expect(
        tester.widget<SelectableText>(find.byKey(ItemDetailPage.titleKey)).data,
        '老友记',
      );

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
      expect(find.byKey(const Key('aggregation-keyword')), findsOneWidget);
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.text('所选范围没有匹配作品'), findsNothing);
      expect(find.text('所选来源全部失败，请逐来源重试'), findsNothing);
      expect(
        server.requests
            .where((request) => request.contains('SearchTerm='))
            .length,
        beforeSearch,
      );

      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        'no-synthetic-match',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(find.text('输入片名后搜索'), findsNothing);
      expect(find.text('没有结果'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        'Inception',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      final overlayHit = find.descendant(
        of: find.byType(AggregationPage),
        matching: find.byWidgetPredicate(
          (w) => w is Text && w.data == 'Inception',
        ),
      );
      expect(overlayHit, findsOneWidget);
      await Scrollable.ensureVisible(tester.element(overlayHit), alignment: .5);
      await settle(tester);
      await tester.tap(overlayHit);
      await settle(tester);
      expect(find.byKey(SearchOverlay.closeKey), findsNothing);
      expect(
        tester.widget<SelectableText>(find.byKey(ItemDetailPage.titleKey)).data,
        'Inception',
      );

      await _tapDetailBack(tester);
      await settle(tester);
      server.searchStatus = 500;
      await tester.tap(find.byTooltip('搜索'));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        'Inception',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(find.text('所选来源全部失败，请逐来源重试'), findsOneWidget);
      // Search retries the failed server as one shelf.
      expect(find.textContaining('HTTP 500'), findsOneWidget);
      expect(find.text('所选范围没有匹配作品'), findsNothing);
      expect(find.text('重试'), findsWidgets);
      server.searchStatus = 200;
      await tester.tap(find.text('重试').first);
      await settle(tester);
      expect(find.text('所选来源全部失败，请逐来源重试'), findsNothing);
      expect(find.text('部分来源失败，已保留成功结果'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'Inception'),
        findsOneWidget,
      );
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
