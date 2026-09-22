import 'dart:io';
import 'dart:ui' as ui;

import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/app/routes.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-home-page',
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

  Future<AuthController> connect(WidgetTester tester) async {
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

  Future<AuthController> pumpLoggedIn(WidgetTester tester) async {
    final auth = await connect(tester);
    await tester.pumpWidget(RillightApp(auth: auth));
    await settle(tester);
    return auth;
  }

  Finder inRow(Key rowKey, Finder matching) =>
      find.descendant(of: find.byKey(rowKey), matching: matching);

  int resumeRequests() => server.requests
      .where((request) => request.contains('Items/Resume'))
      .length;

  /// 把 [finder] 滚到叠层顶栏下方,不依赖 pumpAndSettle(骨架屏常驻动画)。
  Future<void> scrollBelowTopBar(WidgetTester tester, Finder finder) async {
    final context = tester.element(finder);
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) {
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
    await tester.pump();
  }

  testWidgets(
    'home renders without LiquidGlass and refresh reloads the resume shelf',
    (tester) async {
      await pumpLoggedIn(tester);

      expect(
        find.descendant(
          of: find.byType(HomePage),
          matching: find.byType(LiquidGlass),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(HomeHero),
          matching: find.byType(BackdropScrim),
        ),
        findsOneWidget,
      );
      expect(tester.getTopLeft(find.byType(HomeHero)).dy, 0);
      expect(
        tester.getSize(find.byType(HomeHero)).height,
        lessThan(
          tester.view.physicalSize.height / tester.view.devicePixelRatio * 0.90,
        ),
      );
      expect(
        find.descendant(
          of: find.byType(HomeHero),
          matching: find.widgetWithText(OutlinedButton, '详情'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(HomeHero),
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.heroPlay),
          matching: find.text('继续播放'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('已看 40%'), findsWidgets);
      expect(
        tester.widget(find.byKey(CatalogKeys.heroPrev)),
        isA<ScrimIconButton>(),
      );
      expect(
        tester.widget(find.byKey(CatalogKeys.heroNext)),
        isA<ScrimIconButton>(),
      );
      expect(find.byKey(CatalogKeys.heroDot(4)), findsOneWidget);
      expect(
        find.byKey(CatalogKeys.heroDot(HomeHero.maxFeatured)),
        findsNothing,
      );
      const featuredOrder = ['Inception', '飞屋环游记', '封面失败片', '未分类型电影', '混合库电影'];
      for (final title in featuredOrder) {
        if (title != featuredOrder.first) {
          await tester.tap(find.byKey(CatalogKeys.heroNext));
          await tester.pump();
        }
        expect(
          find.descendant(
            of: find.byType(HomeHero),
            matching: find.text(title),
          ),
          findsOneWidget,
        );
        expect(find.text(title), findsWidgets);
      }

      expect(find.byKey(homeRefreshKey), findsOneWidget);
      expect(
        inRow(CatalogKeys.resumeRow, find.byKey(homeRefreshKey)),
        findsOneWidget,
      );
      final title = tester.getRect(
        inRow(CatalogKeys.resumeRow, find.text('继续观看')),
      );
      final refresh = tester.getRect(find.byKey(homeRefreshKey));
      expect(
        refresh.center.dy,
        inInclusiveRange(title.top - 24, title.bottom + 24),
      );
      expect(refresh.left, greaterThanOrEqualTo(title.right));
      final more = tester.getRect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfResume)),
      );
      expect(more.left, greaterThanOrEqualTo(refresh.right));

      final before = resumeRequests();
      for (final item in server.items) {
        if (item.id == 'movie-up') {
          item.name = '手动刷新后的电影';
        }
      }
      await scrollBelowTopBar(tester, find.byKey(homeRefreshKey));
      await tester.tap(find.byKey(homeRefreshKey));
      await settle(tester);

      expect(resumeRequests(), greaterThan(before));
      expect(find.text('手动刷新后的电影'), findsWidgets);
    },
    tags: ['integration'],
  );

  testWidgets(
    'refresh button falls back to the first visible shelf and then libraries',
    (tester) async {
      for (final item in server.items) {
        item.playbackPositionTicks = 0;
        item.playedPercentage = null;
      }
      await pumpLoggedIn(tester);

      expect(find.byKey(CatalogKeys.resumeRow), findsNothing);
      expect(find.byKey(homeRefreshKey), findsOneWidget);
      expect(
        inRow(CatalogKeys.nextUpRow, find.byKey(homeRefreshKey)),
        findsOneWidget,
      );

      final before = resumeRequests();
      await scrollBelowTopBar(tester, find.byKey(homeRefreshKey));
      await tester.tap(find.byKey(homeRefreshKey));
      await settle(tester);
      expect(resumeRequests(), greaterThan(before));

      // 媒体行全部隐藏时退回到媒体库行。
      server.items.clear();
      await scrollBelowTopBar(tester, find.byKey(homeRefreshKey));
      await tester.tap(find.byKey(homeRefreshKey));
      await settle(tester);
      expect(find.byKey(CatalogKeys.resumeRow), findsNothing);
      expect(find.byKey(CatalogKeys.nextUpRow), findsNothing);
      expect(find.byKey(CatalogKeys.latestMoviesRow), findsNothing);
      expect(find.byKey(CatalogKeys.latestSeriesRow), findsNothing);
      expect(find.byKey(homeRefreshKey), findsOneWidget);
      expect(
        inRow(CatalogKeys.librariesMenu, find.byKey(homeRefreshKey)),
        findsOneWidget,
      );
    },
    tags: ['integration'],
  );

  testWidgets(
    'a home row recovers from quiet-retry exhaustion and keeps cached cards',
    (tester) async {
      server.latestMovieStatus = 500;
      final auth = await connect(tester);
      await tester.pumpWidget(RillightApp(auth: auth));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final row = CatalogKeys.latestMoviesRow;
      Finder skeleton() => inRow(row, find.byType(SkeletonShelfRow));
      Finder retry() => inRow(row, find.text('重试'));

      expect(find.byKey(row), findsOneWidget);
      expect(skeleton(), findsOneWidget);
      expect(retry(), findsNothing);

      await tester.pump(const Duration(seconds: 28));
      await tester.pump(const Duration(milliseconds: 50));
      expect(skeleton(), findsNothing);
      expect(retry(), findsOneWidget);
      expect(find.text('飞屋环游记'), findsNothing);
      final requestsAfterExhaustion = server.requests
          .where((request) => request.contains('IncludeItemTypes=Movie'))
          .length;

      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        server.requests
            .where((request) => request.contains('IncludeItemTypes=Movie'))
            .length,
        requestsAfterExhaustion,
      );
      expect(retry(), findsOneWidget);

      // 点击「重试」后恢复。
      server.latestMovieStatus = null;
      await scrollBelowTopBar(tester, retry());
      await tester.tap(retry());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(retry(), findsNothing);
      await scrollBelowTopBar(tester, find.byKey(row));
      await settle(tester);
      expect(inRow(row, find.text('飞屋环游记')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // 已有可见卡片时刷新失败:保留缓存卡片并再次提供本地重试。
      final catalog = CatalogScope.of(tester.element(find.byType(HomePage)));
      server.latestMovieStatus = 500;
      final reload = catalog.reloadHomeRows();
      await settle(tester);
      await reload;
      await tester.pump(const Duration(seconds: 28));
      await settle(tester);
      expect(catalog.latestMovies.notice, isNotNull);
      await scrollBelowTopBar(tester, find.byKey(CatalogKeys.latestMoviesRow));
      expect(
        inRow(CatalogKeys.latestMoviesRow, find.text('飞屋环游记')),
        findsOneWidget,
      );
      expect(
        inRow(CatalogKeys.latestMoviesRow, find.text('重试')),
        findsOneWidget,
      );
      server.latestMovieStatus = null;
      await tester.tap(inRow(CatalogKeys.latestMoviesRow, find.text('重试')));
      await settle(tester);
      expect(catalog.latestMovies.error, isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'home background rebuild retains scroll and compact navigation returns home',
    (tester) async {
      final auth = await connect(tester);
      final app = RillightApp(auth: auth);
      await tester.pumpWidget(app);
      await settle(tester);
      expect(find.byKey(CatalogKeys.librariesMenu), findsNothing);
      final home = tester.element(find.byType(HomePage));
      final catalog = CatalogScope.of(home);
      await scrollBelowTopBar(tester, find.byKey(CatalogKeys.latestMoviesRow));
      final position = Scrollable.of(
        tester.element(find.byType(HomeHero)),
      ).position;
      final offset = position.pixels;
      await tester.tap(find.byKey(AppShell.libraryNavKey('view-movies')));
      await settle(tester);
      expect(find.byKey(AppShell.homeNavKey), findsNothing);
      final reload = catalog.reloadHomeRows();
      await settle(tester);
      await reload;
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(CatalogKeys.back));
      await settle(tester);
      expect(position.pixels, closeTo(offset, 1));
      app.router.go(AppRoutes.library('view-movies'));
      await settle(tester);
      expect(find.byTooltip('首页'), findsOneWidget);
      await tester.tap(find.byKey(CatalogKeys.back));
      await settle(tester);
      expect(find.byType(HomePage), findsOneWidget);
    },
    tags: ['integration'],
  );

  testWidgets('offstage shelf attachment waits for content dimensions', (
    tester,
  ) async {
    final hidden = ValueNotifier(true);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.dark(),
        home: ValueListenableBuilder<bool>(
          valueListenable: hidden,
          builder: (context, value, _) => Offstage(
            offstage: value,
            child: MediaShelf(
              shelfId: 'offstage',
              title: '后台重建',
              focusItemId: 'item-8',
              items: List.generate(
                12,
                (i) => EmbyItem(id: 'item-$i', name: '电影 $i', type: 'Movie'),
              ),
              onTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    hidden.value = false;
    await settle(tester);
    expect(find.text('后台重建'), findsOneWidget);
    expect(
      find.byKey(CatalogKeys.shelfScrollRight('offstage')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'carousel pauses explicitly, on focus, offstage and reduced motion',
    (tester) async {
      HomeHero.autoAdvanceEnabled = true;
      final auth = await connect(tester);
      final app = RillightApp(auth: auth);
      await tester.pumpWidget(app);
      await settle(tester);
      String index() => tester
          .widgetList<KeyedSubtree>(
            find.descendant(
              of: find.byType(HomeHero),
              matching: find.byType(KeyedSubtree),
            ),
          )
          .map((widget) => widget.key.toString())
          .firstWhere((key) => key.contains('movie-'));
      double progress() => tester
          .widget<HomeHeroProgress>(find.byType(HomeHeroProgress))
          .progress
          .value;
      final first = index();
      await tester.pump(HomeHero.autoAdvanceInterval);
      await tester.pump(const Duration(milliseconds: 400));
      expect(index(), isNot(first));

      await tester.tap(find.byKey(CatalogKeys.heroNext));
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 400));
      final manual = index();
      expect(progress(), 0);
      expect(find.byTooltip('恢复轮播'), findsOneWidget);
      await tester.pump(const Duration(seconds: 13));
      expect(index(), manual);
      expect(progress(), 0);

      final half = Duration(
        milliseconds: HomeHero.autoAdvanceInterval.inMilliseconds ~/ 2,
      );
      await tester.tap(find.byKey(const Key('catalog-hero-pause')));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(half);
      expect(index(), manual);
      expect(progress(), closeTo(0.5, 0.05));
      final hovering = index();
      final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await hover.addPointer(location: Offset.zero);
      addTearDown(hover.removePointer);
      await hover.moveTo(tester.getCenter(find.byType(HomeHero)));
      await tester.pump();
      final held = progress();
      await tester.pump(half);
      expect(index(), hovering);
      expect(progress(), held);
      final hero = tester.getRect(find.byType(HomeHero));
      await hover.moveTo(Offset(hero.center.dx, hero.bottom + 48));
      await tester.pump();
      await tester.pump(half);
      final afterHover = progress();
      await tester.pump(const Duration(milliseconds: 400));
      expect(index(), isNot(hovering));
      expect(afterHover, closeTo(0, 0.05));

      final resumed = index();
      await tester.tap(find.byKey(const Key('catalog-hero-pause')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 13));
      expect(index(), resumed);
      expect(find.byTooltip('恢复轮播'), findsOneWidget);
      await tester.tap(find.byKey(const Key('catalog-hero-pause')));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byKey(CatalogKeys.heroPlay),
                matching: find.byType(Text),
              )
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      final focused = index();
      final focusedProgress = progress();
      await tester.pump(
        HomeHero.autoAdvanceInterval + const Duration(seconds: 1),
      );
      expect(index(), focused);
      expect(progress(), focusedProgress);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(HomeHero.autoAdvanceInterval);
      await tester.pump(const Duration(milliseconds: 400));
      expect(index(), isNot(focused));
      expect(find.byTooltip('暂停轮播'), findsOneWidget);

      final running = index();
      app.router.push(AppRoutes.library('view-movies'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 13));
      app.router.pop();
      await settle(tester);
      expect(index(), running);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      final reduced = progress();
      await tester.pump(const Duration(seconds: 13));
      expect(index(), running);
      expect(progress(), reduced);
      expect(
        tester
            .widget<ScrimIconButton>(
              find.byKey(const Key('catalog-hero-pause')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'browse layouts render at desktop and enlarged narrow window sizes',
    (tester) async {
      const capture = bool.fromEnvironment('BROWSE_SCREENSHOTS');
      if (capture) {
        await tester.runAsync(() async {
          final fontPath =
              Platform.environment['BROWSE_FONT'] ??
              'C:/Windows/Fonts/msyh.ttc';
          final bytes = ByteData.sublistView(
            await File(fontPath).readAsBytes(),
          );
          for (final family in ['Segoe UI', 'Microsoft YaHei UI', 'Roboto']) {
            await (FontLoader(family)..addFont(Future.value(bytes))).load();
          }
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      if (capture) {
        final artwork = await tester.runAsync(_renderFixtureArtwork);
        server = _VisualEmbyServer(artwork!);
        adapter = FakeEmbyAdapter([server]);
      }
      server.items.firstWhere((item) => item.id == 'movie-inception')
        ..name = '星际漫游：在漫长的旅途中寻找遥远故乡与失落的记忆'
        ..overview = '跨越群星与时间，一段关于相遇、告别与重逢的旅程。长篇简介在这里保持清晰的阅读层次，让播放与详情始终触手可及。'
        ..backdropImageTag = 'fixture-backdrop';
      server.views.firstWhere((view) => view.id == 'view-movies').name =
          '精选电影 · 环球光影与珍藏放映室';
      for (var i = 0; i < 18; i++) {
        server.items.add(
          FakeEmbyItem(
            id: 'visual-$i',
            name: ['山海之间', '最后一班夜行列车', '与你一起走过四季的漫长旅行'][i % 3],
            type: 'Movie',
            parentId: 'view-movies',
            productionYear: 2020 + i % 6,
            primaryImageTag: i % 4 == 0 ? null : 'fixture-poster-$i',
          ),
        );
      }
      final auth = await connect(tester);
      final app = RillightApp(auth: auth);
      final boundaryKey = GlobalKey();
      for (final scenario in [
        (size: const Size(1280, 720), scale: 1.0, name: '1280x720'),
        (size: const Size(1920, 1080), scale: 1.0, name: '1920x1080'),
        (size: const Size(1439, 900), scale: 1.0, name: '1439x900'),
        (size: const Size(1440, 900), scale: 1.0, name: '1440x900'),
        (size: const Size(1280, 720), scale: 1.5, name: '1280x720-150pct'),
        (size: const Size(800, 600), scale: 1.5, name: '800x600-150pct'),
        (size: const Size(1280, 720), scale: 1.0, name: '1280x720-noimage'),
      ]) {
        tester.view.physicalSize = scenario.size;
        tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
        app.router.go(AppRoutes.home);
        await tester.pumpWidget(RepaintBoundary(key: boundaryKey, child: app));
        await settle(tester);
        if (scenario.name.endsWith('noimage')) {
          server.items.firstWhere((item) => item.id == 'movie-inception')
            ..primaryImageTag = null
            ..backdropImageTag = null;
          final reload = CatalogScope.of(
            tester.element(find.byType(HomePage)),
          ).reloadHomeRows();
          await settle(tester);
          await reload;
        }
        for (final page in ['home', 'library']) {
          if (page == 'library') {
            app.router.push(AppRoutes.library('view-movies'));
            await settle(tester);
            expect(find.byType(LibraryPage), findsOneWidget);
            expect(find.byKey(gridFilterMenuKey).hitTestable(), findsOneWidget);
          } else {
            expect(
              find.byKey(CatalogKeys.heroPlay).hitTestable(),
              findsOneWidget,
            );
            expect(
              tester.getTopLeft(find.byKey(CatalogKeys.resumeRow)).dy,
              lessThan(scenario.size.height),
            );
            if (scenario.name == '1440x900') {
              final play = tester.getRect(find.byKey(CatalogKeys.heroPlay));
              expect(play.top, greaterThanOrEqualTo(0));
              expect(play.bottom, lessThanOrEqualTo(scenario.size.height));
              final shelfTitle = tester.getRect(
                inRow(CatalogKeys.resumeRow, find.text('继续观看')),
              );
              expect(
                shelfTitle.bottom,
                lessThanOrEqualTo(scenario.size.height),
              );
              final card = tester.getRect(
                inRow(CatalogKeys.resumeRow, find.byType(PosterCard)).first,
              );
              expect(card.top, lessThan(scenario.size.height));
              expect(card.bottom, lessThanOrEqualTo(scenario.size.height));
            }
          }
          expect(tester.takeException(), isNull);
          if (capture) {
            // Decode images on the real event loop before capturing rendered pixels.
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 500));
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/browse-experience/$page-${scenario.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(png!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      }
    },
    tags: ['integration'],
  );

  testWidgets('empty home shows an icon, centered copy and refresh', (
    tester,
  ) async {
    server.items.clear();
    server.views.clear();
    await pumpLoggedIn(tester);

    expect(find.byType(AppEmptyView), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    final message = tester.getRect(find.text('暂无可浏览的内容，请刷新或从片库开始浏览。'));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(message.center.dx, closeTo(width / 2, 16));
    expect(
      tester.widget<Text>(find.text('暂无可浏览的内容，请刷新或从片库开始浏览。')).textAlign,
      TextAlign.center,
    );
    final icon = tester.getRect(find.byIcon(Icons.inbox_outlined));
    expect(icon.center.dx, closeTo(message.center.dx, 16));
    expect(icon.bottom, lessThan(message.top));
    expect(find.byKey(homeRefreshKey), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('failed empty shelf keeps the explanation beside refresh', (
    tester,
  ) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaShelf(
            shelfId: 'latest-movies',
            title: '最近电影',
            items: const [],
            error: const EmbyException(
              EmbyFailureKind.unknown,
              detail: '货架加载失败',
            ),
            onRetry: () => retried += 1,
            headerAction: const Icon(Icons.refresh, key: homeRefreshKey),
            onTap: _ignoreItem,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.byType(AppEmptyView), findsNothing);
    expect(find.text('货架加载失败'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byKey(homeRefreshKey), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'overflowing shelf peeks the next card without cropping a short row',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      Future<void> pumpShelf(Size size, int count) async {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.dark(),
            home: Scaffold(
              body: MediaShelf(
                shelfId: 'peek',
                title: '最近电影',
                wide: true,
                items: [
                  for (var i = 0; i < count; i++)
                    EmbyItem(id: 'peek-$i', name: '电影 $i', type: 'Movie'),
                ],
                onTap: _ignoreItem,
              ),
            ),
          ),
        );
        await tester.pump();
      }

      bool cardIsCut(Rect card, double right) =>
          card.left < right - 1 && card.right > right + 1;

      await pumpShelf(const Size(744, 600), 6);
      final clipped = tester.getRect(
        find.descendant(
          of: find.byType(MediaShelf),
          matching: find.byType(Scrollable),
        ),
      );
      final clippedFinder = find.descendant(
        of: find.byType(MediaShelf),
        matching: find.byType(PosterCard),
      );
      final clippedCards = [
        for (var i = 0; i < clippedFinder.evaluate().length; i++)
          tester.getRect(clippedFinder.at(i)),
      ];
      expect(clipped.width, lessThan(744));
      expect(
        clippedCards.any((card) => cardIsCut(card, clipped.right)),
        isTrue,
      );
      expect(clippedCards.first.left, closeTo(24, 1));

      await pumpShelf(const Size(800, 600), 1);
      final full = tester.getRect(
        find.descendant(
          of: find.byType(MediaShelf),
          matching: find.byType(Scrollable),
        ),
      );
      final only = tester.getRect(find.byType(PosterCard));
      expect(full.width, closeTo(800, 1));
      expect(only.right, lessThanOrEqualTo(full.right + 1));
      expect(only.right, closeTo(24 + 232, 1));
      expect(tester.takeException(), isNull);
    },
  );
}

void _ignoreItem(EmbyItem item) {}

// Deterministic synthetic artwork, never a network/downloaded poster.
Future<List<Uint8List>> _renderFixtureArtwork() async {
  final result = <Uint8List>[];
  for (final color in [
    const Color(0xff3d697c),
    const Color(0xff8a564d),
    const Color(0xff526746),
  ]) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const bounds = Rect.fromLTWH(0, 0, 960, 540);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, const Color(0xff101820)],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      const Offset(720, 130),
      65,
      Paint()..color = const Color(0xffecd5a6),
    );
    for (var layer = 0; layer < 3; layer++) {
      final path = Path()..moveTo(0, 310.0 + layer * 55);
      for (var x = 0; x <= 960; x += 120) {
        path.lineTo(x.toDouble(), 230.0 + layer * 90 + ((x ~/ 120) % 2) * 90);
      }
      path
        ..lineTo(960, 540)
        ..lineTo(0, 540)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(
            color,
            const Color(0xff0c1520),
            0.35 + layer * 0.2,
          )!,
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(960, 540);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    result.add(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  }
  return result;
}

class _VisualEmbyServer extends FakeEmbyServer {
  _VisualEmbyServer(this.artwork);
  final List<Uint8List> artwork;

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final response = await super.handle(options, requestStream);
    if (response.statusCode == 200 && options.uri.path.contains('/Images/')) {
      final seed = options.uri.path.codeUnits.fold(0, (a, b) => a + b);
      return ResponseBody.fromBytes(
        artwork[seed % artwork.length],
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    }
    return response;
  }
}
