import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/poster_card.dart';

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

  Future<void> openLibrary(WidgetTester tester, String viewId) async {
    final homeTitle = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('灯川 Rillight'),
    );
    if (homeTitle.evaluate().isNotEmpty) {
      await tester.tap(homeTitle);
      await tester.pumpAndSettle();
    }
    final tile = find.byKey(CatalogKeys.library(viewId));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'home rows show resume progress and hide empty or missing NextUp',
    (tester) async {
      await pumpLoggedIn(tester);

      expect(find.text('灯川测试'), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);
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
      expect(find.text('片库'), findsOneWidget);
      expect(find.byKey(CatalogKeys.library('view-movies')), findsOneWidget);
      expect(find.byKey(CatalogKeys.library('view-tv')), findsOneWidget);
      expect(find.text('音乐'), findsNothing);
      expect(find.text('相册'), findsNothing);
      expect(find.text('混合媒体'), findsNothing);
      expect(find.text('未分类影视'), findsOneWidget);
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

    await tester.pageBack();
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
    await tester.ensureVisible(find.byKey(CatalogKeys.playedToggle));
    await tester.tap(find.byKey(CatalogKeys.playedToggle));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(CatalogKeys.back));
    await tester.tap(find.byKey(CatalogKeys.back));
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
    expect(find.byKey(CatalogKeys.item('movie-inception')), findsOneWidget);

    await tester.tap(find.byKey(CatalogKeys.item('movie-inception')));
    await tester.pumpAndSettle();
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

    await tester.tap(find.byKey(CatalogKeys.sortBy));
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

    await tester.tap(find.text('灯川 Rillight').first);
    await tester.pumpAndSettle();
    await openLibrary(tester, 'view-movies');
    expect(_posterNames(tester).first, '飞屋环游记');
    await tester.tap(find.byKey(CatalogKeys.sortBy));
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
      await tester.tap(find.byKey(CatalogKeys.sortBy));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(CatalogKeys.sortOption('SortName')));
      await tester.pumpAndSettle();

      expect(find.text('HTTP 500: items failed'), findsOneWidget);
      expect(find.text('飞屋环游记'), findsNothing);
    },
  );

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

    await tester.pageBack();
    await tester.pumpAndSettle();
    server.similarEmpty = true;
    final up = find.byKey(CatalogKeys.item('movie-up')).first;
    await tester.ensureVisible(up);
    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(find.text('飞屋环游记 (2009)'), findsOneWidget);
    expect(find.byKey(CatalogKeys.similarRow), findsNothing);
  });
}

Future<void> _openLatestMoviesMore(WidgetTester tester) async {
  final more = find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies));
  await tester.ensureVisible(more);
  await tester.tap(more);
  await tester.pumpAndSettle();
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
