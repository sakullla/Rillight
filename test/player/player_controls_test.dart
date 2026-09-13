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
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeVideoBackend backend;
  late PlayerWindow window;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    backend = FakeVideoBackend();
    window = PlayerWindow();
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
    );
  }

  Future<void> pumpLoggedIn(
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
  }

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
    await waitFor(tester, find.byKey(PlayerKeys.quality));

    expect(find.byKey(PlayerKeys.quality), findsOneWidget);
    expect(find.text('自动'), findsNothing);
    expect(find.byKey(PlayerKeys.volume), findsOneWidget);
    expect(backend.openedUrl!.path, contains('master.m3u8'));
    final firstOpen = backend.openCount;

    await tester.runAsync(() => controllerOf(tester).setAudio(1));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.quality));
    expect(backend.openCount, firstOpen + 1);
    expect(server.lastPlaybackInfoBody?['AudioStreamIndex'], 1);

    await tester.runAsync(() => controllerOf(tester).setMaxBitrate(4000000));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.quality));
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
    await tester.ensureVisible(
      find.byKey(CatalogKeys.episode('episode-friends-s1e1')),
    );
    await tester.tap(find.byKey(CatalogKeys.episode('episode-friends-s1e1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(PlayerKeys.open));
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

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
    await tester.ensureVisible(
      find.byKey(CatalogKeys.episode('episode-friends-s1e2')),
    );
    await tester.tap(find.byKey(CatalogKeys.episode('episode-friends-s1e2')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(PlayerKeys.open));
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

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

  test('volume percent maps to mpv volume through the cube curve', () {
    expect(mpvVolumeForPercent(0), 0.0);
    expect(mpvVolumeForPercent(10), closeTo(0.1, 1e-6));
    expect(mpvVolumeForPercent(50), closeTo(12.5, 1e-6));
    expect(mpvVolumeForPercent(90), closeTo(72.9, 1e-6));
    expect(mpvVolumeForPercent(100), 100.0);
    expect(mpvVolumeForPercent(120), 100.0);
    expect(mpvVolumeForPercent(-5), 0.0);
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
}
