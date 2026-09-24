import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
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
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';
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

  test('dark theme exposes the mobile navigation bar theme from tokens', () {
    final theme = AppTheme.dark();
    final nav = theme.navigationBarTheme;
    expect(nav.elevation, 0);
    expect(nav.surfaceTintColor, Colors.transparent);
    expect(nav.backgroundColor!.a, closeTo(AppMobileNav.backgroundAlpha, 1e-6));
    expect(nav.indicatorShape, isA<StadiumBorder>());
    expect(nav.indicatorColor, isNotNull);
    // 选中 pill 动效档位对齐 AppMotion。
    expect(AppMobileNav.pillDuration, AppMotion.normal);
    expect(AppMobileCard.pressDuration, AppMotion.fast);
    // 控制层渐变 token 与 AppScrim 对齐(R8:不再散落 black54/black87)。
    expect(AppMobileControls.bottomAlpha, AppScrim.playerBar);
    expect(AppMobileControls.bottomSoftAlpha, AppScrim.playerBarSoft);
    // 桌面 NavigationRail 主题保持原样,不受手机 token 影响。
    expect(theme.navigationRailTheme, isNotNull);
  });

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

  testWidgets('MobilePressable scales and brightens while pressed', (
    tester,
  ) async {
    Future<void> pumpPressable() {
      return tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Center(
              child: MobilePressable(
                onTap: () {},
                child: const SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      );
    }

    await pumpPressable();
    final pressable = find.byType(MobilePressable);
    expect(pressable, findsOneWidget);
    final gesture = find.descendant(
      of: pressable,
      matching: find.byType(GestureDetector),
    );
    expect(gesture, findsOneWidget);

    // 未按压:缩放 1、无提亮遮罩。
    AnimatedScale scaleOf() => tester.widget(
      find.descendant(of: pressable, matching: find.byType(AnimatedScale)),
    );
    expect(scaleOf().scale, 1);
    expect(
      tester
          .widget<ColorFiltered>(
            find.descendant(
              of: pressable,
              matching: find.byType(ColorFiltered),
            ),
          )
          .colorFilter,
      const ColorFilter.mode(Colors.transparent, BlendMode.plus),
    );

    final pointer = await tester.startGesture(tester.getCenter(gesture));
    await tester.pump();
    expect(scaleOf().scale, AppMobileCard.pressScale);
    expect(scaleOf().duration, AppMotion.fast);
    await pointer.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(scaleOf().scale, 1);

    // 减弱动效下按压仍可用,但动画时长归零。
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpPressable();
    final reduced = find.byType(MobilePressable);
    final reducedGesture = find.descendant(
      of: reduced,
      matching: find.byType(GestureDetector),
    );
    await tester.startGesture(tester.getCenter(reducedGesture));
    await tester.pump();
    final scale = tester.widget<AnimatedScale>(
      find.descendant(of: reduced, matching: find.byType(AnimatedScale)),
    );
    expect(scale.duration, Duration.zero);
    expect(scale.scale, AppMobileCard.pressScale);
  });

  testWidgets(
    'poster flies to the top as the same image and is the only hero',
    (tester) async {
      await _pumpMotionHome(tester);
      await _until(tester, find.byKey(CatalogKeys.item('movie-inception')));
      // 同一海报 id 只允许一个 Hero,否则 flight 会歧义。
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Hero &&
              widget.tag ==
                  PhoneMotion.imageTag(
                    'movie-inception',
                    preferBackdrop: false,
                  ),
        ),
        findsOneWidget,
      );
      final poster = find.byKey(CatalogKeys.item('movie-inception'));
      final posterImage = tester.widget<MediaImage>(
        find.descendant(of: poster, matching: find.byType(MediaImage)),
      );

      await tester.tap(poster);
      await _until(tester, find.byKey(PhoneItemBanner.bannerKey));
      _expectSameImage(tester, posterImage, onstage: true);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Hero &&
              widget.tag ==
                  PhoneMotion.imageTag(
                    'movie-inception',
                    preferBackdrop: false,
                  ),
        ),
        findsWidgets,
      );

      await _settle(tester);
      expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
      final landed = _bannerImage(tester);
      expect(landed.item.id, posterImage.item.id);
      expect(landed.preferBackdrop, isFalse);
      expect(landed.maxWidth, posterImage.maxWidth);
      expect(landed.item.primaryImageTag, posterImage.item.primaryImageTag);
      final play = find.byKey(const Key('mobile-detail-play'));
      expect(tester.widget<FilledButton>(play).onPressed, isNotNull);
      expect(find.text('Inception'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion keeps the banner and the primary action', (
    tester,
  ) async {
    PhoneHero.autoAdvanceEnabled = true;
    addTearDown(() => PhoneHero.autoAdvanceEnabled = false);
    await _pumpMotionHome(tester, reduceMotion: true);
    await _until(tester, find.byKey(PhoneHero.itemKey('movie-inception')));
    expect(
      tester.widget<IconButton>(find.byKey(PhoneHero.pauseKey)).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(PhoneHero.openKey)).onPressed,
      isNotNull,
    );
    expect(find.text('已看 40%'), findsWidgets);

    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(PhoneHero.itemKey('movie-inception')), findsOneWidget);
    expect(find.text('已看 40%'), findsWidgets);
    expect(find.text('继续播放'), findsWidgets);

    await tester.tap(find.byKey(PhoneHero.openKey));
    await _settle(tester);
    expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
    expect(_bannerImage(tester).preferBackdrop, isTrue);
    expect(_bannerImage(tester).maxWidth, PhoneMotion.heroRequestWidth);
    expect(find.textContaining('dream-sharing'), findsOneWidget);
    expect(find.textContaining('2010'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('mobile-detail-play')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'resume card carries progress and remove, and removal survives refresh',
    (tester) async {
      _usePhoneSurface(tester);
      final catalog = _catalog(
        resume: [_item('movie-b', '乙电影', 'Movie', percent: 10)],
        movies: [_item('movie-c', '示例电影', 'Movie')],
        series: const [],
      );
      addTearDown(catalog.auth.dispose);
      addTearDown(catalog.dispose);
      final router = _router(catalog);
      addTearDown(router.dispose);
      await tester.pumpWidget(_scriptedApp(catalog, router: router));
      await tester.pump();

      // 进度条与单条移除都保留,并落在继续观看卡内(Hero 也有一条进度条)。
      final card = tester.getRect(find.byKey(CatalogKeys.item('movie-b')));
      expect(
        _inside(
          tester.getRect(find.byKey(CatalogKeys.removeFromResume('movie-b'))),
          card,
        ),
        isTrue,
      );
      expect(find.byKey(CatalogKeys.resumeProgress), findsWidgets);
      expect(_inside(tester.getRect(find.text('已看 10%').last), card), isTrue);

      // 真实服务器上移除后刷新,继续观看行保持消失并落库。
      final (liveRouter, server) = await _openPhone(tester);
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
      liveRouter.pop();
      await _settle(tester);

      final remove = find.byKey(
        CatalogKeys.removeFromResume('movie-inception'),
      );
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
    },
    tags: ['integration'],
  );

  testWidgets(
    'shelf more appears only for full rows and opens the phone shelf',
    (tester) async {
      final (_, server) = await _openPhone(tester, prepare: _addShelfMovies);
      expect(find.text('冷门电影'), findsNothing);
      // 电影行满员出现"更多";剧集/继续观看行不满员不出现。
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
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('最近更新的电影'),
        ),
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
    },
    tags: ['integration'],
  );
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

EmbyItem _movie(String id, String name, {double? percent}) {
  return EmbyItem(
    id: id,
    name: name,
    type: 'Movie',
    overview: id == 'movie-inception'
        ? 'A thief who steals corporate secrets through dream-sharing.'
        : null,
    productionYear: id == 'movie-inception' ? 2010 : 2009,
    primaryImageTag: 'tag-$id',
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
    // 顶栏/AppBar 会压住滚动区上缘,留出余量再停。
    if (top >= 96 && top < 640) {
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
              return Scaffold(body: Text('详情 $id'));
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

bool _inside(Rect inner, Rect outer) {
  return inner.left >= outer.left - 0.5 &&
      inner.top >= outer.top - 0.5 &&
      inner.right <= outer.right + 0.5 &&
      inner.bottom <= outer.bottom + 0.5;
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

// ---- Hero/动效专用 harness(自 phone_motion_test 并入) ----

MediaImage _bannerImage(WidgetTester tester) {
  return tester.widget<MediaImage>(
    find.descendant(
      of: find.byKey(PhoneItemBanner.bannerKey),
      matching: find.byType(MediaImage),
      skipOffstage: false,
    ),
  );
}

void _expectSameImage(
  WidgetTester tester,
  MediaImage poster, {
  required bool onstage,
}) {
  final images = tester.widgetList<MediaImage>(
    find.byType(MediaImage, skipOffstage: onstage),
  );
  expect(
    images.where(
      (image) =>
          image.item.id == poster.item.id &&
          image.preferBackdrop == poster.preferBackdrop &&
          image.maxWidth == poster.maxWidth &&
          image.item.primaryImageTag == poster.item.primaryImageTag,
    ),
    isNotEmpty,
  );
}

Future<void> _pumpMotionHome(
  WidgetTester tester, {
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(360, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (reduceMotion) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  final server = FakeEmbyServer();
  final auth = AuthController.memory(
    client: EmbyClient(
      device: _device,
      dio: dioForFakeEmby(FakeEmbyAdapter([server])),
    ),
  );
  await tester.runAsync(
    () => auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    ),
  );
  final catalog = CatalogController(auth: auth);
  catalog.resume = CatalogRowState(
    items: [
      _movie('movie-inception', 'Inception', percent: 40),
      _movie('movie-up', '飞屋环游记'),
    ],
  );
  catalog.nextUp = const CatalogRowState(hidden: true);
  catalog.latestMovies = CatalogRowState(
    items: [
      _movie('movie-inception', 'Inception', percent: 40),
      _movie('movie-up', '飞屋环游记'),
    ],
  );
  catalog.latestSeries = CatalogRowState(
    items: [
      const EmbyItem(
        id: 'series-friends',
        name: '老友记',
        type: 'Series',
        overview: 'Six friends living in New York.',
        primaryImageTag: 'tag-friends',
      ),
    ],
  );
  catalog.librariesLoading = false;
  final router = GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const PhoneHome(),
      ),
      GoRoute(
        path: '/item/:itemId',
        builder: (context, state) =>
            MobileDetailPage(itemId: state.pathParameters['itemId']!),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(catalog.dispose);
  addTearDown(auth.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });
  MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 1);
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: CatalogScope(
        controller: catalog,
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}
