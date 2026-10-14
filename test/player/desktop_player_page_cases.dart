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
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

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
