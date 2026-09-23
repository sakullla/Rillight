import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/danmaku/danmaku_hash.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/phone_player_gestures.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/phone_orientation.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-player',
  version: '1',
);

void main() {
  Future<AuthController> login(FakeEmbyServer server) async {
    final auth = AuthController(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    return auth;
  }

  Future<PlayerController> showPlayer(
    WidgetTester tester, {
    required String itemId,
    FakeVideoBackend? backend,
    PlayerSettingsStore? settings,
    DandanplayClient? danmakuClient,
    PhoneOrientation? orientation,
    PhonePlaybackWakeLock? wakeLock,
    DanmakuStreamHasher? hasher,
    PhoneDisplayControl? display,
    Size size = const Size(800, 360),
    Duration? mediaDuration,
  }) async {
    final server = FakeEmbyServer();
    final auth = await tester.runAsync(() => login(server));
    final video = backend ?? FakeVideoBackend();
    if (mediaDuration != null) video.duration = mediaDuration;
    addTearDown(auth!.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: PlayerScope(
          bindings: PlayerBindings(
            createBackend: () => video,
            settingsStore: settings ?? MemoryPlayerSettingsStore(),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
            danmakuClient: danmakuClient,
          ),
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MobilePlayerPage(
                          itemId: itemId,
                          orientation: orientation,
                          wakeLock: wakeLock,
                          danmakuHasher: hasher,
                          displayControl: display,
                        ),
                      ),
                    );
                  },
                  child: const Text('open-player'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-player'));
    await tester.pump();
    PlayerController? ready;
    for (var i = 0; i < 40; i++) {
      final page = find.byType(MobilePlayerPage);
      if (page.evaluate().isNotEmpty) {
        final current = tester.state<MobilePlayerPageState>(page).controller;
        if (current != null && !current.loading) {
          ready = current;
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 400));
    if (ready == null || ready.loading) fail('player did not become ready');
    return ready;
  }

  Future<void> closePlayer(WidgetTester tester) async {
    final button = find.byTooltip('关闭');
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(MobilePlayerPage).evaluate().isEmpty) return;
    }
    expect(find.byType(MobilePlayerPage), findsNothing);
  }

  testWidgets('exit stays on the entry direction until that viewport is back', (
    tester,
  ) async {
    final orientation = PhoneOrientation(
      restoreTo: const [DeviceOrientation.portraitUp],
      request: (orientations) async {},
    );
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      orientation: orientation,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.error, isNull);
    expect(orientation.calls.first, PhoneOrientation.landscape);
    await closePlayer(tester);
    await orientation.settled;
    expect(find.byType(MobilePlayerPage), findsNothing);
    // The surface is still landscape. A trailing unlock would follow the
    // sensor and leave playback's landscape hold in place.
    expect(orientation.calls, hasLength(2));
    expect(orientation.calls[1], const [DeviceOrientation.portraitUp]);
    expect(orientation.calls.last, isNot(PhoneOrientation.unlocked));

    tester.view.physicalSize = const Size(360, 800);
    await orientation.settled;
    expect(orientation.calls[1], const [DeviceOrientation.portraitUp]);
    expect(orientation.calls.last, PhoneOrientation.unlocked);
  });

  testWidgets(
    'landscape entry is restored before a later rotation is released',
    (tester) async {
      final orientation = PhoneOrientation(
        restoreTo: PhoneOrientation.landscape,
        request: (_) async {},
      );
      tester.view.physicalSize = const Size(800, 360);
      addTearDown(tester.view.resetPhysicalSize);
      await orientation.enterPlayback();
      await orientation.leavePlayback();
      expect(orientation.calls, hasLength(2));
      expect(orientation.calls.last, PhoneOrientation.landscape);
      await tester.pump();
      await orientation.settled;
      expect(
        orientation.calls[1],
        PhoneOrientation.landscape,
        reason: 'restore success is the entry direction, not a trailing unlock',
      );
      expect(orientation.calls.last, PhoneOrientation.unlocked);
    },
  );

  testWidgets('a failed orientation request still starts playback', (
    tester,
  ) async {
    final denied = PhoneOrientation(
      restoreTo: const [DeviceOrientation.portraitUp],
      request: (_) async => throw StateError('orientation denied'),
    );
    final failed = await showPlayer(
      tester,
      itemId: 'movie-inception',
      orientation: denied,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(failed.error, isNull);
    expect(failed.loading, isFalse);
    expect(denied.calls.first, PhoneOrientation.landscape);
    expect(denied.lastError, isA<StateError>());
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    await closePlayer(tester);
    await denied.settled;
    expect(find.byType(MobilePlayerPage), findsNothing);
    expect(denied.calls[1], const [DeviceOrientation.portraitUp]);
    expect(denied.calls.last, isNot(PhoneOrientation.unlocked));
  });

  testWidgets('turning back to portrait keeps the phone player usable', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(backend.isPlaying, isTrue);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    expect(find.byType(TvShell), findsNothing);
    expect(find.byType(TvPlayerPage), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('mobile-player-toggle')));
    await tester.tap(find.byKey(const Key('mobile-player-toggle')));
    await tester.pumpAndSettle();
    expect(backend.isPlaying, isFalse);
    await tester.tap(find.byTooltip('快进 10 秒'));
    await tester.pumpAndSettle();
    expect(backend.position, greaterThan(Duration.zero));
    expect(current.error, isNull);
    await closePlayer(tester);
  });

  testWidgets('next episode countdown can be cancelled or played immediately', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'episode-friends-s1e1',
      backend: backend,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.nextEpisode, isNull);
    backend.completePlayback();
    for (var i = 0; i < 20; i++) {
      if (current.nextEpisode?.remaining != null) break;
      await tester.pump(Duration.zero);
    }
    expect(current.nextEpisode?.remaining, const Duration(seconds: 10));
    expect(find.text('10 秒后播放下一集'), findsOneWidget);
    await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodeCancel));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
    await tester.pump(const Duration(seconds: 12));
    expect(current.itemId, 'episode-friends-s1e1');
    expect(current.nextEpisode, isNull);
    expect(backend.openCount, 1);
    await closePlayer(tester);
  });

  testWidgets('next episode play starts the following episode immediately', (
    tester,
  ) async {
    final playing = FakeVideoBackend();
    final next = await showPlayer(
      tester,
      itemId: 'episode-friends-s1e1',
      backend: playing,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    playing.completePlayback();
    for (var i = 0; i < 20; i++) {
      if (next.nextEpisode?.remaining != null) break;
      await tester.pump(Duration.zero);
    }
    expect(find.text('10 秒后播放下一集'), findsOneWidget);
    await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
    for (var i = 0; i < 40; i++) {
      if (next.itemId == 'episode-friends-s1e2' && !next.loading) break;
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(next.itemId, 'episode-friends-s1e2');
    expect(playing.openCount, greaterThan(1));
    await closePlayer(tester);
  });

  testWidgets('a movie does not offer a next-episode countdown', (
    tester,
  ) async {
    final movie = FakeVideoBackend();
    final film = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: movie,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    movie.completePlayback();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(film.nextEpisode, isNull);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
    await closePlayer(tester);
  });

  testWidgets('danmaku can be shown, hidden, and fail without stopping video', (
    tester,
  ) async {
    final settings = MemoryPlayerSettingsStore(
      const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
    );
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      settings: settings,
      danmakuClient: _CommentClient(),
      hasher: _NullHasher(),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    for (var i = 0; i < 40; i++) {
      if (find.byType(DanmakuView).evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 20));
    }
    final view = tester.widget<DanmakuView>(find.byType(DanmakuView));
    expect(view.controller.danmakuOn, isTrue);
    expect(view.controller.comments.single.text, '滚动评论');
    expect(backend.isPlaying, isTrue);
    expect(current.error, isNull);
    // 顶栏不再有弹幕按钮；弹幕入口迁入"更多"面板（R11）。
    expect(find.byKey(const Key('mobile-player-danmaku')), findsNothing);
    await tester.tap(find.byKey(const Key('mobile-player-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(DanmakuKeys.toggle), findsOneWidget);
    await tester.tap(find.byKey(DanmakuKeys.panel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(DanmakuKeys.opacity), findsOneWidget);
    expect(find.byKey(DanmakuKeys.fontScale), findsOneWidget);
    await tester.ensureVisible(find.byKey(DanmakuKeys.toggle));
    await tester.tap(find.byKey(DanmakuKeys.toggle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(view.controller.danmakuOn, isFalse);
    expect(view.controller.comments, isEmpty);
    expect(backend.isPlaying, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await closePlayer(tester);
  });

  testWidgets('danmaku failure leaves the film playing', (tester) async {
    final failingBackend = FakeVideoBackend();
    final failing = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: failingBackend,
      settings: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _FailingDanmakuClient(),
      hasher: _NullHasher(),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    for (var i = 0; i < 40; i++) {
      if (find
          .byKey(const Key('mobile-danmaku-failure'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('弹幕服务不可达'), findsWidgets);
    expect(failing.error, isNull);
    expect(failingBackend.isPlaying, isTrue);
    await tester.ensureVisible(find.byKey(const Key('mobile-danmaku-off')));
    await tester.tap(find.byKey(const Key('mobile-danmaku-off')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('mobile-danmaku-failure')), findsNothing);
    expect(failingBackend.isPlaying, isTrue);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'screen stays on only while playing and background stays paused',
    (tester) async {
      final calls = <bool>[];
      final wake = PhonePlaybackWakeLock(
        toggle: (enabled) async {
          calls.add(enabled);
        },
      );
      final backend = FakeVideoBackend(
        duration: const Duration(hours: 1, minutes: 5),
      );
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        wakeLock: wake,
        mediaDuration: const Duration(hours: 1, minutes: 5),
      );
      await wake.settled;
      expect(calls, [true]);
      expect(wake.held, isTrue);
      expect(current.duration.inHours, greaterThan(0));
      final hours = current.duration.inHours;
      final minutes = current.duration.inMinutes
          .remainder(60)
          .toString()
          .padLeft(2, '0');
      final seconds = (current.duration.inSeconds % 60).toString().padLeft(
        2,
        '0',
      );
      expect(find.text('$hours:$minutes:$seconds'), findsOneWidget);
      // 应用内音量 Slider 已移出控制层，收入"更多"面板（R10 能力不减）。
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final slider = tester.widget<Slider>(
        find.byKey(const Key('mobile-player-volume')),
      );
      slider.onChanged!(40);
      await tester.pump();
      expect(current.volume, 40);
      expect(backend.volume, 40);
      final closeSheet = find.widgetWithText(TextButton, '返回');
      await tester.ensureVisible(closeSheet);
      await tester.pump();
      await tester.tap(closeSheet);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const Key('mobile-player-toggle')));
      await tester.pump();
      await wake.settled;
      expect(backend.isPlaying, isFalse);
      expect(calls.last, isFalse);

      await tester.tap(find.byKey(const Key('mobile-player-toggle')));
      await tester.pump();
      await wake.settled;
      expect(calls.last, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      await wake.settled;
      expect(backend.isPlaying, isFalse);
      expect(wake.held, isFalse);
      expect(calls.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await wake.settled;
      expect(backend.openCount, 2);
      expect(backend.openedPaused, isTrue);
      expect(backend.isPlaying, isFalse);
      expect(wake.held, isFalse);
      expect(find.text('画中画'), findsNothing);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('double-tap on the right and left half seeks ±10 seconds', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(hours: 2));
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: const Duration(hours: 2),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    // 详情页 resume 点(59:00)会自动续播;手势断言全部用相对量。
    final initial = backend.position;
    expect(initial, greaterThan(Duration.zero));
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.position, initial + const Duration(seconds: 10));
    await tester.tapAt(const Offset(200, 150));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(200, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.position, initial);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'vertical drags on the left and right half drive brightness and volume',
    (tester) async {
      final display = _FakeDisplayControl();
      final backend = FakeVideoBackend();
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        display: display,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      final brightness = await tester.startGesture(const Offset(200, 170));
      await brightness.moveBy(const Offset(0, -20));
      await brightness.moveBy(const Offset(0, -40));
      await brightness.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(
        find.byKey(const Key('mobile-player-gesture-overlay')),
        findsOneWidget,
      );
      // 浮层实时反映亮度通道值。
      final shownBrightness = tester
          .widget<Text>(find.byKey(const Key('mobile-player-gesture-value')))
          .data;
      expect(display.brightnessValue, greaterThan(0.5));
      expect(shownBrightness, '${(display.brightnessValue * 100).round()}%');
      await brightness.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('mobile-player-gesture-overlay')),
        findsNothing,
      );

      final volume = await tester.startGesture(const Offset(600, 170));
      await volume.moveBy(const Offset(0, -25));
      await volume.moveBy(const Offset(0, -25));
      await tester.pump();
      final shownVolume = tester
          .widget<Text>(find.byKey(const Key('mobile-player-gesture-value')))
          .data;
      expect(display.volumeValue, greaterThan(0.5));
      expect(shownVolume, '${(display.volumeValue * 100).round()}%');
      await volume.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.isPlaying, isTrue);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('horizontal drag previews the target and seeks on release', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: const Duration(hours: 1, minutes: 5),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    final initial = backend.position;
    final gesture = await tester.startGesture(const Offset(300, 120));
    await gesture.moveBy(const Offset(50, 0));
    await gesture.moveBy(const Offset(50, 0));
    await gesture.moveBy(const Offset(50, 0));
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(find.byKey(const Key('mobile-player-gesture-seek')), findsOneWidget);
    // 浮层预览目标时间;松手后实际 seek 与预览一致。
    final preview = tester
        .widget<Text>(find.byKey(const Key('mobile-player-gesture-seek')))
        .data!;
    final parts = preview.split(':').map(int.parse).toList();
    final target = parts.length == 3
        ? Duration(hours: parts[0], minutes: parts[1], seconds: parts[2])
        : Duration(minutes: parts[0], seconds: parts[1]);
    expect(target, greaterThan(initial));
    await gesture.up();
    await tester.pump();
    expect(backend.position, target);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locked screen hides controls and gestures; tap unlocks', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(hours: 2));
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: const Duration(hours: 2),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    await tester.tap(find.byKey(const Key('mobile-player-lock')));
    await tester.pump();
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    expect(find.byKey(const Key('mobile-player-more')), findsNothing);
    expect(find.byKey(const Key('mobile-player-unlock')), findsOneWidget);

    // Gestures are inert while locked: dragging must not seek or show
    // gesture feedback (single tap is the unlock affordance).
    final initial = backend.position;
    final drag = await tester.startGesture(const Offset(600, 150));
    await drag.moveBy(const Offset(0, -40));
    await drag.moveBy(const Offset(0, -40));
    await tester.pump();
    await drag.up();
    expect(
      find.byKey(const Key('mobile-player-gesture-overlay')),
      findsNothing,
    );
    expect(backend.position, initial);
    // 锁定态不隐藏锁钮。
    expect(find.byKey(const Key('mobile-player-unlock')), findsOneWidget);

    // A single tap unlocks and reveals the controls again. The tap callback
    // fires after the double-tap timeout, so pump past it.
    await tester.tapAt(const Offset(400, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('mobile-player-unlock')), findsNothing);
    expect(find.byKey(const Key('mobile-player-toggle')), findsOneWidget);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'more panel hosts danmaku, tracks, speed, source, mute and volume',
    (tester) async {
      final backend = FakeVideoBackend();
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      // 顶栏不再出现弹幕按钮（R11）。
      expect(find.byKey(const Key('mobile-player-danmaku')), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(DanmakuKeys.toggle), findsOneWidget);
      expect(find.byKey(DanmakuKeys.search), findsOneWidget);
      expect(find.byKey(DanmakuKeys.panel), findsOneWidget);
      expect(find.text('音轨与字幕'), findsOneWidget);
      expect(find.text('字幕'), findsOneWidget);
      expect(find.text('播放速度'), findsOneWidget);
      expect(find.text('片源'), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-mute')), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-volume')), findsOneWidget);
      // Mute from the more panel keeps the ability (R10).
      final mute = find.byKey(const Key('mobile-player-mute'));
      await tester.ensureVisible(mute);
      await tester.pump();
      await tester.tap(mute);
      await tester.pump();
      expect(backend.volume, 0);
      final closeSheet = find.widgetWithText(TextButton, '返回');
      await tester.ensureVisible(closeSheet);
      await tester.pump();
      await tester.tap(closeSheet);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BottomSheet), findsNothing);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
  );
}

class _FakeDisplayControl implements PhoneDisplayControl {
  double _brightness = 0.5;
  double _volume = 0.5;

  double get brightnessValue => _brightness;
  double get volumeValue => _volume;

  @override
  Future<double> brightness() async => _brightness;

  @override
  Future<void> setBrightness(double value) async => _brightness = value;

  @override
  Future<double> volume() async => _volume;

  @override
  Future<void> setVolume(double value) async => _volume = value;
}

class _NullHasher extends DanmakuStreamHasher {
  _NullHasher() : super(dio: Dio());

  @override
  Future<String?> hashOf(Uri streamUrl) async => null;
}

class _CommentClient extends DandanplayClient {
  _CommentClient() : super(dio: Dio());

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
    return const DanmakuMatchResponse(
      isMatched: true,
      matches: [
        DanmakuMatchCandidate(
          animeId: 1,
          animeTitle: 'Inception',
          episodeId: 7,
          episodeTitle: '正片',
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
    return const [
      DanmakuComment(cid: 1, time: 1, mode: 1, color: 16777215, text: '滚动评论'),
    ];
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

class _FailingDanmakuClient extends DandanplayClient {
  _FailingDanmakuClient() : super(dio: Dio());

  static const _failure = DanmakuApiException(
    DanmakuApiFailureKind.unreachable,
    detail: 'down',
  );

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
    throw _failure;
  }

  @override
  Future<List<DanmakuComment>> fetchComments(
    DandanplaySource source,
    int episodeId, {
    int? serverTimestamp,
    CancelToken? cancelToken,
  }) async {
    throw _failure;
  }

  @override
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    throw _failure;
  }

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    throw _failure;
  }
}
