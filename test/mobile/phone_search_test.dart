import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _field = Key('mobile-search-field');
const _idle = Key('mobile-search-idle');
const _empty = Key('mobile-search-empty');
const _failure = Key('mobile-search-failure');
const _pageFailure = Key('mobile-search-page-failure');
const _pageRetry = Key('mobile-search-page-retry');
const _loadMore = Key('mobile-search-load-more');
const _scroll = PageStorageKey<String>('mobile-search-scroll');

void main() {
  setUp(isolateImageCache);

  Future<RillightApp> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    double width = 360,
    double height = 800,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'phone',
          deviceId: 'phone-search',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.phone,
      playerBindings: PlayerBindings(
        createBackend: FakeVideoBackend.new,
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      auth.dispose();
    });
    return app;
  }

  Future<void> login(WidgetTester tester, FakeEmbyServer server) async {
    await tester.enterText(
      find.byKey(const Key('android-connect-address')),
      server.baseUrl.toString(),
    );
    await tester.enterText(
      find.byKey(const Key('android-connect-username')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const Key('android-connect-password')),
      'correct-horse',
    );
    await tester.ensureVisible(find.byKey(const Key('android-connect-submit')));
    await tester.tap(find.byKey(const Key('android-connect-submit')));
    await tester.pumpAndSettle();
    expect(find.byType(MobileShell), findsOneWidget);
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.text('搜索').last);
    await tester.pumpAndSettle();
  }

  int searchRequests(FakeEmbyServer server) {
    return server.requests.where((line) => line.contains('SearchTerm=')).length;
  }

  ScrollPosition scrollOf(WidgetTester tester) {
    return tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(_scroll),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
  }

  testWidgets('typing searches and the four result screens stay distinct', (
    tester,
  ) async {
    final server = FakeEmbyServer(
      items: [
        for (var i = 0; i < 55; i++)
          FakeEmbyItem(
            id: 'page-$i',
            name: 'Page ${i.toString().padLeft(2, '0')}',
            type: 'Movie',
            parentId: 'view-movies',
            playedPercentage: i == 0 ? 40 : null,
            playbackPositionTicks: i == 0 ? 10000000 * 60 : 0,
            runTimeTicks: 10000000 * 60 * 100,
          ),
      ],
    );
    await start(tester, server);
    await login(tester, server);
    await openSearch(tester);

    expect(find.byKey(_idle), findsOneWidget);
    expect(find.text('输入片名后搜索'), findsOneWidget);
    expect(find.text('没有结果'), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(searchRequests(server), 0);

    await tester.enterText(find.byKey(_field), '   ');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(_idle), findsOneWidget);
    expect(searchRequests(server), 0);

    final beforeType = searchRequests(server);
    await tester.enterText(find.byKey(_field), 'missing-title');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(_idle), findsOneWidget);
    expect(searchRequests(server), beforeType);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(_empty), findsOneWidget);
    expect(find.text('没有结果'), findsOneWidget);
    expect(find.byKey(_idle), findsNothing);
    expect(find.byKey(_failure), findsNothing);
    expect(find.byKey(_pageFailure), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(searchRequests(server), beforeType + 1);

    server.searchStatus = 503;
    await tester.enterText(find.byKey(_field), 'Page');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(_failure), findsOneWidget);
    expect(find.textContaining('503'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byKey(_empty), findsNothing);
    expect(find.byKey(_idle), findsNothing);
    expect(find.byKey(_pageFailure), findsNothing);
    expect(find.text('Page 00'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);

    server.searchStatus = null;
    await tester.tap(find.byKey(MobileFailureState.retryKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile-search-item-page-0')), findsOneWidget);
    expect(find.text('已看 40%'), findsOneWidget);
    expect(find.text('已看 0%'), findsNothing);
    expect(find.byKey(_failure), findsNothing);

    final beforeMore = searchRequests(server);
    server.searchStatus = 503;
    scrollOf(tester).jumpTo(scrollOf(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(_loadMore), findsOneWidget);
    await tester.tap(find.byKey(_loadMore));
    await tester.pumpAndSettle();
    expect(find.byKey(_pageFailure), findsOneWidget);
    expect(find.byKey(_pageRetry), findsOneWidget);
    expect(find.text('Page 00'), findsWidgets);
    expect(find.text('Page 50'), findsNothing);
    expect(find.byKey(_failure), findsNothing);
    expect(find.byKey(_empty), findsNothing);
    expect(find.byKey(_idle), findsNothing);
    expect(find.text('没有结果'), findsNothing);
    expect(searchRequests(server), greaterThan(beforeMore));

    server.searchStatus = null;
    scrollOf(tester).jumpTo(scrollOf(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_pageRetry));
    await tester.pumpAndSettle();
    expect(find.byKey(_pageFailure), findsNothing);
    expect(find.text('Page 54'), findsWidgets);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'series and movies both push the item route without extra submit',
    (tester) async {
      final server = FakeEmbyServer();
      final app = await start(tester, server);
      await login(tester, server);
      await openSearch(tester);

      final before = searchRequests(server);
      await tester.enterText(find.byKey(_field), '老友记');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pumpAndSettle();
      expect(searchRequests(server), before + 1);
      expect(
        find.byKey(const Key('mobile-search-item-series-friends')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('mobile-search-item-series-friends')),
      );
      await tester.pumpAndSettle();
      expect(app.router.state.uri.path, '/item/series-friends');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(app.router.state.uri.path, '/');
      expect(
        tester.widget<TextField>(find.byKey(_field)).controller!.text,
        '老友记',
      );

      await tester.enterText(find.byKey(_field), 'Inception');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('已看 40%'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('mobile-search-item-movie-inception')),
      );
      await tester.pumpAndSettle();
      expect(app.router.state.uri.path, '/item/movie-inception');
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'query and scroll survive leaving, and the keyboard keeps the field visible',
    (tester) async {
      final server = FakeEmbyServer(
        items: [
          for (var i = 0; i < 40; i++)
            FakeEmbyItem(
              id: 'scroll-$i',
              name: 'Scroll ${i.toString().padLeft(2, '0')}',
              type: i.isEven ? 'Movie' : 'Series',
              parentId: 'view-movies',
            ),
        ],
      );
      final app = await start(tester, server);
      await login(tester, server);
      await openSearch(tester);
      await tester.enterText(find.byKey(_field), 'Scroll');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      final fieldRect = tester.getRect(find.byKey(_field));
      final firstRect = tester.getRect(find.text('Scroll 00'));
      expect(fieldRect.bottom, lessThanOrEqualTo(560));
      expect(fieldRect.top, greaterThanOrEqualTo(0));
      expect(firstRect.top, greaterThanOrEqualTo(fieldRect.bottom));
      expect(firstRect.bottom, lessThanOrEqualTo(560));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);

      await tester.drag(find.byKey(_scroll), const Offset(0, -500));
      await tester.pumpAndSettle();
      final before = scrollOf(tester).pixels;
      expect(before, greaterThan(100));

      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(scrollOf(tester).pixels, before);
      expect(
        tester.widget<TextField>(find.byKey(_field)).controller!.text,
        'Scroll',
      );

      final visible = find.byKey(const Key('mobile-search-item-scroll-8'));
      await tester.ensureVisible(visible);
      await tester.pumpAndSettle();
      final opened = scrollOf(tester).pixels;
      await tester.tap(visible);
      await tester.pumpAndSettle();
      expect(app.router.state.uri.path, '/item/scroll-8');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(scrollOf(tester).pixels, opened);
      expect(
        tester.widget<TextField>(find.byKey(_field)).controller!.text,
        'Scroll',
      );

      final position = scrollOf(tester);
      tester.view.physicalSize = const Size(800, 360);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(identical(scrollOf(tester), position), isTrue);
      expect(tester.getRect(find.byKey(_field)).bottom, lessThanOrEqualTo(200));
      expect(
        tester.widget<TextField>(find.byKey(_field)).controller!.text,
        'Scroll',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('results render as a calibrated grid of pressable poster cards', (
    tester,
  ) async {
    final server = FakeEmbyServer(
      items: [
        for (var i = 0; i < 8; i++)
          FakeEmbyItem(
            id: 'grid-$i',
            name: 'Grid ${i.toString().padLeft(2, '0')}',
            type: 'Movie',
            parentId: 'view-movies',
          ),
      ],
    );
    await start(tester, server);
    await login(tester, server);
    await openSearch(tester);

    // 空态与搜索栏入口保持清晰层级。
    expect(find.byKey(_idle), findsOneWidget);
    expect(find.text('输入片名后搜索'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsWidgets);

    await tester.enterText(find.byKey(_field), 'Grid');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // T5:结果区为 GridView 网格,360dp 下列数标定为 3。
    expect(find.byKey(_empty), findsNothing);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect(delegate.crossAxisSpacing, AppSpacing.md);
    expect(delegate.mainAxisSpacing, AppSpacing.md);
    expect(find.byType(MobileGrid), findsOneWidget);
    expect(find.byType(MobilePressable), findsWidgets);
    expect(find.byKey(const Key('mobile-search-item-grid-0')), findsOneWidget);
    final art = tester.getSize(
      find.byKey(const Key('mobile-search-item-grid-0')),
    );
    expect(art.width, closeTo((360 - 32 - 2 * 16) / 3, 1));
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}
