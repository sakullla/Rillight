import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

void main() {
  const windowChannel = MethodChannel('window_manager');

  void _installDesktopOverrides(WidgetTester tester, Size size) {
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

  void _clearDesktopOverrides() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  }

  Future<PlayerController> openPlayer(
    WidgetTester tester,
    FakeVideoBackend video, {
    required String itemId,
    Size size = const Size(1280, 720),
  }) async {
    _installDesktopOverrides(tester, size);
    final server = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
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
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: PlayerScope(
          bindings: PlayerBindings(
            createBackend: () => video,
            window: PlayerWindow(),
            controlsHideAfter: const Duration(seconds: 5),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
            settingsStore: MemoryPlayerSettingsStore(),
          ),
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.dark(),
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

  testWidgets('desktop retry shows the download cache bar', (tester) async {
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
      final cacheBar = find.byKey(const Key('player-byte-cache-track'));
      expect(cacheBar, findsOneWidget);
      expect(cacheBar.hitTestable(), findsOneWidget);
      final cacheRect = tester.getRect(cacheBar);
      final seekRect = tester.getRect(find.byKey(PlayerKeys.seekBar));
      expect(cacheRect.width, greaterThan(200));
      expect(cacheRect.height, greaterThan(0));
      expect(cacheRect.top, greaterThanOrEqualTo(0));
      expect(cacheRect.bottom, lessThanOrEqualTo(720));
      expect(cacheRect.bottom, lessThanOrEqualTo(seekRect.top));
      expect(tester.takeException(), isNull);
    } finally {
      _clearDesktopOverrides();
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
      _clearDesktopOverrides();
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
