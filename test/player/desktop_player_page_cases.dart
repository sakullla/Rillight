import 'package:rillight/media_image/media_image.dart';

import '../helpers/widget_harness.dart';

import 'package:rillight/media_server/device.dart';
import 'package:flutter/foundation.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/playback_control_scrims.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import 'danmaku/danmaku_controller_cases.dart'
    show FakeDandanplayClient, unreachable;

void main() {
  const windowChannel = MethodChannel('window_manager');

  void installDesktopOverrides(WidgetTester tester, Size size) {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          switch (call.method) {
            case 'isMaximized':
            case 'isMinimized':
            case 'isFullScreen':
            case 'isVisible':
            case 'isFocused':
            case 'isAlwaysOnTop':
            case 'isPreventClose':
              return false;
            default:
              return null;
          }
        });
  }

  void clearDesktopOverrides() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  }

  Future<PlayerController> openPlayer(
    WidgetTester tester,
    FakeVideoBackend video, {
    required String itemId,
    Size size = const Size(1280, 720),
    bool independentWindow = false,
    PlayerSettingsStore? settingsStore,
    DandanplayClient? danmakuClient,
  }) async {
    installDesktopOverrides(tester, size);
    final server = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'desktop',
          deviceId: 'desktop-player',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    await tester.runAsync(
      () => auth.selectLine(
        auth.session!.server.id,
        LineSelection.fixed(auth.session!.server.activeLineId!),
      ),
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      auth.dispose();
    });
    final bindings = PlayerBindings(
      createBackend: () => video,
      window: PlayerWindow(),
      controlsHideAfter: const Duration(seconds: 5),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      settingsStore: settingsStore ?? MemoryPlayerSettingsStore(),
      danmakuClient: danmakuClient,
    );
    await tester.pumpWidget(
      independentWindow
          ? PlayerWindowApp.testing(
              launch: PlayerWindowLaunch.fromAuth(
                auth: auth,
                request: PlayerOpenRequest(itemId: itemId, autoResume: false),
              ),
              client: auth.client,
              bindings: bindings,
              onExit: () {},
            )
          : AuthScope(
              controller: auth,
              child: PlayerScope(
                bindings: bindings,
                child: CupertinoApp(
                  locale: const Locale('zh', 'CN'),
                  supportedLocales: AppLocalizations.supportedLocales,
                  localizationsDelegates: [
                    AppLocalizations.delegate,
                    ...GlobalCupertinoLocalizations.delegates,
                  ],
                  theme: AppUiTheme.dark().cupertino,
                  home: PlayerPage(itemId: itemId, autoResume: false),
                ),
              ),
            ),
    );
    PlayerController? ready;
    for (var i = 0; i < 40; i++) {
      final page = find.byType(PlayerPage);
      if (page.evaluate().isNotEmpty) {
        final current = tester.state<PlayerPageState>(page).controller;
        if (current != null && !current.loading) {
          ready = current;
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 400));
    if (ready == null || ready.loading) {
      fail('desktop player did not become ready');
    }
    return ready;
  }

  testWidgets('independent player authorizes images only for its live launch', (
    tester,
  ) async {
    try {
      final current = await openPlayer(
        tester,
        FakeVideoBackend(),
        itemId: 'movie-inception',
        independentWindow: true,
      );
      final auth = AuthScope.of(tester.element(find.byType(PlayerPage)));
      expect(auth.session, isNull);
      expect(mediaImageAccountScope(auth), isNotNull);
      final bytes = await tester.runAsync(
        () => auth.imageClient.getItemImage('movie-inception'),
      );
      expect(bytes, kTinyPng);
      await tester.runAsync(() => current.revokeFromHost(reportStopped: false));
      expect(mediaImageAccountScope(auth), isNull);
      await tester.runAsync(() async {
        await expectLater(
          auth.imageClient.getItemImage('movie-inception'),
          throwsA(anything),
        );
      });
    } finally {
      clearDesktopOverrides();
    }
  }, tags: ['integration']);

  testWidgets('independent Cupertino player edits saved danmaku keywords', (
    tester,
  ) async {
    final settings = MemoryPlayerSettingsStore(
      const PlayerSettings(
        danmakuEnabled: false,
        danmakuAppId: 'synthetic-app',
        danmakuToken: 'synthetic-secret',
        danmakuDisplay: DanmakuDisplaySettings(blockedKeywords: ['广告']),
      ),
    );
    try {
      final current = await openPlayer(
        tester,
        FakeVideoBackend(),
        itemId: 'movie-inception',
        independentWindow: true,
        settingsStore: settings,
      );
      expect(find.byType(PlayerWindowApp), findsOneWidget);
      await tester.tap(find.byKey(DanmakuKeys.menu));
      await tester.pump();
      await tester.tap(find.byKey(DanmakuKeys.advancedToggle));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(DanmakuKeys.keywordChip('广告')), findsOneWidget);

      final input = find.byKey(DanmakuKeys.keywordInput);
      await tester.ensureVisible(input);
      await tester.enterText(input, '剧透');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(DanmakuKeys.keywordChip('剧透')), findsOneWidget);
      expect((await settings.read()).danmakuDisplay!.blockedKeywords, [
        '广告',
        '剧透',
      ]);

      final saved = find.byKey(DanmakuKeys.keywordChip('广告'));
      await tester.ensureVisible(saved);
      await tester.tap(saved);
      await tester.pump();
      expect(saved, findsNothing);
      expect((await settings.read()).danmakuDisplay!.blockedKeywords, ['剧透']);

      final added = find.byKey(DanmakuKeys.keywordChip('剧透'));
      final focus = find.descendant(
        of: added,
        matching: find.byType(FocusableActionDetector),
      );
      Focus.of(
        tester.element(
          find
              .descendant(of: focus, matching: find.byType(GestureDetector))
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(added, findsNothing);
      expect((await settings.read()).danmakuDisplay!.blockedKeywords, isEmpty);

      // Leaving the editor commits once, without requiring the Done action.
      await tester.ensureVisible(input);
      await tester.enterText(input, '焦点提交');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final blurred = find.byKey(DanmakuKeys.keywordChip('焦点提交'));
      expect(blurred, findsOneWidget);
      expect((await settings.read()).danmakuDisplay!.blockedKeywords, ['焦点提交']);
      await tester.ensureVisible(blurred);
      await tester.tap(blurred);
      await tester.pump();
      expect((await settings.read()).danmakuDisplay!.blockedKeywords, isEmpty);
      expect(current.error, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      clearDesktopOverrides();
    }
  }, tags: ['integration']);

  Future<void> hideByTimeout(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5, milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> settleReveal(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  bool controlLayerHidden(WidgetTester tester) {
    final scrims = tester.widget<PlaybackControlScrims>(
      find.byKey(const Key('player-control-scrims')),
    );
    return !scrims.visible &&
        find.byKey(PlayerKeys.playPause).hitTestable().evaluate().isEmpty &&
        find
            .byKey(const Key('player-window-close'))
            .hitTestable()
            .evaluate()
            .isEmpty;
  }

  bool controlLayerShown(WidgetTester tester) {
    final scrims = tester.widget<PlaybackControlScrims>(
      find.byKey(const Key('player-control-scrims')),
    );
    return scrims.visible &&
        find.byKey(PlayerKeys.playPause).hitTestable().evaluate().isNotEmpty &&
        find
            .byKey(const Key('player-window-close'))
            .hitTestable()
            .evaluate()
            .isNotEmpty;
  }

  testWidgets(
    'desktop control layer hides while playing and any key wakes it',
    (tester) async {
      final backend = FakeVideoBackend();
      try {
        final current = await openPlayer(
          tester,
          backend,
          itemId: 'movie-inception',
        );
        current.onUserActivity();
        await settleReveal(tester);
        expect(current.isPlaying, isTrue);
        expect(controlLayerShown(tester), isTrue);

        await hideByTimeout(tester);
        expect(current.controlsVisible, isFalse);
        expect(controlLayerHidden(tester), isTrue);

        // A key without a shortcut action still reveals the controls once.
        final position = backend.position;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await settleReveal(tester);
        expect(current.controlsVisible, isTrue);
        expect(controlLayerShown(tester), isTrue);
        expect(backend.position, position);
        expect(current.isPlaying, isTrue);

        // Shortcut keys keep their action and also reveal the controls.
        await hideByTimeout(tester);
        expect(controlLayerHidden(tester), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settleReveal(tester);
        expect(controlLayerShown(tester), isTrue);
        expect(backend.position, greaterThan(position));

        await hideByTimeout(tester);
        expect(controlLayerHidden(tester), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        for (var i = 0; i < 20 && current.isPlaying; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await settleReveal(tester);
        expect(current.isPlaying, isFalse);
        expect(controlLayerShown(tester), isTrue);

        // Paused playback keeps the controls on screen.
        await hideByTimeout(tester);
        expect(current.controlsVisible, isTrue);
        expect(controlLayerShown(tester), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        clearDesktopOverrides();
      }
    },
    tags: ['integration'],
  );

  Future<void> waitForDanmakuStatus(
    WidgetTester tester,
    DanmakuStatus status,
  ) async {
    final page = tester.state<PlayerPageState>(find.byType(PlayerPage));
    for (var i = 0; i < 100 && page.danmaku?.status != status; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(page.danmaku?.status, status);
  }

  void expectSolidPlayerSurface(WidgetTester tester, Key key) {
    expect(
      find.descendant(
        of: find.byType(PlayerPage),
        matching: find.byType(LiquidGlass),
      ),
      findsNothing,
    );
    final decoration =
        tester.widget<Container>(find.byKey(key)).decoration! as BoxDecoration;
    expect(decoration.color!.a, 1);
    expect(decoration.border, isNotNull);
    expect(decoration.gradient, isNull);
    expect(decoration.boxShadow, isNull);
  }

  testWidgets(
    'desktop danmaku match chip appears and hides with the controls',
    (tester) async {
      final client = FakeDandanplayClient();
      try {
        final current = await openPlayer(
          tester,
          FakeVideoBackend(),
          itemId: 'movie-inception',
          danmakuClient: client,
          settingsStore: MemoryPlayerSettingsStore(
            const PlayerSettings(
              danmakuEnabled: true,
              danmakuAppId: 'synthetic-app',
              danmakuToken: 'synthetic-secret',
            ),
          ),
        );
        await waitForDanmakuStatus(tester, DanmakuStatus.noMatch);
        current.onUserActivity();
        await settleReveal(tester);
        final chip = find.byKey(DanmakuKeys.matchChip);
        expect(chip.hitTestable(), findsOneWidget);
        expectSolidPlayerSurface(tester, DanmakuKeys.matchChip);

        await hideByTimeout(tester);
        expect(controlLayerHidden(tester), isTrue);
        expect(chip.hitTestable(), findsNothing);
        final fade = tester.widget<AnimatedOpacity>(
          find.ancestor(of: chip, matching: find.byType(AnimatedOpacity)).first,
        );
        expect(fade.opacity, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await settleReveal(tester);
        expect(chip.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        clearDesktopOverrides();
      }
    },
    tags: ['integration'],
  );

  testWidgets(
    'desktop danmaku source banner appears and hides with the controls',
    (tester) async {
      final client = FakeDandanplayClient()..matchError = unreachable;
      try {
        final current = await openPlayer(
          tester,
          FakeVideoBackend(),
          itemId: 'movie-inception',
          danmakuClient: client,
          settingsStore: MemoryPlayerSettingsStore(
            const PlayerSettings(
              danmakuEnabled: true,
              danmakuServer: 'https://dan.example.com',
              danmakuToken: 'synthetic-secret',
            ),
          ),
        );
        await waitForDanmakuStatus(tester, DanmakuStatus.customUnreachable);
        current.onUserActivity();
        await settleReveal(tester);
        final banner = find.byKey(DanmakuKeys.sourceBanner);
        expect(
          find.byKey(DanmakuKeys.useOfficial).hitTestable(),
          findsOneWidget,
        );
        expectSolidPlayerSurface(tester, DanmakuKeys.sourceBanner);

        await hideByTimeout(tester);
        expect(controlLayerHidden(tester), isTrue);
        expect(find.byKey(DanmakuKeys.useOfficial).hitTestable(), findsNothing);
        final fade = tester.widget<AnimatedOpacity>(
          find
              .ancestor(of: banner, matching: find.byType(AnimatedOpacity))
              .first,
        );
        expect(fade.opacity, 0);

        current.onPointerHover();
        await settleReveal(tester);
        expect(
          find.byKey(DanmakuKeys.useOfficial).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        clearDesktopOverrides();
      }
    },
    tags: ['integration'],
  );

  testWidgets('desktop retry keeps one combined playback and cache timeline', (
    tester,
  ) async {
    final backend = _RetryOpenBackend();
    late final PlayerController current;
    try {
      current = await openPlayer(tester, backend, itemId: 'movie-inception');
      expect(current.error, isNotNull);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(current.loading, isTrue);
      final previousSession = current.bufferSnapshot.sessionId;
      for (
        var i = 0;
        i < 30 && current.bufferSnapshot.sessionId == previousSession;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final session = current.bufferSnapshot.sessionId;
      backend.emitEvent(
        VideoEventKind.bufferSnapshot,
        BufferSnapshot(
          sessionId: session,
          resourceId: current.bufferSnapshot.resourceId,
          representationVersion: current.bufferSnapshot.representationVersion,
          trackVersion: current.bufferSnapshot.trackVersion,
          sequence: current.bufferSnapshot.sequence + 1,
          ranges: const [],
          unknownReason: 'preparing',
          byteCoverage: BufferedByteCoverage(
            totalBytes: 1000,
            ranges: const [BufferedByteRange(0, 400)],
          ),
        ),
        forSession: session,
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('player-byte-cache-track')), findsNothing);
      for (var i = 0; i < 40 && current.loading; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(current.error, isNull);
      expect(backend.attempts, 2);
      expect(find.byType(BufferedRangesTrack), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      clearDesktopOverrides();
    }
  }, tags: ['integration']);

  testWidgets('desktop next episode stays on screen and starts playing', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    late final PlayerController current;
    try {
      current = await openPlayer(
        tester,
        backend,
        itemId: 'episode-friends-s1e1',
      );
      final opens = backend.openCount;
      backend.completePlayback();
      for (var i = 0; i < 40 && current.nextEpisode == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.nextEpisode?.item.id, 'episode-friends-s1e2');
      final card = tester.getRect(find.byKey(PlayerKeys.nextEpisode));
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(720));
      expect(card.right, lessThanOrEqualTo(1280));
      expect(card.height, lessThanOrEqualTo(88));
      final play = find.byKey(PlayerKeys.nextEpisodePlay);
      expect(play.hitTestable(), findsOneWidget);
      expect(tester.getSize(play).height, greaterThanOrEqualTo(40));
      await tester.tap(play);
      for (
        var i = 0;
        i < 40 && (current.itemId != 'episode-friends-s1e2' || current.loading);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.itemId, 'episode-friends-s1e2');
      expect(backend.openCount, greaterThan(opens));
      expect(backend.openedPaused, isFalse);
      expect(backend.isPlaying, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      clearDesktopOverrides();
    }
  }, tags: ['integration']);
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
