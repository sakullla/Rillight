import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/search/search_page.dart';

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
    HomeHero.autoAdvanceEnabled = false;
  });

  tearDown(() {
    HomeHero.autoAdvanceEnabled = true;
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
        return;
      }
      final back = find.byKey(CatalogKeys.back);
      if (back.evaluate().isEmpty) {
        return;
      }
      await tester.tap(back);
      await settle(tester);
    }
  }

  Future<void> openLibrary(WidgetTester tester, String viewId) async {
    await goHome(tester);
    final tile = find.byKey(AppShell.libraryNavKey(viewId));
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
      expect(find.byKey(AppShell.libraryNavKey('view-movies')), findsOneWidget);
      expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(CatalogKeys.resumeRow)).dy,
        lessThan(tester.getTopLeft(find.byKey(CatalogKeys.nextUpRow)).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(CatalogKeys.resumeRow)).dy,
        lessThan(tester.getTopLeft(find.byKey(CatalogKeys.latestMoviesRow)).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(CatalogKeys.resumeRow)).dy,
        lessThan(tester.getTopLeft(find.byKey(CatalogKeys.latestSeriesRow)).dy),
      );
      expect(find.text('Inception'), findsWidgets);
      expect(find.byKey(CatalogKeys.resumeProgress), findsWidgets);
      expect(find.byKey(CatalogKeys.nextUpRow), findsOneWidget);
      expect(find.text('最近更新的电影'), findsOneWidget);
      expect(find.text('飞屋环游记'), findsWidgets);
      expect(find.text('最近更新的剧集'), findsOneWidget);
      expect(find.text('老友记'), findsWidgets);
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfResume)),
        findsOneWidget,
      );
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfNextUp)),
        findsOneWidget,
      );
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies)),
        findsOneWidget,
      );
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestSeries)),
        findsOneWidget,
      );
      expect(find.text('更多'), findsNWidgets(4));
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.librariesMenu),
          matching: find.text('片库'),
        ),
        findsNothing,
      );
      expect(find.byKey(CatalogKeys.library('view-movies')), findsNothing);
      expect(find.byKey(CatalogKeys.library('view-tv')), findsNothing);
      expect(find.text('音乐'), findsNothing);
      expect(find.text('相册'), findsNothing);
      expect(find.text('混合媒体'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.librariesMenu),
          matching: find.text('未分类影视'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(AppShell.libraryNavKey('view-untyped')),
        findsOneWidget,
      );

      await openLibrary(tester, 'view-movies');
      expect(find.byKey(AppShell.libraryNavKey('view-movies')), findsNothing);
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
      expect(find.byKey(CatalogKeys.viewSeries), findsOneWidget);
      expect(find.byKey(CatalogKeys.episodesRow), findsNothing);
      await ensureVisibleBelowTopBar(
        tester,
        find.byKey(CatalogKeys.viewSeries),
      );
      await tapBelowTopBar(tester, find.byKey(CatalogKeys.viewSeries));
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
      expect(find.byKey(CatalogKeys.resumeRow), findsNothing);
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

  testWidgets('library and shelf grids center an empty icon and message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    server.items = [FakeEmbyItem(id: 'loose', name: '未入库', type: 'Movie')];
    final auth = await _connect(tester, adapter, server);
    await tester.pumpWidget(
      _host(
        auth,
        const ShelfGridPage(
          source: 'items',
          parentId: 'view-empty',
          includeItemTypes: 'Movie,Series',
          recursive: true,
          title: '空片库',
        ),
      ),
    );
    await settle(tester);
    _expectCenteredEmpty(tester);

    await tester.pumpWidget(
      _host(auth, const ShelfGridPage(source: 'resume', title: '继续观看')),
    );
    await settle(tester);
    _expectCenteredEmpty(tester);
  }, tags: ['integration']);

  testWidgets('search arrow keys move focus and bring the card into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    server.items = [
      for (var i = 0; i < 16; i++)
        FakeEmbyItem(
          id: 'focus-${i.toString().padLeft(2, '0')}',
          name: 'Focus ${i.toString().padLeft(2, '0')}',
          type: 'Movie',
        ),
    ];
    final auth = await _connect(tester, adapter, server);
    await tester.pumpWidget(_host(auth, const SearchPage()));
    await tester.enterText(find.byKey(CatalogKeys.searchField), 'Focus');
    await tester.tap(find.byKey(CatalogKeys.searchSubmit));
    await settle(tester);

    final scrollable = _verticalScrollable(find.byType(SearchPage));
    _requestItemFocus(tester, 'focus-00');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_focusedCatalogItemId(), 'focus-00');
    final offscreenId = _firstOffscreenItemId(tester, scrollable);
    expect(offscreenId, isNotNull);
    final targetId = offscreenId!;
    final before = tester.getRect(find.byKey(CatalogKeys.item(targetId)));
    expect(before.bottom, greaterThan(tester.getRect(scrollable).bottom + 1));

    String? focused;
    for (var step = 0; step < 8; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      focused = _focusedCatalogItemId();
      if (focused == targetId) {
        break;
      }
    }
    expect(focused, targetId);
    final revealed = tester.getRect(find.byKey(CatalogKeys.item(targetId)));
    final view = tester.getRect(scrollable);
    expect(revealed.top, greaterThanOrEqualTo(view.top - 1));
    expect(revealed.bottom, lessThanOrEqualTo(view.bottom + 1));
  }, tags: ['integration']);

  testWidgets(
    'search load-more failure keeps results and offers retry above them',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      server.items = [
        for (var i = 0; i < 55; i++)
          FakeEmbyItem(
            id: 'alpha-${i.toString().padLeft(2, '0')}',
            name: 'Alpha ${i.toString().padLeft(2, '0')}',
            type: 'Movie',
          ),
      ];
      final auth = await _connect(tester, adapter, server);
      await tester.pumpWidget(_host(auth, const SearchPage()));
      await tester.enterText(find.byKey(CatalogKeys.searchField), 'Alpha');
      await tester.tap(find.byKey(CatalogKeys.searchSubmit));
      await settle(tester);
      expect(find.byKey(CatalogKeys.item('alpha-00')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('alpha-50')), findsNothing);

      server.searchStatus = 500;
      final scrollable = _verticalScrollable(find.byType(SearchPage));
      var position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      await settle(tester);

      expect(find.text('HTTP 500: search failed'), findsOneWidget);
      expect(find.byType(AppErrorView), findsNothing);
      final notice = find.text('HTTP 500: search failed');
      final grid = find.byType(GridView);
      expect(
        tester.getBottomLeft(notice).dy,
        lessThanOrEqualTo(tester.getTopLeft(grid).dy + 1),
      );
      expect(find.descendant(of: grid, matching: notice), findsNothing);
      position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(0);
      await tester.pump();
      expect(find.byKey(CatalogKeys.item('alpha-00')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('alpha-50')), findsNothing);

      server.searchStatus = null;
      await tester.tap(find.byKey(SearchPage.loadMoreRetryKey));
      await tester.pump();
      await tester.pump();
      await settle(tester);
      expect(find.text('HTTP 500: search failed'), findsNothing);
      position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(find.byKey(CatalogKeys.item('alpha-50')), findsOneWidget);
      position.jumpTo(0);
      await tester.pump();
      expect(find.byKey(CatalogKeys.item('alpha-00')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    },
    tags: ['integration'],
  );

  testWidgets(
    'library load-more failure keeps cards and offers retry above them',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      server.items = [
        for (var i = 0; i < 80; i++)
          FakeEmbyItem(
            id: 'page-${i.toString().padLeft(2, '0')}',
            name: 'Page ${i.toString().padLeft(2, '0')}',
            type: 'Movie',
            parentId: 'view-pages',
          ),
      ];
      final auth = await _connect(tester, adapter, server);
      await tester.pumpWidget(
        _host(
          auth,
          const ShelfGridPage(
            source: 'items',
            parentId: 'view-pages',
            includeItemTypes: 'Movie',
            recursive: true,
            title: '分页片库',
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(CatalogKeys.item('page-00')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('page-60')), findsNothing);

      server.itemsStatus = 500;
      final scrollable = _verticalScrollable(find.byType(ShelfGridPage));
      var position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await settle(tester);
      position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await settle(tester);

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'catalog-item-',
              ),
        ),
        findsWidgets,
      );

      position.jumpTo(0);
      await tester.pump();
      const message = 'HTTP 500: items failed';
      expect(find.text(message), findsOneWidget);
      expect(find.byType(AppErrorView), findsNothing);
      final notice = find.text(message);
      final firstCard = find.byKey(CatalogKeys.item('page-00'));
      expect(firstCard, findsOneWidget);
      expect(
        tester.getBottomLeft(notice).dy,
        lessThanOrEqualTo(tester.getTopLeft(firstCard).dy + 1),
      );
      expect(find.byKey(CatalogKeys.item('page-60')), findsNothing);

      server.itemsStatus = null;
      await tester.tap(find.byKey(const Key('catalog-grid-page-retry')));
      await tester.pump();
      await settle(tester);
      expect(find.text(message), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(CatalogKeys.item('page-60')),
        400,
        scrollable: scrollable,
      );
      expect(find.byKey(CatalogKeys.item('page-60')), findsOneWidget);
      position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(0);
      await tester.pump();
      expect(find.byKey(CatalogKeys.item('page-00')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    },
    tags: ['integration'],
  );

  testWidgets(
    'stale search load-more does not apply after a new search or a cleared query',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final held = _HoldingSearchServer();
      final gates = <Completer<void>>[];
      addTearDown(() {
        for (final gate in gates) {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
      });
      held.items = [
        for (var i = 0; i < 55; i++)
          FakeEmbyItem(
            id: 'alpha-${i.toString().padLeft(2, '0')}',
            name: 'Alpha ${i.toString().padLeft(2, '0')}',
            type: 'Movie',
          ),
        FakeEmbyItem(id: 'beta-00', name: 'Beta', type: 'Movie'),
      ];
      final auth = await _connect(tester, FakeEmbyAdapter([held]), held);
      await tester.pumpWidget(_host(auth, const SearchPage()));

      Future<void> search(String term) async {
        await tester.enterText(find.byKey(CatalogKeys.searchField), term);
        await tester.tap(find.byKey(CatalogKeys.searchSubmit));
        await settle(tester);
      }

      Future<Completer<void>> armLoadMore() async {
        final gate = Completer<void>();
        gates.add(gate);
        held.holdLoadMore = gate;
        final scrollable = _verticalScrollable(find.byType(SearchPage));
        final position = tester.state<ScrollableState>(scrollable).position;
        position.jumpTo(position.maxScrollExtent);
        for (var i = 0; i < 20 && held.loadMoreHolds < gates.length; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(held.loadMoreHolds, gates.length);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        return gate;
      }

      void expectLoad(
        List<String> itemIds, {
        required int fetched,
        required bool hasMore,
        required bool loadingMore,
        required bool pageError,
      }) {
        final state = SearchPage.debugLoadState(
          tester.element(find.byType(SearchPage)),
        );
        expect(state.itemIds, itemIds);
        expect(state.fetched, fetched);
        expect(state.hasMore, hasMore);
        expect(state.loadingMore, loadingMore);
        expect(state.pageError, pageError);
      }

      await search('Alpha');
      expect(find.byKey(CatalogKeys.item('alpha-00')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('alpha-50')), findsNothing);
      final firstPage = [
        for (var i = 0; i < 50; i++) 'alpha-${i.toString().padLeft(2, '0')}',
      ];
      expectLoad(
        firstPage,
        fetched: 50,
        hasMore: true,
        loadingMore: false,
        pageError: false,
      );

      final newerSearch = await armLoadMore();
      await search('Beta');
      expect(find.byKey(CatalogKeys.item('beta-00')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('alpha-50')), findsNothing);
      expectLoad(
        const ['beta-00'],
        fetched: 1,
        hasMore: false,
        loadingMore: false,
        pageError: false,
      );
      newerSearch.complete();
      await tester.pump();
      await settle(tester);
      expect(find.byKey(CatalogKeys.item('beta-00')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('alpha-00')), findsNothing);
      expect(find.byKey(CatalogKeys.item('alpha-50')), findsNothing);
      expect(find.text('HTTP 500: search failed'), findsNothing);
      expectLoad(
        const ['beta-00'],
        fetched: 1,
        hasMore: false,
        loadingMore: false,
        pageError: false,
      );

      await search('Alpha');
      final cleared = await armLoadMore();
      await tester.enterText(find.byKey(CatalogKeys.searchField), '');
      await tester.tap(find.byKey(CatalogKeys.searchSubmit));
      await tester.pump();
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('alpha-00')), findsNothing);
      expectLoad(
        const [],
        fetched: 0,
        hasMore: false,
        loadingMore: false,
        pageError: false,
      );
      held.searchStatus = 500;
      cleared.complete();
      await tester.pump();
      await settle(tester);
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('alpha-00')), findsNothing);
      expect(find.byKey(CatalogKeys.item('alpha-50')), findsNothing);
      expect(find.text('HTTP 500: search failed'), findsNothing);
      expectLoad(
        const [],
        fetched: 0,
        hasMore: false,
        loadingMore: false,
        pageError: false,
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

Future<AuthController> _connect(
  WidgetTester tester,
  FakeEmbyAdapter adapter,
  FakeEmbyServer server,
) async {
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
  return auth;
}

Widget _host(AuthController auth, Widget child) {
  return MaterialApp(
    theme: AppTheme.dark(),
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: AuthScope(
      controller: auth,
      child: Scaffold(body: child),
    ),
  );
}

void _expectCenteredEmpty(WidgetTester tester) {
  const message = '暂无可浏览的内容，请刷新或从片库开始浏览。';
  final icon = find.byIcon(Icons.inbox_outlined);
  final text = find.text(message);
  expect(icon, findsOneWidget);
  expect(text, findsOneWidget);
  expect(tester.widget<Text>(text).textAlign, TextAlign.center);
  final page = tester.getRect(find.byType(ShelfGridPage));
  final iconRect = tester.getRect(icon);
  final textRect = tester.getRect(text);
  expect(iconRect.center.dx, closeTo(page.center.dx, 12));
  expect(textRect.center.dx, closeTo(page.center.dx, 12));
  expect(iconRect.bottom, lessThanOrEqualTo(textRect.top));
  final clusterCenterY = (iconRect.top + textRect.bottom) / 2;
  expect(clusterCenterY, closeTo(page.center.dy, page.height * 0.22));
}

class _HoldingSearchServer extends FakeEmbyServer {
  Completer<void>? holdLoadMore;
  int loadMoreHolds = 0;

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final search = options.uri.queryParameters['SearchTerm'];
    final start =
        int.tryParse(options.uri.queryParameters['StartIndex'] ?? '') ?? 0;
    final gate = holdLoadMore;
    if (search != null && start > 0 && gate != null) {
      holdLoadMore = null;
      loadMoreHolds++;
      await gate.future;
    }
    return super.handle(options, requestStream);
  }
}

Finder _verticalScrollable(Finder scope) {
  return find.descendant(
    of: scope,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    ),
  );
}

String? _firstOffscreenItemId(WidgetTester tester, Finder scrollable) {
  final viewport = tester.getRect(scrollable);
  String? offscreenId;
  for (final element in find.byType(InkWell).evaluate()) {
    final key = element.widget.key;
    if (key is! ValueKey<String> || !key.value.startsWith('catalog-item-')) {
      continue;
    }
    final box = element.renderObject! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.bottom > viewport.bottom + 1) {
      offscreenId = key.value.substring('catalog-item-'.length);
      break;
    }
  }
  return offscreenId;
}

void _requestItemFocus(WidgetTester tester, String id) {
  final element = tester.element(find.byKey(CatalogKeys.item(id)));
  Element? focusElement;
  void visit(Element child) {
    if (focusElement != null) {
      return;
    }
    if (child.widget is Focus) {
      focusElement = child;
      return;
    }
    child.visitChildren(visit);
  }

  visit(element);
  expect(focusElement, isNotNull);
  final focusNode =
      ((focusElement! as StatefulElement).state as dynamic).focusNode
          as FocusNode;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    focusNode.requestFocus();
  });
}

String? _focusedCatalogItemId() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) {
    return null;
  }
  String? id;
  context.visitAncestorElements((element) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('catalog-item-')) {
      id = key.value.substring('catalog-item-'.length);
      return false;
    }
    return true;
  });
  return id;
}

/// 返回钮在顶栏内,与首页导航并列。
Future<void> _tapDetailBack(WidgetTester tester) async {
  final back = find.byKey(CatalogKeys.back);
  expect(back, findsOneWidget);
  await tester.tap(back);
}
