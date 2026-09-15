import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/top_bar_hit.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-player-ui',
  version: '0.1.0',
);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeVideoBackend backend;
  late PlayerWindow window;
  late MemoryPlaybackSessionSnapshotStore snapshots;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    backend = FakeVideoBackend();
    window = PlayerWindow();
    snapshots = MemoryPlaybackSessionSnapshotStore();
  });

  PlayerBindings bindings({
    Duration hideAfter = const Duration(days: 1),
    Duration progressInterval = const Duration(seconds: 10),
    PlayerSettingsStore? settingsStore,
  }) {
    return PlayerBindings(
      createBackend: () => backend,
      window: window,
      progressInterval: progressInterval,
      controlsHideAfter: hideAfter,
      nextEpisodeCountdown: const Duration(seconds: 3),
      settingsStore: settingsStore,
      snapshotStore: snapshots,
    );
  }

  Future<AuthController> pumpLoggedIn(
    WidgetTester tester, {
    Duration hideAfter = const Duration(days: 1),
    Duration progressInterval = const Duration(seconds: 10),
    PlayerSettingsStore? settingsStore,
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
    await tester.pumpWidget(
      RillightApp(
        auth: auth,
        playerBindings: bindings(
          hideAfter: hideAfter,
          progressInterval: progressInterval,
          settingsStore: settingsStore ?? MemoryPlayerSettingsStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  /// 不经 widget 树直接驱动的控制器(真实异步),用于断言 close() 的
  /// Stopped→onClose 顺序与 3 秒上限。
  Future<PlayerController> startStandaloneController({
    VoidCallback? onClose,
    Duration progressInterval = const Duration(seconds: 10),
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
      itemId: 'movie-up',
      backend: backend,
      window: window,
      progressInterval: progressInterval,
      settingsStore: MemoryPlayerSettingsStore(),
      snapshotStore: snapshots,
      onClose: onClose,
    );
    await controller.start();
    expect(controller.loading, isFalse);
    expect(controller.resolved, isNotNull);
    return controller;
  }

  List<FakePlaybackEvent> stoppedEvents() =>
      server.playbackEvents.where((event) => event.kind == 'Stopped').toList();

  int progressCount() =>
      server.playbackEvents.where((event) => event.kind == 'Progress').length;

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

  Future<void> openLibrary(WidgetTester tester, String viewId) async {
    final homeTitle = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('灯川 Rillight'),
    );
    if (homeTitle.evaluate().isNotEmpty) {
      await tester.tap(homeTitle);
      await tester.pumpAndSettle();
    }
    final tile = find.byKey(CatalogKeys.library(viewId));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<void> openPlayable(WidgetTester tester, String itemId) async {
    final item = find.byKey(CatalogKeys.item(itemId)).first;
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
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

  Future<void> playListedEpisode(WidgetTester tester, String episodeId) async {
    final play = find.byKey(CatalogKeys.episodePlay(episodeId));
    await ensureVisibleBelowTopBar(tester, play);
    await tapBelowTopBar(tester, play);
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
  }

  Future<void> openEpisode(WidgetTester tester, String episodeId) async {
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-anim')));
    await tester.pumpAndSettle();
    await playListedEpisode(tester, episodeId);
  }

  /// 弹出菜单项:点击整行(而非 Text 本身,后者不参与命中测试)。
  Finder popupItem(String label) => find
      .ancestor(
        of: find.text(label).last,
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      )
      .last;

  Future<void> openPlaybackSettings(WidgetTester tester) async {
    await waitFor(tester, find.byKey(PlayerKeys.more));
    await tester.tap(find.byKey(PlayerKeys.more));
    await tester.pumpAndSettle();
  }

  Future<void> choosePlaybackOption(
    WidgetTester tester,
    Key settingKey,
    String option,
  ) async {
    await openPlaybackSettings(tester);
    await tester.tap(find.byKey(settingKey));
    await tester.pumpAndSettle();
    await tester.tap(popupItem(option));
    await tester.pumpAndSettle();
  }

  double controlsOpacity(WidgetTester tester) {
    return tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byKey(PlayerKeys.controls),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
  }

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
  });

  testWidgets('seek bar paints demuxer cache as the secondary track', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await waitFor(tester, find.byKey(PlayerKeys.seekBar));

    final duration = controllerOf(tester).duration;
    expect(duration, greaterThan(Duration.zero));
    backend.emitBuffer(Duration(milliseconds: duration.inMilliseconds ~/ 2));
    await tester.pump();

    final slider = tester.widget<Slider>(find.byKey(PlayerKeys.seekBar));
    expect(slider.secondaryTrackValue, closeTo(0.5, 0.02));
  });

  testWidgets('detail play from start opens at zero instead of resume', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    final item = find.byKey(CatalogKeys.item('movie-inception')).first;
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(find.byKey(PlayerKeys.resumeFromStart), findsOneWidget);
    await tester.tap(find.byKey(PlayerKeys.resumeFromStart));
    await tester.pump();
    await waitFor(tester, find.byType(PlayerPage));
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(backend.openedStart, Duration.zero);
    expect(find.text('要从上次的位置继续播放吗？'), findsNothing);
  });

  testWidgets('pointer leaving the player hides the control bar', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');
    await tester.pump();
    final player = controllerOf(tester);
    for (var i = 0; i < 40 && !player.isPlaying; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(player.isPlaying, isTrue);
    player.onUserActivity();
    expect(player.controlsVisible, isTrue);
    player.hideControlsOnPointerExit();
    expect(player.controlsVisible, isFalse);
  });

  testWidgets('progress reports every 10s and not after stop', (tester) async {
    await pumpLoggedIn(tester, progressInterval: const Duration(seconds: 10));
    await openPlayable(tester, 'movie-up');
    expect(find.byKey(PlayerKeys.playPause), findsOneWidget);

    final before = server.playbackEvents
        .where((event) => event.kind == 'Progress')
        .length;
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(
      server.playbackEvents.where((event) => event.kind == 'Progress').length,
      before + 1,
    );

    await tester.runAsync(() => controllerOf(tester).close());
    await tester.pump();
    expect(server.playbackEvents.map((event) => event.kind).last, 'Stopped');
    final stoppedCount = server.playbackEvents
        .where((event) => event.kind == 'Progress')
        .length;
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(
      server.playbackEvents.where((event) => event.kind == 'Progress').length,
      stoppedCount,
    );
  });

  testWidgets(
    'space arrows F and Esc control playback without leaving the app',
    (tester) async {
      await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');
      expect(find.byType(PlayerPage), findsOneWidget);

      await tester.tap(find.byKey(PlayerKeys.surface));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.isPlaying, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.isPlaying, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(backend.position, const Duration(seconds: 10));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(backend.position, Duration.zero);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(window.isFullScreen, isTrue);
      expect(find.byType(PlayerPage), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(window.isFullScreen, isFalse);
      expect(find.byType(PlayerPage), findsOneWidget);

      await tester.tap(find.byKey(PlayerKeys.surface));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitForGone(tester, find.byType(PlayerPage));
      expect(find.text('飞屋环游记 (2009)'), findsOneWidget);
    },
  );

  testWidgets('controls autohide while playing and return on activity', (
    tester,
  ) async {
    await pumpLoggedIn(tester, hideAfter: const Duration(milliseconds: 40));
    await openPlayable(tester, 'movie-up');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(PlayerKeys.controls), findsOneWidget);
    expect(controlsOpacity(tester), 0.0);

    await tester.tap(find.byKey(PlayerKeys.surface));
    await tester.pump();
    expect(controlsOpacity(tester), 1.0);

    await tester.tap(find.byKey(PlayerKeys.surface));
    await tester.pump();
    expect(controlsOpacity(tester), 0.0);
  });

  testWidgets('volume changes keep controls until the hide timeout', (
    tester,
  ) async {
    await pumpLoggedIn(tester, hideAfter: const Duration(milliseconds: 80));
    await openPlayable(tester, 'movie-up');
    await tester.pump(const Duration(milliseconds: 90));
    expect(controlsOpacity(tester), 0.0);

    await tester.tap(find.byKey(PlayerKeys.surface));
    await tester.pump();
    expect(controlsOpacity(tester), 1.0);

    await controllerOf(tester).setVolume(56);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(controlsOpacity(tester), 1.0);

    await tester.pump(const Duration(milliseconds: 50));
    expect(controlsOpacity(tester), 0.0);
  });

  testWidgets('transcode is labeled and quality change reopens the stream', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    await tester.ensureVisible(find.byKey(CatalogKeys.item('movie-transcode')));
    await tester.tap(find.byKey(CatalogKeys.item('movie-transcode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(find.byKey(PlayerKeys.more), findsOneWidget);
    expect(find.byKey(PlayerKeys.quality), findsNothing);
    expect(find.text('自动'), findsNothing);
    expect(find.byKey(PlayerKeys.volume), findsOneWidget);
    expect(backend.openedUrl!.path, contains('master.m3u8'));
    final firstOpen = backend.openCount;

    await tester.runAsync(() => controllerOf(tester).setAudio(1));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(backend.openCount, firstOpen + 1);
    expect(server.lastPlaybackInfoBody?['AudioStreamIndex'], 1);

    await tester.runAsync(() => controllerOf(tester).setMaxBitrate(4000000));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(backend.openCount, firstOpen + 2);
    expect(server.lastPlaybackInfoBody?['MaxStreamingBitrate'], 4000000);
    expect(
      server.playbackEvents.where((event) => event.kind == 'Stopped'),
      isNotEmpty,
    );
  });

  testWidgets('next episode countdown can be cancelled', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    await playListedEpisode(tester, 'episode-friends-s1e1');

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.nextEpisode));
    expect(find.byKey(PlayerKeys.nextEpisode), findsOneWidget);
    expect(find.textContaining('秒后播放下一集'), findsOneWidget);

    await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
    await tester.pump();
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    expect(
      server.requests.where(
        (request) =>
            request.contains('PlaybackInfo') && request.contains('s1e2'),
      ),
      isEmpty,
    );
  });

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
  });

  testWidgets('last episode end offers series instead of next episode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    await playListedEpisode(tester, 'episode-friends-s1e2');

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playbackEnded));
    expect(find.text('播放结束'), findsOneWidget);
    expect(find.byKey(PlayerKeys.endedViewSeries), findsOneWidget);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
  });

  testWidgets('mpv errors while playing do not overlay disconnect', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    backend.emitError('libass: fontselect warning');
    await tester.pump();
    backend.emitError('Cannot open connection');
    await tester.pump();
    backend.emitError('connection lost');
    await tester.pump();
    expect(find.byKey(PlayerKeys.disconnect), findsNothing);
    expect(find.text('播放中断，请检查网络'), findsNothing);
    expect(backend.isPlaying, isTrue);
  });

  testWidgets('progress sync failure is visible without stopping playback', (
    tester,
  ) async {
    server.progressStatus = 500;
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
    expect(find.text('进度同步失败'), findsOneWidget);
    expect(backend.isPlaying, isTrue);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.byKey(PlayerKeys.progressSyncFailed), findsNothing);
    expect(backend.isPlaying, isTrue);
  });

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
  );

  testWidgets('persistent progress banner can be dismissed by hand', (
    tester,
  ) async {
    server.progressStatus = 500;
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(controllerOf(tester).progressSyncPersistent, isTrue);
    expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);

    await tester.tap(find.byKey(const Key('player-progress-sync-dismiss')));
    await tester.pump();
    expect(find.byKey(PlayerKeys.progressSyncFailed), findsNothing);

    // 再次失败仍按持续态重新显示。
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
    expect(
      find.byKey(const Key('player-progress-sync-dismiss')),
      findsOneWidget,
    );
  });

  testWidgets(
    'expired session stops progress reports and shows the expiry banner',
    (tester) async {
      final auth = await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');
      await waitFor(tester, find.byKey(PlayerKeys.playPause));

      // 播放进程内没有可刷新的会话:401 直接落到播放器。
      auth.client.onRefreshSession = null;
      auth.client.onSessionExpired = null;
      server.expireAuthenticatedRequests = true;

      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      final player = controllerOf(tester);
      expect(player.sessionExpired, isTrue);
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
      expect(find.text('会话已过期，进度无法保存'), findsOneWidget);
      expect(find.text('进度同步失败'), findsNothing);
      expect(backend.isPlaying, isTrue);

      final progressAfterExpiry = progressCount();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(progressCount(), progressAfterExpiry);
      // 横幅持续显示,快照保留供宿主代发。
      expect(find.text('会话已过期，进度无法保存'), findsOneWidget);
      expect(snapshots.snapshot, isNotNull);
      expect(find.byType(PlayerPage), findsOneWidget);
    },
  );

  testWidgets(
    'Esc reports Stopped once at the last position and clears the snapshot',
    (tester) async {
      await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');
      await waitFor(tester, find.byKey(PlayerKeys.playPause));

      // Playing 成功后即有快照,字段完整。
      final initial = snapshots.snapshot;
      expect(initial, isNotNull);
      expect(initial!.itemId, 'movie-up');
      expect(initial.mediaSourceId, isNotEmpty);
      expect(initial.playSessionId, isNotEmpty);
      expect(initial.baseUrl, server.baseUrl.toString());
      expect(initial.userId, 'user-alice');

      await tester.runAsync(
        () => controllerOf(tester).seekTo(const Duration(seconds: 65)),
      );
      await tester.pump();
      expect(
        snapshots.snapshot!.positionTicks,
        ticksFromDuration(const Duration(seconds: 65)),
      );

      await tester.tap(find.byKey(PlayerKeys.surface));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitForGone(tester, find.byType(PlayerPage));

      final stopped = stoppedEvents();
      expect(stopped, hasLength(1));
      expect(
        stopped.single.body['PositionTicks'],
        ticksFromDuration(const Duration(seconds: 65)),
      );
      expect(snapshots.snapshot, isNull);
      expect(snapshots.deleteCount, 1);
      // 回到详情页后排空图片请求,避免遗留零时长定时器。
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'closing during the next-episode countdown reports Stopped once',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpLoggedIn(tester);
      await openLibrary(tester, 'view-tv');
      await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
      await tester.pumpAndSettle();
      await playListedEpisode(tester, 'episode-friends-s1e1');

      backend.completePlayback();
      await tester.pump();
      await waitFor(tester, find.byKey(PlayerKeys.nextEpisode));
      expect(stoppedEvents(), hasLength(1));

      await tester.tap(find.byKey(const Key('player-window-close')));
      await waitForGone(tester, find.byType(PlayerPage));
      expect(stoppedEvents(), hasLength(1));
      expect(
        server.requests.where(
          (request) =>
              request.contains('PlaybackInfo') && request.contains('s1e2'),
        ),
        isEmpty,
      );
    },
  );

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
    'close gives up on a hanging Stopped within 3s and keeps the snapshot',
    () async {
      var closed = false;
      final controller = await startStandaloneController(
        onClose: () => closed = true,
      );
      addTearDown(controller.dispose);
      expect(snapshots.snapshot, isNotNull);

      server.sessionsDelay = const Duration(seconds: 10);
      final watch = Stopwatch()..start();
      await controller.close();
      watch.stop();

      expect(closed, isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      // 假服务器在延迟前已记录事件:恰一次 Stopped;超时按失败处理,快照保留。
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

      server.sessionsDelay = const Duration(milliseconds: 800);
      final switching = controller.setMaxBitrate(4000000);
      for (var i = 0; i < 50 && stoppedEvents().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(stoppedEvents(), isNotEmpty);

      final watch = Stopwatch()..start();
      await controller.close();
      watch.stop();
      await switching;

      expect(closeCount, 1);
      expect(stoppedEvents(), hasLength(1));
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 200)));
    },
  );

  test('a second close joins the first and fires onClose once', () async {
    var closeCount = 0;
    final controller = await startStandaloneController(
      onClose: () => closeCount++,
    );
    addTearDown(controller.dispose);
    server.sessionsDelay = const Duration(milliseconds: 400);
    final first = controller.close();
    final second = controller.close();
    await Future.wait([first, second]);
    expect(closeCount, 1);
    expect(stoppedEvents(), hasLength(1));
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

  testWidgets('text subtitle is handed to the backend as an external URL', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(backend.subtitleUri, isNotNull);
    expect(backend.subtitleUri!.path, contains('/Subtitles/2/Stream.srt'));
  });

  testWidgets('mouse wheel over the player nudges volume by five percent', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.text('100%'));

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(PlayerKeys.surface)),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump();
    expect(find.text('95%'), findsOneWidget);
    expect(backend.volume, closeTo(mpvVolumeForPercent(95), 1e-6));

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(PlayerKeys.surface)),
        scrollDelta: const Offset(0, -120),
      ),
    );
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('mouse wheel over the episode panel does not change volume', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    await playListedEpisode(tester, 'episode-friends-s1e1');
    await waitFor(tester, find.text('100%'));

    await tester.tap(find.byKey(const Key('player-episodes')));
    await waitFor(tester, find.byKey(const Key('player-episodes-panel')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(
          find.byKey(const Key('player-episodes-list')),
        ),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('95%'), findsNothing);
    expect(backend.volume, closeTo(mpvVolumeForPercent(100), 1e-6));
  });

  test('volume percent maps linearly to mpv volume', () {
    expect(mpvVolumeForPercent(0), 0.0);
    expect(mpvVolumeForPercent(10), 10.0);
    expect(mpvVolumeForPercent(17), 17.0);
    expect(mpvVolumeForPercent(50), 50.0);
    expect(mpvVolumeForPercent(90), 90.0);
    expect(mpvVolumeForPercent(100), 100.0);
    expect(mpvVolumeForPercent(120), 100.0);
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

  testWidgets('volume tiers map to mpv and persist the user percent', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    await pumpLoggedIn(tester, settingsStore: store);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.text('100%'));

    for (final percent in const [10, 50, 90]) {
      await tester.runAsync(() async {
        await controllerOf(tester).setVolume(percent);
      });
      await tester.pump();
      expect(find.text('$percent%'), findsOneWidget);
      expect(backend.volume, closeTo(mpvVolumeForPercent(percent), 1e-6));
    }

    await tester.tap(find.byKey(PlayerKeys.mute));
    await tester.pump();
    expect(find.text('0%'), findsOneWidget);
    expect(backend.volume, 0.0);

    await tester.tap(find.byKey(PlayerKeys.mute));
    await tester.pump();
    expect(find.text('90%'), findsOneWidget);
    expect(backend.volume, closeTo(mpvVolumeForPercent(90), 1e-6));

    // 防抖持久化在 fake 时钟推进后写入用户百分比。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect((await store.read()).volume, 90);
  });

  testWidgets('volume slider drag keeps display and backend on one mapping', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.text('100%'));

    await tester.drag(find.byKey(PlayerKeys.volume), const Offset(-55, 0));
    await tester.pump();
    final percent = controllerOf(tester).volume;
    expect(percent, lessThan(100));
    expect(find.text('$percent%'), findsOneWidget);
    expect(backend.volume, closeTo(mpvVolumeForPercent(percent), 1e-6));
  });

  testWidgets('volume is restored from settings and saved after change', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore(const PlayerSettings(volume: 35));
    await pumpLoggedIn(tester, settingsStore: store);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.text('35%'));
    expect(backend.volume, closeTo(mpvVolumeForPercent(35), 1e-6));

    await tester.runAsync(() async {
      await controllerOf(tester).setVolume(20);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    expect(find.text('20%'), findsOneWidget);
    expect((await store.read()).volume, 20);
  });

  testWidgets('volume icon mutes and restores the previous level', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.text('100%'));
    await tester.runAsync(() async {
      await controllerOf(tester).setVolume(78);
    });
    await tester.pump();
    expect(find.text('78%'), findsOneWidget);

    await tester.tap(find.byKey(PlayerKeys.mute));
    await tester.pump();
    expect(find.text('0%'), findsOneWidget);
    expect(backend.volume, 0.0);

    await tester.tap(find.byKey(PlayerKeys.mute));
    await tester.pump();
    expect(find.text('78%'), findsOneWidget);
    expect(backend.volume, closeTo(mpvVolumeForPercent(78), 1e-6));
  });

  testWidgets(
    'slow pointer movement wakes hidden controls without a threshold',
    (tester) async {
      await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');
      final player = controllerOf(tester);
      for (var i = 0; i < 40 && !player.isPlaying; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(player.isPlaying, isTrue);
      expect(controlsOpacity(tester), 1.0);

      // 单击隐藏后,无位移阈值:1–2px 的极慢移动立即唤出。
      await tester.tap(find.byKey(PlayerKeys.surface));
      await tester.pump();
      expect(controlsOpacity(tester), 0.0);

      final center = tester.getCenter(find.byKey(PlayerKeys.surface));
      await tester.sendEventToBinding(
        PointerHoverEvent(position: center + const Offset(1.5, 0)),
      );
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);
    },
  );

  testWidgets('overlay chrome can drag and close through the player path', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(WindowDragArea), findsOneWidget);
    expect(find.byKey(const Key('player-window-drag')), findsOneWidget);
    expect(find.byKey(PlayerKeys.playPause), findsOneWidget);
    final player = tester.getRect(find.byType(PlayerPage));
    final drag = tester.getRect(find.byKey(const Key('player-window-drag')));
    expect(drag.top, player.top);
    expect(drag.left, player.left);
    expect(drag.width, player.width);
    expect(drag.height, kPlayerChromeBarExtent);
    expect(drag.contains(Offset(player.center.dx, player.top + 4)), isTrue);
    final caption = Offset(player.center.dx, player.top + 4);
    final hits = tester.hitTestOnBinding(caption);
    final dragBox = tester.renderObject(
      find.byKey(const Key('player-window-drag')),
    );
    expect(hits.path.any((entry) => entry.target == dragBox), isTrue);

    await tester.tap(find.byKey(const Key('player-window-close')));
    await waitForGone(tester, find.byType(PlayerPage));
    expect(find.text('飞屋环游记 (2009)'), findsOneWidget);
  });

  testWidgets('close button closes the player even from fullscreen', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(window.isFullScreen, isTrue);
    expect(find.byType(PlayerPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('player-window-close')));
    await waitForGone(tester, find.byType(PlayerPage));
    expect(window.isFullScreen, isFalse);
    expect(find.text('飞屋环游记 (2009)'), findsOneWidget);
  });

  testWidgets('infrequent playback settings sit behind the overflow menu', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(find.byKey(PlayerKeys.more), findsOneWidget);
    expect(find.byKey(PlayerKeys.speed), findsNothing);
    expect(find.byKey(PlayerKeys.quality), findsNothing);
    expect(find.byKey(PlayerKeys.audio), findsNothing);
    expect(find.byKey(PlayerKeys.mediaSource), findsNothing);
    expect(find.byKey(PlayerKeys.skipSettings), findsNothing);
    expect(find.byKey(PlayerKeys.fullscreen), findsOneWidget);

    await openPlaybackSettings(tester);
    expect(find.byKey(PlayerKeys.speed), findsOneWidget);
    expect(find.text('倍速'), findsOneWidget);
    expect(find.byKey(PlayerKeys.quality), findsNothing);
    expect(find.byKey(PlayerKeys.mediaSource), findsNothing);
  });

  testWidgets(
    'speed menu switches rate instantly and echoes the current rate',
    (tester) async {
      await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');
      await waitFor(tester, find.byKey(PlayerKeys.playPause));

      expect(controllerOf(tester).playbackRate, 1.0);
      expect(backend.rate, 1.0);
      await openPlaybackSettings(tester);
      expect(find.text('1x'), findsOneWidget);

      await tester.tap(find.byKey(PlayerKeys.speed));
      await tester.pumpAndSettle();
      await tester.tap(popupItem('2x'));
      await tester.pumpAndSettle();

      expect(controllerOf(tester).playbackRate, 2.0);
      expect(backend.rate, 2.0);
      await openPlaybackSettings(tester);
      expect(find.text('2x'), findsOneWidget);

      await tester.tap(find.byKey(PlayerKeys.speed));
      await tester.pumpAndSettle();
      await tester.tap(popupItem('1x'));
      await tester.pumpAndSettle();

      expect(controllerOf(tester).playbackRate, 1.0);
      expect(backend.rate, 1.0);
      await openPlaybackSettings(tester);
      expect(find.text('1x'), findsOneWidget);
    },
  );

  testWidgets('bracket shortcuts step playback rate through the ladder', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await tester.tap(find.byKey(PlayerKeys.surface));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    expect(controllerOf(tester).playbackRate, 1.25);
    expect(backend.rate, 1.25);
    await openPlaybackSettings(tester);
    expect(find.text('1.25x'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    expect(controllerOf(tester).playbackRate, 1.5);

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(controllerOf(tester).playbackRate, 1.25);

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(controllerOf(tester).playbackRate, 1.0);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(controllerOf(tester).playbackRate, 0.75);
    expect(backend.rate, 0.75);
    await openPlaybackSettings(tester);
    expect(find.text('0.75x'), findsOneWidget);
  });

  testWidgets('playback rate carries over to the next episode', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    await playListedEpisode(tester, 'episode-friends-s1e1');

    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.pump();
    }
    expect(controllerOf(tester).playbackRate, 2.0);
    expect(backend.rate, 2.0);

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(controllerOf(tester).playbackRate, 2.0);
    expect(backend.rate, 2.0);
    await openPlaybackSettings(tester);
    expect(find.text('2x'), findsOneWidget);
  });

  testWidgets('audio subtitle and bitrate are remembered for the series', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    server = multiTrackSeriesServer();
    adapter = FakeEmbyAdapter([server]);
    final store = MemoryPlayerSettingsStore();
    await pumpLoggedIn(tester, settingsStore: store);
    await openEpisode(tester, 'episode-anim-1');

    await choosePlaybackOption(tester, PlayerKeys.audio, '日语');
    expect(backend.audioIndex, 2);

    await tester.tap(find.byKey(PlayerKeys.subtitle));
    await tester.pumpAndSettle();
    await tester.tap(popupItem('英文字幕'));
    await tester.pumpAndSettle();
    expect(backend.subtitleUri, isNotNull);
    expect(backend.subtitleUri!.path, contains('/Subtitles/4/Stream.srt'));

    await tester.runAsync(() => controllerOf(tester).setMaxBitrate(20000000));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    final preference = (await store.read()).seriesPreferences['series-anim'];
    expect(preference, isNotNull);
    expect(preference!.audioStreamIndex, 2);
    expect(preference.subtitleStreamIndex, 4);
    expect(preference.maxStreamingBitrate, 20000000);

    // 同剧下一集自动应用记忆的音轨/字幕/码率。
    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    final player = controllerOf(tester);
    expect(player.audioStreamIndex, 2);
    expect(player.subtitleStreamIndex, 4);
    expect(player.maxStreamingBitrate, 20000000);
    expect(backend.audioIndex, 2);
    expect(backend.subtitleUri!.path, contains('/Subtitles/4/Stream.srt'));
    expect(server.lastPlaybackInfoBody?['AudioStreamIndex'], 2);
    expect(server.lastPlaybackInfoBody?['SubtitleStreamIndex'], 4);
    expect(server.lastPlaybackInfoBody?['MaxStreamingBitrate'], 20000000);
  });

  testWidgets(
    'subtitle-off preference survives a restart through a fresh store',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      server = multiTrackSeriesServer();
      adapter = FakeEmbyAdapter([server]);
      final store = MemoryPlayerSettingsStore();
      await pumpLoggedIn(tester, settingsStore: store);
      await openEpisode(tester, 'episode-anim-1');

      await tester.tap(find.byKey(PlayerKeys.subtitle));
      await tester.pumpAndSettle();
      await tester.tap(popupItem('关闭字幕'));
      await tester.pumpAndSettle();
      expect(controllerOf(tester).subtitleStreamIndex, isNull);
      expect(backend.subtitleOff, isTrue);
      final preference = (await store.read()).seriesPreferences['series-anim'];
      expect(preference, isNotNull);
      expect(preference!.subtitleStreamIndex, isNull);

      // 模拟重启:新的 store 实例从持久化内容初始化后打开同剧另一集。
      final restarted = MemoryPlayerSettingsStore(await store.read());
      server = multiTrackSeriesServer();
      adapter = FakeEmbyAdapter([server]);
      await pumpLoggedIn(tester, settingsStore: restarted);
      await openEpisode(tester, 'episode-anim-2');

      final player = controllerOf(tester);
      expect(player.subtitleStreamIndex, isNull);
      expect(backend.subtitleOff, isTrue);
      // 音轨无记忆,沿用现有默认逻辑。
      expect(player.audioStreamIndex, 1);
      expect(server.lastPlaybackInfoBody?['SubtitleStreamIndex'], isNull);
    },
  );

  testWidgets('always-on-top toggles by button and keyboard with state shown', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(window.isAlwaysOnTop, isFalse);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

    final pin = find.byKey(const Key('player-always-on-top'));
    await tester.tap(pin);
    await tester.pump();
    expect(window.isAlwaysOnTop, isTrue);
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    addTearDown(hover.removePointer);
    await hover.moveTo(tester.getCenter(pin));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('取消置顶'), findsOneWidget);

    // T 快捷键切换置顶。
    await tester.tap(find.byKey(PlayerKeys.surface));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(window.isAlwaysOnTop, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(window.isAlwaysOnTop, isTrue);

    // 全屏与置顶并存,互不冲突。
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(window.isFullScreen, isTrue);
    expect(window.isAlwaysOnTop, isTrue);
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
  });

  testWidgets('movies do not show the episode list entry', (tester) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(find.byKey(const Key('player-episodes')), findsNothing);
    expect(find.byKey(PlayerKeys.mediaSource), findsNothing);
  });

  testWidgets('danmaku button opens a compact panel with search', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    await tester.tap(find.byKey(const Key('player-danmaku-menu')));
    await tester.pump();
    await waitFor(tester, find.byKey(const Key('player-danmaku-panel')));
    await waitFor(tester, find.byKey(const Key('player-danmaku-setup-hint')));
    expect(find.byKey(const Key('player-danmaku-search')), findsOneWidget);
    expect(find.byKey(const Key('player-danmaku-toggle')), findsOneWidget);
    expect(find.text('不透明度'), findsNothing);
    expect(find.text('25%'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(find.byKey(const Key('player-danmaku-search')));
    await tester.pump();
    await tester.pump();
    await waitFor(tester, find.byKey(const Key('player-danmaku-search-panel')));
    expect(
      find.byKey(const Key('player-danmaku-search-field')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('player-danmaku-panel')), findsNothing);
  });

  testWidgets(
    'episode panel lists and switches episodes with correct reports',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 目标集为部分观看状态,服务器配置续播回退 5 秒。
      const minute = 10000000 * 60;
      server = FakeEmbyServer(
        users: const [
          FakeEmbyUser(
            username: 'alice',
            password: 'correct-horse',
            userId: 'user-alice',
            resumeRewindSeconds: 5,
          ),
        ],
        items: defaultCatalogItems(),
      );
      final target = server.items.firstWhere(
        (item) => item.id == 'episode-friends-s1e2',
      );
      target.playbackPositionTicks = minute * 10;
      target.playedPercentage = 45;
      adapter = FakeEmbyAdapter([server]);
      await pumpLoggedIn(tester);
      await openLibrary(tester, 'view-tv');
      await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
      await tester.pumpAndSettle();
      await playListedEpisode(tester, 'episode-friends-s1e1');

      // 剧集入口仅播放剧集时显示。
      await tester.tap(find.byKey(const Key('player-episodes')));
      await waitFor(
        tester,
        find.byKey(const Key('player-episode-episode-friends-s1e2')),
      );

      // 当前集高亮,季默认取当前集所在季。
      final currentRow = tester.widget<ListTile>(
        find.byKey(const Key('player-episode-episode-friends-s1e1')),
      );
      expect(currentRow.selected, isTrue);
      expect(controllerOf(tester).episodeSeasonId, 'season-friends-1');
      expect(find.byKey(const Key('player-season-picker')), findsNothing);
      final panel = find.byKey(const Key('player-episodes-panel'));
      expect(
        find.descendant(of: panel, matching: find.textContaining('正在观看')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: panel, matching: find.textContaining('22分钟')),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.text('Monica gets a new apartment.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: panel, matching: find.textContaining('已看 45%')),
        findsOneWidget,
      );

      // 点击部分观看的集:进程内切集,从续播位置(回退 5 秒)起播,
      // 旧集 Stopped、新集 Playing 上报正确。
      final playingBefore = server.playbackEvents
          .where((event) => event.kind == 'Playing')
          .length;
      await tester.tap(
        find.byKey(const Key('player-episode-episode-friends-s1e2')),
      );
      for (var i = 0; i < 80; i++) {
        if (controllerOf(tester).itemId == 'episode-friends-s1e2' &&
            !controllerOf(tester).loading) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(controllerOf(tester).itemId, 'episode-friends-s1e2');
      expect(backend.openedUrl!.path, contains('episode-friends-s1e2'));
      expect(
        backend.openedStart,
        const Duration(minutes: 10) - const Duration(seconds: 5),
      );
      // Emby 自有流仍携带会话头。
      expect(backend.openedHeaders.containsKey('X-Emby-Token'), isTrue);
      final kinds = server.playbackEvents.map((event) => event.kind).toList();
      expect(kinds.contains('Stopped'), isTrue);
      expect(
        server.playbackEvents.where((event) => event.kind == 'Playing').length,
        playingBefore + 1,
      );
      final lastPlaying = server.playbackEvents
          .where((event) => event.kind == 'Playing')
          .last;
      expect(lastPlaying.body['ItemId'], 'episode-friends-s1e2');
      expect(lastPlaying.body['PositionTicks'], minute * 10 - 10000000 * 5);

      // 切集在播放进程内完成:面板保留,新集行高亮。
      await waitFor(tester, find.byKey(PlayerKeys.playPause));
      expect(find.byKey(const Key('player-episodes-panel')), findsOneWidget);
      final switchedRow = tester.widget<ListTile>(
        find.byKey(const Key('player-episode-episode-friends-s1e2')),
      );
      expect(switchedRow.selected, isTrue);
      expect(controllerOf(tester).itemId, 'episode-friends-s1e2');
    },
  );

  testWidgets('episode list retry works after a failed fetch', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    await playListedEpisode(tester, 'episode-friends-s1e1');

    // 分集拉取失败:面板显示失败态与重试入口,不影响播放。
    server.itemsStatus = 500;
    await tester.tap(find.byKey(const Key('player-episodes')));
    await waitFor(tester, find.byKey(const Key('player-episodes-retry')));
    expect(backend.isPlaying, isTrue);
    expect(controllerOf(tester).episodes, isEmpty);

    // 恢复后重试生效:同剧重新拉取并列出分集。
    server.itemsStatus = null;
    await tester.tap(find.byKey(const Key('player-episodes-retry')));
    await waitFor(
      tester,
      find.byKey(const Key('player-episode-episode-friends-s1e2')),
    );
    expect(controllerOf(tester).episodeListFailed, isFalse);
    expect(controllerOf(tester).episodes.length, 2);
  });

  testWidgets('episode panel switches seasons and plays another season', (
    tester,
  ) async {
    server = multiSeasonSeriesServer();
    adapter = FakeEmbyAdapter([server]);
    await pumpLoggedIn(tester);
    await openEpisode(tester, 'episode-anim-1');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    await tester.tap(find.byKey(const Key('player-episodes')));
    await waitFor(
      tester,
      find.byKey(const Key('player-episode-episode-anim-1')),
    );
    expect(
      find.byKey(const Key('player-episode-episode-anim-s2e1')),
      findsNothing,
    );

    // 换季:仅切换列表内容,不切集。
    await tester.tap(find.byKey(const Key('player-season-picker')));
    await tester.pumpAndSettle();
    await tester.tap(popupItem('第 2 季'));
    await waitFor(
      tester,
      find.byKey(const Key('player-episode-episode-anim-s2e1')),
    );
    expect(
      find.byKey(const Key('player-episode-episode-anim-1')),
      findsNothing,
    );
    expect(controllerOf(tester).itemId, 'episode-anim-1');

    // 点击另一季的集立即切换。
    await tester.tap(find.byKey(const Key('player-episode-episode-anim-s2e1')));
    for (var i = 0; i < 80; i++) {
      if (controllerOf(tester).itemId == 'episode-anim-s2e1' &&
          !controllerOf(tester).loading) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controllerOf(tester).itemId, 'episode-anim-s2e1');
    expect(backend.openedUrl!.path, contains('episode-anim-s2e1'));
  });

  testWidgets('long season lists scroll lazily with ListView.builder', (
    tester,
  ) async {
    server = longSeasonSeriesServer();
    adapter = FakeEmbyAdapter([server]);
    await pumpLoggedIn(tester);
    await openEpisode(tester, 'episode-anim-1');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    await tester.tap(find.byKey(const Key('player-episodes')));
    await waitFor(
      tester,
      find.byKey(const Key('player-episode-episode-anim-1')),
    );
    final list = find.byKey(const Key('player-episodes-list'));
    expect(controllerOf(tester).episodes.length, 120);
    // 惰性构建:首屏远少于全集数。
    final builtRows = find
        .byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.key != null &&
              widget.key.toString().contains('player-episode-'),
        )
        .evaluate()
        .length;
    expect(builtRows, lessThan(120));
    // 滚动到末尾的第 120 集仍可命中。
    await tester.dragUntilVisible(
      find.byKey(const Key('player-episode-episode-anim-120')),
      list,
      const Offset(0, -300),
    );
    expect(
      find.byKey(const Key('player-episode-episode-anim-120')),
      findsOneWidget,
    );
  });

  testWidgets('episode panel is opaque and closes without leaving the player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    await playListedEpisode(tester, 'episode-friends-s1e1');

    await tester.tap(find.byKey(const Key('player-episodes')));
    await waitFor(tester, find.byKey(const Key('player-episodes-panel')));
    final panel = tester.widget<Material>(
      find.byKey(const Key('player-episodes-panel')),
    );
    expect(panel.color, isNotNull);
    expect(panel.color!.a, 1.0);
    expect(
      find.byKey(const Key('player-episode-episode-friends-s1e1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('player-episodes-close')));
    await tester.pump();
    expect(find.byKey(const Key('player-episodes-panel')), findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('player-episodes')));
    await waitFor(tester, find.byKey(const Key('player-episodes-dismiss')));
    await tester.tap(find.byKey(const Key('player-episodes-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('player-episodes-panel')), findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('player-episodes')));
    await waitFor(tester, find.byKey(const Key('player-episodes-panel')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('player-episodes-panel')), findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);
  });

  testWidgets('chapter markers surface skip intro and outro buttons', (
    tester,
  ) async {
    server = chapteredSeriesServer();
    adapter = FakeEmbyAdapter([server]);
    await pumpLoggedIn(tester);
    await openEpisode(tester, 'episode-anim-1');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    // 有服务器章节标记时不显示手动设置入口。
    await openPlaybackSettings(tester);
    expect(find.byKey(PlayerKeys.skipSettings), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 起播即在片头区间,跳过片头立即可见,点击跳到区间终点。
    await waitFor(tester, find.byKey(const Key('player-skip-segment')));
    expect(find.text('跳过片头'), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-skip-segment')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(controllerOf(tester).position, const Duration(seconds: 90));
    expect(find.byKey(const Key('player-skip-segment')), findsNothing);

    // 回到片头区间按钮再次出现。
    await tester.runAsync(
      () => controllerOf(tester).seekTo(const Duration(seconds: 30)),
    );
    await tester.pump();
    await waitFor(tester, find.byKey(const Key('player-skip-segment')));
    expect(find.text('跳过片头'), findsOneWidget);

    // 进入片尾区间改为下一集入口,不再叠一个跳过片尾。
    await tester.runAsync(
      () => controllerOf(tester).seekTo(const Duration(minutes: 21)),
    );
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.nextEpisode));
    expect(find.byKey(const Key('player-skip-segment')), findsNothing);
    // 收尾排空未等待的上报链。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('manual intro skip is remembered per series and auto-applied', (
    tester,
  ) async {
    server = multiTrackSeriesServer();
    adapter = FakeEmbyAdapter([server]);
    final store = MemoryPlayerSettingsStore();
    await pumpLoggedIn(tester, settingsStore: store);
    await openEpisode(tester, 'episode-anim-1');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    // 无章节标记的剧集显示手动设置入口。
    await choosePlaybackOption(tester, PlayerKeys.skipSettings, '片头 60 秒');

    final preference = (await store.read()).seriesPreferences['series-anim'];
    expect(preference, isNotNull);
    expect(preference!.introSkipSeconds, 60);

    // 设置立即生效:片头区间内显示跳过按钮。
    await waitFor(tester, find.byKey(const Key('player-skip-segment')));
    expect(find.text('跳过片头'), findsOneWidget);
    await tester.runAsync(
      () => controllerOf(tester).seekTo(const Duration(seconds: 70)),
    );
    await tester.pump();
    expect(find.byKey(const Key('player-skip-segment')), findsNothing);

    // 同剧下一集自动应用记忆的手动片头时长。
    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await waitFor(tester, find.byKey(const Key('player-skip-segment')));
    expect(find.text('跳过片头'), findsOneWidget);
    expect(
      controllerOf(tester).activeSkipSegment?.end,
      const Duration(seconds: 60),
    );
  });

  testWidgets('media source menu switches source from the current position', (
    tester,
  ) async {
    server = multiSourceMovieServer();
    adapter = FakeEmbyAdapter([server]);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    await tester.ensureVisible(
      find.byKey(CatalogKeys.item('movie-multisource')),
    );
    await tester.tap(find.byKey(CatalogKeys.item('movie-multisource')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    await openPlaybackSettings(tester);
    expect(find.byKey(PlayerKeys.mediaSourceLabel), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => controllerOf(tester).seekTo(const Duration(seconds: 60)),
    );
    await tester.pump();

    await choosePlaybackOption(tester, PlayerKeys.mediaSource, '4K 版本');
    for (var i = 0; i < 80; i++) {
      if (controllerOf(tester).resolved?.mediaSource.id == 'src-4k' &&
          !controllerOf(tester).loading) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }

    // 新源重新解析,从当前进度继续。
    expect(controllerOf(tester).resolved?.mediaSource.id, 'src-4k');
    expect(backend.openedUrl!.queryParameters['MediaSourceId'], 'src-4k');
    expect(backend.openedStart, const Duration(seconds: 60));
    expect(server.lastPlaybackInfoBody?['MediaSourceId'], 'src-4k');

    // 进度上报对新源正确(MediaSourceId 为新源)。
    final lastPlaying = server.playbackEvents
        .where((event) => event.kind == 'Playing')
        .last;
    expect(lastPlaying.body['MediaSourceId'], 'src-4k');
    await openPlaybackSettings(tester);
    expect(
      tester.widget<Text>(find.byKey(PlayerKeys.mediaSourceLabel)).data,
      '4K 版本',
    );
  });

  testWidgets('single media source hides the switch entry', (tester) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    await openPlaybackSettings(tester);
    expect(find.byKey(PlayerKeys.mediaSource), findsNothing);
  });

  testWidgets('chosen media source name carries to the next episode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    server = multiSourceSeriesServer();
    adapter = FakeEmbyAdapter([server]);
    await pumpLoggedIn(tester);
    await openEpisode(tester, 'episode-anim-1');

    await choosePlaybackOption(tester, PlayerKeys.mediaSource, '4K 版本');
    for (var i = 0; i < 80; i++) {
      if (controllerOf(tester).resolved?.mediaSource.id == 'e1-4k' &&
          !controllerOf(tester).loading) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controllerOf(tester).resolved?.mediaSource.id, 'e1-4k');

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(controllerOf(tester).itemId, 'episode-anim-2');
    expect(controllerOf(tester).resolved?.mediaSource.id, 'e2-4k');
    await openPlaybackSettings(tester);
    expect(
      tester.widget<Text>(find.byKey(PlayerKeys.mediaSourceLabel)).data,
      '4K 版本',
    );
  });

  testWidgets('strm remote direct stream opens without session headers', (
    tester,
  ) async {
    server = strmMovieServer();
    adapter = FakeEmbyAdapter([server]);
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-strm');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    // 远端直连:打开原始 URL,不附带 Emby 会话头(令牌不泄漏给第三方)。
    expect(controllerOf(tester).isTranscode, isFalse);
    expect(
      backend.openedUrl.toString(),
      'https://cdn.example.com/strm-movie.mkv',
    );
    expect(backend.openedHeaders, isEmpty);
  });

  testWidgets('PGS subtitle renders locally on direct play without reopen', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    await tester.ensureVisible(find.byKey(CatalogKeys.item('movie-pgs')));
    await tester.tap(find.byKey(CatalogKeys.item('movie-pgs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    // 直连流,选择 PGS 轨道本地渲染。
    expect(controllerOf(tester).isTranscode, isFalse);
    expect(backend.openedUrl!.queryParameters['static'], 'true');
    final opens = backend.openCount;

    await tester.tap(find.byKey(PlayerKeys.subtitle));
    await tester.pumpAndSettle();
    await tester.tap(popupItem('PGS'));
    await tester.pumpAndSettle();

    expect(controllerOf(tester).subtitleStreamIndex, 2);
    expect(backend.subtitleIndex, 2);
    expect(backend.subtitleUri, isNull);
    expect(backend.openCount, opens);
    expect(find.byKey(PlayerKeys.subtitleNotice), findsNothing);
    final lastProgress = server.playbackEvents.last;
    expect(lastProgress.body['SubtitleStreamIndex'], 2);
  });

  testWidgets('PGS subtitle burns in via reopen when transcoding', (
    tester,
  ) async {
    server = transcodePgsMovieServer();
    adapter = FakeEmbyAdapter([server]);
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-movies');
    await tester.ensureVisible(
      find.byKey(CatalogKeys.item('movie-pgs-transcode')),
    );
    await tester.tap(find.byKey(CatalogKeys.item('movie-pgs-transcode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(controllerOf(tester).isTranscode, isTrue);
    final opens = backend.openCount;

    await tester.tap(find.byKey(PlayerKeys.subtitle));
    await tester.pumpAndSettle();
    await tester.tap(popupItem('PGS'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    // 转码维持烧录:重开新流并明确提示。
    expect(backend.openCount, greaterThan(opens));
    expect(backend.openedUrl!.path, contains('master.m3u8'));
    expect(backend.openedUrl!.queryParameters['SubtitleStreamIndex'], '2');
    expect(find.byKey(PlayerKeys.subtitleNotice), findsOneWidget);
    expect(find.text('该字幕为位图，将请求服务器烧录'), findsOneWidget);
  });
}

/// 双音轨+双文本字幕的剧集夹具,供按剧记忆测试使用。
FakeEmbyServer multiTrackSeriesServer() {
  const minute = 10000000 * 60;
  const tracks = [
    FakeMediaStream(
      index: 0,
      type: 'Video',
      codec: 'h264',
      displayTitle: '1080p',
    ),
    FakeMediaStream(
      index: 1,
      type: 'Audio',
      codec: 'aac',
      language: 'eng',
      displayTitle: '英语',
      isDefault: true,
    ),
    FakeMediaStream(
      index: 2,
      type: 'Audio',
      codec: 'aac',
      language: 'jpn',
      displayTitle: '日语',
    ),
    FakeMediaStream(
      index: 3,
      type: 'Subtitle',
      codec: 'subrip',
      language: 'chi',
      displayTitle: '中文字幕',
      isDefault: true,
      isTextSubtitleStream: true,
    ),
    FakeMediaStream(
      index: 4,
      type: 'Subtitle',
      codec: 'subrip',
      language: 'eng',
      displayTitle: '英文字幕',
      isTextSubtitleStream: true,
    ),
  ];
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems().where(
        (item) =>
            item.id != 'series-friends' &&
            item.id != 'season-friends-1' &&
            item.id != 'episode-friends-s1e1' &&
            item.id != 'episode-friends-s1e2',
      ),
      FakeEmbyItem(
        id: 'series-anim',
        name: '测试动画',
        type: 'Series',
        parentId: 'view-tv',
        productionYear: 2024,
        childCount: 2,
        primaryImageTag: 'tag-anim',
      ),
      FakeEmbyItem(
        id: 'season-anim-1',
        name: '第 1 季',
        type: 'Season',
        parentId: 'series-anim',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        indexNumber: 1,
      ),
      FakeEmbyItem(
        id: 'episode-anim-1',
        name: '第一集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 1,
        parentIndexNumber: 1,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e1',
        mediaStreams: tracks,
      ),
      FakeEmbyItem(
        id: 'episode-anim-2',
        name: '第二集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 2,
        parentIndexNumber: 1,
        nextUp: true,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e2',
        mediaStreams: tracks,
      ),
    ],
  );
}

/// 双季剧集夹具:第 1 季两集、第 2 季一集,供剧集列表换季测试使用。
FakeEmbyServer multiSeasonSeriesServer() {
  const minute = 10000000 * 60;
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems().where(
        (item) =>
            item.id != 'series-friends' &&
            item.id != 'season-friends-1' &&
            item.id != 'episode-friends-s1e1' &&
            item.id != 'episode-friends-s1e2',
      ),
      FakeEmbyItem(
        id: 'series-anim',
        name: '测试动画',
        type: 'Series',
        parentId: 'view-tv',
        productionYear: 2024,
        childCount: 3,
        primaryImageTag: 'tag-anim',
      ),
      FakeEmbyItem(
        id: 'season-anim-1',
        name: '第 1 季',
        type: 'Season',
        parentId: 'series-anim',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        indexNumber: 1,
      ),
      FakeEmbyItem(
        id: 'season-anim-2',
        name: '第 2 季',
        type: 'Season',
        parentId: 'series-anim',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        indexNumber: 2,
      ),
      FakeEmbyItem(
        id: 'episode-anim-1',
        name: '第一集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 1,
        parentIndexNumber: 1,
        nextUp: true,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e1',
      ),
      FakeEmbyItem(
        id: 'episode-anim-2',
        name: '第二集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 2,
        parentIndexNumber: 1,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e2',
      ),
      FakeEmbyItem(
        id: 'episode-anim-s2e1',
        name: '第二季第一集',
        type: 'Episode',
        parentId: 'season-anim-2',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-2',
        indexNumber: 1,
        parentIndexNumber: 2,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-s2e1',
      ),
    ],
  );
}

/// 120 集长季夹具,验证剧集列表面板 ListView.builder 惰性构建与滚动。
FakeEmbyServer longSeasonSeriesServer() {
  const minute = 10000000 * 60;
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems().where(
        (item) =>
            item.id != 'series-friends' &&
            item.id != 'season-friends-1' &&
            item.id != 'episode-friends-s1e1' &&
            item.id != 'episode-friends-s1e2',
      ),
      FakeEmbyItem(
        id: 'series-anim',
        name: '测试动画',
        type: 'Series',
        parentId: 'view-tv',
        productionYear: 2024,
        childCount: 120,
        primaryImageTag: 'tag-anim',
      ),
      FakeEmbyItem(
        id: 'season-anim-1',
        name: '第 1 季',
        type: 'Season',
        parentId: 'series-anim',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        indexNumber: 1,
      ),
      for (var i = 1; i <= 120; i++)
        FakeEmbyItem(
          id: 'episode-anim-$i',
          name: '第 $i 集',
          type: 'Episode',
          parentId: 'season-anim-1',
          seriesId: 'series-anim',
          seriesName: '测试动画',
          seasonId: 'season-anim-1',
          indexNumber: i,
          parentIndexNumber: 1,
          runTimeTicks: minute * 22,
        ),
    ],
  );
}

/// 带服务器章节标记(Intro/Outro)的剧集夹具,供片头片尾跳过测试使用。
FakeEmbyServer chapteredSeriesServer() {
  const minute = 10000000 * 60;
  const chapters = [
    FakeChapter(name: 'Intro', startPositionTicks: 0),
    FakeChapter(name: '正文', startPositionTicks: 90 * 10000000),
    FakeChapter(name: 'Outro', startPositionTicks: 20 * minute),
  ];
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems().where(
        (item) =>
            item.id != 'series-friends' &&
            item.id != 'season-friends-1' &&
            item.id != 'episode-friends-s1e1' &&
            item.id != 'episode-friends-s1e2',
      ),
      FakeEmbyItem(
        id: 'series-anim',
        name: '测试动画',
        type: 'Series',
        parentId: 'view-tv',
        productionYear: 2024,
        childCount: 2,
        primaryImageTag: 'tag-anim',
      ),
      FakeEmbyItem(
        id: 'season-anim-1',
        name: '第 1 季',
        type: 'Season',
        parentId: 'series-anim',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        indexNumber: 1,
      ),
      FakeEmbyItem(
        id: 'episode-anim-1',
        name: '第一集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 1,
        parentIndexNumber: 1,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e1',
        chapters: chapters,
      ),
      FakeEmbyItem(
        id: 'episode-anim-2',
        name: '第二集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 2,
        parentIndexNumber: 1,
        nextUp: true,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e2',
        chapters: chapters,
      ),
    ],
  );
}

/// 双版本剧集夹具:两集各自有独立 MediaSourceId、同名「4K 版本」,
/// 供播放中换源后下一集按显示名对齐。
FakeEmbyServer multiSourceSeriesServer() {
  const minute = 10000000 * 60;
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems().where(
        (item) =>
            item.id != 'series-friends' &&
            item.id != 'season-friends-1' &&
            item.id != 'episode-friends-s1e1' &&
            item.id != 'episode-friends-s1e2',
      ),
      FakeEmbyItem(
        id: 'series-anim',
        name: '测试动画',
        type: 'Series',
        parentId: 'view-tv',
        productionYear: 2024,
        childCount: 2,
        primaryImageTag: 'tag-anim',
      ),
      FakeEmbyItem(
        id: 'season-anim-1',
        name: '第 1 季',
        type: 'Season',
        parentId: 'series-anim',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        indexNumber: 1,
      ),
      FakeEmbyItem(
        id: 'episode-anim-1',
        name: '第一集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 1,
        parentIndexNumber: 1,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e1',
        extraSources: const [FakeMediaSource(id: 'e1-4k', name: '4K 版本')],
      ),
      FakeEmbyItem(
        id: 'episode-anim-2',
        name: '第二集',
        type: 'Episode',
        parentId: 'season-anim-1',
        seriesId: 'series-anim',
        seriesName: '测试动画',
        seasonId: 'season-anim-1',
        indexNumber: 2,
        parentIndexNumber: 1,
        nextUp: true,
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-anim-e2',
        extraSources: const [FakeMediaSource(id: 'e2-4k', name: '4K 版本')],
      ),
    ],
  );
}

/// 双媒体源电影夹具(默认源 + 4K 额外源),供换源测试使用。
FakeEmbyServer multiSourceMovieServer() {
  const minute = 10000000 * 60;
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems(),
      FakeEmbyItem(
        id: 'movie-multisource',
        name: '多版本片',
        type: 'Movie',
        parentId: 'view-movies',
        productionYear: 2018,
        runTimeTicks: minute * 90,
        primaryImageTag: 'tag-multisource',
        extraSources: const [FakeMediaSource(id: 'src-4k', name: '4K 版本')],
      ),
    ],
  );
}

/// strm 远端直连电影夹具:服务端把条目解析为远端 http 地址,
/// PlaybackInfo 返回 Protocol=Http + Path,不提供 DirectStreamUrl。
FakeEmbyServer strmMovieServer() {
  const minute = 10000000 * 60;
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems(),
      FakeEmbyItem(
        id: 'movie-strm',
        name: 'strm 远端片',
        type: 'Movie',
        parentId: 'view-movies',
        productionYear: 2023,
        runTimeTicks: minute * 90,
        primaryImageTag: 'tag-strm',
        remotePath: 'https://cdn.example.com/strm-movie.mkv',
      ),
    ],
  );
}

/// 强制转码 + PGS 位图字幕的电影夹具,验证转码维持烧录现状。
FakeEmbyServer transcodePgsMovieServer() {
  const minute = 10000000 * 60;
  return FakeEmbyServer(
    items: [
      ...defaultCatalogItems(),
      FakeEmbyItem(
        id: 'movie-pgs-transcode',
        name: '需转码位图字幕片',
        type: 'Movie',
        parentId: 'view-movies',
        productionYear: 2017,
        runTimeTicks: minute * 80,
        primaryImageTag: 'tag-pgs-transcode',
        forceTranscode: true,
        mediaStreams: const [
          FakeMediaStream(
            index: 0,
            type: 'Video',
            codec: 'hevc',
            displayTitle: '1080p',
          ),
          FakeMediaStream(
            index: 1,
            type: 'Audio',
            codec: 'aac',
            language: 'eng',
            displayTitle: 'English',
            isDefault: true,
          ),
          FakeMediaStream(
            index: 2,
            type: 'Subtitle',
            codec: 'pgssub',
            language: 'chi',
            displayTitle: 'PGS',
            isDefault: true,
            isTextSubtitleStream: false,
          ),
        ],
      ),
    ],
  );
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
