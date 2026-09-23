import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/player/mobile_player_page.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-home',
  version: '1',
);

void main() {
  setUp(isolateImageCache);

  testWidgets('banner prefers resume, pauses after a tap, and stops at five', (
    tester,
  ) async {
    PhoneHero.autoAdvanceEnabled = true;
    addTearDown(() => PhoneHero.autoAdvanceEnabled = false);
    _usePhoneSurface(tester);
    final catalog = _catalog(
      resume: [
        _item('episode-a', '试播集', 'Episode', percent: 40, seriesName: '示例剧'),
        _item('movie-b', '乙电影', 'Movie', percent: 10),
      ],
      movies: [
        _item('movie-b', '乙电影', 'Movie', percent: 10),
        _item('movie-c', '示例电影', 'Movie'),
        _item('movie-d', '丁电影', 'Movie'),
        _item('movie-e', '戊电影', 'Movie'),
        _item('movie-f', '落选电影', 'Movie'),
      ],
      series: [_item('series-h', '示例剧全集', 'Series')],
    );
    addTearDown(catalog.auth.dispose);
    addTearDown(catalog.dispose);
    final router = _router(catalog);
    addTearDown(router.dispose);
    await tester.pumpWidget(_scriptedApp(catalog, router: router));
    await tester.pump();

    expect(find.byType(HomeHero), findsNothing);
    expect(find.byKey(PhoneHero.itemKey('episode-a')), findsOneWidget);
    expect(find.byKey(PhoneHero.itemKey('movie-f')), findsNothing);
    expect(find.byKey(PhoneHero.itemKey('series-h')), findsNothing);
    expect(find.byKey(CatalogKeys.heroDot(4)), findsOneWidget);
    expect(find.byKey(CatalogKeys.heroDot(5)), findsNothing);
    expect(find.text('继续播放'), findsOneWidget);
    expect(find.text('已看 40%'), findsWidgets);
    expect(find.byTooltip('暂停轮播'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(PhoneHero.itemKey('episode-a')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(PhoneHero.itemKey('movie-b')), findsOneWidget);

    final banner = tester.getRect(find.byKey(PhoneHero.bannerKey));
    await tester.tapAt(banner.topLeft + const Offset(16, 16));
    await tester.pump();
    expect(find.byTooltip('恢复轮播'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(PhoneHero.itemKey('movie-b')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disableAnimations keeps the same banner', (tester) async {
    PhoneHero.autoAdvanceEnabled = true;
    addTearDown(() => PhoneHero.autoAdvanceEnabled = false);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    _usePhoneSurface(tester);
    final catalog = _catalog(
      resume: [
        _item('episode-a', '试播集', 'Episode', percent: 40, seriesName: '示例剧'),
        _item('movie-b', '乙电影', 'Movie'),
      ],
      movies: [_item('movie-c', '示例电影', 'Movie')],
      series: const [],
    );
    addTearDown(catalog.auth.dispose);
    addTearDown(catalog.dispose);
    final router = _router(catalog);
    addTearDown(router.dispose);
    await tester.pumpWidget(_scriptedApp(catalog, router: router));
    await tester.pump();

    expect(
      tester.widget<IconButton>(find.byKey(PhoneHero.pauseKey)).onPressed,
      isNull,
    );
    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(PhoneHero.itemKey('episode-a')), findsOneWidget);
    expect(find.text('继续播放'), findsOneWidget);
    expect(find.text('已看 40%'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'series opens the series page and movies or episodes open detail',
    (tester) async {
      _usePhoneSurface(tester);
      final catalog = _catalog(
        resume: [
          _item('episode-a', '试播集', 'Episode', percent: 40, seriesName: '示例剧'),
        ],
        movies: [_item('movie-c', '示例电影', 'Movie')],
        series: [_item('series-h', '示例剧全集', 'Series')],
      );
      addTearDown(catalog.auth.dispose);
      addTearDown(catalog.dispose);
      final router = _router(catalog);
      addTearDown(router.dispose);
      await tester.pumpWidget(_scriptedApp(catalog, router: router));
      await _settle(tester);

      await tester.tap(find.byKey(PhoneHero.openKey));
      await _settle(tester);
      expect(find.text('详情 episode-a'), findsOneWidget);
      expect(find.textContaining('播放 episode-a'), findsNothing);

      router.pop();
      await _settle(tester);
      await _showOnHome(tester, find.text('示例电影'));
      await tester.tap(find.text('示例电影'));
      await _settle(tester);
      expect(find.text('详情 movie-c'), findsOneWidget);

      router.pop();
      await _settle(tester);
      await _showOnHome(tester, find.text('示例剧全集'));
      await tester.tap(find.text('示例剧全集'));
      await _settle(tester);
      expect(find.text('剧集页 series-h'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('more is only offered when the row still has items after it', (
    tester,
  ) async {
    _usePhoneSurface(tester);
    final catalog = _catalog(
      resume: [_item('movie-b', '乙电影', 'Movie', percent: 10)],
      movies: [
        for (var i = 0; i < phoneHomeRowLimit; i++)
          _item('movie-$i', '电影 $i', 'Movie'),
      ],
      series: [
        for (var i = 0; i < phoneHomeRowLimit - 1; i++)
          _item('series-$i', '剧 $i', 'Series'),
      ],
    );
    addTearDown(catalog.auth.dispose);
    addTearDown(catalog.dispose);
    final router = _router(catalog);
    addTearDown(router.dispose);
    await tester.pumpWidget(_scriptedApp(catalog, router: router));
    await _settle(tester);

    expect(
      find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies)),
      findsOneWidget,
    );
    expect(
      find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestSeries)),
      findsNothing,
    );
    expect(
      find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfResume)),
      findsNothing,
    );
    expect(find.byType(ShelfGridPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed resume item stays gone after refresh', (tester) async {
    final (router, server) = await _openPhone(tester);
    expect(find.byType(HomeHero), findsNothing);
    expect(find.byType(PhoneHero), findsOneWidget);
    expect(find.byKey(PhoneHero.itemKey('movie-inception')), findsOneWidget);
    expect(find.text('继续播放'), findsWidgets);
    expect(find.text('已看 40%'), findsWidgets);
    expect(find.text('继续观看'), findsOneWidget);

    await tester.tap(find.byKey(PhoneHero.openKey));
    await _settle(tester);
    expect(find.byType(MobilePlayerPage), findsNothing);
    expect(
      tester.widget<MobileDetailPage>(find.byType(MobileDetailPage)).itemId,
      'movie-inception',
    );
    router.pop();
    await _settle(tester);

    await _showOnHome(tester, find.text('老友记'));
    await tester.tap(find.text('老友记'));
    await _settle(tester);
    expect(
      tester.widget<MobileDetailPage>(find.byType(MobileDetailPage)).itemId,
      'series-friends',
    );
    router.pop();
    await _settle(tester);

    await _showOnHome(tester, find.text('The One with the Sonogram'));
    await tester.tap(find.text('The One with the Sonogram'));
    await _settle(tester);
    expect(
      tester.widget<MobileDetailPage>(find.byType(MobileDetailPage)).itemId,
      'episode-friends-s1e2',
    );
    router.pop();
    await _settle(tester);

    final remove = find.byKey(CatalogKeys.removeFromResume('movie-inception'));
    await _showOnHome(tester, remove);
    await tester.tap(remove);
    await _settle(tester);
    expect(find.text('继续观看'), findsNothing);

    await _showOnHome(tester, find.text('刷新'));
    await tester.tap(find.text('刷新'));
    await _settle(tester);
    expect(find.text('继续观看'), findsNothing);
    expect(
      server.items
          .firstWhere((item) => item.id == 'movie-inception')
          .hideFromResume,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('a full row opens a phone shelf with the same title', (
    tester,
  ) async {
    final (_, server) = await _openPhone(tester, prepare: _addShelfMovies);
    expect(find.text('冷门电影'), findsNothing);
    final more = find.byKey(
      CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies),
    );
    await _showOnHome(tester, more);
    await tester.tap(more);
    await _settle(tester);

    expect(find.byType(PhoneShelfPage), findsOneWidget);
    expect(find.byType(ShelfGridPage), findsNothing);
    expect(find.byType(HomeHero), findsNothing);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('最近更新的电影')),
      findsOneWidget,
    );
    expect(find.text('加载更多'), findsNothing);
    expect(
      server.requests.where(
        (request) =>
            request.contains('IncludeItemTypes=Movie') &&
            request.contains('Limit=${PhoneShelfPage.pageSize}') &&
            request.contains('StartIndex=0') &&
            request.contains('SortBy=DateLastContentAdded') &&
            request.contains('SortOrder=Descending'),
      ),
      isNotEmpty,
    );
    await tester.scrollUntilVisible(find.text('冷门电影'), 400);
    expect(find.text('冷门电影'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('desktop shelf route still uses the desktop grid', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final server = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(() async {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    final desktopRouter = createAppRouter(
      auth: auth,
      environment: PresentationEnvironment.desktop,
    );
    addTearDown(desktopRouter.dispose);
    desktopRouter.go(AppRoutes.shelfResume);
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: desktopRouter,
        ),
      ),
    );
    await _settle(tester);
    expect(find.byType(ShelfGridPage), findsOneWidget);
    expect(find.byType(PhoneShelfPage), findsNothing);

    final phoneRouter = createAppRouter(
      auth: auth,
      environment: PresentationEnvironment.phone,
    );
    addTearDown(phoneRouter.dispose);
    phoneRouter.go(AppRoutes.shelfLatestMovies);
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: phoneRouter,
        ),
      ),
    );
    await _settle(tester);
    expect(find.byType(PhoneShelfPage), findsOneWidget);
    expect(find.byType(ShelfGridPage), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}

CatalogController _catalog({
  required List<EmbyItem> resume,
  required List<EmbyItem> movies,
  required List<EmbyItem> series,
}) {
  final catalog = CatalogController(auth: AuthController.memory());
  catalog.resume = CatalogRowState(items: resume);
  catalog.nextUp = const CatalogRowState(hidden: true);
  catalog.latestMovies = CatalogRowState(items: movies);
  catalog.latestSeries = CatalogRowState(items: series);
  catalog.librariesLoading = false;
  return catalog;
}

EmbyItem _item(
  String id,
  String name,
  String type, {
  double? percent,
  String? seriesName,
}) {
  return EmbyItem(
    id: id,
    name: name,
    type: type,
    seriesName: seriesName,
    userData: percent == null
        ? const EmbyUserData()
        : EmbyUserData(playbackPositionTicks: 1, playedPercentage: percent),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _showOnHome(WidgetTester tester, Finder finder) async {
  final list = find.byKey(const PageStorageKey('mobile-home-scroll'));
  for (var i = 0; i < 8; i++) {
    final top = tester.getTopLeft(finder).dy;
    if (top >= 0 && top < 640) {
      return;
    }
    await tester.drag(list, Offset(0, top > 640 ? -350 : 350));
    await tester.pump();
  }
}

void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _scriptedApp(CatalogController catalog, {required GoRouter router}) {
  return MaterialApp.router(
    theme: AppTheme.dark(),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    routerConfig: router,
  );
}

GoRouter _router(CatalogController catalog) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return CatalogScope(controller: catalog, child: child);
        },
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const PhoneHome(),
          ),
          GoRoute(
            path: '/item/:itemId',
            builder: (context, state) {
              final id = state.pathParameters['itemId']!;
              final item = _findItem(catalog, id);
              final label = item != null && item.isSeries ? '剧集页' : '详情';
              return Scaffold(body: Text('$label $id'));
            },
          ),
          GoRoute(
            path: '/play/:itemId',
            builder: (context, state) {
              return Text('播放 ${state.pathParameters['itemId']}');
            },
          ),
        ],
      ),
    ],
  );
}

EmbyItem? _findItem(CatalogController catalog, String id) {
  for (final state in [
    catalog.resume,
    catalog.nextUp,
    catalog.latestMovies,
    catalog.latestSeries,
  ]) {
    for (final item in state.items) {
      if (item.id == id) {
        return item;
      }
    }
  }
  return null;
}

void _addShelfMovies(FakeEmbyServer server) {
  for (var i = 0; i < phoneHomeRowLimit; i++) {
    final added = DateTime.utc(2030, 1, 1).add(Duration(days: i));
    server.items.add(
      FakeEmbyItem(
        id: 'movie-new-$i',
        name: '新片 $i',
        type: 'Movie',
        parentId: 'view-movies',
        dateCreated: added,
        dateLastContentAdded: added,
      ),
    );
  }
  server.items.add(
    FakeEmbyItem(
      id: 'movie-cold',
      name: '冷门电影',
      type: 'Movie',
      parentId: 'view-movies',
      dateCreated: DateTime.utc(2001, 1, 1),
      dateLastContentAdded: DateTime.utc(2001, 1, 1),
    ),
  );
}

Future<(GoRouter, FakeEmbyServer)> _openPhone(
  WidgetTester tester, {
  void Function(FakeEmbyServer server)? prepare,
}) async {
  _usePhoneSurface(tester);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final server = FakeEmbyServer();
  prepare?.call(server);
  final auth = AuthController.memory(
    client: EmbyClient(
      device: _device,
      dio: dioForFakeEmby(FakeEmbyAdapter([server])),
    ),
  );
  addTearDown(auth.dispose);
  await tester.runAsync(() async {
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
  });
  final router = createAppRouter(
    auth: auth,
    environment: PresentationEnvironment.phone,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    ),
  );
  await _settle(tester);
  return (router, server);
}
