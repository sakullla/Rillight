import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/home_page.dart';

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
    'refresh button falls back to the first visible shelf without resume',
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
    },
    tags: ['integration'],
  );

  testWidgets(
    'refresh button falls back to libraries when media rows are hidden',
    (tester) async {
      server.items.clear();
      await pumpLoggedIn(tester);

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
    'a home row shows error and retry after quiet retries are exhausted',
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
      expect(inRow(row, find.text('飞屋环游记')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    },
    tags: ['integration'],
  );
}
