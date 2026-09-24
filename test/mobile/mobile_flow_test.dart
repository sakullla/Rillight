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
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
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

void main() {
  setUp(isolateImageCache);
  Future<(RillightApp, FakeVideoBackend)> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    double width = 360,
    double scale = 1,
    FakeVideoBackend? backend,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'phone',
          deviceId: 'mobile-widget',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    final video = backend ?? FakeVideoBackend();
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.phone,
      playerBindings: PlayerBindings(
        createBackend: () => video,
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      auth.dispose();
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

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapSheetText(WidgetTester tester, String text) async {
    final list = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(Scrollable),
    );
    final target = find.text(text);
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
      final field = find.byKey(const Key('mobile-search-field'));
      await tester.enterText(field, 'Inception');
      await tester.pump(const Duration(milliseconds: 400));
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
      await tester.tap(find.text('片库').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('phone-library-block-view-tv'));
      expect(
        tester.widget<Text>(find.byKey(const Key('phone-library-title'))).data,
        '剧集',
      );
      await tester.ensureVisible(find.text('老友记'));
      await tester.tap(find.text('老友记'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileSeriesPage), findsOneWidget);
      expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
      expect(find.text('The Pilot'), findsWidgets);
      // 已看集在分集列表有"已看"文字与缩略图角标。
      expect(find.text('已看'), findsOneWidget);
      expect(find.byKey(const Key('phone-episode-watched')), findsOneWidget);
      expectPhoneOnly(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MobileShell), findsOneWidget);

      await tapKey(tester, const Key('phone-library-block-view-movies'));
      expect(
        tester.widget<Text>(find.byKey(const Key('phone-library-title'))).data,
        '电影',
      );
      await tester.ensureVisible(find.text('Inception').first);
      await tester.tap(find.text('Inception').first);
      await tester.pumpAndSettle();
      expect(find.byType(MobileDetailPage), findsOneWidget);
      expect(find.byType(MobileSeriesPage), findsNothing);
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

      // 音轨/字幕入口已收入"更多"底部面板(fca9712),不再有顶层 Tooltip。
      final more = find.byKey(const Key('mobile-player-more'));
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BottomSheet), findsOneWidget);
      await tapSheetText(tester, '英文字幕');
      expect(current.subtitleStreamIndex, 4);
      expect(current.trackFailure, isNull);
      expect(backend.subtitleIndex, 4);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
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
      expect(find.byType(BottomSheet), findsOneWidget);
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
  testWidgets('token renewal with tracks open exits the owned player route', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final (app, _) = await start(tester, server);
    await login(tester, server);
    unawaited(app.router.push('/item/movie-inception'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile-detail-play')));
    await tester.pumpAndSettle();
    // 音轨/字幕入口已收入"更多"底部面板(fca9712),不再有顶层 Tooltip。
    await tester.tap(find.byKey(const Key('mobile-player-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BottomSheet), findsOneWidget);
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
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(MobilePlayerPage), findsNothing);
    expect(find.byType(MobileDetailPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MobileShell), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
  testWidgets('cached library refresh failure is visible and retryable', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    await start(tester, server);
    await login(tester, server);
    await tester.tap(find.text('片库').last);
    await tester.pumpAndSettle();
    final library = server.views.first.name;
    expect(find.text(library), findsOneWidget);
    server.viewsStatus = 503;
    await tester.drag(
      find.byKey(const PageStorageKey('mobile-libraries-scroll')),
      const Offset(0, 350),
    );
    await tester.pumpAndSettle();
    expect(find.text(library), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    server.viewsStatus = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsNothing);
    expect(find.text(library), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
  testWidgets(
    'search failure retains results, retries, empty state and expired login reconnect',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, _) = await start(tester, server);
      await login(tester, server);
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('mobile-search-field'));
      await tester.enterText(field, 'Inception');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      server.searchStatus = 503;
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('Inception'), findsWidgets);
      expect(find.text('重试'), findsWidgets);
      server.searchStatus = null;
      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'no-such-movie');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('没有结果'), findsOneWidget);
      server.expireAuthenticatedRequests = true;
      await tester.enterText(field, 'Inception');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(app.auth.isLoggedIn, isFalse);
      expect(find.byKey(const Key('android-connect-submit')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  testWidgets(
    'search keeps idle, empty, failure and page-failure screens distinct',
    (tester) async {
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
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('mobile-search-field'));
      ScrollPosition scrollOf() => tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const PageStorageKey('mobile-search-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      int searchRequests() =>
          server.requests.where((line) => line.contains('SearchTerm=')).length;

      expect(find.byKey(const Key('mobile-search-idle')), findsOneWidget);
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.text('没有结果'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(searchRequests(), 0);

      await tester.enterText(field, '   ');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobile-search-idle')), findsOneWidget);
      expect(searchRequests(), 0);

      final beforeType = searchRequests();
      await tester.enterText(field, 'missing-title');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('mobile-search-idle')), findsOneWidget);
      expect(searchRequests(), beforeType);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobile-search-empty')), findsOneWidget);
      expect(find.text('没有结果'), findsOneWidget);
      expect(find.byKey(const Key('mobile-search-idle')), findsNothing);
      expect(find.byKey(const Key('mobile-search-failure')), findsNothing);
      expect(find.byKey(const Key('mobile-search-page-failure')), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(searchRequests(), beforeType + 1);

      server.searchStatus = 503;
      await tester.enterText(field, 'Page');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobile-search-failure')), findsOneWidget);
      expect(find.textContaining('503'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byKey(const Key('mobile-search-empty')), findsNothing);
      expect(find.byKey(const Key('mobile-search-idle')), findsNothing);
      expect(find.byKey(const Key('mobile-search-page-failure')), findsNothing);
      expect(find.text('Page 00'), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);

      server.searchStatus = null;
      await tester.tap(find.byKey(MobileFailureState.retryKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('mobile-search-item-page-0')),
        findsOneWidget,
      );
      expect(find.text('已看 40%'), findsOneWidget);
      expect(find.text('已看 0%'), findsNothing);
      expect(find.byKey(const Key('mobile-search-failure')), findsNothing);

      final beforeMore = searchRequests();
      server.searchStatus = 503;
      scrollOf().jumpTo(scrollOf().maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobile-search-load-more')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mobile-search-load-more')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('mobile-search-page-failure')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mobile-search-page-retry')), findsOneWidget);
      expect(find.text('Page 00'), findsWidgets);
      expect(find.text('Page 50'), findsNothing);
      expect(find.byKey(const Key('mobile-search-failure')), findsNothing);
      expect(find.byKey(const Key('mobile-search-empty')), findsNothing);
      expect(find.byKey(const Key('mobile-search-idle')), findsNothing);
      expect(find.text('没有结果'), findsNothing);
      expect(searchRequests(), greaterThan(beforeMore));

      server.searchStatus = null;
      scrollOf().jumpTo(scrollOf().maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mobile-search-page-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobile-search-page-failure')), findsNothing);
      expect(find.text('Page 54'), findsWidgets);
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
      unawaited(current.seekTo(const Duration(seconds: 25)));
      await tester.pumpAndSettle();
      backend.emitError('network stream interrupted');
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(backend.openedStart, const Duration(seconds: 25));
      expect(current.error, isNull);
      server.progressStatus = 503;
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(current.progressSyncFailed, isTrue);
      expect(current.error, isNull);
      expect(find.textContaining('进度'), findsWidgets);
      server.stoppedStatus = 503;
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
      final field = find.byKey(const Key('mobile-search-field'));
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

  testWidgets('empty catalog and unsupported media expose recoverable states', (
    tester,
  ) async {
    final server = FakeEmbyServer(items: [], views: []);
    final (app, backend) = await start(tester, server);
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
    await tester.tap(find.text('片库').last);
    await tester.pumpAndSettle();
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.byType(MobileEmptyState), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
    server.items.add(
      FakeEmbyItem(
        id: 'unsupported',
        name: 'Unsupported',
        type: 'Movie',
        supportsDirectPlay: false,
        supportsDirectStream: false,
      ),
    );
    app.router.push('/play/unsupported');
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
        find.byKey(const Key('mobile-search-field')),
        'Scroll',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final list = find.byKey(const PageStorageKey('mobile-search-scroll'));
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      final before = position().pixels;
      expect(before, greaterThan(100));
      // 离开搜索 tab 再回来:滚动位置保持(IndexedStack 状态保持)。
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(position().pixels, before);
      final visibleTitle = find.text('Scroll 04');
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
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('mobile-search-field')))
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
      final posterWidth = (360 - AppSpacing.md * 2 - AppSpacing.sm * 3) / 3.3;
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
      await tester.tap(find.text('片库').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileLibraryPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
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
      expect(find.text('播放速度'), findsOneWidget);
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
        tester.getRect(find.byKey(const Key('mobile-search-field'))).bottom,
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
      final field = find.byKey(const Key('mobile-search-field'));
      await tester.enterText(field, 'Inception');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('片库').last);
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
