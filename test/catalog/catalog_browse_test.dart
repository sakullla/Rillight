import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/search/search_page.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-catalog-ui',
  version: '0.1.0',
);

void main() {
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
    await tester.pumpAndSettle();
    return auth;
  }

  Future<void> goHome(WidgetTester tester) async {
    final home = find.byKey(AppShell.homeNavKey);
    if (home.evaluate().isNotEmpty) {
      await tester.tap(home);
      await tester.pumpAndSettle();
    }
  }

  Future<void> openLibrary(WidgetTester tester, String viewId) async {
    await goHome(tester);
    final tile = find.byKey(CatalogKeys.library(viewId));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'home rows show resume progress and hide empty or missing NextUp',
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
      expect(find.text('最近添加的电影'), findsOneWidget);
      expect(find.text('飞屋环游记'), findsWidgets);
      expect(find.text('最近添加的剧集'), findsOneWidget);
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
        findsOneWidget,
      );
      expect(find.byKey(CatalogKeys.library('view-movies')), findsOneWidget);
      expect(find.byKey(CatalogKeys.library('view-tv')), findsOneWidget);
      expect(find.text('音乐'), findsNothing);
      expect(find.text('相册'), findsNothing);
      expect(find.text('混合媒体'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.librariesMenu),
          matching: find.text('未分类影视'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(AppShell.libraryNavKey('view-untyped')),
        findsOneWidget,
      );
    },
  );

  testWidgets('empty catalog rows are hidden and NextUp 404 is not faked', (
    tester,
  ) async {
    for (final item in server.items) {
      item.playbackPositionTicks = 0;
      item.playedPercentage = null;
      item.nextUp = false;
    }
    server.items.removeWhere(
      (item) => item.type == 'Movie' || item.type == 'Episode',
    );
    server.nextUpStatus = 404;
    await pumpLoggedIn(tester);

    expect(find.byKey(CatalogKeys.resumeRow), findsNothing);
    expect(find.byKey(CatalogKeys.nextUpRow), findsNothing);
    expect(find.byKey(CatalogKeys.latestMoviesRow), findsNothing);
    expect(find.byKey(CatalogKeys.latestSeriesRow), findsNothing);
    expect(find.text('The One with the Sonogram'), findsNothing);
  });

  testWidgets('a failed home row stays visible without hiding the others', (
    tester,
  ) async {
    server.latestMovieStatus = 500;
    await pumpLoggedIn(tester);

    expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);
    expect(find.byKey(CatalogKeys.latestMoviesRow), findsOneWidget);
    expect(find.text('HTTP 500: latest movies failed'), findsOneWidget);
    expect(find.text('飞屋环游记'), findsNothing);
    expect(find.text('Inception'), findsWidgets);
  });

  testWidgets('library poster wall opens movie and series episode details', (
    tester,
  ) async {
    await pumpLoggedIn(tester);

    await openLibrary(tester, 'view-movies');
    expect(find.byKey(CatalogKeys.item('movie-inception')), findsOneWidget);
    expect(find.byKey(CatalogKeys.item('movie-up')), findsOneWidget);

    await tester.tap(find.byKey(CatalogKeys.item('movie-inception')));
    await tester.pumpAndSettle();
    expect(find.text('Inception (2010)'), findsOneWidget);
    expect(
      find.text('A thief who steals corporate secrets through dream-sharing.'),
      findsOneWidget,
    );
    expect(find.text('已看 40%'), findsOneWidget);
    await tester.ensureVisible(find.text('章节'));
    expect(find.text('章节'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);

    await _tapBelowTopBar(tester, find.byKey(CatalogKeys.back));
    await tester.pumpAndSettle();
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    expect(find.text('老友记 (1994)'), findsOneWidget);
    final episode = find.byKey(CatalogKeys.episode('episode-friends-s1e2'));
    await tester.ensureVisible(episode);
    await tester.tap(episode);
    await tester.pumpAndSettle();
    expect(find.textContaining('The One with the Sonogram'), findsWidgets);
  });

  testWidgets('marking played updates continue watching from the server', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);

    final resumeItem = find.byKey(CatalogKeys.item('movie-inception')).first;
    await tester.ensureVisible(resumeItem);
    await tester.tap(resumeItem);
    await tester.pumpAndSettle();
    await _tapBelowTopBar(tester, find.byKey(CatalogKeys.playedToggle));
    await tester.pumpAndSettle();

    await _tapBelowTopBar(tester, find.byKey(CatalogKeys.back));
    await tester.pumpAndSettle();
    expect(find.byKey(CatalogKeys.resumeRow), findsNothing);
    await tester.ensureVisible(find.byKey(CatalogKeys.item('movie-inception')));
    expect(find.byKey(CatalogKeys.item('movie-inception')), findsWidgets);
  });

  testWidgets('search hits open detail; empty query does not request', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    final beforeSearch = server.requests
        .where((request) => request.contains('SearchTerm='))
        .length;

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CatalogKeys.searchSubmit));
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    final overlayHit = find.descendant(
      of: find.byType(SearchOverlay),
      matching: find.byKey(CatalogKeys.item('movie-inception')),
    );
    expect(overlayHit, findsOneWidget);

    await tester.tap(overlayHit);
    await tester.pumpAndSettle();
    expect(find.byType(SearchOverlay), findsNothing);
    expect(find.text('Inception (2010)'), findsOneWidget);
  });

  testWidgets('search HTTP failure is an error, not empty success', (
    tester,
  ) async {
    server.searchStatus = 500;
    await pumpLoggedIn(tester);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(CatalogKeys.searchField), 'Inception');
    await tester.tap(find.byKey(CatalogKeys.searchSubmit));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('HTTP 500: search failed'), findsOneWidget);
    expect(find.text('没有结果'), findsNothing);
    expect(find.byKey(CatalogKeys.searchNoResults), findsNothing);
  });

  testWidgets('search overlay paginates 50 items with 600px prefetch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (var i = 0; i < 70; i++) {
      server.items.add(
        FakeEmbyItem(
          id: 'search-hit-$i',
          name: 'PagedHit $i',
          type: 'Movie',
          parentId: 'view-movies',
        ),
      );
    }
    await pumpLoggedIn(tester);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchOverlay), findsOneWidget);
    expect(find.byType(SearchPage), findsOneWidget);

    await tester.enterText(find.byKey(CatalogKeys.searchField), 'PagedHit');
    await tester.tap(find.byKey(CatalogKeys.searchSubmit));
    await tester.pumpAndSettle();
    Finder overlayItem(String id) {
      return find.descendant(
        of: find.byType(SearchOverlay),
        matching: find.byKey(CatalogKeys.item(id)),
      );
    }

    expect(overlayItem('search-hit-0'), findsOneWidget);
    expect(overlayItem('search-hit-69'), findsNothing);

    final grid = find.descendant(
      of: find.byType(SearchOverlay),
      matching: find.byType(GridView),
    );
    for (var i = 0; i < 30; i++) {
      await tester.drag(grid, const Offset(0, -400));
      await tester.pumpAndSettle();
      if (overlayItem('search-hit-69').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(overlayItem('search-hit-69'), findsOneWidget);
    expect(
      server.requests.any(
        (request) =>
            request.contains('SearchTerm=PagedHit') &&
            request.contains('StartIndex=50'),
      ),
      isTrue,
    );
  });

  testWidgets('a failed cover uses a placeholder and other items still open', (
    tester,
  ) async {
    await pumpLoggedIn(tester);

    expect(find.byType(PosterPlaceholder), findsWidgets);
    final upCard = find.byKey(CatalogKeys.item('movie-up'));
    await tester.ensureVisible(upCard);
    await tester.tap(upCard);
    await tester.pumpAndSettle();
    expect(find.text('飞屋环游记 (2009)'), findsOneWidget);
    expect(
      find.text('An old man flies his house to Paradise Falls.'),
      findsOneWidget,
    );
  });

  testWidgets('more page and movie library change order when SortBy changes', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await _openLatestMoviesMore(tester);

    expect(find.text('最近添加的电影'), findsWidgets);
    expect(_posterNames(tester).first, '飞屋环游记');

    await _tapBelowTopBar(tester, find.byKey(CatalogKeys.sortBy));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CatalogKeys.sortOption('SortName')));
    await tester.pumpAndSettle();
    expect(_posterNames(tester).first, 'Inception');
    expect(
      server.requests.any(
        (request) =>
            request.contains('SortBy=SortName') &&
            request.contains('SortOrder=Ascending'),
      ),
      isTrue,
    );

    await goHome(tester);
    await openLibrary(tester, 'view-movies');
    expect(_posterNames(tester).first, '飞屋环游记');
    await _tapBelowTopBar(tester, find.byKey(CatalogKeys.sortBy));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CatalogKeys.sortOption('SortName')));
    await tester.pumpAndSettle();
    expect(_posterNames(tester).first, 'Inception');
  });

  testWidgets(
    'changing sort shows the server failure instead of the old order',
    (tester) async {
      await pumpLoggedIn(tester);
      await _openLatestMoviesMore(tester);
      expect(_posterNames(tester).first, '飞屋环游记');

      server.itemsStatus = 500;
      await _tapBelowTopBar(tester, find.byKey(CatalogKeys.sortBy));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(CatalogKeys.sortOption('SortName')));
      await tester.pumpAndSettle();

      expect(find.text('HTTP 500: items failed'), findsOneWidget);
      expect(find.text('飞屋环游记'), findsNothing);
    },
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

  testWidgets('poster grid column count grows with the window width', (
    tester,
  ) async {
    int crossAxisCount() {
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      return delegate.crossAxisCount;
    }

    await pumpLoggedIn(tester);
    await _openLatestMoviesMore(tester);
    final compactCount = crossAxisCount();

    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();

    expect(crossAxisCount(), greaterThan(compactCount));
  });

  testWidgets(
    'overflowing shelf reveals hidden posters with the right control',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (var i = 0; i < 8; i++) {
        server.items.add(
          FakeEmbyItem(
            id: 'movie-extra-$i',
            name: 'Extra $i',
            type: 'Movie',
            parentId: 'view-movies',
            dateCreated: DateTime.utc(2000, 1, i + 1),
          ),
        );
      }
      server.items.add(
        FakeEmbyItem(
          id: 'movie-shelf-tail',
          name: 'ShelfTail',
          type: 'Movie',
          parentId: 'view-movies',
          dateCreated: DateTime.utc(1999, 1, 1),
        ),
      );

      await pumpLoggedIn(tester);
      await tester.ensureVisible(find.byKey(CatalogKeys.latestMoviesRow));
      expect(
        find.byKey(CatalogKeys.shelfScrollRight(CatalogKeys.shelfLatestMovies)),
        findsOneWidget,
      );
      expect(find.text('ShelfTail'), findsNothing);

      var taps = 0;
      while (find.text('ShelfTail').evaluate().isEmpty && taps < 16) {
        await tester.tap(
          find.byKey(
            CatalogKeys.shelfScrollRight(CatalogKeys.shelfLatestMovies),
          ),
        );
        await tester.pumpAndSettle();
        taps++;
      }
      expect(find.text('ShelfTail'), findsOneWidget);
    },
  );

  testWidgets('detail similar row appears only when the API returns items', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    final inception = find.byKey(CatalogKeys.item('movie-inception')).first;
    await tester.ensureVisible(inception);
    await tester.tap(inception);
    await tester.pumpAndSettle();
    expect(find.byKey(CatalogKeys.similarRow), findsOneWidget);
    expect(find.text('更多类似'), findsOneWidget);
    expect(find.byKey(CatalogKeys.item('movie-up')), findsWidgets);

    await _tapBelowTopBar(tester, find.byKey(CatalogKeys.back));
    await tester.pumpAndSettle();
    server.similarEmpty = true;
    final up = find.byKey(CatalogKeys.item('movie-up')).first;
    await tester.ensureVisible(up);
    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(find.text('飞屋环游记 (2009)'), findsOneWidget);
    expect(find.byKey(CatalogKeys.similarRow), findsNothing);
  });

  testWidgets('top bar switches libraries without returning home', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await tester.tap(find.byKey(AppShell.libraryNavKey('view-movies')));
    await tester.pumpAndSettle();
    expect(find.byKey(CatalogKeys.librarySwitcher), findsNothing);
    expect(find.byKey(CatalogKeys.item('movie-inception')), findsOneWidget);
    expect(find.byKey(CatalogKeys.item('series-friends')), findsNothing);
    expect(_posterNames(tester).first, '飞屋环游记');

    await _tapBelowTopBar(tester, find.byKey(CatalogKeys.sortBy));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CatalogKeys.sortOption('SortName')));
    await tester.pumpAndSettle();
    expect(_posterNames(tester).first, 'Inception');

    await tester.tap(find.byKey(AppShell.libraryNavKey('view-tv')));
    await tester.pumpAndSettle();
    expect(find.byKey(AppShell.homeNavKey), findsOneWidget);
    expect(find.byKey(CatalogKeys.item('movie-inception')), findsNothing);
    await tester.ensureVisible(find.byKey(CatalogKeys.item('series-friends')));
    expect(find.byKey(CatalogKeys.item('series-friends')), findsOneWidget);

    await tester.tap(find.byKey(AppShell.libraryNavKey('view-movies')));
    await tester.pumpAndSettle();
    expect(find.byKey(CatalogKeys.item('series-friends')), findsNothing);
    expect(_posterNames(tester).first, '飞屋环游记');
  });

  testWidgets('home hero rotates featured items via arrows', (tester) async {
    await pumpLoggedIn(tester);
    expect(find.byType(HomeHero), findsOneWidget);
    expect(tester.getTopLeft(find.byType(HomeHero)).dy, 0);
    expect(find.byKey(CatalogKeys.heroNext), findsOneWidget);
    expect(find.byKey(const Key('catalog-hero-index-0')), findsOneWidget);

    await tester.tap(find.byKey(CatalogKeys.heroNext));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-hero-index-0')), findsNothing);
    expect(find.byKey(const Key('catalog-hero-index-1')), findsOneWidget);

    await tester.tap(find.byKey(CatalogKeys.heroPrev));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-hero-index-0')), findsOneWidget);
  });

  testWidgets('home hero auto-advance pauses on hover and focus', (
    tester,
  ) async {
    final auth = await pumpLoggedIn(tester);
    HomeHero.autoAdvanceEnabled = true;
    await tester.pumpWidget(RillightApp(auth: auth));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('catalog-hero-index-0')), findsOneWidget);

    await tester.pump(
      HomeHero.autoAdvanceInterval + const Duration(milliseconds: 1),
    );
    expect(find.byKey(const Key('catalog-hero-index-1')), findsOneWidget);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(HomeHero)));
    await tester.pump();
    await tester.pump(HomeHero.autoAdvanceInterval);
    expect(find.byKey(const Key('catalog-hero-index-1')), findsOneWidget);

    await gesture.moveTo(Offset.zero);
    await tester.pump();
    final details = find.descendant(
      of: find.byType(HomeHero),
      matching: find.widgetWithText(OutlinedButton, '详情'),
    );
    _focusOf(tester, details)?.requestFocus();
    await tester.pump();
    await tester.pump(HomeHero.autoAdvanceInterval);
    expect(find.byKey(const Key('catalog-hero-index-1')), findsOneWidget);
  });

  testWidgets('home hero does not auto-advance when animations are disabled', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    HomeHero.autoAdvanceEnabled = true;
    await tester.pump();
    expect(find.byKey(const Key('catalog-hero-index-0')), findsOneWidget);
    await tester.pump(HomeHero.autoAdvanceInterval);
    expect(find.byKey(const Key('catalog-hero-index-0')), findsOneWidget);
    expect(find.byKey(const Key('catalog-hero-index-1')), findsNothing);
  });

  testWidgets('shelf arrow keys move focus between adjacent posters', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    final movies = find.byKey(CatalogKeys.latestMoviesRow);
    final first = find.descendant(
      of: movies,
      matching: find.byKey(CatalogKeys.item('movie-up')),
    );
    final second = find.descendant(
      of: movies,
      matching: find.byKey(CatalogKeys.item('movie-broken')),
    );
    await tester.ensureVisible(first);
    _focusOf(tester, first)?.requestFocus();
    await tester.pump();
    expect(_focusOf(tester, first)?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_focusOf(tester, second)?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_focusOf(tester, first)?.hasPrimaryFocus, isTrue);
  });

  testWidgets('vertical wheel on a shelf still scrolls the home page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpLoggedIn(tester);
    final poster = find.descendant(
      of: find.byKey(CatalogKeys.latestMoviesRow),
      matching: find.byKey(CatalogKeys.item('movie-up')),
    );
    await tester.ensureVisible(poster);
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byWidgetPredicate(
              (widget) => widget is Scrollable && widget.axis == Axis.vertical,
            ),
          )
          .first,
    );
    final before = scrollable.position.pixels;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(poster),
        scrollDelta: const Offset(0, 180),
      ),
    );
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(before));
  });

  testWidgets('detail chapter row scrolls horizontally with buttons', (
    tester,
  ) async {
    final movie = server.items.firstWhere((i) => i.id == 'movie-inception');
    movie.chapters = [
      for (var i = 0; i < 12; i++)
        FakeChapter(
          name: 'Chapter ${i + 1}',
          startPositionTicks: i * 5 * 60 * 10000000,
        ),
    ];
    await pumpLoggedIn(tester);
    final inception = find.byKey(CatalogKeys.item('movie-inception')).first;
    await tester.ensureVisible(inception);
    await tester.tap(inception);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('章节'));
    await tester.pumpAndSettle();
    final right = find.byKey(CatalogKeys.shelfScrollRight('chapters'));
    final left = find.byKey(CatalogKeys.shelfScrollLeft('chapters'));
    expect(right, findsOneWidget);
    expect(left, findsNothing);

    await tester.tap(right);
    await tester.pumpAndSettle();
    expect(left, findsOneWidget);
  });

  testWidgets(
    'detail hero is full-width with readable title and poster fallback',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      MediaImage.debugClearCache();
      addTearDown(MediaImage.debugClearCache);

      await pumpLoggedIn(tester);
      final inception = find.byKey(CatalogKeys.item('movie-inception')).first;
      await tester.ensureVisible(inception);
      await tester.tap(inception);
      await tester.pumpAndSettle();

      final hero = _detailHero();
      expect(hero, findsOneWidget);
      expect(tester.getTopLeft(hero).dx, 0);
      expect(tester.getTopLeft(hero).dy, 0);
      expect(tester.getSize(hero).width, 1200);

      final title = find.text('Inception (2010)');
      expect(title, findsOneWidget);
      expect(tester.getRect(hero).overlaps(tester.getRect(title)), isTrue);
      expect(find.byKey(PlayerKeys.open), findsOneWidget);
      expect(
        tester
            .getRect(hero)
            .overlaps(tester.getRect(find.byKey(PlayerKeys.open))),
        isTrue,
      );
      expect(find.byKey(CatalogKeys.back), findsOneWidget);
      expect(find.byKey(CatalogKeys.playedToggle), findsOneWidget);
      await tester.ensureVisible(find.text('章节'));
      expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
      expect(find.byKey(CatalogKeys.similarRow), findsOneWidget);

      await _pumpUntilHeroImage(tester);
      final image = tester.widget<Image>(
        find.descendant(of: hero, matching: find.byType(Image)),
      );
      expect(image.fit, BoxFit.contain);
      expect(image.alignment, Alignment.centerLeft);
      expect(
        server.requests.where(
          (request) => request.contains('/Images/Backdrop'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('switching versions restores the new source default audio', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    server.items.add(_VersionedMovie());

    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    final item = find.byKey(CatalogKeys.item('movie-versions'));
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(CatalogKeys.mediaSource));
    expect(find.byKey(CatalogKeys.mediaSource), findsOneWidget);
    expect(find.byKey(CatalogKeys.detailAudio), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byKey(CatalogKeys.detailAudio),
          )
          .initialValue,
      1,
    );

    await tester.tap(find.byKey(CatalogKeys.mediaSource));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧场版').last);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(CatalogKeys.mediaSource),
          )
          .initialValue,
      'source-b',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byKey(CatalogKeys.detailAudio),
          )
          .initialValue,
      3,
    );
    expect(find.byKey(PlayerKeys.open), findsOneWidget);
  });

  testWidgets('library poster wall loads more pages at the bottom', (
    tester,
  ) async {
    _addPagedMovies(server, 70);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    expect(find.byKey(CatalogKeys.item('bulk-0')), findsOneWidget);
    expect(find.byKey(CatalogKeys.item('bulk-69')), findsNothing);

    await _scrollGridUntil(tester, find.byKey(CatalogKeys.item('bulk-69')));
    expect(find.byKey(CatalogKeys.item('bulk-69')), findsOneWidget);
    expect(
      server.requests.any(
        (request) =>
            request.contains('ParentId=view-movies') &&
            request.contains('Limit=${ShelfGridPage.pageSize}') &&
            request.contains('StartIndex=${ShelfGridPage.pageSize}'),
      ),
      isTrue,
    );
  });

  testWidgets('append failure keeps the first page and retries later', (
    tester,
  ) async {
    _addPagedMovies(server, 70);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    expect(find.byKey(CatalogKeys.item('bulk-0')), findsOneWidget);
    expect(find.byKey(CatalogKeys.item('bulk-69')), findsNothing);
    expect(_posterNames(tester), contains('飞屋环游记'));

    bool requestedSecondPage() {
      return server.requests.any(
        (request) =>
            request.contains('ParentId=view-movies') &&
            request.contains('StartIndex=${ShelfGridPage.pageSize}'),
      );
    }

    expect(requestedSecondPage(), isFalse);

    server.itemsStatus = 500;
    await _prefetchNextGridPage(tester);
    expect(requestedSecondPage(), isTrue);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.byType(PosterCard), findsWidgets);
    expect(find.byKey(CatalogKeys.item('bulk-69')), findsNothing);

    await _jumpGridToTop(tester);
    expect(find.byKey(CatalogKeys.item('bulk-0')), findsOneWidget);
    expect(_posterNames(tester).first, '飞屋环游记');
    expect(find.byKey(CatalogKeys.sortBy), findsOneWidget);

    server.itemsStatus = null;
    await _scrollGridUntil(tester, find.byKey(CatalogKeys.item('bulk-69')));
    expect(find.byKey(CatalogKeys.item('bulk-69')), findsOneWidget);
  });

  testWidgets('similar shelf more stays on a single page', (tester) async {
    _addPagedMovies(server, 70);
    await pumpLoggedIn(tester);
    final inception = find.byKey(CatalogKeys.item('movie-inception')).first;
    await tester.ensureVisible(inception);
    await tester.tap(inception);
    await tester.pumpAndSettle();

    final more = find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfSimilar));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.byKey(CatalogKeys.item('bulk-0')), findsOneWidget);
    expect(find.byKey(CatalogKeys.item('bulk-69')), findsNothing);

    await _scrollGridUntil(
      tester,
      find.byKey(CatalogKeys.item('bulk-69')),
      maxDrags: 12,
    );
    expect(find.byKey(CatalogKeys.item('bulk-69')), findsNothing);
    final similarRequests = server.requests.where(
      (request) => request.contains('/Similar'),
    );
    expect(similarRequests, isNotEmpty);
    expect(similarRequests, everyElement(isNot(contains('StartIndex='))));
  });

  testWidgets('grid arrow keys move focus by row and column', (tester) async {
    server.items.add(
      FakeEmbyItem(
        id: 'movie-grid-tail',
        name: 'GridTail',
        type: 'Movie',
        parentId: 'view-movies',
        dateCreated: DateTime.utc(1990, 1, 1),
      ),
    );
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');

    final first = find.byKey(CatalogKeys.item('movie-up'));
    final nextColumn = find.byKey(CatalogKeys.item('movie-broken'));
    final nextRow = find.byKey(CatalogKeys.item('movie-grid-tail'));
    await tester.ensureVisible(first);
    _focusOf(tester, first)?.requestFocus();
    await tester.pump();
    expect(_focusOf(tester, first)?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_focusOf(tester, nextColumn)?.hasPrimaryFocus, isTrue);

    _focusOf(tester, first)?.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusOf(tester, nextRow)?.hasPrimaryFocus, isTrue);
  });
}

/// 顶栏叠在内容上时,控件中心可能落在栏内;点到栏下方仍落在同一控件上的位置.
Future<void> _tapBelowTopBar(WidgetTester tester, Finder finder) async {
  final bar = find.byKey(AppShell.topBarKey);
  final rect = tester.getRect(finder);
  var dy = rect.center.dy;
  if (bar.evaluate().isNotEmpty) {
    final barBottom = tester.getRect(bar).bottom;
    if (dy <= barBottom) {
      dy = (barBottom + 1).clamp(rect.top + 1, rect.bottom - 1).toDouble();
    }
  }
  await tester.tapAt(Offset(rect.center.dx, dy));
}

Future<void> _ensureVisibleBelowTopBar(
  WidgetTester tester,
  Finder finder,
) async {
  final context = tester.element(finder);
  final scrollable = Scrollable.maybeOf(context);
  if (scrollable == null) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    return;
  }
  final viewport = scrollable.position.viewportDimension;
  final bar = find.byKey(AppShell.topBarKey);
  final barBottom = bar.evaluate().isEmpty ? 0.0 : tester.getRect(bar).bottom;
  final alignment = viewport <= 0 ? 0.0 : ((barBottom + 8) / viewport);
  await Scrollable.ensureVisible(
    context,
    alignment: alignment.clamp(0.0, 1.0).toDouble(),
    duration: Duration.zero,
  );
  await tester.pumpAndSettle();
}

FocusNode? _focusOf(WidgetTester tester, Finder host) {
  final inner = find.descendant(of: host, matching: find.byType(ClipRRect));
  final context = inner.evaluate().isNotEmpty
      ? tester.element(inner.first)
      : tester.element(
          find.descendant(of: host, matching: find.byType(Text)).first,
        );
  return Focus.maybeOf(context);
}

Future<void> _openLatestMoviesMore(WidgetTester tester) async {
  final more = find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies));
  await _ensureVisibleBelowTopBar(tester, more);
  await _tapBelowTopBar(tester, more);
  await tester.pumpAndSettle();
}

void _addPagedMovies(FakeEmbyServer server, int count) {
  for (var i = 0; i < count; i++) {
    server.items.add(
      FakeEmbyItem(
        id: 'bulk-$i',
        name: 'Bulk $i',
        type: 'Movie',
        parentId: 'view-movies',
        primaryImageTag: 'tag-bulk-$i',
        dateCreated: DateTime.utc(
          1990,
          1,
          1,
        ).add(Duration(days: count - 1 - i)),
      ),
    );
  }
}

ScrollableState _gridScrollable(WidgetTester tester) {
  return tester.state<ScrollableState>(
    find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    ),
  );
}

Future<void> _jumpGridToTop(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  _gridScrollable(tester).position.jumpTo(0);
  await tester.pump();
}

Future<void> _prefetchNextGridPage(WidgetTester tester) async {
  final position = _gridScrollable(tester).position;
  var target = position.maxScrollExtent - ShelfGridPage.loadMoreThreshold + 1;
  if (target < 0) {
    target = 0;
  }
  position.jumpTo(target);
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _scrollGridUntil(
  WidgetTester tester,
  Finder target, {
  int maxDrags = 24,
}) async {
  final grid = find.byType(CustomScrollView);
  for (var i = 0; i < maxDrags; i++) {
    if (target.evaluate().isNotEmpty) {
      return;
    }
    await tester.drag(grid, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
}

List<String> _posterNames(WidgetTester tester) {
  return tester
      .widgetList<PosterCard>(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(PosterCard),
        ),
      )
      .map((card) => card.item.name)
      .toList();
}

Finder _detailHero() {
  return find.byWidgetPredicate(
    (widget) => widget is MediaImage && widget.preferBackdrop,
  );
}

Future<void> _pumpUntilHeroImage(WidgetTester tester) async {
  final image = find.descendant(
    of: _detailHero(),
    matching: find.byType(Image),
  );
  for (var i = 0; i < 12; i++) {
    if (image.evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }
  fail('detail hero image did not load');
}

class _VersionedMovie extends FakeEmbyItem {
  _VersionedMovie()
    : super(
        id: 'movie-versions',
        name: '双版本片',
        type: 'Movie',
        parentId: 'view-movies',
        overview: 'Two cuts of the same film.',
        productionYear: 2022,
        primaryImageTag: 'tag-versions',
      );

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json['MediaSources'] = [
      {
        'Id': 'source-a',
        'Name': '导演剪辑',
        'MediaStreams': [
          const FakeMediaStream(
            index: 0,
            type: 'Video',
            displayTitle: '1080p',
          ).toJson(),
          const FakeMediaStream(
            index: 1,
            type: 'Audio',
            displayTitle: 'English',
          ).toJson(),
          const FakeMediaStream(
            index: 2,
            type: 'Audio',
            displayTitle: '日本語',
          ).toJson(),
        ],
      },
      {
        'Id': 'source-b',
        'Name': '剧场版',
        'MediaStreams': [
          const FakeMediaStream(
            index: 0,
            type: 'Video',
            displayTitle: '1080p',
          ).toJson(),
          const FakeMediaStream(
            index: 3,
            type: 'Audio',
            displayTitle: '普通话',
          ).toJson(),
          const FakeMediaStream(
            index: 4,
            type: 'Audio',
            displayTitle: '粤语',
          ).toJson(),
        ],
      },
    ];
    return json;
  }
}
