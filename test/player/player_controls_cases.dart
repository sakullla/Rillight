import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-player-ui',
  version: '0.1.0',
);

void main() {
  setUp(isolateImageCache);
  late RillightApp app;
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeVideoBackend backend;
  late PlayerWindow window;
  late MemoryPlaybackSessionSnapshotStore snapshots;

  setUp(() {
    HomeHero.autoAdvanceEnabled = false;
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    backend = FakeVideoBackend();
    window = PlayerWindow();
    snapshots = MemoryPlaybackSessionSnapshotStore();
  });

  tearDown(() {
    HomeHero.autoAdvanceEnabled = true;
  });

  PlayerBindings bindings({
    Duration hideAfter = const Duration(days: 1),
    Duration progressInterval = const Duration(seconds: 10),
    PlayerSettingsStore? settingsStore,
    DandanplayClient? danmakuClient,
  }) {
    return PlayerBindings(
      createBackend: () => backend,
      window: window,
      progressInterval: progressInterval,
      controlsHideAfter: hideAfter,
      nextEpisodeCountdown: const Duration(seconds: 3),
      settingsStore: settingsStore,
      snapshotStore: snapshots,
      danmakuClient: danmakuClient,
    );
  }

  Future<AuthController> pumpLoggedIn(
    WidgetTester tester, {
    Duration hideAfter = const Duration(days: 1),
    Duration progressInterval = const Duration(seconds: 10),
    PlayerSettingsStore? settingsStore,
    DandanplayClient? danmakuClient,
  }) async {
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
    app = RillightApp(
      auth: auth,
      playerBindings: bindings(
        hideAfter: hideAfter,
        progressInterval: progressInterval,
        settingsStore: settingsStore ?? MemoryPlayerSettingsStore(),
        danmakuClient: danmakuClient,
      ),
    );
    return auth;
  }

  /// 不经 widget 树直接驱动的控制器(真实异步),用于断言 close() 的
  /// Stopped→onClose 顺序与 3 秒上限。
  Future<PlayerController> startStandaloneController({
    VoidCallback? onClose,
    ValueChanged<String>? onOpenItem,
    void Function(String itemId, {String? seasonId})? onOpenItemDetail,
    Duration progressInterval = const Duration(seconds: 10),
    Duration stoppedTimeout = PlayerController.stoppedDeadline,
    Duration disposeTimeout = PlayerController.stoppedDeadline,
    String itemId = 'movie-up',
    PlayerSettingsStore? settingsStore,
  }) async {
    final client = EmbyClient(device: _device, dio: dioForFakeEmby(adapter));
    final auth = AuthController(
      client: client,
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    expect(auth.isLoggedIn, isTrue);
    final controller = PlayerController(
      client: client,
      itemId: itemId,
      backend: backend,
      window: window,
      stoppedTimeout: stoppedTimeout,
      disposeTimeout: disposeTimeout,
      progressInterval: progressInterval,
      settingsStore: settingsStore ?? MemoryPlayerSettingsStore(),
      snapshotStore: snapshots,
      onClose: onClose,
      onOpenItem: onOpenItem,
      onOpenItemDetail: onOpenItemDetail,
    );
    await controller.start();
    expect(controller.loading, isFalse);
    expect(controller.resolved, isNotNull);
    return controller;
  }

  List<FakePlaybackEvent> stoppedEvents() =>
      server.playbackEvents.where((event) => event.kind == 'Stopped').toList();

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isNotEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('never found $finder');
  }

  Future<void> waitForGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('still found $finder');
  }

  Future<void> openPlayable(WidgetTester tester, String itemId) async {
    app.router.go('/item/$itemId');
    await tester.pumpWidget(app);
    await settle(tester);
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byType(PlayerPage));
    for (var i = 0; i < 40; i++) {
      if (find.byKey(PlayerKeys.playPause).evaluate().isNotEmpty ||
          find.byKey(PlayerKeys.resumeContinue).evaluate().isNotEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('player did not show controls or resume prompt');
  }

  PlayerController controllerOf(WidgetTester tester) {
    return tester.state<PlayerPageState>(find.byType(PlayerPage)).controller!;
  }

  void setPlayerLogicalSize(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
  }) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openDanmakuSearch(WidgetTester tester) async {
    await waitFor(tester, find.byKey(const Key('player-danmaku-menu')));
    await tester.tap(find.byKey(const Key('player-danmaku-menu')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('player-danmaku-search')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  void pressPlayerIcon(WidgetTester tester, Key key) {
    tester
        .widget<IconButton>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed!();
  }

  Future<void> openDanmakuPanel(WidgetTester tester) async {
    await waitFor(tester, find.byKey(const Key('player-danmaku-menu')));
    pressPlayerIcon(tester, const Key('player-danmaku-menu'));
    await tester.pump();
    await tester.pump();
    await waitFor(tester, find.byKey(const Key('player-danmaku-panel')));
  }

  Future<void> flushPlayerAsync(
    WidgetTester tester, {
    Duration extra = Duration.zero,
  }) async {
    if (extra > Duration.zero) {
      await tester.pump(extra);
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(Duration.zero);
    }
  }

  testWidgets('failed subtitle selection shows a dismissible player banner', (
    tester,
  ) async {
    final failing = _FailingSubtitleBackend();
    backend = failing;
    _withEpisodeStreams(server, subtitleIndexById: {'movie-up': 2});
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(controllerOf(tester).subtitleStreamIndex, 2);

    failing.failSubtitleOff = true;
    await tester.tap(find.byTooltip('字幕'));
    await settle(tester);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, '关闭字幕'));
    await settle(tester);

    final banner = find.byKey(const ValueKey('player-track-failure'));
    expect(banner, findsOneWidget);
    expect(find.text('音轨 / 字幕：加载失败'), findsOneWidget);
    expect(controllerOf(tester).subtitleStreamIndex, 2);
    expect(failing.subtitleOff, isFalse);
    await tester.tap(
      find.descendant(of: banner, matching: find.byType(IconButton)),
    );
    await tester.pump();
    expect(banner, findsNothing);

    failing.failSubtitleOff = false;
    await tester.tap(find.byTooltip('字幕'));
    await settle(tester);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, '关闭字幕'));
    await settle(tester);
    expect(controllerOf(tester).subtitleStreamIndex, isNull);
    expect(failing.subtitleOff, isTrue);
    expect(banner, findsNothing);
  }, tags: ['integration']);

  testWidgets('saved progress resumes without a continue-or-restart prompt', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');

    expect(find.text('要从上次的位置继续播放吗？'), findsNothing);
    expect(find.byKey(PlayerKeys.resumeContinue), findsNothing);
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(find.byKey(PlayerKeys.volumePercent), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(backend.openedUrl, isNotNull);
    expect(backend.openedUrl!.queryParameters['static'], 'true');
    expect(backend.openedStart, greaterThan(Duration.zero));
    expect(
      server.playbackEvents.map((event) => event.kind),
      contains('Playing'),
    );
  }, tags: ['integration']);

  testWidgets('movie end shows replay card instead of a blank frame', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playbackEnded));
    expect(find.text('播放结束'), findsOneWidget);
    expect(find.byKey(PlayerKeys.replay), findsOneWidget);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
    expect(find.byKey(PlayerKeys.playPause), findsNothing);

    final opens = backend.openCount;
    await tester.tap(find.byKey(PlayerKeys.replay));
    await tester.pump();
    await waitForGone(tester, find.byKey(PlayerKeys.playbackEnded));
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(backend.openCount, opens + 1);
    expect(controllerOf(tester).playbackEnded, isFalse);
  }, tags: ['integration']);

  testWidgets('pausing on the last frame without EOF does not end playback', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    backend.pauseAtEndWithoutComplete(at: controllerOf(tester).duration);
    await tester.pump();
    expect(find.byKey(PlayerKeys.playbackEnded), findsNothing);
    expect(find.byKey(PlayerKeys.replay), findsNothing);
    expect(controllerOf(tester).playbackEnded, isFalse);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
    await tester.pump(PlayerController.stoppedDeadline);
    await tester.pump();
  }, tags: ['integration']);

  testWidgets('view series from the ended card opens series detail', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'episode-friends-s1e2');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.endedViewSeries));
    await tester.tap(find.byKey(PlayerKeys.endedViewSeries));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await waitForGone(tester, find.byType(PlayerPage));
    expect(find.text('条目不可用'), findsNothing);
    await waitFor(tester, find.byType(ItemDetailPage));
    final app = tester.widget<RillightApp>(find.byType(RillightApp));
    expect(app.router.state.uri.path, '/item/series-friends');
    expect(app.router.state.uri.queryParameters['season'], 'season-friends-1');
    await tester.pump(PlayerController.stoppedDeadline);
    await tester.pump();
  }, tags: ['integration']);

  test(
    'openEndedSeries opens series detail instead of playing the series',
    () async {
      String? detailId;
      String? detailSeasonId;
      String? openId;
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e2',
        onOpenItem: (id) => openId = id,
        onOpenItemDetail: (id, {seasonId}) {
          detailId = id;
          detailSeasonId = seasonId;
        },
      );
      addTearDown(controller.dispose);

      controller.openEndedSeries();
      expect(detailId, 'series-friends');
      expect(detailSeasonId, 'season-friends-1');
      expect(openId, isNull);
      expect(controller.error, isNull);
    },
  );

  test(
    'openEndedSeries without a detail callback closes instead of playing',
    () async {
      final closed = Completer<void>();
      String? openId;
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e2',
        onClose: closed.complete,
        onOpenItem: (id) => openId = id,
      );
      addTearDown(controller.dispose);

      controller.openEndedSeries();
      await closed.future.timeout(const Duration(seconds: 5));
      expect(openId, isNull);
    },
  );

  test(
    'episode pause at end offers the next episode without a completed event',
    () async {
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e1',
      );
      addTearDown(controller.dispose);

      backend.pauseAtEndWithoutComplete(at: controller.duration);
      for (var i = 0; i < 50; i++) {
        if (controller.nextEpisode != null) {
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.nextEpisode?.item.id, 'episode-friends-s1e2');
      expect(controller.playbackEnded, isFalse);
    },
  );

  test('next episode keeps subtitle language and bitrate', () async {
    _withEpisodeStreams(
      server,
      subtitleIndexById: {'episode-friends-s1e1': 2, 'episode-friends-s1e2': 4},
    );
    final controller = await startStandaloneController(
      itemId: 'episode-friends-s1e1',
    );
    addTearDown(controller.dispose);
    expect(controller.subtitleStreamIndex, 2);

    await controller.setSubtitle(2);
    await controller.setMaxBitrate(4000000);
    final next = await controller.client.getItem('episode-friends-s1e2');
    controller.nextEpisode = NextEpisodeOffer(item: next);
    await controller.playNextEpisode();

    expect(controller.itemId, 'episode-friends-s1e2');
    expect(controller.subtitleStreamIndex, 4);
    expect(controller.maxStreamingBitrate, 4000000);
    expect(controller.error, isNull);
  });

  test(
    'bitrate-only memory does not turn subtitles off on the next episode',
    () async {
      _withEpisodeStreams(
        server,
        subtitleIndexById: {
          'episode-friends-s1e1': 2,
          'episode-friends-s1e2': 3,
        },
      );
      final store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          seriesPreferences: {
            'series-friends': PlayerSeriesPreference(
              maxStreamingBitrate: 4000000,
            ),
          },
        ),
      );
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e1',
        settingsStore: store,
      );
      addTearDown(controller.dispose);
      expect(controller.subtitleStreamIndex, 2);
      expect(controller.maxStreamingBitrate, 4000000);

      final next = await controller.client.getItem('episode-friends-s1e2');
      controller.nextEpisode = NextEpisodeOffer(item: next);
      await controller.playNextEpisode();
      expect(controller.subtitleStreamIndex, 3);
      expect(controller.maxStreamingBitrate, 4000000);
    },
  );

  testWidgets(
    'repeated progress failures keep the banner until a report succeeds',
    (tester) async {
      server.progressStatus = 500;
      await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');

      // 首次失败:4 秒后自动隐藏,无关闭钮。
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
      expect(controllerOf(tester).progressSyncPersistent, isFalse);
      expect(
        find.byKey(const Key('player-progress-sync-dismiss')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsNothing);

      // 连续第二次失败:持续显示,4 秒后仍在,带关闭钮。
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
      expect(find.text('进度同步失败'), findsOneWidget);
      expect(controllerOf(tester).progressSyncPersistent, isTrue);
      expect(
        find.byKey(const Key('player-progress-sync-dismiss')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
      expect(backend.isPlaying, isTrue);

      // 下一次上报成功后消失。
      server.progressStatus = null;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsNothing);
      expect(controllerOf(tester).progressSyncPersistent, isFalse);
    },
    tags: ['integration'],
  );

  testWidgets('danmaku search field can be focused, selected, and edited', (
    tester,
  ) async {
    await pumpLoggedIn(
      tester,
      settingsStore: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _SilentDanmakuClient(),
    );
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await waitFor(tester, find.byKey(const Key('player-danmaku-menu')));
    await tester.tap(find.byKey(const Key('player-danmaku-menu')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('player-danmaku-search')));
    await tester.pump();
    await tester.pump();

    final field = find.byKey(const Key('player-danmaku-search-field'));
    expect(field, findsOneWidget);
    final textField = tester.widget<TextField>(field);
    expect(textField.controller!.text, isNotEmpty);
    expect(textField.controller!.selection.baseOffset, 0);
    expect(
      textField.controller!.selection.extentOffset,
      textField.controller!.text.length,
    );
    expect(
      tester
          .state<EditableTextState>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .widget
          .focusNode
          .hasFocus,
      isTrue,
    );

    final playing = controllerOf(tester).isPlaying;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controllerOf(tester).isPlaying, playing);
    await tester.enterText(field, '自定义 关键词');
    await tester.pump();
    expect(textField.controller!.text, '自定义 关键词');
    expect(controllerOf(tester).isPlaying, playing);
  }, tags: ['integration']);

  testWidgets('danmaku search Esc restores play-pause shortcut', (
    tester,
  ) async {
    await pumpLoggedIn(
      tester,
      settingsStore: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _SilentDanmakuClient(),
    );
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await openDanmakuSearch(tester);

    expect(
      find.byKey(const Key('player-danmaku-search-panel')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('player-danmaku-search-panel')), findsNothing);

    final playing = controllerOf(tester).isPlaying;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controllerOf(tester).isPlaying, isNot(playing));
    await flushPlayerAsync(tester);
  }, tags: ['integration']);

  testWidgets(
    'displacing danmaku search with settings or episodes restores play-pause',
    (tester) async {
      await pumpLoggedIn(
        tester,
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
        ),
        danmakuClient: _SilentDanmakuClient(),
      );
      await openPlayable(tester, 'episode-friends-s1e2');
      await waitFor(tester, find.byKey(PlayerKeys.playPause));
      await openDanmakuSearch(tester);
      expect(
        find.byKey(const Key('player-danmaku-search-panel')),
        findsOneWidget,
      );

      pressPlayerIcon(tester, const Key('player-danmaku-menu'));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('player-danmaku-search-panel')),
        findsNothing,
      );
      expect(find.byKey(const Key('player-danmaku-panel')), findsOneWidget);

      var playing = controllerOf(tester).isPlaying;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controllerOf(tester).isPlaying, isNot(playing));

      await tester.tap(find.byKey(const Key('player-danmaku-search')));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('player-danmaku-search-panel')),
        findsOneWidget,
      );

      pressPlayerIcon(tester, const Key('player-episodes'));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('player-danmaku-search-panel')),
        findsNothing,
      );
      expect(find.byKey(const Key('player-episodes-panel')), findsOneWidget);

      playing = controllerOf(tester).isPlaying;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controllerOf(tester).isPlaying, isNot(playing));
      await waitFor(tester, find.byKey(const Key('player-episodes-list')));
      await flushPlayerAsync(tester, extra: const Duration(seconds: 12));
    },
    tags: ['integration'],
  );

  testWidgets(
    'danmaku panel basic controls fit 1280x720 with advanced collapsed',
    (tester) async {
      setPlayerLogicalSize(tester);
      await pumpLoggedIn(
        tester,
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
        ),
        danmakuClient: _SilentDanmakuClient(),
      );
      await openPlayable(tester, 'movie-up');
      await waitFor(tester, find.byKey(PlayerKeys.playPause));
      await openDanmakuPanel(tester);

      expect(find.byKey(DanmakuKeys.opacity), findsOneWidget);
      expect(find.byKey(DanmakuKeys.fontScale), findsOneWidget);
      expect(find.byKey(DanmakuKeys.speed), findsOneWidget);
      expect(find.byKey(DanmakuKeys.area), findsOneWidget);
      expect(find.byKey(DanmakuKeys.typeScroll), findsOneWidget);
      expect(find.byKey(DanmakuKeys.typeTop), findsOneWidget);
      expect(find.byKey(DanmakuKeys.typeBottom), findsOneWidget);
      expect(find.byKey(DanmakuKeys.typeColorful), findsOneWidget);
      expect(find.byKey(DanmakuKeys.advancedToggle), findsOneWidget);
      expect(find.byKey(DanmakuKeys.density), findsNothing);
      expect(find.byKey(DanmakuKeys.preventOverlap), findsNothing);
      expect(find.byKey(DanmakuKeys.timeOffset), findsNothing);

      final panel = tester.getRect(find.byKey(DanmakuKeys.panel));
      for (final key in [
        DanmakuKeys.opacity,
        DanmakuKeys.fontScale,
        DanmakuKeys.speed,
        DanmakuKeys.area,
        DanmakuKeys.typeScroll,
        DanmakuKeys.advancedToggle,
      ]) {
        final rect = tester.getRect(find.byKey(key));
        expect(rect.height, greaterThan(0));
        expect(panel.overlaps(rect), isTrue);
      }
      expect(
        tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byKey(DanmakuKeys.panel),
                matching: find.byType(Scrollable),
              ),
            )
            .position
            .maxScrollExtent,
        0,
      );

      await tester.tap(find.byKey(DanmakuKeys.advancedToggle));
      await tester.pump();
      expect(find.byKey(DanmakuKeys.preventOverlap), findsOneWidget);
      expect(find.byKey(DanmakuKeys.mergeDuplicates), findsOneWidget);
      expect(find.byKey(DanmakuKeys.outline), findsOneWidget);
      expect(find.byKey(DanmakuKeys.followPlaybackRate), findsOneWidget);
      expect(find.byKey(DanmakuKeys.density), findsOneWidget);
      expect(find.byKey(DanmakuKeys.timeOffset), findsOneWidget);
    },
    tags: ['integration'],
  );

  testWidgets('danmaku panel active status shows loaded count and title', (
    tester,
  ) async {
    await pumpLoggedIn(
      tester,
      settingsStore: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _MatchedDanmakuClient(
        title: '测试番剧',
        comments: const [
          DanmakuComment(cid: 1, time: 1, mode: 1, color: 16777215, text: 'a'),
          DanmakuComment(cid: 2, time: 2, mode: 1, color: 16777215, text: 'b'),
          DanmakuComment(cid: 3, time: 3, mode: 1, color: 16777215, text: 'c'),
        ],
      ),
    );
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await openDanmakuPanel(tester);
    await waitFor(tester, find.textContaining('已加载 3 条'));
    expect(find.textContaining('已匹配：测试番剧'), findsOneWidget);
  }, tags: ['integration']);

  testWidgets('danmaku panel active status with zero comments', (tester) async {
    await pumpLoggedIn(
      tester,
      settingsStore: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _MatchedDanmakuClient(title: '测试番剧'),
    );
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await openDanmakuPanel(tester);
    await waitFor(tester, find.textContaining('本集无弹幕'));
  }, tags: ['integration']);

  testWidgets('danmaku panel keywords persist and restore defaults', (
    tester,
  ) async {
    setPlayerLogicalSize(tester);
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
    );
    await pumpLoggedIn(
      tester,
      settingsStore: store,
      danmakuClient: _SilentDanmakuClient(),
    );
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await openDanmakuPanel(tester);
    await tester.tap(find.byKey(DanmakuKeys.advancedToggle));
    await tester.pump();
    final field = find.byKey(DanmakuKeys.keywordInput);
    await tester.ensureVisible(field);
    await tester.pump();
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '剧透');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await flushPlayerAsync(tester);
    expect(find.byKey(DanmakuKeys.keywordChip('剧透')), findsOneWidget);
    expect((await store.read()).danmakuDisplay?.blockedKeywords, ['剧透']);

    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '   ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await flushPlayerAsync(tester);
    expect((await store.read()).danmakuDisplay?.blockedKeywords, ['剧透']);

    final restore = find.byKey(DanmakuKeys.restoreDefaults);
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await tester.pump();
    await tester.pump();
    expect((await store.read()).danmakuDisplay, const DanmakuDisplaySettings());
  }, tags: ['integration']);

  testWidgets('unconfigured danmaku panel shows guide without form', (
    tester,
  ) async {
    setPlayerLogicalSize(tester);
    await pumpLoggedIn(tester, danmakuClient: _SilentDanmakuClient());
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await openDanmakuPanel(tester);
    expect(find.byKey(DanmakuKeys.setupHint), findsOneWidget);
    expect(find.byKey(const Key('player-danmaku-search')), findsOneWidget);
    expect(find.byKey(DanmakuKeys.opacity), findsNothing);
    expect(find.byKey(DanmakuKeys.fontScale), findsNothing);
    expect(find.byKey(DanmakuKeys.speed), findsNothing);
    expect(find.byKey(DanmakuKeys.area), findsNothing);
  }, tags: ['integration']);

  testWidgets('tapping empty player surface closes the danmaku panel', (
    tester,
  ) async {
    setPlayerLogicalSize(tester);
    await pumpLoggedIn(
      tester,
      settingsStore: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _SilentDanmakuClient(),
    );
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await waitFor(tester, find.byKey(const Key('player-danmaku-menu')));
    pressPlayerIcon(tester, const Key('player-danmaku-menu'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('player-danmaku-panel')), findsOneWidget);

    await tester.tap(find.byKey(PlayerKeys.surface));
    await tester.pump();
    expect(find.byKey(const Key('player-danmaku-panel')), findsNothing);
  }, tags: ['integration']);

  testWidgets('danmaku search field stays editable while results load', (
    tester,
  ) async {
    await pumpLoggedIn(
      tester,
      settingsStore: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _HangingSearchDanmakuClient(),
    );
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await openDanmakuSearch(tester);

    final field = find.byKey(const Key('player-danmaku-search-field'));
    final panel = find.byKey(const Key('player-danmaku-search-panel'));
    await waitFor(
      tester,
      find.descendant(
        of: panel,
        matching: find.byKey(const Key('player-danmaku-search-loading')),
      ),
    );
    expect(tester.widget<TextField>(field).enabled, isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('player-danmaku-search-submit')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.enterText(field, '新关键词');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '新关键词');
    await tester.tap(find.byKey(const Key('player-danmaku-search-submit')));
    await tester.pump();
    expect(tester.widget<TextField>(field).enabled, isTrue);
    expect(
      find.descendant(
        of: panel,
        matching: find.byKey(const Key('player-danmaku-search-loading')),
      ),
      findsOneWidget,
    );
  }, tags: ['integration']);

  test(
    'close waits for Stopped before onClose and reports the last position',
    () async {
      var stoppedAtClose = -1;
      final controller = await startStandaloneController(
        onClose: () => stoppedAtClose = stoppedEvents().length,
      );
      addTearDown(controller.dispose);

      await controller.seekTo(const Duration(seconds: 65));
      await controller.close();

      expect(stoppedAtClose, 1);
      final stopped = stoppedEvents();
      expect(stopped, hasLength(1));
      expect(
        stopped.single.body['PositionTicks'],
        ticksFromDuration(const Duration(seconds: 65)),
      );
      expect(snapshots.snapshot, isNull);
    },
  );

  test(
    'close gives up on a hanging Stopped at its deadline and keeps the snapshot',
    () async {
      var closed = false;
      final controller = await startStandaloneController(
        onClose: () => closed = true,
        stoppedTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(controller.dispose);
      expect(snapshots.snapshot, isNotNull);

      server.sessionsHold = Completer<void>();
      addTearDown(() {
        final hold = server.sessionsHold;
        if (hold != null && !hold.isCompleted) {
          hold.complete();
        }
      });

      final closing = controller.close();
      expect(closed, isFalse);
      await closing;
      expect(closed, isTrue);

      // 1ms 上限可在 HTTP 到达假服务器前到期;close 仍必须返回。
      // 在途 Stopped 随后被记录并挂起,超时按失败处理,快照保留。
      for (var i = 0; i < 50 && stoppedEvents().isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(stoppedEvents(), hasLength(1));
      expect(snapshots.snapshot, isNotNull);
      expect(controller.progressSyncFailed, isTrue);
    },
  );

  test(
    'close waits for an in-flight Stopped started by setMaxBitrate',
    () async {
      var closeCount = 0;
      final controller = await startStandaloneController(
        onClose: () => closeCount++,
      );
      addTearDown(controller.dispose);

      server.sessionsHold = Completer<void>();
      addTearDown(() {
        final hold = server.sessionsHold;
        if (hold != null && !hold.isCompleted) {
          hold.complete();
        }
      });
      final switching = controller.setMaxBitrate(4000000);
      for (var i = 0; i < 50 && stoppedEvents().isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(stoppedEvents(), isNotEmpty);
      expect(closeCount, 0);

      final closing = controller.close();
      await Future<void>.delayed(Duration.zero);
      expect(closeCount, 0);

      server.sessionsHold!.complete();
      await closing;
      await switching;

      expect(closeCount, 1);
      expect(stoppedEvents(), hasLength(1));
    },
  );

  test('a second close joins the first and fires onClose once', () async {
    var closeCount = 0;
    final controller = await startStandaloneController(
      onClose: () => closeCount++,
    );
    addTearDown(controller.dispose);
    server.sessionsHold = Completer<void>();
    addTearDown(() {
      final hold = server.sessionsHold;
      if (hold != null && !hold.isCompleted) {
        hold.complete();
      }
    });
    final first = controller.close();
    final second = controller.close();
    await Future<void>.delayed(Duration.zero);
    expect(closeCount, 0);
    server.sessionsHold!.complete();
    await Future.wait([first, second]);
    expect(closeCount, 1);
    expect(stoppedEvents(), hasLength(1));
  });

  testWidgets('tapping player chrome close closes the player', (tester) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(const Key('player-window-close')));
    await tester.tap(find.byKey(const Key('player-window-close')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await waitForGone(tester, find.byType(PlayerPage));
  }, tags: ['integration']);

  testWidgets('player chrome close still hits after OSD hides', (tester) async {
    await pumpLoggedIn(tester, hideAfter: const Duration(milliseconds: 1));
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(const Key('player-window-close')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(controllerOf(tester).controlsVisible, isFalse);
    await tester.tap(find.byKey(const Key('player-window-close')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await waitForGone(tester, find.byType(PlayerPage));
  }, tags: ['integration']);

  test('close still fires onClose if backend dispose hangs', () async {
    final gated = _GatedDisposeBackend();
    backend = gated;
    gated.disposeGate = Completer<void>();
    addTearDown(() {
      final gate = gated.disposeGate;
      if (gate != null && !gate.isCompleted) {
        gate.complete();
      }
    });
    var closed = false;
    final controller = await startStandaloneController(
      onClose: () => closed = true,
      disposeTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);

    final closing = controller.close();
    await closing.timeout(const Duration(seconds: 2));
    expect(closed, isTrue);
  });

  test('close waits for snapshot delete before onClose', () async {
    final gated = _GatedDeleteStore();
    snapshots = gated;
    gated.deleteGate = Completer<void>();
    addTearDown(() {
      if (!gated.deleteGate!.isCompleted) {
        gated.deleteGate!.complete();
      }
    });

    var closed = false;
    Object? snapshotAtClose;
    final controller = await startStandaloneController(
      onClose: () {
        closed = true;
        snapshotAtClose = snapshots.snapshot;
      },
    );
    addTearDown(controller.dispose);
    expect(snapshots.snapshot, isNotNull);

    final closing = controller.close();
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(snapshots.snapshot, isNotNull);

    gated.deleteGate!.complete();
    await closing;
    expect(closed, isTrue);
    expect(snapshotAtClose, isNull);
    expect(snapshots.snapshot, isNull);
    expect(snapshots.deleteCount, 1);
  });

  test('volume percent maps linearly to mpv volume', () {
    expect(mpvVolumeForPercent(0), 0.0);
    expect(mpvVolumeForPercent(10), 10.0);
    expect(mpvVolumeForPercent(17), 17.0);
    expect(mpvVolumeForPercent(50), 50.0);
    expect(mpvVolumeForPercent(90), 90.0);
    expect(mpvVolumeForPercent(100), 100.0);
    expect(mpvVolumeForPercent(120), 120.0);
    expect(mpvVolumeForPercent(150), 150.0);
    expect(mpvVolumeForPercent(200), PlayerSettings.volumeMax.toDouble());
    expect(mpvVolumeForPercent(-5), 0.0);
  });

  test('buffer fraction is cache end over duration', () {
    expect(
      playerBufferFraction(buffer: Duration.zero, duration: Duration.zero),
      0.0,
    );
    expect(
      playerBufferFraction(
        buffer: const Duration(minutes: 11),
        duration: const Duration(minutes: 22),
      ),
      0.5,
    );
    expect(
      playerBufferFraction(
        buffer: const Duration(minutes: 30),
        duration: const Duration(minutes: 22),
      ),
      1.0,
    );
  });

  test('episode list offset jumps by index without walking prior rows', () {
    expect(
      playerEpisodeListOffset(
        index: 0,
        itemCount: 120,
        itemExtent: 112,
        viewport: 560,
      ),
      0,
    );
    expect(
      playerEpisodeListOffset(
        index: 80,
        itemCount: 120,
        itemExtent: 112,
        viewport: 560,
      ),
      80 * 112 - 560 * 0.25,
    );
    expect(
      playerEpisodeListOffset(
        index: 119,
        itemCount: 120,
        itemExtent: 112,
        viewport: 560,
      ),
      120 * 112 - 560,
    );
  });

  test('episode window start fills a page around the current index', () {
    expect(playerEpisodeWindowStart(indexNumber: 1, total: 191), 0);
    expect(
      playerEpisodeWindowStart(indexNumber: 191, total: 191),
      191 - kPlayerEpisodePageSize,
    );
    expect(playerEpisodeWindowStart(indexNumber: 40, total: 191), 40 - 1 - 4);
  });
}

void _withEpisodeStreams(
  FakeEmbyServer server, {
  required Map<String, int> subtitleIndexById,
}) {
  for (final item in server.items) {
    final subtitleIndex = subtitleIndexById[item.id];
    if (subtitleIndex == null) {
      continue;
    }
    item.mediaStreams = [
      const FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
      const FakeMediaStream(
        index: 1,
        type: 'Audio',
        codec: 'aac',
        language: 'jpn',
        displayTitle: 'Japanese',
        isDefault: true,
      ),
      FakeMediaStream(
        index: subtitleIndex,
        type: 'Subtitle',
        codec: 'ass',
        language: 'chi',
        displayTitle: '中文',
        isDefault: true,
        isTextSubtitleStream: true,
      ),
    ];
  }
}

class _GatedDisposeBackend extends FakeVideoBackend {
  Completer<void>? disposeGate;

  @override
  Future<void> dispose() async {
    final gate = disposeGate;
    if (gate != null) {
      await gate.future;
    }
  }
}

class _GatedDeleteStore extends MemoryPlaybackSessionSnapshotStore {
  Completer<void>? deleteGate;

  @override
  Future<void> delete() async {
    final gate = deleteGate;
    if (gate != null) {
      await gate.future;
    }
    await super.delete();
  }
}

class _FailingSubtitleBackend extends FakeVideoBackend {
  bool failSubtitleOff = false;

  @override
  Future<void> setSubtitleOff() async {
    if (failSubtitleOff) throw StateError('subtitle switch failed');
    await super.setSubtitleOff();
  }
}

class _HangingSearchDanmakuClient extends DandanplayClient {
  _HangingSearchDanmakuClient() : super(dio: Dio());

  @override
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
    String matchMode = 'hashAndFileName',
    CancelToken? cancelToken,
  }) async {
    return const DanmakuMatchResponse(isMatched: false, matches: []);
  }

  @override
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword, {
    CancelToken? cancelToken,
  }) {
    return Completer<List<DanmakuAnime>>().future;
  }

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) {
    return Completer<List<DanmakuAnime>>().future;
  }
}

class _MatchedDanmakuClient extends DandanplayClient {
  _MatchedDanmakuClient({this.title = '测试番剧', this.comments = const []})
    : super(dio: Dio());

  final String title;
  final List<DanmakuComment> comments;

  @override
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
    String matchMode = 'hashAndFileName',
    CancelToken? cancelToken,
  }) async {
    return DanmakuMatchResponse(
      isMatched: true,
      matches: [
        DanmakuMatchCandidate(
          animeId: 1,
          animeTitle: title,
          episodeId: 100,
          episodeTitle: '第01话',
        ),
      ],
    );
  }

  @override
  Future<List<DanmakuComment>> fetchComments(
    DandanplaySource source,
    int episodeId, {
    int? serverTimestamp,
    CancelToken? cancelToken,
  }) async {
    return comments;
  }

  @override
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    return const [];
  }
}

class _SilentDanmakuClient extends DandanplayClient {
  _SilentDanmakuClient() : super(dio: Dio());

  @override
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
    String matchMode = 'hashAndFileName',
    CancelToken? cancelToken,
  }) async {
    return const DanmakuMatchResponse(isMatched: false, matches: []);
  }

  @override
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    return const [];
  }
}
