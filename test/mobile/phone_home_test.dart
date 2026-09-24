import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/phone_libraries_tab.dart';
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
import 'package:rillight/home/phone_home_sections.dart';
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
  setUp(() {
    isolateImageCache();
    PhoneHomeSectionController.debugResetApp();
  });

  testWidgets(
    'banner prefers resume, pauses from the button, and stops at five',
    (tester) async {
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

      await tester.tap(find.byKey(PhoneHero.pauseKey));
      await tester.pump();
      expect(find.byTooltip('恢复轮播'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(
        _heroPageLeft(tester, 'movie-b'),
        closeTo(tester.getRect(find.byKey(PhoneHero.bannerKey)).left, 1),
      );

      final banner = tester.getRect(find.byKey(PhoneHero.bannerKey));
      await tester.tapAt(banner.topLeft + const Offset(16, 80));
      await _settle(tester);
      expect(find.text('详情 movie-b'), findsOneWidget);
      expect(find.textContaining('播放 movie-b'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('banner swipes to the next and previous item', (tester) async {
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

    final banner = find.byKey(PhoneHero.bannerKey);
    expect(
      _heroPageLeft(tester, 'episode-a'),
      closeTo(tester.getRect(banner).left, 1),
    );
    await tester.drag(banner, const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(
      _heroPageLeft(tester, 'movie-b'),
      closeTo(tester.getRect(banner).left, 1),
    );
    await tester.drag(banner, const Offset(280, 0));
    await tester.pumpAndSettle();
    expect(
      _heroPageLeft(tester, 'episode-a'),
      closeTo(tester.getRect(banner).left, 1),
    );
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
    expect(
      _heroPageLeft(tester, 'episode-a'),
      closeTo(tester.getRect(find.byKey(PhoneHero.bannerKey)).left, 1),
    );
    expect(find.text('继续播放'), findsOneWidget);
    expect(find.text('已看 40%'), findsWidgets);
    await tester.drag(find.byKey(PhoneHero.bannerKey), const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(
      _heroPageLeft(tester, 'movie-b'),
      closeTo(tester.getRect(find.byKey(PhoneHero.bannerKey)).left, 1),
    );
    await tester.tapAt(
      tester.getRect(find.byKey(PhoneHero.bannerKey)).topLeft +
          const Offset(16, 80),
    );
    await _settle(tester);
    expect(find.text('详情 movie-b'), findsOneWidget);
    expect(find.textContaining('播放 movie-b'), findsNothing);
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

  testWidgets('poster cards are pressable 2:3 cards sized by screen width', (
    tester,
  ) async {
    _usePhoneSurface(tester);
    final catalog = _catalog(
      resume: [_item('movie-b', '乙电影', 'Movie', percent: 10)],
      movies: [_item('movie-c', '示例电影', 'Movie')],
      series: [_item('series-h', '示例剧全集', 'Series')],
    );
    addTearDown(catalog.auth.dispose);
    addTearDown(catalog.dispose);
    final router = _router(catalog);
    addTearDown(router.dispose);
    await tester.pumpWidget(_scriptedApp(catalog, router: router));
    await tester.pump();

    // 行结构仍在:继续观看/最新电影/最新剧集三行 + Hero。
    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('最近更新的电影'), findsOneWidget);
    expect(find.text('最近更新的剧集'), findsOneWidget);

    // 每张海报卡都是 MobilePressable,按压档位取 AppMobileCard token。
    final pressables = tester.widgetList<MobilePressable>(
      find.byType(MobilePressable),
    );
    expect(pressables.length, 3);
    for (final pressable in pressables) {
      expect(pressable.scale, AppMobileCard.pressScale);
      expect(pressable.brighten, AppMobileCard.pressBrighten);
      expect(pressable.duration, AppMobileCard.pressDuration);
    }

    // 海报区保持 2:3 竖版。
    final ratios = tester.widgetList<AspectRatio>(find.byType(AspectRatio));
    expect(ratios.where((widget) => widget.aspectRatio == 2 / 3), isNotEmpty);

    // 最近电影卡宽：约 3 张完整海报再露出下一张。
    final width360 = tester
        .getRect(find.byKey(CatalogKeys.item('movie-c')))
        .width;
    expect(width360, closeTo(phoneHomePosterCardWidth(360), 0.5));
    final available = 360 - AppSpacing.md * 2;
    final stride = width360 + AppSpacing.sm;
    expect(stride * 3, lessThan(available));
    expect(stride * 3 + width360, greaterThan(available));
    expect(tester.takeException(), isNull);
  });

  testWidgets('card width tracks a wider phone and text scale grows the row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final catalog = _catalog(
      resume: const [],
      movies: [_item('movie-c', '示例电影', 'Movie')],
      series: const [],
    );
    addTearDown(catalog.auth.dispose);
    addTearDown(catalog.dispose);
    final router = _router(catalog);
    addTearDown(router.dispose);
    await tester.pumpWidget(_scriptedApp(catalog, router: router));
    await tester.pump();

    final width412 = tester
        .getRect(find.byKey(CatalogKeys.item('movie-c')))
        .width;
    expect(width412, closeTo(phoneHomePosterCardWidth(412), 0.5));
    final available = 412 - AppSpacing.md * 2;
    final stride = width412 + AppSpacing.sm;
    expect(stride * 3, lessThan(available));
    expect(stride * 3 + width412, greaterThan(available));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'resume card overlays title, progress and remove control in the card',
    (tester) async {
      _usePhoneSurface(tester);
      final catalog = _catalog(
        resume: [_item('movie-b', '乙电影', 'Movie', percent: 10)],
        movies: [_item('movie-c', '示例电影', 'Movie')],
        series: const [],
        nextUp: [_item('episode-n', '下一集卡片', 'Episode')],
      );
      addTearDown(catalog.auth.dispose);
      addTearDown(catalog.dispose);
      final router = _router(catalog);
      addTearDown(router.dispose);
      await tester.pumpWidget(_scriptedApp(catalog, router: router));
      await tester.pump();

      // 进度条与单条移除都保留。横卡是 16:9，移除按钮在画面下方。
      final cardFinder = find.byKey(CatalogKeys.item('movie-b'));
      final card = tester.getRect(cardFinder);
      final image = tester.getRect(
        find.descendant(of: cardFinder, matching: find.byType(AspectRatio)),
      );
      expect(
        tester
            .widget<AspectRatio>(
              find.descendant(
                of: cardFinder,
                matching: find.byType(AspectRatio),
              ),
            )
            .aspectRatio,
        16 / 9,
      );
      final remove = tester.getRect(
        find.byKey(CatalogKeys.removeFromResume('movie-b')),
      );
      expect(_inside(remove, card), isTrue);
      expect(remove.top, greaterThanOrEqualTo(image.bottom - 1));
      expect(find.byKey(CatalogKeys.resumeProgress), findsWidgets);
      expect(_inside(tester.getRect(find.text('已看 10%').last), card), isTrue);
      final nextCard = find.byKey(CatalogKeys.item('episode-n'));
      expect(
        tester
            .widget<AspectRatio>(
              find.descendant(of: nextCard, matching: find.byType(AspectRatio)),
            )
            .aspectRatio,
        16 / 9,
      );
      await tester.tap(find.text('下一集卡片'));
      await _settle(tester);
      expect(find.text('详情 episode-n'), findsOneWidget);
      expect(find.textContaining('播放 episode-n'), findsNothing);
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

    final seriesCard = find.descendant(
      of: find.byKey(CatalogKeys.latestSeriesRow),
      matching: find.text('老友记'),
    );
    await _showOnHome(tester, seriesCard);
    await tester.tap(seriesCard);
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
    expect(_sameRow(tester, ['新片 23', '新片 22', '新片 21']), isTrue);
    expect(
      tester.getTopLeft(find.text('新片 20')).dy,
      greaterThan(tester.getTopLeft(find.text('新片 23')).dy + 40),
    );
    await tester.scrollUntilVisible(find.text('冷门电影'), 400);
    expect(find.text('冷门电影'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('latest shelf stays at three columns on a 412dp phone', (
    tester,
  ) async {
    await _openPhone(
      tester,
      size: const Size(412, 900),
      prepare: _addShelfMovies,
    );
    final more = find.byKey(
      CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies),
    );
    await _showOnHome(tester, more);
    await tester.tap(more);
    await _settle(tester);
    expect(_sameRow(tester, ['新片 23', '新片 22', '新片 21']), isTrue);
    expect(
      tester.getTopLeft(find.text('新片 20')).dy,
      greaterThan(tester.getTopLeft(find.text('新片 23')).dy + 40),
    );
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

  testWidgets('hidden and reordered sections stay on the next home open', (
    tester,
  ) async {
    _usePhoneSurface(tester);
    final server = FakeEmbyServer();
    server.items.add(
      FakeEmbyItem(
        id: 'lib-movie',
        name: '库内新片',
        type: 'Movie',
        parentId: 'view-movies',
        dateCreated: DateTime.utc(2024, 6, 1),
      ),
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    final serverId = auth.session!.server.id;
    final libraries = [
      const EmbyItem(
        id: 'view-movies',
        name: '电影',
        type: 'CollectionFolder',
        collectionType: 'movies',
      ),
      const EmbyItem(
        id: 'view-tv',
        name: '剧集',
        type: 'CollectionFolder',
        collectionType: 'tvshows',
      ),
    ];
    final store = MemoryPhoneHomeSectionStore();
    final sections = PhoneHomeSectionController(store: store);
    addTearDown(sections.dispose);
    await sections.load(serverId);
    await sections.setVisible(PhoneHomeSectionId.latestMovies, false);
    await sections.setVisible(PhoneHomeSectionId.libraries, false);
    final libraryLatest = PhoneHomeSectionId.libraryLatest('view-movies');
    while (sections.orderedIds(libraries).indexOf(libraryLatest) >
        sections.orderedIds(libraries).indexOf(PhoneHomeSectionId.resume)) {
      await sections.move(libraryLatest, -1, libraries);
    }
    final catalog = CatalogController(auth: auth)
      ..cache.debugSetDiskStore(null);
    addTearDown(catalog.dispose);
    catalog.resume = CatalogRowState(
      items: [_item('movie-b', '乙电影', 'Movie', percent: 10)],
    );
    catalog.nextUp = const CatalogRowState(hidden: true);
    catalog.latestMovies = CatalogRowState(
      items: [_item('movie-c', '示例电影', 'Movie')],
    );
    catalog.latestSeries = const CatalogRowState(hidden: true);
    catalog.libraries = libraries;
    catalog.librariesLoading = false;

    await tester.pumpWidget(
      _sectionedHome(auth: auth, catalog: catalog, sections: sections),
    );
    await _settle(tester);

    expect(find.text('最近更新的电影'), findsNothing);
    expect(find.text('即将播放'), findsNothing);
    expect(find.byKey(const Key('phone-home-libraries')), findsNothing);
    expect(find.text('库内新片'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('电影 · 最近添加')).dy,
      lessThan(tester.getTopLeft(find.text('继续观看')).dy),
    );

    final reopened = PhoneHomeSectionController(store: store);
    addTearDown(reopened.dispose);
    await reopened.load(serverId);
    await tester.pumpWidget(
      _sectionedHome(auth: auth, catalog: catalog, sections: reopened),
    );
    await _settle(tester);
    expect(find.text('最近更新的电影'), findsNothing);
    expect(
      tester.getTopLeft(find.text('电影 · 最近添加')).dy,
      lessThan(tester.getTopLeft(find.text('继续观看')).dy),
    );

    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: CatalogScope(
          controller: catalog,
          child: MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const PhoneLibrariesTab(),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(
      find.byKey(const Key('phone-library-block-view-movies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('phone-library-block-view-tv')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

double _heroPageLeft(WidgetTester tester, String id) {
  return tester.getRect(find.byKey(PhoneHero.itemKey(id))).left;
}

bool _sameRow(WidgetTester tester, List<String> names) {
  final tops = [
    for (final name in names) tester.getTopLeft(find.text(name)).dy,
  ];
  return tops.every((top) => (top - tops.first).abs() < 1);
}

CatalogController _catalog({
  required List<EmbyItem> resume,
  required List<EmbyItem> movies,
  required List<EmbyItem> series,
  List<EmbyItem>? nextUp,
}) {
  final catalog = CatalogController(auth: AuthController.memory());
  catalog.resume = CatalogRowState(items: resume);
  catalog.nextUp = nextUp == null
      ? const CatalogRowState(hidden: true)
      : CatalogRowState(items: nextUp);
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

Widget _sectionedHome({
  required AuthController auth,
  required CatalogController catalog,
  required PhoneHomeSectionController sections,
}) {
  return AuthScope(
    controller: auth,
    child: CatalogScope(
      controller: catalog,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: PhoneHome(sections: sections),
      ),
    ),
  );
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
  Size size = const Size(360, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
