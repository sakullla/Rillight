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
import 'package:rillight/player/player_bindings.dart';
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
  }) {
    return PlayerBindings(
      createBackend: () => backend,
      window: window,
      progressInterval: progressInterval,
      controlsHideAfter: hideAfter,
      nextEpisodeCountdown: const Duration(seconds: 3),
    );
  }

  Future<void> pumpLoggedIn(
    WidgetTester tester, {
    Duration hideAfter = const Duration(days: 1),
    Duration progressInterval = const Duration(seconds: 10),
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
      if (find.byKey(PlayerKeys.playMethod).evaluate().isNotEmpty ||
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

  testWidgets('resume prompt continues from saved progress', (tester) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');

    expect(find.text('要从上次的位置继续播放吗？'), findsOneWidget);
    await tester.tap(find.byKey(PlayerKeys.resumeContinue));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playMethod));

    expect(find.text('直连'), findsOneWidget);
    expect(backend.openedUrl, isNotNull);
    expect(backend.openedUrl!.queryParameters['static'], 'true');
    expect(backend.openedStart, greaterThan(Duration.zero));
    expect(
      server.playbackEvents.map((event) => event.kind),
      contains('Playing'),
    );
  });

  testWidgets('progress reports every 10s and not after stop', (tester) async {
    await pumpLoggedIn(tester, progressInterval: const Duration(seconds: 10));
    await openPlayable(tester, 'movie-up');
    expect(find.text('直连'), findsOneWidget);

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
    await waitFor(tester, find.text('转码'));

    expect(find.byKey(PlayerKeys.quality), findsOneWidget);
    expect(find.byKey(PlayerKeys.volume), findsOneWidget);
    expect(backend.openedUrl!.path, contains('master.m3u8'));
    final firstOpen = backend.openCount;

    await tester.runAsync(() => controllerOf(tester).setAudio(1));
    await tester.pump();
    await waitFor(tester, find.text('转码'));
    expect(backend.openCount, firstOpen + 1);
    expect(server.lastPlaybackInfoBody?['AudioStreamIndex'], 1);

    await tester.runAsync(() => controllerOf(tester).setMaxBitrate(4000000));
    await tester.pump();
    await waitFor(tester, find.text('转码'));
    expect(backend.openCount, firstOpen + 2);
    expect(server.lastPlaybackInfoBody?['MaxStreamingBitrate'], 4000000);
    expect(
      server.playbackEvents.where((event) => event.kind == 'Stopped'),
      isNotEmpty,
    );
  });

  testWidgets('next episode countdown can be cancelled', (tester) async {
    await pumpLoggedIn(tester);
    await openLibrary(tester, 'view-tv');
    await tester.tap(find.byKey(CatalogKeys.item('series-friends')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(CatalogKeys.episode('episode-friends-s1e1')),
    );
    await tester.tap(find.byKey(CatalogKeys.episode('episode-friends-s1e1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playMethod));

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
  });

  testWidgets('text subtitle is handed to the backend as an external URL', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');
    await tester.tap(find.byKey(PlayerKeys.resumeFromStart));
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playMethod));
    expect(backend.subtitleUri, isNotNull);
    expect(backend.subtitleUri!.path, contains('/Subtitles/2/Stream.srt'));
  });
}
