import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

void main() {
  Future<PlayerController> start(
    WidgetTester tester,
    FakeVideoBackend video, {
    bool reducedMotion = false,
    Size size = const Size(960, 540),
    String itemId = 'movie-inception',
  }) async {
    final server = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'tv',
          deviceId: 'tv-controls',
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
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
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
            controlsHideAfter: const Duration(seconds: 2),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
            settingsStore: MemoryPlayerSettingsStore(),
          ),
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: child!,
            ),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        TvPlayerPage(itemId: itemId, autoResume: false),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // A pending native open must not be awaited by pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return tester
        .state<TvPlayerPageState>(find.byType(TvPlayerPage))
        .controller!;
  }

  testWidgets('TV completion focuses replay and remote can replay or close', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(minutes: 148));
    final current = await start(tester, backend);
    backend.completePlayback();
    await tester.pumpAndSettle();
    expect(find.byKey(PlayerKeys.playbackEnded), findsOneWidget);
    expect(
      tester
          .widget<TvAction>(find.byKey(PlayerKeys.replay))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    final opens = backend.openCount;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(current.playbackEnded, isFalse);
    expect(backend.openCount, greaterThan(opens));
    backend.completePlayback();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    for (
      var i = 0;
      i < 40 && find.byType(TvPlayerPage).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(TvPlayerPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  }, tags: ['integration']);

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  bool focused(WidgetTester tester, String key) => tester
      .widgetList<Semantics>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(Semantics),
        ),
      )
      .any((s) => s.properties.focused == true);

  testWidgets(
    'single-choice TV tracks quality and source actions stay hidden',
    (tester) async {
      final c = await start(tester, FakeVideoBackend());
      const source = PlaybackMediaSource(
        id: 'only',
        mediaStreams: [MediaStreamInfo(index: 1, type: 'Audio', codec: 'aac')],
      );
      c.resolved = ResolvedPlayback(
        playMethod: PlayMethod.directPlay,
        streamUrl: Uri.parse('https://example.test/media'),
        playSessionId: 'session',
        mediaSource: source,
        itemId: c.itemId,
      );
      c.mediaSources = const [source];
      c.onUserActivity();
      await tester.pump();
      for (final key in ['tv-player-quality', 'tv-player-source']) {
        expect(find.byKey(Key(key)), findsNothing);
      }
      expect(find.byKey(const Key('tv-player-tracks')), findsNothing);
      expect(find.byKey(const Key('tv-player-speed')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'surface remote seek and scan preserve playing and paused intent',
    (tester) async {
      final video = FakeVideoBackend();
      await start(tester, video);
      await tester.pumpAndSettle();
      expect(video.isPlaying, isTrue);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(video.position, const Duration(seconds: 10));
      expect(video.isPlaying, isTrue);
      await key(tester, LogicalKeyboardKey.select);
      expect(video.isPlaying, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 40));
      }
      // Scan previews locally and commits once on release.
      expect(video.position, const Duration(seconds: 10));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(video.position, const Duration(seconds: 160));
      expect(video.isPlaying, isFalse);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(video.position, const Duration(seconds: 150));
      await key(tester, LogicalKeyboardKey.select);
      expect(video.isPlaying, isTrue);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets('D-pad reaches every panel and back restores its entry focus', (
    tester,
  ) async {
    final c = await start(tester, FakeVideoBackend(), reducedMotion: true);
    c.mediaSources = [
      ...c.mediaSources,
      const PlaybackMediaSource(id: 'alternate'),
    ];
    c.onUserActivity();
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(tester, 'tv-player-toggle'), isTrue);
    for (final entry in ['tracks', 'quality', 'source', 'skip', 'speed']) {
      await key(tester, LogicalKeyboardKey.arrowRight);
      if (entry == 'source') {
        // Manual cross-source switching now has its own action between quality
        // and the local media-version panel. Exercise rather than skip it.
        expect(find.byKey(const Key('player-manual-switch')), findsOneWidget);
        final manualFocus = FocusManager.instance.primaryFocus;
        await key(tester, LogicalKeyboardKey.select);
        expect(find.byType(SourceSwitchMenu), findsOneWidget);
        expect(c.controlsPinned, isTrue);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(SourceSwitchMenu), findsNothing);
        expect(FocusManager.instance.primaryFocus, same(manualFocus));
        expect(c.controlsPinned, isFalse);
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focused(tester, 'tv-player-$entry'), isTrue);
      final origin = FocusManager.instance.primaryFocus;
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const Key('tv-player-panel')), findsOneWidget);
      expect(c.controlsPinned, isTrue);
      expect(FocusManager.instance.primaryFocus, isNot(same(origin)));
      final viewport = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('tv-player-panel')),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      final focusedOption = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.focused == true &&
            widget.properties.button == true,
      );
      final border = tester.renderObject<RenderBox>(
        find
            .descendant(of: focusedOption, matching: find.byType(DecoratedBox))
            .first,
      );
      final paintedBorder = MatrixUtils.transformRect(
        border.getTransformTo(null),
        Offset.zero & border.size,
      );
      expect(paintedBorder.left, greaterThanOrEqualTo(viewport.left));
      expect(paintedBorder.right, lessThanOrEqualTo(viewport.right));
      if (entry == 'skip') {
        expect(c.skipIntroEnabled, isTrue);
        await key(tester, LogicalKeyboardKey.select);
        expect(c.skipIntroEnabled, isFalse);
        await key(tester, LogicalKeyboardKey.arrowDown);
        await key(tester, LogicalKeyboardKey.select);
        expect(c.skipOutroEnabled, isFalse);
        expect(c.controlsPinned, isTrue);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(origin));
      expect(c.controlsPinned, isFalse);
    }
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(c.playbackRate, 1.25);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(c.controlsVisible, isFalse);
    await key(tester, LogicalKeyboardKey.select);
    expect(c.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, tags: ['integration']);

  testWidgets(
    'timeline confirms preview, hide returns surface focus and zero speed remains visible',
    (tester) async {
      final video = FakeVideoBackend();
      final c = await start(tester, video);
      await tester.pumpAndSettle();
      final snapshot = BufferSnapshot(
        sessionId: video.sessionId,
        resourceId: 'test',
        representationVersion: '1',
        trackVersion: 0,
        sequence: 1,
        ranges: const [
          BufferedRange(Duration.zero, Duration(seconds: 30)),
          BufferedRange(Duration(seconds: 60), Duration(seconds: 90)),
        ],
      );
      video.emitEvent(VideoEventKind.bufferSnapshot, snapshot);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final speed = tester.widget<NetworkSpeedReadout>(
        find.byKey(const Key('tv-player-network-speed')),
      );
      expect(speed.bytesPerSecond, 0);
      expect(speed.textStyle!.fontSize, greaterThanOrEqualTo(20));
      expect(find.textContaining('缓存'), findsNothing);
      expect(
        tester
            .widget<BufferedRangesProgressIndicator>(
              find.byType(BufferedRangesProgressIndicator),
            )
            .snapshot
            .ranges,
        hasLength(2),
      );
      expect(
        tester.getRect(find.byKey(const Key('tv-player-gradient'))),
        const Rect.fromLTWH(0, 0, 960, 540),
      );
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(tester, 'tv-player-seek'), isTrue);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(video.position, Duration.zero);
      await key(tester, LogicalKeyboardKey.select);
      expect(video.position, const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(c.controlsVisible, isFalse);
      expect(find.byKey(const Key('tv-player-toggle')), findsNothing);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(video.position, const Duration(seconds: 20));
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'native view stays mounted while loading and retry recovers focus',
    (tester) async {
      final video = _DelayedBackend();
      final c = await start(tester, video);
      expect(c.loading, isTrue);
      final view = tester.element(find.byKey(const Key('native-view')));
      video.openGate.complete();
      await tester.pumpAndSettle();
      expect(c.loading, isFalse);
      expect(tester.element(find.byKey(const Key('native-view'))), same(view));
      video.emitError('network timeout');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(c.disconnected, isTrue);
      expect(
        focused(tester, 'tv-player-retry'),
        isTrue,
        reason: '${FocusManager.instance.primaryFocus}',
      );
      await key(tester, LogicalKeyboardKey.select);
      expect(c.error, isNull);
      expect(c.disconnected, isFalse);
      expect(tester.element(find.byKey(const Key('native-view'))), same(view));
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'cancelling next episode blocks another auto countdown at natural end',
    (tester) async {
      final backend = FakeVideoBackend();
      final current = await start(
        tester,
        backend,
        itemId: 'episode-friends-s1e1',
      );
      for (var i = 0; i < 40 && current.loading; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.loading, isFalse);
      expect(current.itemId, 'episode-friends-s1e1');
      backend.emitEvent(
        VideoEventKind.position,
        backend.duration - const Duration(minutes: 1),
      );
      for (var i = 0; i < 40 && current.nextEpisode == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.nextEpisode?.item.id, 'episode-friends-s1e2');
      expect(current.nextEpisode?.remaining, isNull);
      await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.pump();
      expect(current.nextEpisode, isNull);
      expect(current.itemId, 'episode-friends-s1e1');

      final opens = backend.openCount;
      backend.completePlayback();
      for (var i = 0; i < 40 && current.nextEpisode == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.itemId, 'episode-friends-s1e1');
      expect(current.nextEpisode?.item.id, 'episode-friends-s1e2');
      expect(current.nextEpisode?.remaining, isNull);
      expect(find.textContaining('秒后播放下一集'), findsNothing);
      await tester.pump(
        current.nextEpisodeCountdown + const Duration(seconds: 2),
      );
      expect(current.itemId, 'episode-friends-s1e1');
      expect(current.nextEpisode?.remaining, isNull);
      expect(backend.openCount, opens);
      expect(find.textContaining('秒后播放下一集'), findsNothing);

      await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodePlay));
      await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
      for (
        var i = 0;
        i < 40 && (current.itemId != 'episode-friends-s1e2' || current.loading);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.itemId, 'episode-friends-s1e2');
      expect(backend.openCount, greaterThan(opens));
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );
}

class _DelayedBackend extends FakeVideoBackend {
  final openGate = Completer<void>();
  @override
  Future<void> open(VideoOpenRequest request) async {
    await openGate.future;
    await super.open(request);
  }

  @override
  Widget buildView({Key? key}) =>
      const ColoredBox(key: Key('native-view'), color: Colors.blue);
}
