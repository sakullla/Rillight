import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/theme/tokens.dart';
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
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/poster_card.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-home-page',
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
    await tester.pumpAndSettle();
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

  testWidgets('home renders without LiquidGlass and hero uses BackdropScrim', (
    tester,
  ) async {
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
      tester.widget(find.byKey(CatalogKeys.heroPrev)),
      isA<ScrimIconButton>(),
    );
    expect(
      tester.widget(find.byKey(CatalogKeys.heroNext)),
      isA<ScrimIconButton>(),
    );
  });

  testWidgets('shelf scroll buttons are ScrimIconButtons', (tester) async {
    for (var i = 0; i < 20; i++) {
      server.items.add(
        FakeEmbyItem(
          id: 'movie-filler-$i',
          name: 'Filler $i',
          type: 'Movie',
          parentId: 'view-movies',
          dateCreated: DateTime.utc(2000, 1, i + 1),
        ),
      );
    }
    await pumpLoggedIn(tester);
    await tester.ensureVisible(find.byKey(CatalogKeys.latestMoviesRow));
    await tester.pumpAndSettle();

    final right = find.byKey(
      CatalogKeys.shelfScrollRight(CatalogKeys.shelfLatestMovies),
    );
    expect(right, findsOneWidget);
    expect(tester.widget(right), isA<ScrimIconButton>());
    expect(
      find.descendant(
        of: find.byKey(CatalogKeys.latestMoviesRow),
        matching: find.byType(LiquidGlass),
      ),
      findsNothing,
    );

    await tester.tap(right);
    await tester.pumpAndSettle();
    final left = find.byKey(
      CatalogKeys.shelfScrollLeft(CatalogKeys.shelfLatestMovies),
    );
    expect(left, findsOneWidget);
    expect(tester.widget(left), isA<ScrimIconButton>());
  });

  testWidgets('refresh button sits in the resume shelf header and reloads', (
    tester,
  ) async {
    await pumpLoggedIn(tester);

    expect(find.byKey(homeRefreshKey), findsOneWidget);
    expect(
      inRow(CatalogKeys.resumeRow, find.byKey(homeRefreshKey)),
      findsOneWidget,
    );
    // 刷新钮与货架标题同一行:纵向落在标题文本范围内。
    final title = tester.getRect(
      inRow(CatalogKeys.resumeRow, find.text('继续观看')),
    );
    final refresh = tester.getRect(find.byKey(homeRefreshKey));
    expect(
      refresh.center.dy,
      inInclusiveRange(title.top - 24, title.bottom + 24),
    );
    // 标题为 Expanded,右缘即刷新钮左缘;「更多」在刷新钮右侧。
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
    await tester.pumpAndSettle();

    expect(resumeRequests(), greaterThan(before));
    expect(find.text('手动刷新后的电影'), findsWidgets);
  });

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
      await tester.pumpAndSettle();
      expect(resumeRequests(), greaterThan(before));
    },
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

      // 2s:第一次静默重试失败,仍是骨架屏。
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 50));
      expect(skeleton(), findsOneWidget);
      expect(retry(), findsNothing);

      // 6s:第二次静默重试失败,仍是骨架屏。
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 50));
      expect(skeleton(), findsOneWidget);
      expect(retry(), findsNothing);

      // 20s:第三次静默重试失败,计划耗尽,行显示错误与「重试」。
      await tester.pump(const Duration(seconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
      expect(skeleton(), findsNothing);
      expect(retry(), findsOneWidget);
      expect(find.text('飞屋环游记'), findsNothing);
      final requestsAfterExhaustion = server.requests
          .where((request) => request.contains('IncludeItemTypes=Movie'))
          .length;

      // 不再自动重试。
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
  );

  testWidgets('wide shelf row hugs the card and keeps the card gap', (
    tester,
  ) async {
    // 继续观看同时含电影(单行标题)与单集(剧名 + S1E2 副标题两行)。
    for (final item in server.items) {
      if (item.id == 'movie-up' || item.id == 'episode-friends-s1e2') {
        item.playbackPositionTicks = 60 * 10000000;
      }
    }
    await pumpLoggedIn(tester);

    final cards = inRow(CatalogKeys.resumeRow, find.byType(PosterCard));
    expect(cards, findsAtLeastNWidgets(3));
    expect(inRow(CatalogKeys.resumeRow, find.text('老友记')), findsOneWidget);
    final list = inRow(CatalogKeys.resumeRow, find.byType(ListView));
    final rowHeight = tester.getSize(list).height;
    final tallestCard = cards
        .evaluate()
        .map((element) => (element.renderObject! as RenderBox).size.height)
        .reduce((a, b) => a > b ? a : b);
    expect(rowHeight, greaterThanOrEqualTo(tallestCard));
    expect(
      rowHeight - tallestCard,
      lessThan(AppSpacing.sm),
      reason: '行高只为 hover 放大留余量,不再为标签多留空白',
    );

    final first = tester.getRect(cards.at(0));
    final second = tester.getRect(cards.at(1));
    expect(
      second.left - first.right,
      moreOrLessEquals(MediaShelf.cardGap, epsilon: 0.5),
    );
    expect(first.left, moreOrLessEquals(AppSpacing.page, epsilon: 0.5));
    // 首卡按 hoverScale 放大后的右缘仍在邻卡左缘之前,不与邻卡重叠。
    final scaledRight =
        first.center.dx + first.width * MediaShelf.hoverScale / 2;
    expect(scaledRight, lessThan(second.left));
  });
}
