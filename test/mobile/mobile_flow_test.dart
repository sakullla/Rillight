import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/phone_libraries_tab.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';

void main() {
  setUp(isolateImageCache);
  Future<(RillightApp, FakeVideoBackend)> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    double width = 360,
    double scale = 1,
    FakeVideoBackend? backend,
    Set<String>? libraryIds,
    List<FakeEmbyServer> extraServers = const [],
    bool signedIn = false,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = [server, ...extraServers];
    final auth = SyntheticSourceAuth(
      adapter: FakeEmbyAdapter(catalog),
      device: const EmbyDeviceInfo(
        clientName: 'test',
        deviceName: 'phone',
        deviceId: 'mobile-widget',
        version: '1',
      ),
      libraryIds: libraryIds ?? server.views.map((view) => view.id).toSet(),
    );
    final runtime = await tester.runAsync(auth.runtime);
    final video = backend ?? FakeVideoBackend();
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.phone,
      playerBindings: PlayerBindings(
        runtime: runtime,
        createBackend: () => video,
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    if (signedIn) {
      await tester.runAsync(() async {
        for (final item in catalog) {
          final connected = await auth.connect(
            address: item.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
          if (!connected) {
            throw StateError('signed-in fixture failed for ${item.baseUrl}');
          }
        }
      });
    }
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      // HTTP image futures launched in fake time need a frame after unmount.
      await tester.pump(const Duration(seconds: 13));
      app.router.dispose();
      final closing = runtime!.history.close().timeout(
        const Duration(seconds: 5),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.runAsync(() => closing);
      auth.dispose();
      // Real async cache reads can enqueue fake-time HTTP timers after unmount.
      await tester.pump(const Duration(seconds: 13));
      await tester.pump();
    });
    return (app, video);
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

  Future<void> tapSheetText(WidgetTester tester, String text) async {
    final list = find.descendant(
      of: find.byKey(const Key('mobile-player-options')),
      matching: find.byType(Scrollable),
    );
    final target = find.descendant(
      of: find.byKey(const Key('mobile-player-options')),
      matching: find.text(text),
    );
    for (var i = 0; i < 12; i++) {
      if (target.evaluate().isNotEmpty) {
        final box = tester.renderObject<RenderBox>(target);
        final top = box.localToGlobal(Offset.zero).dy;
        final bottom = top + box.size.height;
        final screen = tester.view.physicalSize.height;
        if (top >= 0 && bottom <= screen) {
          await tester.tap(target);
          await tester.pumpAndSettle();
          return;
        }
      }
      await tester.drag(list, const Offset(0, -120));
      await tester.pumpAndSettle();
    }
    fail('could not tap $text in the tracks sheet');
  }

  void expectPhoneOnly(WidgetTester tester) {
    expect(find.byType(AppShell, skipOffstage: false), findsNothing);
    expect(find.byType(TvShell, skipOffstage: false), findsNothing);
    expect(find.byType(LibraryPage, skipOffstage: false), findsNothing);
    expect(find.byType(ItemDetailPage, skipOffstage: false), findsNothing);
    expect(find.byType(PlayerPage, skipOffstage: false), findsNothing);
    expect(find.byType(TvLibraryPage, skipOffstage: false), findsNothing);
    expect(find.byType(TvDetailPage, skipOffstage: false), findsNothing);
    expect(find.byType(TvPlayerPage, skipOffstage: false), findsNothing);
  }

  testWidgets('home chrome ignores aggregation scroll and layout restoration', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    // One continue-watching row fits in 360×800, so the outer list cannot
    // scroll. Extra signed-in servers add vertical shelves.
    await start(
      tester,
      server,
      extraServers: [
        for (var i = 2; i <= 3; i++)
          FakeEmbyServer(
            serverId: 'server-id-$i',
            serverName: '来源 $i',
            baseUrl: Uri.parse('http://emby-$i.test:8096'),
          ),
      ],
      signedIn: true,
    );
    ScrollPosition position(String key, {bool offstage = false}) {
      final elements = find
          .descendant(
            of: find.byKey(PageStorageKey(key), skipOffstage: !offstage),
            matching: find.byType(Scrollable, skipOffstage: !offstage),
            skipOffstage: !offstage,
          )
          .evaluate();
      for (final element in elements) {
        final scroll =
            ((element as StatefulElement).state as ScrollableState).position;
        if (scroll.axis == Axis.vertical) return scroll;
      }
      fail('no vertical scrollable for $key');
    }

    bool transparent() =>
        tester.widget<AppBar>(find.byType(AppBar)).forceMaterialTransparency;
    expect(transparent(), isTrue);
    final home = position('mobile-home-scroll');
    // No pump between jumps: the final notification must supersede the first,
    // even though it equals the currently rendered transparent state.
    home.jumpTo(100);
    home.jumpTo(0);
    await tester.pumpAndSettle();
    expect(transparent(), isTrue);
    home.jumpTo(100);
    await tester.pumpAndSettle();
    expect(transparent(), isFalse);
    home.jumpTo(0);
    await tester.pumpAndSettle();
    expect(transparent(), isTrue);
    await tester.tap(find.text('聚合').last);
    await tester.pumpAndSettle();
    final aggregation = position('aggregation');
    expect(aggregation.maxScrollExtent, greaterThan(0));
    aggregation.jumpTo(aggregation.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.text('首页').last);
    await tester.pumpAndSettle();
    expect(transparent(), isTrue);
    // Offstage IndexedStack children still issue scroll notifications. They
    // must not change home chrome, including ballistic dimension correction.
    final offstageAggregation = position('aggregation', offstage: true);
    expect(offstageAggregation.maxScrollExtent, greaterThan(0));
    offstageAggregation.jumpTo(offstageAggregation.maxScrollExtent);
    expect(offstageAggregation.pixels, greaterThan(0));
    tester.view.physicalSize = const Size(800, 360);
    await tester.pumpAndSettle();
    expect(transparent(), isTrue);
    expect(position('mobile-home-scroll').pixels, 0);
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(seconds: 13));
    }
  }, tags: ['integration']);

  testWidgets('phone hero resumes through the app router and returns home', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final (_, backend) = await start(
      tester,
      server,
      backend: FakeVideoBackend(duration: const Duration(hours: 3)),
    );
    await login(tester, server);
    final catalog = CatalogScope.of(tester.element(find.byType(PhoneHome)));
    final item = PhoneHero.featuredItemsOf(catalog).first;
    expect(item.canResume, isTrue);
    final resume = find.byKey(ValueKey('hero-resume-${item.id}'));
    await tester.tap(resume);
    await tester.pumpAndSettle();
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    expect(find.text('无法播放'), findsNothing);
    expect(backend.openCount, 1);
    expect(backend.isPlaying, isTrue);
    final controller = tester
        .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
        .controller!;
    expect(controller.itemId, item.id);
    expect(
      backend.openedStart,
      Duration(microseconds: item.userData.playbackPositionTicks ~/ 10),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(MobileShell), findsOneWidget);
    expect(find.byType(MobilePlayerPage), findsNothing);
    expect(tester.widget<FilledButton>(resume).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'touch journey: login, search, series, playback, subtitle, landscape and progress',
    (tester) async {
      // 360dp 单宽度承载完整旅程;412dp 曾并行运行,属同一行为的等价断言。
      const width = 360.0;
      final server = FakeEmbyServer();
      final movie = server.items.firstWhere(
        (item) => item.id == 'movie-inception',
      );
      movie.mediaStreams = [
        ...movie.mediaStreams,
        const FakeMediaStream(
          index: 4,
          type: 'Subtitle',
          codec: 'subrip',
          language: 'eng',
          displayTitle: '英文字幕',
          isTextSubtitleStream: true,
        ),
      ];
      server.items.firstWhere((item) => item.id == 'series-friends').favorite =
          true;
      final (app, backend) = await start(
        tester,
        server,
        width: width,
        backend: FakeVideoBackend(duration: const Duration(hours: 3)),
      );
      await login(tester, server);

      // 登录后首页可见续播进度,且手机环境不出现桌面/TV 壳。
      expect(find.byType(MobileShell), findsOneWidget);
      expect(find.text('已看 40%'), findsWidgets);
      expectPhoneOnly(tester);

      // 搜索:横屏下结果可见,草稿跨 tab 保留。
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('aggregation-keyword'));
      await tester.enterText(field, 'Inception');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      tester.testTextInput.hide();
      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpAndSettle();
      expect(find.text('Inception'), findsWidgets);
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'Inception');

      // 片库:剧集块打开系列分集页,电影块打开详情页。
      tester.view.physicalSize = const Size(width, 800);
      await tester.pumpAndSettle();
      await tester.tap(find.text('聚合').last);
      await tester.pumpAndSettle();
      expect(find.byType(AggregationPage), findsOneWidget);
      await tester.tap(find.byKey(const Key('aggregation-segment-favorites')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('老友记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('老友记'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileDetailPage), findsOneWidget);
      expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
      expect(find.text('The Pilot'), findsWidgets);
      // 已看集在分集列表有"已看"文字与缩略图角标。
      expect(find.text('已看'), findsOneWidget);
      expect(find.byKey(const Key('phone-episode-watched')), findsOneWidget);
      expectPhoneOnly(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MobileShell), findsOneWidget);
      // Aggregation opens the source detail directly, without an intermediate
      // library route. One back returns to the server rows.
      expect(find.byType(AggregationPage), findsOneWidget);
      await tester.tap(find.byKey(const Key('aggregation-segment-continue')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Inception').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inception').first);
      await tester.pumpAndSettle();
      expect(find.byType(MobileDetailPage), findsOneWidget);
      expect(find.byTooltip('继续播放'), findsOneWidget);
      expect(find.byTooltip('从头播放'), findsOneWidget);
      expectPhoneOnly(tester);

      final play = find.byKey(const Key('mobile-detail-play'));
      expect(tester.getRect(play).bottom, lessThanOrEqualTo(width));
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      expect(
        ModalRoute.of(
          tester.element(find.byType(MobileDetailPage, skipOffstage: false)),
        )!.isCurrent,
        isFalse,
        reason: 'Covered detail must not receive Android predictive back',
      );
      expect(backend.openCount, 1);
      final current = tester
          .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
          .controller!;
      expect(
        current.error,
        isNull,
        reason: '${current.loadFailure} ${current.trackFailure}',
      );
      expect(current.loading, isFalse);
      // 详情页带出的续播点生效,字幕尚未切换。
      expect(backend.isPlaying, isTrue);
      expect(backend.position, const Duration(minutes: 59));
      expect(current.subtitleStreamIndex, isNot(4));

      // 横屏播放不重开;横屏下暂停与拖动进度条仍可用。
      tester.view.physicalSize = const Size(800, width);
      await tester.pumpAndSettle();
      expect(
        tester.view.physicalSize.width,
        greaterThan(tester.view.physicalSize.height),
      );
      expect(backend.isPlaying, isTrue);
      expect(backend.openCount, 1);
      expectPhoneOnly(tester);

      await tester.ensureVisible(find.byKey(const Key('mobile-player-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mobile-player-toggle')));
      await tester.pumpAndSettle();
      expect(backend.isPlaying, isFalse);
      expect(
        tester.view.physicalSize.width,
        greaterThan(tester.view.physicalSize.height),
      );

      final seek = find.byKey(const Key('mobile-player-seek'));
      await tester.ensureVisible(seek);
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(seek);
      slider.onChangeEnd!(slider.max * .75);
      await tester.pumpAndSettle();
      expect(backend.position, greaterThan(const Duration(minutes: 70)));

      // 更多面板随横竖屏选择侧边或底部布局，音轨字幕功能保持。
      final more = find.byKey(const Key('mobile-player-more'));
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('mobile-player-options')), findsOneWidget);
      final tracks = find.byKey(const Key('mobile-player-section-tracks'));
      await tester.ensureVisible(tracks);
      await tester.pumpAndSettle();
      await tester.tap(tracks);
      await tester.pumpAndSettle();
      await tapSheetText(tester, '英文字幕');
      expect(current.subtitleStreamIndex, 4);
      expect(current.trackFailure, isNull);
      expect(backend.subtitleIndex, 4);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobile-player-options')), findsNothing);
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      expectPhoneOnly(tester);

      // 回竖屏不重开;快进仍然推进进度。
      tester.view.physicalSize = const Size(width, 800);
      await tester.pumpAndSettle();
      expect(backend.openCount, 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('mobile-player-toggle')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('快进 10 秒'));
      await tester.pumpAndSettle();
      expect(backend.position, greaterThan(const Duration(minutes: 70)));

      // 后台暂停,回前台以暂停态续开。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(backend.openCount, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(backend.openCount, 2);
      expect(backend.openedPaused, isTrue);
      // "更多"面板入口在同一旅程中仍可打开(T1 修绿路径,语义保留)。
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('mobile-player-options')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(MobilePlayerPage), findsNothing);
      expect(find.byType(MobileDetailPage), findsOneWidget);
      expect(find.byTooltip('继续播放'), findsOneWidget);
      expect(
        server.playbackEvents.where((event) => event.kind == 'Stopped'),
        isNotEmpty,
      );

      // 返回首页后,服务器侧进度已更新并反映为新的"已看"百分比。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MobileShell), findsOneWidget);
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();
      final updated = server.items.firstWhere(
        (item) => item.id == 'movie-inception',
      );
      expect(
        updated.playbackPositionTicks,
        greaterThan(movie.runTimeTicks! ~/ 2),
      );
      final percent = (updated.playedPercentage ?? 0).round();
      expect(percent, isNot(40));
      expect(find.text('已看 40%'), findsNothing);
      expect(find.text('已看 $percent%'), findsWidgets);
      expectPhoneOnly(tester);
      expect(app.auth.isLoggedIn, isTrue);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  testWidgets('token renewal closes playback and reloads ordinary detail', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final (app, _) = await start(tester, server);
    await login(tester, server);
    unawaited(app.router.push('/item/movie-inception'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile-detail-play')));
    await tester.pumpAndSettle();
    // 更多面板随横竖屏选择侧边或底部布局，音轨字幕功能保持。
    await tester.tap(find.byKey(const Key('mobile-player-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('mobile-player-options')), findsOneWidget);
    final oldDetail = tester.state(
      find.byType(MobileDetailPage, skipOffstage: false),
    );
    final token = app.auth.client.accessToken;
    server.issuedTokens.clear();
    unawaited(app.auth.client.getUser());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    // 面板随会话过期的路由收起后,控制层会再排一个 4s 隐藏计时器,
    // 需要再推进一段虚拟时间冲掉,否则 teardown 报 pending timer。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(app.auth.client.accessToken, isNot(token));
    expect(find.byKey(const Key('mobile-player-options')), findsNothing);
    expect(find.byType(MobilePlayerPage), findsNothing);
    // The ordinary detail follows the renewed login with a fresh controller.
    expect(app.auth.isLoggedIn, isTrue);
    expect(find.byType(MobileDetailPage), findsOneWidget);
    expect(tester.state(find.byType(MobileDetailPage)), isNot(same(oldDetail)));
    expect(
      app.router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/item/movie-inception',
    );
    expect(find.byKey(const Key('mobile-detail-play')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
  testWidgets('aggregation browse failure is visible and source retryable', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    await start(tester, server, libraryIds: {'view-movies'});
    server.viewsStatus = 503;
    await login(tester, server);
    await tester.tap(find.text('聚合').last);
    await tester.pumpAndSettle();
    expect(find.byType(AggregationPage), findsOneWidget);
    await tester.tap(find.byKey(const Key('aggregation-segment-libraries')));
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    server.viewsStatus = null;
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsNothing);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('电影'), findsWidgets);
    // Lazy cards started cache IO on their last mount. Drain real reads and
    // fake-time HTTP/image deadlines before the test-body invariant check.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(seconds: 13));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
  testWidgets(
    'search revokes old keyword results, retries source and isolates expired login',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, _) = await start(tester, server);
      await login(tester, server);
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('aggregation-keyword'));
      await tester.enterText(field, 'Inception');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byType(PosterCard), findsWidgets);
      server.searchStatus = 503;
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('aggregation-keyword')),
          matching: find.byIcon(Icons.search),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('所选来源全部失败，请逐来源重试'), findsOneWidget);
      expect(find.text('重试'), findsWidgets);
      // 再次提交片名会撤掉上一轮海报，失败不能拿旧结果冒充成功。
      expect(find.byType(PosterCard), findsNothing);
      server.searchStatus = null;
      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      expect(find.byType(PosterCard), findsWidgets);
      expect(find.text('重试'), findsNothing);
      await tester.enterText(field, 'no-such-movie');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('没有结果'), findsOneWidget);
      expect(find.text('所选范围没有匹配作品'), findsNothing);
      expect(find.text('未选择可参与的服务或媒体库'), findsNothing);
      server.expireAuthenticatedRequests = true;
      await tester.enterText(field, 'Inception');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(app.auth.isLoggedIn, isTrue);
      expect(find.byType(MobileShell), findsOneWidget);
      // 来源登录过期只留在这一次搜索上，不把当前全局连接退出。
      expect(find.text('重试'), findsWidgets);
      expect(find.byType(PosterCard), findsNothing);
      expect(find.byKey(const Key('android-connect-submit')), findsNothing);
      final requestsAfterRevocation = server.requests.length;
      await tester.pump(const Duration(seconds: 1));
      expect(
        server.requests.length,
        requestsAfterRevocation,
        reason: '已撤销来源不在后台自动重试',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  testWidgets(
    'search keeps idle, empty, no-result and failure screens distinct',
    (tester) async {
      final server = FakeEmbyServer(
        items: [
          for (var i = 0; i < 8; i++)
            FakeEmbyItem(
              id: 'page-$i',
              name: 'Page ${i.toString().padLeft(2, '0')}',
              type: 'Movie',
              parentId: 'view-movies',
            ),
        ],
      );
      await start(tester, server, libraryIds: {'view-movies'});
      await login(tester, server);
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('aggregation-keyword'));
      int searchRequests() =>
          server.requests.where((line) => line.contains('SearchTerm=')).length;

      expect(find.byType(AggregationPage), findsOneWidget);
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.text('没有结果'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(find.text('所选范围没有匹配作品'), findsNothing);
      expect(find.text('未选择可参与的服务或媒体库'), findsNothing);
      expect(searchRequests(), 0);

      await tester.enterText(field, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(searchRequests(), 0);

      final beforeMissing = searchRequests();
      await tester.enterText(field, 'missing-title');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('没有结果'), findsOneWidget);
      expect(find.text('输入片名后搜索'), findsNothing);
      expect(find.text('所选范围没有匹配作品'), findsNothing);
      expect(find.text('未选择可参与的服务或媒体库'), findsNothing);
      expect(find.text('所选来源全部失败，请逐来源重试'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(searchRequests(), beforeMissing + 1);

      server.searchStatus = 503;
      await tester.enterText(field, 'Page');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('所选来源全部失败，请逐来源重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('没有结果'), findsNothing);
      expect(find.text('输入片名后搜索'), findsNothing);
      expect(find.text('所选范围没有匹配作品'), findsNothing);
      expect(find.text('Page 00'), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);

      server.searchStatus = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('Page 00'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.text('所选来源全部失败，请逐来源重试'), findsNothing);
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  testWidgets(
    'transport retry retains position; report failures stay separate and visible',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, backend) = await start(tester, server);
      await login(tester, server);
      app.router.push('/play/movie-inception');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      final current = tester
          .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
          .controller!;
      expect(current.runtime, isNull);
      expect(current.origin, isNull);
      expect(identical(current.client, app.auth.client), isTrue);
      unawaited(current.seekTo(const Duration(seconds: 25)));
      await tester.pumpAndSettle();
      backend.emitError('network stream interrupted');
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(backend.openedStart, const Duration(seconds: 25));
      expect(current.error, isNull);
      // Drain begin-session/history work before advancing the periodic report
      // clock; retry's open event alone is not actual viewing evidence.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 26));
      await tester.pump();
      server.progressStatus = 503;
      await tester.pump(const Duration(seconds: 11));
      // Scoped playback writes local history before reporting to its own
      // client. Fake-time frame settling alone does not drain that writer.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(
        server.playbackEvents.where((event) => event.kind == 'Progress'),
        isNotEmpty,
        reason:
            'Writer draining must reach the synthetic remote report, not only a local error',
      );
      expect(
        current.progressSyncFailed,
        isTrue,
        reason:
            'Source-owned progress report failed: ${server.playbackEvents.map((event) => event.kind).toList()}',
      );
      expect(current.error, isNull);
      expect(find.textContaining('进度'), findsWidgets);
      server.stoppedStatus = 503;
      // Waiting for the report also expires the controls' auto-hide timer.
      // Reveal them before exercising the actual close button.
      current.onUserActivity();
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(MobilePlayerPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'landscape search with large text and IME keeps submit and results scrollable',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(800, 360);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('aggregation-keyword'));
      await tester.enterText(field, 'Inception');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.getRect(field).bottom, lessThanOrEqualTo(200));
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('mobile-home-scroll')),
        findsOneWidget,
      );
    },
    tags: ['integration'],
  );

  testWidgets(
    'search page back and system back return home; mine opens private',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, _) = await start(tester, server);
      await login(tester, server);

      Future<void> openSearch() async {
        await tester.tap(find.text('搜索').last);
        await tester.pumpAndSettle();
      }

      Finder searchBack() => find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is AggregationPage && widget.search,
        ),
        matching: find.byType(BackButton),
      );

      await openSearch();
      expect(searchBack(), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        'Inception',
      );
      await tester.pump();
      await tester.tap(searchBack());
      await tester.pumpAndSettle();
      expect(find.byType(MobileShell), findsOneWidget);
      expect(
        find.byKey(const PageStorageKey('mobile-home-scroll')),
        findsOneWidget,
      );
      expect(app.router.state.uri.path, AppRoutes.home);

      await openSearch();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('mobile-home-scroll')),
        findsOneWidget,
      );
      expect(app.router.state.uri.path, AppRoutes.home);

      await tester.tap(find.byKey(const Key('mobile-shell-mine-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(PhoneMinePage.changePasswordKey), findsOneWidget);
      expect(find.text('连接其他服务器'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      expect(find.byKey(PhoneMinePage.privateKey), findsOneWidget);
      await tester.runAsync(() async {
        await app.auth.setPrivatePin('1234', '1234');
        await app.auth.regionAccess.unlock('1234');
      });
      await tester.ensureVisible(find.byKey(PhoneMinePage.privateKey));
      await tester.tap(find.byKey(PhoneMinePage.privateKey));
      await tester.pumpAndSettle();
      expect(app.router.state.uri.path, '/private');
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('empty catalog and unsupported media expose recoverable states', (
    tester,
  ) async {
    final server = FakeEmbyServer(items: [], views: []);
    final (app, backend) = await start(tester, server);
    final navigator = Navigator.of(
      tester.element(find.byType(AndroidConnectPage)),
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (context) => const AggregationPage()),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppEmptyView, '没有已登录的服务器'), findsOneWidget);
    expect(find.widgetWithText(AppEmptyView, '添加服务器'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    await login(tester, server);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.byType(MobileEmptyState), findsOneWidget);
    expect(find.byType(MobileFailureState), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(find.text('刷新'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(MobileEmptyState.actionKey)).shortestSide,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('聚合').last);
    await tester.pumpAndSettle();
    expect(find.byType(AggregationPage), findsOneWidget);
    expect(find.widgetWithText(AppEmptyView, '所选范围没有匹配作品'), findsOneWidget);
    expect(find.widgetWithText(AppEmptyView, '添加服务器'), findsNothing);
    expect(find.text('所选来源全部失败，请逐来源重试'), findsNothing);
    // Declare a real synthetic library before testing an allowed but
    // unsupported stream; empty/unknown scope must never bypass the gate.
    server.views.add(defaultCatalogViews().first);
    await tester.runAsync(
      () => app.auth.sources.configureScope(
        app.auth.session!.server.id,
        participates: true,
        libraryIds: {'view-movies'},
      ),
    );
    server.items.add(
      FakeEmbyItem(
        id: 'unsupported',
        parentId: 'view-movies',
        name: 'Unsupported',
        type: 'Movie',
        supportsDirectPlay: false,
        supportsDirectStream: false,
      ),
    );
    app.router.push('/play/unsupported');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(backend.openCount, 0);
    expect(find.text('没有可播放的流'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(MobilePlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
  testWidgets(
    'search scroll and draft survive tabs, detail back and rotation',
    (tester) async {
      final server = FakeEmbyServer(
        items: [
          for (var i = 0; i < 40; i++)
            FakeEmbyItem(
              id: 'scroll-$i',
              name: 'Scroll ${i.toString().padLeft(2, '0')}',
              type: 'Movie',
              parentId: 'view-movies',
            ),
        ],
      );
      await start(tester, server);
      await login(tester, server);
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        'Scroll',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final list = find.byKey(const PageStorageKey('aggregation-search'));
      ScrollPosition position() {
        final elements = find
            .descendant(of: list, matching: find.byType(Scrollable))
            .evaluate();
        ScrollPosition? chosen;
        for (final element in elements) {
          final scroll =
              ((element as StatefulElement).state as ScrollableState).position;
          if (scroll.axis != Axis.horizontal) continue;
          chosen = scroll;
          if (scroll.maxScrollExtent > 0) return scroll;
        }
        return chosen ??
            ((elements.first as StatefulElement).state as ScrollableState)
                .position;
      }

      final scroll = position();
      final target = scroll.maxScrollExtent == 0
          ? 0.0
          : scroll.maxScrollExtent.clamp(0, 120).toDouble();
      scroll.jumpTo(target);
      await tester.pumpAndSettle();
      final before = position().pixels;
      expect(before, target);
      // 离开搜索 tab 再回来:滚动位置保持(IndexedStack 状态保持)。
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(position().pixels, before);
      final visibleTitle = find.text('Scroll 00');
      await tester.ensureVisible(visibleTitle);
      await tester.pumpAndSettle();
      final openedOffset = position().pixels;
      await tester.tap(visibleTitle);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(position().pixels, openedOffset);
      final previousPosition = position();
      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpAndSettle();
      expect(identical(position(), previousPosition), isTrue);
      position().jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('aggregation-keyword')))
            .controller!
            .text,
        'Scroll',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'loading placeholders and empty/failure copy stay content-shaped per tab',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = AuthController.memory();
      final catalog = _ScriptedCatalog(auth);
      addTearDown(catalog.dispose);
      addTearDown(auth.dispose);
      Future<void> pumpTab(Widget child) {
        return tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: CatalogScope(controller: catalog, child: child),
            ),
          ),
        );
      }

      // 首页加载占位是内容形状的骨架,而非通用进度条。
      await pumpTab(const PhoneHome());
      await tester.pump();
      expect(find.byKey(MobileLoadingPlaceholder.homeKey), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('暂无内容'), findsNothing);
      expect(find.text('重试'), findsNothing);
      final blocks = tester
          .widgetList<SkeletonBlock>(find.byType(SkeletonBlock))
          .toList();
      expect(
        blocks.where(
          (block) => (block.width ?? 0) > 200 && (block.height ?? 0) > 100,
        ),
        isNotEmpty,
      );
      final posterWidth = phoneHomePosterCardWidth(360);
      expect(
        blocks
            .where((block) => (block.width! - posterWidth).abs() < 0.1)
            .length,
        greaterThanOrEqualTo(3),
      );

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpTab(const PhoneHome());
      await tester.pump();
      expect(
        tester
            .widgetList<SkeletonBlock>(find.byType(SkeletonBlock))
            .every((block) => !block.animated),
        isTrue,
      );

      // 首页空态与失败态是不同文案的不同组件,重试命中区不小于 48dp。
      catalog.edit((page) {
        page.resume = const CatalogRowState(hidden: true);
        page.nextUp = const CatalogRowState(hidden: true);
        page.latestMovies = const CatalogRowState(hidden: true);
        page.latestSeries = const CatalogRowState(hidden: true);
      });
      await pumpTab(const PhoneHome());
      expect(find.byType(MobileEmptyState), findsOneWidget);
      expect(find.text('暂无内容'), findsOneWidget);
      expect(find.text('加载失败'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(
        tester.getSize(find.byKey(MobileEmptyState.actionKey)).shortestSide,
        greaterThanOrEqualTo(48),
      );

      catalog.edit((page) {
        page.resume = const CatalogRowState(
          error: EmbyException(EmbyFailureKind.unknown),
        );
      });
      await tester.pump();
      expect(find.byType(MobileFailureState), findsOneWidget);
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('暂无内容'), findsNothing);
      final retry = find.byKey(MobileFailureState.retryKey);
      expect(tester.getSize(retry).shortestSide, greaterThanOrEqualTo(48));
      await tester.tap(retry);
      await tester.pump();

      // 片库 tab 有自己的骨架与空/失败文案,不与首页混用。
      catalog.edit((page) {
        page.librariesLoading = false;
        page.librariesError = null;
        page.libraries = const [];
      });
      await pumpTab(const PhoneLibrariesTab());
      expect(find.byKey(MobileLoadingPlaceholder.librariesKey), findsNothing);
      expect(find.text('暂无内容'), findsOneWidget);
      expect(find.text('加载失败'), findsNothing);
      final libraryBlocks = tester
          .widgetList<SkeletonBlock>(find.byType(SkeletonBlock))
          .toList();
      expect(libraryBlocks, isEmpty);

      catalog.edit((page) {
        page.librariesLoading = true;
      });
      await tester.pump();
      expect(find.byKey(MobileLoadingPlaceholder.librariesKey), findsOneWidget);
      expect(find.text('暂无内容'), findsNothing);
      final tiles = tester
          .widgetList<SkeletonBlock>(find.byType(SkeletonBlock))
          .toList();
      expect(tiles.length, greaterThanOrEqualTo(8));
      expect(
        tiles.where((block) => (block.height ?? 0) > 40).length,
        greaterThanOrEqualTo(4),
      );
      expect(tiles.where((block) => block.height == 14).length, 4);

      catalog.edit((page) {
        page.librariesLoading = false;
        page.librariesError = const EmbyException(EmbyFailureKind.unknown);
      });
      await tester.pump();
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('暂无内容'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'split home, libraries and mine keep navigation, back and keyboard inset',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, _) = await start(tester, server);
      await login(tester, server);
      expect(
        tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .destinations
            .length,
        3,
      );
      expect(find.text('我的'), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-shell-mine-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneMinePage), findsOneWidget);
      expect(
        app.router.routerDelegate.currentConfiguration.last.matchedLocation,
        AppRoutes.mine,
      );
      // /mine 与 MobileShell 平级,进入后 shell 被顶离路由栈。
      expect(find.byType(MobileShell), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MobileShell), findsOneWidget);
      expect(find.byType(PhoneMinePage), findsNothing);
      await tester.ensureVisible(find.byKey(PhoneHero.openKey));
      await tester.tap(find.byKey(PhoneHero.openKey));
      await tester.pumpAndSettle();
      expect(find.byType(MobileDetailPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('聚合').last);
      await tester.pumpAndSettle();
      expect(find.byType(AggregationPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('mobile-home-scroll')),
        findsOneWidget,
      );
      // 头像入口进入 /mine,返回先回 shell 首页。
      await tester.tap(find.byKey(const Key('mobile-shell-mine-entry')));
      await tester.pumpAndSettle();
      expect(find.text('alice'), findsOneWidget);
      expect(find.byKey(PhoneMinePage.settingsKey), findsOneWidget);
      expect(find.byType(PhoneMinePage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PhoneMinePage), findsNothing);
      expect(
        find.byKey(const PageStorageKey('mobile-home-scroll')),
        findsOneWidget,
      );
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        tester.getRect(find.byKey(const Key('aggregation-keyword'))).bottom,
        lessThanOrEqualTo(560),
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'bottom nav switches with a shared axis X slide and keeps tab state',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      SlideTransition slide() => tester.widget<SlideTransition>(
        find.descendant(
          of: find.byType(PhoneTabTransition),
          matching: find.byType(SlideTransition),
        ),
      );

      // 首次入场不播放,位置归零。
      expect(slide().position.value, Offset.zero);

      // 前进方向:新页从右侧滑入。
      await tester.tap(find.text('搜索').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(slide().position.value.dx, greaterThan(0));
      await tester.pumpAndSettle();
      expect(slide().position.value, Offset.zero);

      // 反向切换:从左侧滑入。
      await tester.tap(find.text('首页').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(slide().position.value.dx, lessThan(0));
      await tester.pumpAndSettle();
      expect(slide().position.value, Offset.zero);

      // IndexedStack 保留在转场内,tab 草稿不丢。
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('aggregation-keyword'));
      await tester.enterText(field, 'Inception');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('聚合').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'Inception');

      // 减少动效:切换即时就位。
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('首页').last);
      await tester.pump();
      expect(slide().position.value, Offset.zero);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey('mobile-home-scroll')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}

class _ScriptedCatalog extends CatalogController {
  _ScriptedCatalog(AuthController auth) : super(auth: auth);

  void edit(void Function(_ScriptedCatalog catalog) change) {
    change(this);
    notifyListeners();
  }
}
