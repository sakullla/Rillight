@Tags(['integration'])
library;

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
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/search/search_page.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/top_bar_hit.dart';

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
    for (var i = 0; i < 8; i++) {
      final home = find.byKey(AppShell.homeNavKey);
      if (home.evaluate().isNotEmpty) {
        await tester.tap(home);
        await tester.pumpAndSettle();
        return;
      }
      final back = find.byKey(CatalogKeys.back);
      if (back.evaluate().isEmpty) {
        return;
      }
      await tester.tap(back);
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

      await openLibrary(tester, 'view-movies');
      expect(find.byKey(AppShell.libraryNavKey('view-movies')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.text('电影'),
        ),
        findsNothing,
      );
      expect(find.byKey(CatalogKeys.item('movie-inception')), findsOneWidget);
      expect(find.byKey(CatalogKeys.item('movie-up')), findsOneWidget);

      await tester.tap(find.byKey(CatalogKeys.item('movie-inception')));
      await tester.pumpAndSettle();
      expect(find.text('Inception (2010)'), findsOneWidget);
      expect(
        find.text(
          'A thief who steals corporate secrets through dream-sharing.',
        ),
        findsWidgets,
      );
      expect(find.text('已看 40%'), findsOneWidget);
      expect(find.text('章节'), findsOneWidget);
      expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);

      await _tapDetailBack(tester);
      await tester.pumpAndSettle();
      await openLibrary(tester, 'view-tv');
      await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
      await tester.pumpAndSettle();
      expect(find.text('老友记 (1994)'), findsOneWidget);
      expect(find.byKey(CatalogKeys.overview), findsOneWidget);
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
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      expect(find.text('老友记 (1994)'), findsOneWidget);

      await goHome(tester);
      expect(find.byKey(CatalogKeys.resumeRow), findsOneWidget);
      final resumeItem = find.byKey(CatalogKeys.item('movie-inception')).first;
      await tester.ensureVisible(resumeItem);
      await tester.tap(resumeItem);
      await tester.pumpAndSettle();
      await tapBelowTopBar(tester, find.byKey(CatalogKeys.playedToggle));
      await tester.pumpAndSettle();
      await _tapDetailBack(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CatalogKeys.resumeRow), findsNothing);
      await tester.ensureVisible(
        find.byKey(CatalogKeys.item('movie-inception')),
      );
      expect(find.byKey(CatalogKeys.item('movie-inception')), findsWidgets);

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

      await _tapDetailBack(tester);
      await tester.pumpAndSettle();
      server.searchStatus = 500;
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CatalogKeys.searchField), 'Inception');
      await tester.tap(find.byKey(CatalogKeys.searchSubmit));
      await tester.pumpAndSettle();
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('HTTP 500: search failed'), findsOneWidget);
      expect(find.text('没有结果'), findsNothing);
      expect(find.byKey(CatalogKeys.searchNoResults), findsNothing);
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
}

/// 网格页头排序必须落在叠层顶栏下方,普通 center tap 即可命中,不能点到搜索/会话.
Future<void> _tapGridSort(WidgetTester tester) async {
  final sortBy = find.byKey(CatalogKeys.sortBy);
  expect(sortBy, findsOneWidget);
  final barBottom = tester.getRect(find.byKey(AppShell.topBarKey)).bottom;
  expect(tester.getCenter(sortBy).dy, greaterThan(barBottom));
  await tester.tap(sortBy);
  await tester.pumpAndSettle();
}

/// 返回钮在顶栏内,与首页导航并列。
Future<void> _tapDetailBack(WidgetTester tester) async {
  final back = find.byKey(CatalogKeys.back);
  expect(back, findsOneWidget);
  await tester.tap(back);
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
  await ensureVisibleBelowTopBar(tester, more);
  await tapBelowTopBar(tester, more);
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
