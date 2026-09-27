import 'dart:async';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme.dart';
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
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/buffered_ranges_track.dart';

import '../emby/fake_emby_server.dart';

const _androidPlayerChannel = MethodChannel('rillight/android_core');

void _mockAndroidPlayerChannel(List<MethodCall> calls, {int sdk = 34}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_androidPlayerChannel, (call) async {
    calls.add(call);
    if (call.method == 'androidSdkInt') return sdk;
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_androidPlayerChannel, null),
  );
}

List<bool> _systemBarHidden(List<MethodCall> calls) {
  return calls
      .where((call) => call.method == 'setSystemBarsHidden')
      .map((call) => (call.arguments as Map)['hidden'] as bool)
      .toList();
}

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
    PhoneSystemBars? systemBars,
    PhonePlaybackWakeLock? wakeLock,
    void Function(FakeEmbyServer server)? prepare,
    DanmakuStreamHasher? hasher,
    PhoneDisplayControl? display,
    Size size = const Size(800, 360),
    Duration? mediaDuration,
  }) async {
    final server = FakeEmbyServer();
    prepare?.call(server);
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
                          systemBars: systemBars,
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

  testWidgets(
    'playback requests landscape and restores portrait; a denied request still plays',
    (tester) async {
      final orientation = PhoneOrientation(request: (orientations) async {});
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
      expect(orientation.calls[1], PhoneOrientation.portrait);
      expect(orientation.calls.last, isNot(PhoneOrientation.unlocked));

      tester.view.physicalSize = const Size(360, 800);
      await orientation.settled;
      expect(orientation.calls[1], PhoneOrientation.portrait);
      expect(orientation.calls.last, PhoneOrientation.unlocked);

      // 系统拒绝方向请求时播放仍要能启动，退出仍请求竖屏。
      final denied = PhoneOrientation(
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
      expect(denied.calls[1], PhoneOrientation.portrait);
      expect(denied.calls.last, isNot(PhoneOrientation.unlocked));
    },
    tags: ['integration'],
  );

  testWidgets('portrait viewport remains usable while landscape is pending', (
    tester,
  ) async {
    final orientation = PhoneOrientation(request: (_) async {});
    final player = await showPlayer(
      tester,
      itemId: 'movie-inception',
      size: const Size(360, 800),
      orientation: orientation,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(orientation.calls.first, PhoneOrientation.landscape);
    expect(player.error, isNull);
    expect(find.byKey(const Key('mobile-player-lock')), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    await closePlayer(tester);
    await tester.pump();
    await orientation.settled;
    expect(orientation.calls, [
      PhoneOrientation.landscape,
      PhoneOrientation.portrait,
      PhoneOrientation.unlocked,
    ]);
  }, tags: ['integration']);

  testWidgets(
    'next episode countdown can be cancelled, played, or absent for movies',
    (tester) async {
      // 取消倒计时停留在本集。
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
      await tester.tap(find.byKey(const Key('mobile-player-lock')));
      await tester.pump();
      expect(find.byKey(PlayerKeys.nextEpisodePlay), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-player-unlock')));
      await tester.pump();
      expect(find.byKey(PlayerKeys.nextEpisodePlay), findsOneWidget);
      await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.pump(const Duration(seconds: 12));
      expect(current.itemId, 'episode-friends-s1e1');
      expect(current.nextEpisode, isNull);
      expect(backend.openCount, 1);
      await closePlayer(tester);

      // 立即播放切换到下一集。
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

      // 电影播完不出现下集倒计时。
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
    },
    tags: ['integration'],
  );

  testWidgets(
    'danmaku works from the more panel and failure leaves the film playing',
    (tester) async {
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
      // 底部提供弹幕快捷入口，完整设置仍保留原有选项。
      expect(find.byKey(const Key('mobile-player-danmaku')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // "更多"面板承载弹幕、音轨字幕、速度、片源、静音与音量(R10/R11)。
      expect(find.byKey(DanmakuKeys.toggle), findsOneWidget);
      expect(find.byKey(DanmakuKeys.search), findsOneWidget);
      expect(find.byKey(DanmakuKeys.panel), findsOneWidget);
      expect(find.text('音轨与字幕'), findsWidgets);
      expect(find.text('字幕'), findsOneWidget);
      expect(find.text('播放速度'), findsOneWidget);
      expect(find.text('来源'), findsNothing);
      expect(find.byKey(const Key('mobile-player-mute')), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-volume')), findsOneWidget);

      // 弹幕子面板:透明度/字号可调,开关即时生效(此时面板未滚动)。
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

      // 重新打开"更多"面板本体,静音能力保留(R10)。
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
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
      await closePlayer(tester);

      // 弹幕服务不可达时提示可关闭,视频继续播放。
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
    },
    tags: ['integration'],
  );

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
      expect(find.textContaining('$hours:$minutes:$seconds'), findsOneWidget);
      // 应用内音量 Slider 已移出控制层,收入"更多"面板(R10 能力不减)。
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
    tags: ['integration'],
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
  }, tags: ['integration']);

  testWidgets(
    'drives brightness, volume and seek previews with edge gestures',
    (tester) async {
      final display = _FakeDisplayControl();
      final backend = FakeVideoBackend();
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        display: display,
        mediaDuration: const Duration(hours: 1, minutes: 5),
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

      // 横向拖动预览目标时间,松手后实际 seek 与预览一致。
      final initial = backend.position;
      final gesture = await tester.startGesture(const Offset(300, 120));
      await gesture.moveBy(const Offset(50, 0));
      await gesture.moveBy(const Offset(50, 0));
      await gesture.moveBy(const Offset(50, 0));
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(
        find.byKey(const Key('mobile-player-gesture-seek')),
        findsOneWidget,
      );
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
    },
    tags: ['integration'],
  );

  testWidgets('failed system brightness gesture shows no invented percent', (
    tester,
  ) async {
    final display = _FailDisplayControl();
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      display: display,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    final drag = await tester.startGesture(const Offset(200, 170));
    await drag.moveBy(const Offset(0, -40));
    await drag.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(find.text('系统调节暂不可用'), findsOneWidget);
    expect(find.byKey(const Key('mobile-player-gesture-value')), findsNothing);
    await drag.up();
    final volume = await tester.startGesture(const Offset(600, 170));
    await volume.moveBy(const Offset(0, -40));
    await volume.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(display.volumeValue, greaterThan(0.5));
    expect(
      find.byKey(const Key('mobile-player-gesture-value')),
      findsOneWidget,
    );
    await volume.up();
    await closePlayer(tester);
  }, tags: ['integration']);

  testWidgets('invalid brightness read leaves volume gesture available', (
    tester,
  ) async {
    final display = _InvalidBrightnessDisplayControl();
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      display: display,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    final brightness = await tester.startGesture(const Offset(200, 170));
    await brightness.moveBy(const Offset(0, -40));
    await brightness.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(find.text('系统调节暂不可用'), findsOneWidget);
    await brightness.up();
    final volume = await tester.startGesture(const Offset(600, 170));
    await volume.moveBy(const Offset(0, -40));
    await volume.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(display.volumeValue, greaterThan(0.5));
    expect(
      find.byKey(const Key('mobile-player-gesture-value')),
      findsOneWidget,
    );
    await volume.up();
    await closePlayer(tester);
  }, tags: ['integration']);

  testWidgets('locked screen needs an explicit unlock button tap', (
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
    expect(find.byIcon(Icons.screen_rotation), findsNothing);
    expect(find.byKey(const Key('mobile-player-unlock')), findsOneWidget);
    final lockCenter = tester.getCenter(
      find.byKey(const Key('mobile-player-unlock')),
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const Key('mobile-player-unlock')), findsNothing);
    await tester.tapAt(lockCenter);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    expect(
      tester.getCenter(find.byKey(const Key('mobile-player-unlock'))).dx,
      closeTo(lockCenter.dx, 1),
    );

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

    // Tapping the picture reveals the entry but consumes that gesture.
    await tester.tapAt(const Offset(400, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    expect(find.byKey(const Key('mobile-player-unlock')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-player-unlock')));
    await tester.pump();
    expect(find.byKey(const Key('mobile-player-unlock')), findsNothing);
    expect(find.byKey(const Key('mobile-player-toggle')), findsOneWidget);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

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
      expect(find.byKey(DanmakuKeys.toggle), findsNothing);
      expect(find.byKey(DanmakuKeys.search), findsNothing);
      expect(find.byKey(DanmakuKeys.panel), findsNothing);
      expect(find.text('播放速度'), findsOneWidget);
      expect(find.text('来源'), findsNothing);
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
    tags: ['integration'],
  );

  testWidgets('source panel announces initial selection state', (tester) async {
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: FakeVideoBackend(),
      size: const Size(360, 800),
      prepare: (server) {
        server.items
            .firstWhere((item) => item.id == 'movie-inception')
            .extraSources = const [
          FakeMediaSource(id: 'alternate', name: '另一个版本'),
        ];
      },
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.canSwitchMediaSource, isTrue);
    await tester.tap(find.byKey(const Key('mobile-player-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('mobile-player-source-entry')));
    await tester.pump();
    expect(find.text('另一个版本'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('另一个版本')), findsWidgets);
    if (current.activeMediaSourceId == null) {
      expect(find.text('正在确认当前来源…'), findsOneWidget);
      for (final source in current.mediaSources) {
        expect(
          tester
              .widget<ListTile>(
                find.byKey(ValueKey('mobile-source-${source.id}')),
              )
              .selected,
          isFalse,
        );
      }
    }
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'multiple sources appear only in more, never in quality',
    (tester) async {
      final backend = _ControlledSourceBackend();
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        size: const Size(360, 800),
        prepare: (server) {
          server.items
              .firstWhere((item) => item.id == 'movie-inception')
              .extraSources = const [
            FakeMediaSource(id: 'alternate', name: '另一个版本'),
          ];
        },
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(current.canSwitchMediaSource, isTrue);
      expect(find.text('来源'), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-player-quality')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('来源'), findsNothing);
      expect(find.text('另一个版本'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('另一个版本'), findsNothing);
      final sourceEntry = find.byKey(const Key('mobile-player-source-entry'));
      await tester.ensureVisible(sourceEntry);
      await tester.pump();
      await tester.tap(sourceEntry);
      await tester.pump();
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('另一个版本'), findsOneWidget);
      final alternate = find.byKey(const Key('mobile-source-alternate'));
      expect(alternate, findsOneWidget);
      await tester.ensureVisible(alternate);
      final originalId = current.resolved!.mediaSource.id;
      await tester.tap(alternate);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (!current.loading && current.activeMediaSourceId == 'alternate') {
          break;
        }
      }
      expect(current.activeMediaSourceId, 'alternate');
      expect(current.pendingMediaSourceId, isNull);
      expect(find.text('正在切换来源…'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '返回'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('mobile-player-source-entry')));
      await tester.pump();
      final gate = Completer<void>();
      backend.blockNext = gate;
      backend.failNext = true;
      final original = find.byKey(ValueKey('mobile-source-$originalId'));
      await tester.ensureVisible(original);
      await tester.tap(original);
      await tester.pump();
      expect(current.pendingMediaSourceId, originalId);
      expect(current.activeMediaSourceId, 'alternate');
      expect(find.text('正在切换来源…'), findsOneWidget);
      expect(
        tester
            .widget<Icon>(
              find.byKey(ValueKey('mobile-source-icon-$originalId')),
            )
            .icon,
        Icons.hourglass_top,
      );
      expect(tester.widget<ListTile>(alternate).selected, isTrue);
      expect(tester.widget<ListTile>(original).selected, isFalse);
      gate.complete();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (!current.isRecovering) break;
      }
      expect(current.activeMediaSourceId, 'alternate');
      expect(current.error, isNull);
      expect(find.text('来源切换失败，原来源已恢复'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '返回'));
      await tester.pump();
      expect(
        find.byKey(const Key('mobile-player-source-entry')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await closePlayer(tester);
    },
    tags: ['integration'],
    semanticsEnabled: false,
  );

  testWidgets(
    'fit is the default scale with central transport and a full-width timeline',
    (tester) async {
      final backend = FakeVideoBackend(
        duration: const Duration(hours: 1, minutes: 5),
      );
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        mediaDuration: const Duration(hours: 1, minutes: 5),
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: const Size(800, 360),
      );
      final toggle = tester.getRect(
        find.byKey(const Key('mobile-player-toggle')),
      );
      final seek = tester.getRect(find.byKey(const Key('mobile-player-seek')));
      expect(toggle.center.dx, closeTo(400, .2));
      expect(toggle.bottom, lessThan(seek.top));
      expect(seek.width, greaterThan(740));

      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const Key('mobile-player-scale-fit')),
            )
            .selected,
        isTrue,
      );
      expect(find.text('适应'), findsOneWidget);
      expect(find.text('填充'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mobile-player-scale-fill')));
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const Key('mobile-player-scale-fill')),
            )
            .selected,
        isTrue,
      );
      final closeSheet = find.widgetWithText(TextButton, '返回');
      await tester.ensureVisible(closeSheet);
      await tester.pump();
      await tester.tap(closeSheet);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pump(const Duration(seconds: 5));
      expect(
        find.byKey(const Key('mobile-player-toggle')).hitTestable(),
        findsNothing,
      );
      await tester.tapAt(const Offset(400, 80));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('mobile-player-toggle')).hitTestable(),
        findsOneWidget,
      );
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('unknown duration disables every phone seek entry', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: Duration.zero);
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: Duration.zero,
      prepare: (server) {
        final movie = server.items.firstWhere(
          (item) => item.id == 'movie-inception',
        );
        movie.runTimeTicks = 0;
        movie.playbackPositionTicks = 0;
      },
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.duration, Duration.zero);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('mobile-player-rewind')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('mobile-player-forward')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('mobile-player-seek')))
          .onChanged,
      isNull,
    );
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.position, Duration.zero);
    await closePlayer(tester);
  }, tags: ['integration']);

  testWidgets('player controls fade instead of popping', (tester) async {
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(PhoneMotion.playerControlsKey))
          .duration,
      AppMotion.normal,
    );
    double controlsOpacity() => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byKey(PhoneMotion.playerControlsKey),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;
    expect(controlsOpacity(), 1);

    current.toggleControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final fading = controlsOpacity();
    expect(fading, greaterThan(0));
    expect(fading, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controlsOpacity(), 0);

    current.toggleControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final showing = controlsOpacity();
    expect(showing, greaterThan(0));
    expect(showing, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controlsOpacity(), 1);
    await tester.tap(find.byKey(const Key('mobile-player-toggle')));
    await tester.pump();
    expect(current.isPlaying, isFalse);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'playback hides system bars, reasserts landscape, and drops the rotate button',
    (tester) async {
      final channelCalls = <MethodCall>[];
      _mockAndroidPlayerChannel(channelCalls);
      final bars = PhoneSystemBars();
      final orientation = PhoneOrientation(request: (_) async {});
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        orientation: orientation,
        systemBars: bars,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      await bars.settled;
      expect(bars.calls, [true]);
      expect(_systemBarHidden(channelCalls), [true]);
      expect(orientation.calls.single, PhoneOrientation.landscape);
      expect(find.byIcon(Icons.screen_rotation), findsNothing);
      expect(find.byKey(const Key('mobile-player-lock')), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-more')), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await bars.settled;
      expect(bars.calls, [true, true]);
      expect(_systemBarHidden(channelCalls), [true, true]);
      await orientation.settled;
      expect(orientation.calls, [
        PhoneOrientation.landscape,
        PhoneOrientation.landscape,
      ]);

      await closePlayer(tester);
      await bars.settled;
      await orientation.settled;
      expect(bars.calls, [true, true, false]);
      expect(_systemBarHidden(channelCalls), [true, true, false]);
      expect(orientation.calls[2], PhoneOrientation.portrait);
      expect(find.byType(MobilePlayerPage), findsNothing);
    },
    tags: ['integration'],
  );

  testWidgets('transport targets are at least 48dp and still step 10 seconds', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(hours: 3));
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: const Duration(hours: 3),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      size: const Size(360, 640),
    );
    final rewind = tester.getRect(
      find.byKey(const Key('mobile-player-rewind')),
    );
    final toggle = tester.getRect(
      find.byKey(const Key('mobile-player-toggle')),
    );
    final forward = tester.getRect(
      find.byKey(const Key('mobile-player-forward')),
    );
    for (final rect in [rewind, toggle, forward]) {
      expect(rect.width, greaterThanOrEqualTo(48 - 0.01));
      expect(rect.height, greaterThanOrEqualTo(48 - 0.01));
    }
    expect(toggle.left - rewind.right, greaterThanOrEqualTo(8 - 0.01));
    expect(forward.left - toggle.right, greaterThanOrEqualTo(8 - 0.01));
    for (final key in [
      find.byTooltip('关闭'),
      find.byKey(const Key('mobile-player-lock')),
      find.byKey(const Key('mobile-player-more')),
    ]) {
      expect(tester.getSize(key).shortestSide, greaterThanOrEqualTo(48 - 0.01));
    }
    expect(tester.takeException(), isNull);

    final start = backend.position;
    await tester.tap(find.byKey(const Key('mobile-player-forward')));
    await tester.pump();
    expect(backend.position - start, const Duration(seconds: 10));
    await tester.tap(find.byKey(const Key('mobile-player-rewind')));
    await tester.pump();
    expect(backend.position, start);
    await closePlayer(tester);
  }, tags: ['integration']);

  testWidgets(
    'landscape controls use actual top obstruction while video stays full bleed',
    (tester) async {
      const size = Size(800, 360);
      tester.view.padding = FakeViewPadding();
      tester.view.viewPadding = const FakeViewPadding(top: 30);
      tester.view.systemGestureInsets = const FakeViewPadding(
        left: 24,
        top: 12,
        right: 24,
        bottom: 40,
      );
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetSystemGestureInsets);
      final channelCalls = <MethodCall>[];
      _mockAndroidPlayerChannel(channelCalls, sdk: 34);
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: size,
      );
      expect(
        channelCalls.map((call) => call.method),
        contains('androidSdkInt'),
      );

      final back = tester.getRect(find.byTooltip('关闭'));
      final more = tester.getRect(find.byKey(const Key('mobile-player-more')));
      final rewind = tester.getRect(
        find.byKey(const Key('mobile-player-rewind')),
      );
      final video = find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == const Color(0xFF000000),
      );
      expect(video, findsOneWidget);
      final picture = tester.getRect(video);
      expect(picture.left, closeTo(0, 0.2));
      expect(picture.top, closeTo(0, 0.2));
      expect(picture.width, closeTo(size.width, 0.2));
      expect(picture.height, closeTo(size.height, 0.2));
      final topScrim = find.byKey(const Key('mobile-player-top-scrim'));
      final bottomScrim = find.byKey(const Key('mobile-player-bottom-scrim'));
      expect(tester.getRect(topScrim).top, closeTo(picture.top, 0.01));
      expect(tester.getRect(topScrim).left, closeTo(picture.left, 0.01));
      expect(tester.getRect(topScrim).right, closeTo(picture.right, 0.01));
      expect(tester.getRect(bottomScrim).bottom, closeTo(picture.bottom, 0.01));
      expect(tester.getRect(bottomScrim).left, closeTo(picture.left, 0.01));
      expect(tester.getRect(bottomScrim).right, closeTo(picture.right, 0.01));
      final topDecoration =
          tester.widget<DecoratedBox>(topScrim).decoration as BoxDecoration;
      expect(topDecoration.gradient!.colors.first.a, greaterThan(0));
      expect(back.top - picture.top, closeTo(0, 0.01));
      expect(back.left - picture.left, closeTo(24, 0.01));
      expect(picture.right - more.right, greaterThanOrEqualTo(24));
      expect(rewind.left - picture.left, greaterThanOrEqualTo(24));
      expect(picture.bottom - more.bottom, greaterThanOrEqualTo(40));
      expect(rewind.bottom, lessThan(more.top));
      await tester.tap(find.byKey(const Key('mobile-player-lock')));
      await tester.pump();
      expect(tester.getRect(topScrim).top, closeTo(picture.top, 0.01));
      expect(tester.getRect(topScrim).left, closeTo(picture.left, 0.01));
      expect(
        tester.getTopLeft(find.byKey(const Key('mobile-player-unlock'))).dy,
        closeTo(0, 0.01),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('mobile-player-unlock')));
      await tester.pump();
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'pre-30 display cutouts inset controls and API 30 keeps them in view padding',
    (tester) async {
      const size = Size(800, 360);
      const cutout = DisplayFeature(
        bounds: Rect.fromLTWH(0, 40, 32, 120),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      );

      Future<double> backLeft(int sdk) async {
        tester.view.padding = FakeViewPadding();
        tester.view.viewPadding = FakeViewPadding();
        tester.view.systemGestureInsets = FakeViewPadding();
        tester.view.displayFeatures = const [cutout];
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetSystemGestureInsets);
        addTearDown(tester.view.resetDisplayFeatures);
        _mockAndroidPlayerChannel(<MethodCall>[], sdk: sdk);
        await showPlayer(
          tester,
          itemId: 'movie-inception',
          wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
          size: size,
        );
        final video = find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox && widget.color == const Color(0xFF000000),
        );
        final picture = tester.getRect(video);
        expect(picture.left, closeTo(0, 0.2));
        expect(picture.width, closeTo(size.width, 0.2));
        expect(picture.height, closeTo(size.height, 0.2));
        final left = tester.getTopLeft(find.byTooltip('关闭')).dx - picture.left;
        await closePlayer(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        return left;
      }

      expect(await backLeft(29), greaterThanOrEqualTo(32 - 0.01));
      expect(await backLeft(30), lessThan(1));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('landscape top cutout still insets the top controls', (
    tester,
  ) async {
    tester.view.padding = FakeViewPadding();
    tester.view.viewPadding = const FakeViewPadding(top: 36);
    tester.view.systemGestureInsets = FakeViewPadding();
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: Rect.fromLTWH(350, 0, 100, 24),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      ),
    ];
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetSystemGestureInsets);
    addTearDown(tester.view.resetDisplayFeatures);
    _mockAndroidPlayerChannel(<MethodCall>[], sdk: 36);
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      size: const Size(800, 360),
    );
    expect(tester.getTopLeft(find.byTooltip('关闭')).dy, closeTo(24, 0.01));
    await closePlayer(tester);
  }, tags: ['integration']);

  testWidgets(
    'unsupported startup tracks stay silent and a manual choice is in Chinese',
    (tester) async {
      final backend = _PhoneTrackBackend(
        rejectedAudio: {8},
        rejectedSubtitles: {4},
      );
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: const Size(800, 800),
        prepare: (server) {
          server.items
              .firstWhere((item) => item.id == 'movie-inception')
              .mediaStreams = const [
            FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
            FakeMediaStream(
              index: 1,
              type: 'Audio',
              codec: 'aac',
              displayTitle: 'English',
              isDefault: true,
            ),
            FakeMediaStream(
              index: 8,
              type: 'Audio',
              codec: 'ac3',
              displayTitle: 'Commentary',
            ),
            FakeMediaStream(
              index: 4,
              type: 'Subtitle',
              codec: 'ass',
              displayTitle: '中文',
              isDefault: true,
              isTextSubtitleStream: true,
            ),
          ];
        },
      );
      expect(current.error, isNull);
      expect(current.trackFailure, isNull);
      expect(current.isPlaying, isTrue);
      expect(backend.audioCalls, [1]);
      expect(backend.subtitleCalls, isEmpty);
      expect(find.text('此轨道在当前设备上不可用'), findsNothing);
      expect(find.textContaining('Bad state:'), findsNothing);
      expect(find.textContaining('Unsupported media track'), findsNothing);

      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final commentary = find.text('Commentary');
      await tester.ensureVisible(commentary);
      await tester.pump();
      await tester.tap(commentary);
      await tester.pump();
      expect(find.text('此轨道在当前设备上不可用'), findsWidgets);
      expect(find.textContaining('Bad state:'), findsNothing);
      expect(find.textContaining('Unsupported media track'), findsNothing);
      expect(find.text('Device track is not playable'), findsNothing);
      expect(current.error, isNull);
      expect(current.isPlaying, isTrue);
      expect(current.audioStreamIndex, 1);
      expect(backend.audioCalls, [1]);
      expect(backend.openCount, 1);
      expect(find.text('重试'), findsNothing);

      final closeSheet = find.widgetWithText(TextButton, '返回');
      await tester.ensureVisible(closeSheet);
      await tester.pump();
      await tester.tap(closeSheet);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final before = backend.position;
      await tester.tap(find.byKey(const Key('mobile-player-forward')));
      await tester.pump();
      expect(backend.position - before, const Duration(seconds: 10));
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  for (final size in [
    const Size(320, 568),
    const Size(360, 800),
    const Size(412, 915),
    const Size(640, 320),
    const Size(800, 360),
    const Size(915, 412),
  ]) {
    testWidgets('phone shortcuts and cache remain usable at $size', (
      tester,
    ) async {
      final backend = FakeVideoBackend();
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        size: size,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      for (final key in ['speed', 'more']) {
        final button = find.byKey(Key('mobile-player-$key'));
        expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
      }
      final timeline = find.byKey(const Key('mobile-player-seek'));
      expect(tester.getSize(timeline).width, greaterThan(size.width - 50));
      final cache = find.byKey(const Key('mobile-player-cache-status'));
      final clock = find.byKey(const Key('mobile-player-clock'));
      if (size.width < size.height) {
        expect(
          tester.getTopLeft(cache).dy,
          greaterThan(tester.getBottomLeft(clock).dy),
        );
      } else {
        expect(
          tester.getTopLeft(cache).dy,
          closeTo(tester.getTopLeft(clock).dy, 4),
        );
      }
      backend.emitEvent(VideoEventKind.cacheSpeed, 1048576);
      backend.emitEvent(
        VideoEventKind.bufferSnapshot,
        BufferSnapshot(
          sessionId: current.bufferSnapshot.sessionId,
          resourceId: 'phone-test',
          representationVersion: 'v1',
          trackVersion: 0,
          sequence: 1,
          ranges: const [BufferedRange(Duration.zero, Duration(minutes: 1))],
        ),
      );
      await tester.pump();
      expect(find.text('1.0 MB/s'), findsOneWidget);
      expect(
        tester
            .widget<BufferedRangesTrack>(find.byType(BufferedRangesTrack))
            .snapshot
            .ranges,
        hasLength(1),
      );
      backend.emitEvent(VideoEventKind.cacheSpeed, 0);
      await tester.pump();
      expect(find.text('0 KB/s'), findsOneWidget);
      expect(
        tester
            .widget<BufferedRangesTrack>(find.byType(BufferedRangesTrack))
            .snapshot
            .ranges,
        hasLength(1),
      );

      await tester.tap(find.byKey(const Key('mobile-player-speed')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final options = tester.getRect(
        find.byKey(const Key('mobile-player-options')),
      );
      expect(find.text('播放速度'), findsOneWidget);
      if (size.width > size.height) {
        expect(options.width, lessThanOrEqualTo(360));
        expect(options.right, closeTo(size.width, .2));
        expect(options.left, greaterThan(size.width * .3));
      } else {
        expect(options.bottom, closeTo(size.height, .2));
        expect(options.height, lessThan(size.height * .8));
      }
      await tester.tap(find.widgetWithText(ChoiceChip, '1.5x'));
      await tester.pump();
      expect(current.playbackRate, 1.5);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.descendant(
          of: find.byKey(const Key('mobile-player-speed')),
          matching: find.text('1.5x'),
        ),
        findsOneWidget,
      );

      expect(find.byKey(const Key('mobile-player-quality')), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-tracks')), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-danmaku')), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-player-quality')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('来源'), findsNothing);
      expect(find.byType(ChoiceChip), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // A long scrub must not lose its controls halfway through the gesture.
      final gesture = await tester.startGesture(tester.getCenter(timeline));
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(seconds: 5));
      expect(current.controlsVisible, isTrue);
      await gesture.up();
      await tester.pump();
      expect(backend.position, greaterThan(Duration.zero));
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      current.toggleControls();
      await tester.pump();
      expect(
        tester
            .widget<AnimatedOpacity>(find.byKey(PhoneMotion.playerControlsKey))
            .duration,
        Duration.zero,
      );
      expect(
        find.byKey(const Key('mobile-player-toggle')).hitTestable(),
        findsNothing,
      );
      current.toggleControls();
      await tester.pump();
      expect(
        find.byKey(const Key('mobile-player-toggle')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await closePlayer(tester);
    }, tags: ['integration']);
  }

  testWidgets('a video that cannot open still offers retry', (tester) async {
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: _FailOpenBackend(),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(find.text('无法播放'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('Bad state:'), findsNothing);
    await tester.tap(find.byKey(const Key('mobile-player-lock')));
    await tester.pump();
    expect(find.text('重试'), findsNothing);
    await tester.tapAt(const Offset(400, 160));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('重试'), findsNothing);
    await tester.tap(find.byKey(const Key('mobile-player-unlock')));
    await tester.pump();
    expect(find.text('重试'), findsOneWidget);
    await closePlayer(tester);
  }, tags: ['integration']);

  testWidgets('retry button actually opens the failed phone playback', (
    tester,
  ) async {
    final backend = _RetryOpenBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.error, isNotNull);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(current.loading, isTrue);
    for (var i = 0; i < 30 && current.loading; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(current.error, isNull);
    expect(backend.attempts, 2);
    await closePlayer(tester);
  }, tags: ['integration']);
}

class _PhoneTrackBackend extends FakeVideoBackend
    implements VideoBackendTrackSupport {
  _PhoneTrackBackend({
    this.rejectedAudio = const {},
    this.rejectedSubtitles = const {},
  }) : super(duration: const Duration(hours: 3));

  final Set<int> rejectedAudio;
  final Set<int> rejectedSubtitles;
  final List<int> audioCalls = [];
  final List<int> subtitleCalls = [];

  @override
  bool? audioTrackSupported(int index) =>
      rejectedAudio.contains(index) ? false : true;

  @override
  bool? subtitleTrackSupported(int index) =>
      rejectedSubtitles.contains(index) ? false : true;

  @override
  Future<void> setAudioIndex(int index) async {
    audioCalls.add(index);
    await super.setAudioIndex(index);
  }

  @override
  Future<void> setSubtitleIndex(int index) async {
    subtitleCalls.add(index);
    await super.setSubtitleIndex(index);
  }
}

class _FailOpenBackend extends FakeVideoBackend {
  @override
  Future<void> open(VideoOpenRequest request) async {
    throw StateError('media open failed');
  }
}

class _RetryOpenBackend extends FakeVideoBackend {
  int attempts = 0;

  @override
  Future<void> open(VideoOpenRequest request) async {
    attempts++;
    if (attempts == 1) throw StateError('first open failed');
    await super.open(request);
  }
}

class _ControlledSourceBackend extends FakeVideoBackend {
  Completer<void>? blockNext;
  bool failNext = false;

  @override
  Future<void> open(VideoOpenRequest request) async {
    final gate = blockNext;
    blockNext = null;
    if (gate != null) await gate.future;
    if (failNext) {
      failNext = false;
      throw StateError('selected source could not open');
    }
    await super.open(request);
  }
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

class _FailDisplayControl extends _FakeDisplayControl {
  @override
  Future<void> setBrightness(double value) async {
    throw StateError('platform denied brightness');
  }
}

class _InvalidBrightnessDisplayControl extends _FakeDisplayControl {
  @override
  Future<double> brightness() async => -1;
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
