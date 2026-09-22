import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
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
    final backend = FakeVideoBackend();
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.phone,
      playerBindings: PlayerBindings(
        createBackend: () => backend,
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
    return (app, backend);
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

  for (final width in [360.0, 412.0]) {
    testWidgets(
      '$width touch login search detail playback, rotation and background resume',
      (tester) async {
        final server = FakeEmbyServer();
        final (app, backend) = await start(tester, server, width: width);
        await login(tester, server);
        await tester.tap(find.text('搜索').last);
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('mobile-search-field'));
        await tester.enterText(field, 'Inception');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        tester.testTextInput.hide();
        tester.view.physicalSize = Size(800, width);
        await tester.pumpAndSettle();
        expect(find.text('Inception'), findsWidgets);
        await tester.tap(find.text('首页').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('搜索').last);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, 'Inception');
        await tester.ensureVisible(find.text('Inception').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Inception').last);
        await tester.pumpAndSettle();
        expect(find.byType(MobileDetailPage), findsOneWidget);
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
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpAndSettle();
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
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('mobile-player-toggle')))
              .onPressed,
          isNotNull,
        );
        await tester.ensureVisible(
          find.byKey(const Key('mobile-player-toggle')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('mobile-player-toggle')));
        await tester.pumpAndSettle();
        expect(backend.isPlaying, isFalse);
        await tester.tap(find.byTooltip('快进 10 秒'));
        await tester.pumpAndSettle();
        expect(backend.position, greaterThan(Duration.zero));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pumpAndSettle();
        expect(backend.openCount, 1);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(backend.openCount, 2);
        expect(backend.openedPaused, isTrue);
        await tester.tap(find.byTooltip('音轨与字幕'));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(MobilePlayerPage), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(find.byType(MobilePlayerPage), findsNothing);
        expect(find.byType(MobileDetailPage), findsOneWidget);
        expect(
          server.playbackEvents.where((event) => event.kind == 'Stopped'),
          isNotEmpty,
        );
        expect(app.auth.isLoggedIn, isTrue);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }
  testWidgets(
    'connection draft survives keyboard, enlarged text and rotation',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, _) = await start(tester, server);
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
        'draft-password',
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      tester.view.physicalSize = const Size(800, 360);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(app.auth.connectDraft?.password, 'draft-password');
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('android-connect-submit')),
      );
      expect(
        tester.getRect(find.byKey(const Key('android-connect-submit'))).bottom,
        lessThanOrEqualTo(360),
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
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
    await tester.tap(find.text('片库').last);
    await tester.pumpAndSettle();
    expect(find.text('暂无内容'), findsOneWidget);
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
      await tester.tap(find.text('我的').last);
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
}
