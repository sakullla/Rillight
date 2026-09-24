import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'package:flutter/material.dart';
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
import 'package:rillight/library/poster_card.dart';

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
        findsNothing,
      );
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
      const featuredOrder = ['飞屋环游记', '封面失败片', 'Inception', '未分类型电影', '混合库电影'];
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
