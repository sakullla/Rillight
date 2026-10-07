import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';
import 'package:rillight/aggregation/query/aggregation_query.dart'
    show SourceReference;
import 'package:rillight/player/playback_runtime.dart';
import '../helpers/settle.dart';
import 'dart:async';
import 'package:rillight/player/player_host_command.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/phone/phone_player_interaction.dart';
import 'package:rillight/player/phone_player_controls.dart';
import 'package:rillight/player/playback_output_panel.dart';
import 'package:rillight/player/playback_settings_menu.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/playback_state.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/network_throughput.dart';
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

void _useAacSource(FakeEmbyServer server) {
  final item = server.items.firstWhere((entry) => entry.id == 'movie-up');
  item.mediaStreams = const [
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
      displayTitle: 'English',
      isDefault: true,
    ),
  ];
}

class _RecordingOutputBackend extends FakeVideoBackend
    implements VideoBackendOutputReport {
  @override
  PlaybackOutputStatus outputStatus = PlaybackOutputStatus.unknown;

  bool? clearOverload;
  VideoEnhancementSelection? applied;

  @override
  Future<PlaybackOutputStatus> refreshOutputStatus() async => outputStatus;

  @override
  Future<void> applyVideoEnhancement(
    VideoEnhancementSelection selection, {
    bool clearOverload = false,
  }) async {
    applied = selection;
    this.clearOverload = clearOverload;
  }
}

class _RejectingOutputBackend extends FakeVideoBackend
    implements VideoBackendOutputReport {
  @override
  PlaybackOutputStatus outputStatus = PlaybackOutputStatus.unknown;

  @override
  Future<PlaybackOutputStatus> refreshOutputStatus() async => outputStatus;

  @override
  Future<void> applyVideoEnhancement(
    VideoEnhancementSelection selection, {
    bool clearOverload = false,
  }) {
    throw StateError('enhancement rejected');
  }
}

class _FailOneOpenBackend extends FakeVideoBackend {
  bool failNext = false;

  @override
  Future<void> open(VideoOpenRequest request) async {
    if (failNext) {
      failNext = false;
      throw StateError('Candidate stream failed');
    }
    await super.open(request);
  }
}

void main() {
  setUp(isolateImageCache);
  late RillightApp app;
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
    PlaybackRuntime? runtime,
  }) {
    return PlayerBindings(
      runtime: runtime,
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
    final auth = SyntheticSourceAuth(
      adapter: adapter,
      device: _device,
      libraryIds: {'view-movies', 'view-tv'},
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    final runtime = await tester.runAsync(auth.runtime);
    app = RillightApp(
      auth: auth,
      playerBindings: bindings(
        runtime: runtime,
        hideAfter: hideAfter,
        progressInterval: progressInterval,
        settingsStore: settingsStore ?? MemoryPlayerSettingsStore(),
      ),
    );
    return auth;
  }

  /// 不经 widget 树直接驱动的控制器(真实异步),用于断言 close() 的
  /// Stopped→onClose 顺序与 3 秒上限。
  Future<PlayerController> startStandaloneController({
    VoidCallback? onClose,
    ValueChanged<String>? onOpenItem,
    void Function(
      String itemId, {
      String? seasonId,
      PlayerHostOpenItemCommand? command,
    })?
    onOpenItemDetail,
    Duration progressInterval = const Duration(seconds: 10),
    Duration stoppedTimeout = PlayerController.stoppedDeadline,
    Duration disposeTimeout = PlayerController.stoppedDeadline,
    String itemId = 'movie-up',
    PlayerSettingsStore? settingsStore,
    String? userAgent,
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
    if (userAgent != null) client.setUserAgent(userAgent);
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
    final libraryId = server.items
        .firstWhere((item) => item.id == itemId)
        .parentId!;
    final account = await tester.runAsync(
      () => app.auth.sources.acquireAccount(
        app.auth.session!.server.id,
        region: AccessRegion.ordinary,
        libraryId: libraryId,
      ),
    );
    final permit = app.auth.sources.permit(account!, libraryId: libraryId);
    app.router.go(
      '/item/$itemId',
      extra: PlayerHostOpenItemCommand(
        itemId: itemId,
        source: SourceReference(account: account, itemId: itemId),
        libraryId: libraryId,
        regionGeneration: permit.regionGeneration,
      ),
    );
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

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.runAsync(
      () => app.windowHost.close().timeout(const Duration(seconds: 5)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    app.router.dispose();
    // Flush widget-zone continuations, then close the writer in the real
    // async zone so its store-close continuation cannot wait on another pump.
    await tester.pump();
    await tester.runAsync(
      () => app.playerBindings.runtime!.history.close().timeout(
        const Duration(seconds: 5),
      ),
    );
    app.auth.dispose();
  }

  testWidgets('settings own keyboard input and Escape returns to the player', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    if (find.byKey(PlayerKeys.resumeFromStart).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(PlayerKeys.resumeFromStart));
      await settle(tester);
    }
    await tester.tap(find.byKey(PlayerKeys.more));
    await settle(tester);
    final position = backend.position;
    final playing = backend.isPlaying;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(backend.position, position);
    expect(backend.isPlaying, playing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const Key('player-settings-panel')), findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(PlayerKeys.more))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    controllerOf(tester).hideControlsOnPointerExit();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<IconButton>(find.byKey(PlayerKeys.more))
          .focusNode!
          .canRequestFocus,
      isFalse,
    );
    await disposeApp(tester);
  }, tags: ['integration']);

  test('embedded text subtitles select the container track', () async {
    _withEpisodeStreams(server, subtitleIndexById: {'movie-up': 2});
    final controller = await startStandaloneController();
    addTearDown(controller.dispose);
    expect(backend.subtitleIndex, 2);
    expect(backend.subtitleUri, isNull);
    expect(controller.trackFailure, isNull);
    expect(controller.subtitleStreamIndex, 2);
  });

  test('external text subtitles still load from the subtitle url', () async {
    _withEpisodeStreams(
      server,
      subtitleIndexById: {'movie-up': 2},
      subtitleExternal: true,
    );
    final controller = await startStandaloneController(
      userAgent: 'LineUA/subs',
    );
    addTearDown(controller.dispose);
    expect(backend.subtitleIndex, 2);
    expect(backend.subtitleUri?.scheme, 'file');
    final subtitleRequest = server.requests.indexWhere(
      (request) => request.contains('/Subtitles/2/0/Stream.ass'),
    );
    expect(subtitleRequest, isNonNegative);
    expect(server.requestUserAgents[subtitleRequest], 'LineUA/subs');
    expect(controller.trackFailure, isNull);
    expect(controller.subtitleStreamIndex, 2);
    final path = backend.subtitleUri!.toFilePath();
    expect(File(path).existsSync(), isTrue);
    await controller.disposeAsync();
    expect(File(path).existsSync(), isFalse);
  });

  test(
    'failed external subtitle download does not keep the clicked track',
    () async {
      server.subtitleStatus = 500;
      addTearDown(() => server.subtitleStatus = null);
      _withEpisodeStreams(
        server,
        subtitleIndexById: {'movie-up': 2},
        subtitleExternal: true,
      );
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      expect(controller.subtitleStreamIndex, isNull);
      expect(controller.trackFailure, isNotNull);

      controller.dismissTrackFailure();
      await controller.setSubtitle(2);
      expect(controller.subtitleStreamIndex, isNull);
      expect(backend.subtitleUri, isNull);
      expect(controller.trackFailure, isNotNull);
    },
  );

  test(
    'missing container track falls back to the extracted subtitle',
    () async {
      backend = _IndexMissBackend();
      _withEpisodeStreams(server, subtitleIndexById: {'movie-up': 2});
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      expect(backend.subtitleUri?.scheme, 'file');
      expect(
        server.requests.any(
          (request) => request.contains('/Subtitles/2/0/Stream.ass'),
        ),
        isTrue,
      );
      expect(controller.trackFailure, isNull);
      expect(controller.subtitleStreamIndex, 2);
    },
  );

  test(
    'device-rejected startup tracks are not selected and stay silent',
    () async {
      final support = _TrackSupportBackend(
        rejectedAudio: {9},
        rejectedSubtitles: {2},
      );
      backend = support;
      final movie = server.items.firstWhere((item) => item.id == 'movie-up');
      movie.mediaStreams = const [
        FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
        FakeMediaStream(
          index: 1,
          type: 'Audio',
          codec: 'aac',
          displayTitle: 'Japanese',
          isDefault: true,
        ),
        FakeMediaStream(
          index: 9,
          type: 'Audio',
          codec: 'ac3',
          displayTitle: 'Commentary',
        ),
        FakeMediaStream(
          index: 2,
          type: 'Subtitle',
          codec: 'ass',
          displayTitle: '中文',
          isDefault: true,
          isTextSubtitleStream: true,
        ),
      ];
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      expect(support.audioCalls, [1]);
      expect(support.subtitleCalls, isEmpty);
      expect(controller.audioStreamIndex, 1);
      expect(controller.subtitleStreamIndex, isNull);
      expect(controller.trackFailure, isNull);
      expect(controller.error, isNull);
      expect(controller.isPlaying, isTrue);
      expect(support.openCount, 1);

      await controller.setAudio(9);
      expect(support.audioCalls, [1]);
      expect(controller.audioStreamIndex, 1);
      expect(controller.trackFailure, isNotNull);
      expect(controller.trackFailure, isNot(contains('Bad state:')));
      expect(
        controller.trackFailure,
        isNot(contains('Unsupported media track')),
      );
      expect(controller.error, isNull);
      expect(support.openCount, 1);

      await controller.setSubtitle(2);
      expect(support.subtitleCalls, isEmpty);
      expect(controller.subtitleStreamIndex, isNull);
      expect(controller.trackFailure, isNotNull);
      expect(support.openCount, 1);

      await controller.setAudio(1);
      expect(controller.audioStreamIndex, 1);
      expect(controller.trackFailure, isNull);
      expect(support.openCount, 1);
    },
  );

  testWidgets('saved progress resumes without a continue-or-restart prompt', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');

    expect(find.text('要从上次的位置继续播放吗？'), findsNothing);
    expect(find.byKey(PlayerKeys.resumeContinue), findsNothing);
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(find.byKey(PlayerKeys.networkSpeed), findsOneWidget);
    expect(find.byKey(DanmakuKeys.menu), findsNothing);
    expect(find.text('0 KB/s'), findsOneWidget);
    expect(find.textContaining('缓存'), findsNothing);
    expect(find.byKey(PlayerKeys.volumePercent), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final volumeSlider = tester.widget<Slider>(find.byKey(PlayerKeys.volume));
    expect(volumeSlider.divisions, isNull);
    expect(volumeSlider.max, PlayerSettings.volumeMax.toDouble());
    expect(backend.openedUrl, isNotNull);
    expect(backend.openedUrl!.queryParameters['static'], 'true');
    expect(backend.openedStart, greaterThan(Duration.zero));
    final controller = controllerOf(tester);
    expect(identical(controller.client, app.auth.client), isFalse);
    expect(controller.origin!.source.itemId, 'movie-inception');
    expect(controller.origin!.libraryId, 'view-movies');
    expect(controller.origin!.permit.isValid, isTrue);
    // Source-bound startup begins the local watch session before reporting.
    // Controls readiness is intentionally earlier than that async transaction.
    for (
      var i = 0;
      i < 40 && !server.playbackEvents.any((event) => event.kind == 'Playing');
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      server.playbackEvents.map((event) => event.kind),
      contains('Playing'),
    );
    expect(
      server.playbackEvents
          .firstWhere((event) => event.kind == 'Playing')
          .body['ItemId'],
      'movie-inception',
    );
    await disposeApp(tester);
  }, tags: ['integration']);

  testWidgets('movie end shows replay card instead of a blank frame', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    backend.completePlayback(at: controllerOf(tester).duration);
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

    // 仅暂停在最后一帧而没有 completed 事件时不算播放结束。
    backend.pauseAtEndWithoutComplete(at: controllerOf(tester).duration);
    await tester.pump();
    expect(find.byKey(PlayerKeys.playbackEnded), findsNothing);
    expect(find.byKey(PlayerKeys.replay), findsNothing);
    expect(controllerOf(tester).playbackEnded, isFalse);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
    await tester.pump(PlayerController.stoppedDeadline);
    await tester.pump();
    await disposeApp(tester);
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
        onOpenItemDetail: (id, {seasonId, command}) {
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

  test('early end of file does not skip an unfinished episode', () async {
    final controller = await startStandaloneController(
      itemId: 'episode-friends-s1e1',
    );
    addTearDown(controller.dispose);
    expect(controller.duration, const Duration(minutes: 22));

    backend.emitEvent(
      VideoEventKind.position,
      const Duration(minutes: 2, seconds: 5),
    );
    backend.emitEvent(VideoEventKind.completed, true);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.itemId, 'episode-friends-s1e1');
    expect(controller.nextEpisode, isNull);
    expect(controller.playbackEnded, isFalse);
  });

  test(
    'a short probed duration does not make an early eof look finished',
    () async {
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e1',
      );
      addTearDown(controller.dispose);

      backend.emitEvent(VideoEventKind.duration, const Duration(minutes: 2));
      backend.emitEvent(
        VideoEventKind.position,
        const Duration(minutes: 2, seconds: 5),
      );
      backend.emitEvent(VideoEventKind.completed, true);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.itemId, 'episode-friends-s1e1');
      expect(controller.nextEpisode, isNull);
      expect(controller.playbackEnded, isFalse);
    },
  );

  test(
    'an opening chapter named as credits does not offer the next episode',
    () async {
      const minute = 10000000 * 60;
      final episode = server.items.firstWhere(
        (item) => item.id == 'episode-friends-s1e1',
      );
      final previous = episode.chapters;
      episode.chapters = const [
        FakeChapter(name: '片尾', startPositionTicks: 2 * minute),
      ];
      addTearDown(() => episode.chapters = previous);
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e1',
      );
      addTearDown(controller.dispose);

      backend.emitEvent(
        VideoEventKind.position,
        const Duration(minutes: 2, seconds: 5),
      );
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.nextEpisode, isNull);
      expect(controller.playbackEnded, isFalse);
    },
  );

  test('next episode overlay does not pin the seek bar', () async {
    final controller = await startStandaloneController(
      itemId: 'episode-friends-s1e1',
    );
    addTearDown(controller.dispose);
    final next = await controller.client.getItem('episode-friends-s1e2');
    controller.nextEpisode = NextEpisodeOffer(item: next);
    controller.controlsVisible = true;
    controller.hideControlsOnPointerExit();
    expect(controller.controlsVisible, isFalse);
    expect(controller.nextEpisode?.item.id, 'episode-friends-s1e2');
    controller.toggleControls();
    expect(controller.controlsVisible, isTrue);
    controller.toggleControls();
    expect(controller.controlsVisible, isFalse);
    expect(controller.nextEpisode?.item.id, 'episode-friends-s1e2');
  });

  test(
    'duplicate playing notifications do not reopen hidden controls',
    () async {
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      controller.hideControlsOnPointerExit();
      expect(controller.controlsVisible, isFalse);
      backend.emitEvent(VideoEventKind.playing, true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.controlsVisible, isFalse);
    },
  );

  test('skip intro stays visible for the whole intro after resume', () async {
    const second = 10000000;
    final episode = server.items.firstWhere(
      (item) => item.id == 'episode-friends-s1e1',
    );
    episode.played = false;
    episode.playedPercentage = 2;
    episode.playbackPositionTicks = 20 * second;
    episode.chapters = const [
      FakeChapter(
        name: 'Intro',
        startPositionTicks: 0,
        markerType: 'IntroStart',
      ),
      FakeChapter(
        name: 'Intro End',
        startPositionTicks: 90 * second,
        markerType: 'IntroEnd',
      ),
    ];
    final controller = await startStandaloneController(
      itemId: 'episode-friends-s1e1',
    );
    addTearDown(controller.dispose);
    expect(controller.activeSkipSegment?.kind, PlayerSkipKind.intro);
    expect(controller.skipPromptVisible, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.skipPromptVisible, isTrue);
  });

  test('a following episode hides skip outro', () async {
    const minute = 10000000 * 60;
    final episode = server.items.firstWhere(
      (item) => item.id == 'episode-friends-s1e1',
    );
    episode.played = false;
    episode.playbackPositionTicks = 0;
    episode.chapters = const [
      FakeChapter(name: '片尾', startPositionTicks: 20 * minute),
    ];
    final controller = await startStandaloneController(
      itemId: 'episode-friends-s1e1',
    );
    addTearDown(controller.dispose);
    backend.emitEvent(VideoEventKind.duration, const Duration(minutes: 22));
    backend.emitEvent(
      VideoEventKind.position,
      const Duration(minutes: 20, seconds: 30),
    );
    for (var i = 0; i < 30; i++) {
      if (controller.nextEpisode != null) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.nextEpisode?.item.id, 'episode-friends-s1e2');
    expect(controller.skipPromptVisible, isFalse);
  });

  test('the last episode still shows skip outro', () async {
    const minute = 10000000 * 60;
    final episode = server.items.firstWhere(
      (item) => item.id == 'episode-friends-s1e2',
    );
    episode.played = false;
    episode.playbackPositionTicks = 0;
    episode.chapters = const [
      FakeChapter(name: '片尾', startPositionTicks: 20 * minute),
    ];
    final controller = await startStandaloneController(
      itemId: 'episode-friends-s1e2',
    );
    addTearDown(controller.dispose);
    backend.emitEvent(VideoEventKind.duration, const Duration(minutes: 22));
    backend.emitEvent(
      VideoEventKind.position,
      const Duration(minutes: 20, seconds: 30),
    );
    for (var i = 0; i < 30; i++) {
      if (controller.skipPromptVisible) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.nextEpisode, isNull);
    expect(controller.activeSkipSegment?.kind, PlayerSkipKind.outro);
    expect(controller.skipPromptVisible, isTrue);
  });

  test('resuming in the last minutes still offers the next episode', () async {
    const minute = 10000000 * 60;
    final episode = server.items.firstWhere(
      (item) => item.id == 'episode-friends-s1e1',
    );
    episode.played = false;
    episode.playedPercentage = 86;
    episode.playbackPositionTicks = 19 * minute + 10 * 10000000;
    final controller = await startStandaloneController(
      itemId: 'episode-friends-s1e1',
    );
    addTearDown(controller.dispose);
    for (var i = 0; i < 50; i++) {
      if (controller.nextEpisode != null) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.nextEpisode?.item.id, 'episode-friends-s1e2');
    controller.hideControlsOnPointerExit();
    expect(controller.controlsVisible, isFalse);
  });

  test('next episode keeps subtitle language and bitrate', () async {
    _withEpisodeStreams(
      server,
      subtitleIndexById: {'episode-friends-s1e1': 2, 'episode-friends-s1e2': 4},
    );
    final current = server.items.firstWhere(
      (item) => item.id == 'episode-friends-s1e1',
    );
    current.played = false;
    current.playedPercentage = 0;
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
    expect(
      server.items
          .firstWhere((item) => item.id == 'episode-friends-s1e1')
          .played,
      isTrue,
    );
  });

  test(
    'switching episodes before the ending does not mark it played',
    () async {
      final current = server.items.firstWhere(
        (item) => item.id == 'episode-friends-s1e1',
      );
      current.played = false;
      current.playedPercentage = 0;
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e1',
      );
      addTearDown(controller.dispose);
      final next = await controller.client.getItem('episode-friends-s1e2');
      await controller.playEpisode(next);
      expect(
        server.items
            .firstWhere((item) => item.id == 'episode-friends-s1e1')
            .played,
        isFalse,
      );
    },
  );

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

  test(
    'failed quality switch restores selected quality and pause intent',
    () async {
      // Dolby audio is refused before open, so this switch must be AAC.
      _useAacSource(server);
      final failing = _FailOneOpenBackend();
      backend = failing;
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      final previous = controller.maxStreamingBitrate;
      await controller.togglePlay();
      expect(controller.isPlaying, isFalse);
      failing.failNext = true;

      await controller.setMaxBitrate(4000000);

      expect(controller.maxStreamingBitrate, previous);
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
      expect(controller.isPlaying, isFalse);
      expect(controller.trackFailure, contains('did not confirm'));
    },
  );

  test(
    'server output above requested quality restores prior selection',
    () async {
      // Dolby audio is refused before open, so this switch must be AAC.
      _useAacSource(server);
      server.forcedTranscodeOutputBitrate = 8000000;
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      await controller.seekTo(const Duration(seconds: 42));
      await controller.togglePlay();
      final previous = controller.maxStreamingBitrate;
      final opens = backend.openCount;

      await controller.setMaxBitrate(4000000);

      expect(backend.openCount, opens + 2);
      expect(controller.maxStreamingBitrate, previous);
      expect(controller.isPlaying, isFalse);
      expect(backend.openedPaused, isTrue);
      expect(backend.openedStart, const Duration(seconds: 42));
      expect(controller.error, isNull);
      expect(controller.trackFailure, contains('did not confirm'));
    },
  );

  test('unverifiable transcode cap keeps prior quality', () async {
    server.omitTranscodeOutputBitrates = true;
    final controller = await startStandaloneController();
    addTearDown(controller.dispose);
    final previous = controller.maxStreamingBitrate;

    await controller.setMaxBitrate(4000000);

    expect(controller.maxStreamingBitrate, previous);
    expect(controller.error, isNull);
    expect(controller.trackFailure, contains('did not confirm'));
  });

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
    'consecutive progress report failures escalate to a persistent dismissible banner',
    () async {
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      server.progressStatus = 500;
      addTearDown(() => server.progressStatus = null);

      // 第一次失败:仍是短暂横幅。
      await controller.seekTo(const Duration(seconds: 5));
      expect(controller.progressSyncFailed, isTrue);
      expect(controller.progressSyncPersistent, isFalse);

      // 第二次连续失败:升级为持续横幅。
      await controller.seekTo(const Duration(seconds: 8));
      expect(controller.progressSyncFailed, isTrue);
      expect(controller.progressSyncPersistent, isTrue);

      // 持续态可手动关闭,但失败计数保留:再失败仍按持续态显示。
      controller.dismissProgressSyncBanner();
      expect(controller.progressSyncFailed, isFalse);
      expect(controller.progressSyncPersistent, isTrue);
      await controller.seekTo(const Duration(seconds: 12));
      expect(controller.progressSyncFailed, isTrue);
      expect(controller.progressSyncPersistent, isTrue);

      // 任一上报成功:横幅与持续态一并复位。
      server.progressStatus = null;
      await controller.seekTo(const Duration(seconds: 20));
      expect(controller.progressSyncFailed, isFalse);
      expect(controller.progressSyncPersistent, isFalse);
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

  test(
    'stopping a session clears playing state before it can replay',
    () async {
      final controller = await startStandaloneController();
      addTearDown(controller.dispose);
      expect(controller.isPlaying, isTrue);

      await controller.shutdownSession();
      expect(controller.isPlaying, isFalse);
      expect(controller.state.phase, PlaybackPhase.idle);
      expect(backend.isPlaying, isFalse);

      await controller.replay();
      expect(controller.isPlaying, isTrue);
    },
  );

  test('disposing a live session publishes stopped state', () async {
    final controller = await startStandaloneController();
    addTearDown(controller.dispose);
    expect(controller.isPlaying, isTrue);
    final observed = <bool>[];
    controller.addListener(() => observed.add(controller.isPlaying));

    await controller.disposeAsync();

    expect(controller.isPlaying, isFalse);
    expect(observed, contains(false));
    expect(backend.isPlaying, isFalse);
    expect(controller.state.phase, PlaybackPhase.closed);
  });

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

  test('volume wheel lands on 100 instead of skipping it', () {
    expect(volumeAfterWheelNudge(91, 5), 95);
    expect(volumeAfterWheelNudge(95, 5), 100);
    expect(volumeAfterWheelNudge(96, 5), 100);
    expect(volumeAfterWheelNudge(99, 5), 100);
    expect(volumeAfterWheelNudge(100, 5), 105);
    expect(volumeAfterWheelNudge(100, -5), 95);
    expect(volumeAfterWheelNudge(91, -5), 90);
    expect(volumeAfterWheelNudge(2, -5), 0);
    expect(volumeAfterWheelNudge(148, 5), 150);
    expect(volumeAfterWheelNudge(150, 5), 150);
  });

  test('network throughput uses 1024-based units', () {
    expect(formatNetworkThroughput(0), '0 KB/s');
    expect(formatNetworkThroughput(double.nan), '0 KB/s');
    expect(formatNetworkThroughput(-8), '0 KB/s');
    expect(formatNetworkThroughput(1024), '1 KB/s');
    expect(formatNetworkThroughput(2.5 * 1024 * 1024), '2.5 MB/s');
    expect(formatNetworkThroughput(12.4 * 1024 * 1024), '12 MB/s');
  });

  testWidgets(
    'network readout uses an inbound arrow instead of a download tray',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NetworkSpeedReadout(bytesPerSecond: 2.5 * 1024 * 1024),
          ),
        ),
      );
      expect(find.byIcon(Icons.download_rounded), findsNothing);
      expect(find.byIcon(Icons.download), findsNothing);
      expect(find.byIcon(Icons.wifi), findsNothing);
      expect(find.byIcon(Icons.speed), findsNothing);
      expect(find.text('2.5 MB/s'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is InboundSpeedMarkPainter,
        ),
        findsOneWidget,
      );
    },
  );

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

  testWidgets(
    'playback settings show actual output separately from the source',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = FakeVideoBackend()
        ..isPlaying = true
        ..position = const Duration(seconds: 12)
        ..rate = 1.5;
      final controller = PlayerController(
        client: EmbyClient(device: _device),
        itemId: 'synthetic',
        backend: video,
        window: PlayerWindow(),
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(volume: 40, playbackRate: 1.25),
        ),
      );
      addTearDown(controller.dispose);
      controller.loading = false;
      controller.playbackRate = 1.25;
      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 5,
          'dolbyVisionCompatibility': 1,
          'videoOutputKind': 1,
          'doviReconstruction': 3,
          'audioDelivery': 1,
          'audioChannels': 2,
          'audioAtmos': 1,
          'catalogVideo': '杜比视界',
          'catalogAudio': 'Atmos',
          'requestedInterpolation': 2,
          'effectiveInterpolation': 0,
          'reasonInterpolation': 2,
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: PlaybackSettingsMenu(controller: controller)),
        ),
      );
      await tester.tap(find.byKey(PlayerKeys.more));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final outputSection = find.byKey(const Key('player-output-section'));
      await tester.ensureVisible(outputSection);
      await tester.tap(outputSection);
      await tester.pump();

      final source = tester
          .widget<Text>(find.byKey(const Key('playback-output-source')))
          .data!;
      final picture = tester
          .widget<Text>(find.byKey(const Key('playback-output-video')))
          .data!;
      final audio = tester
          .widget<Text>(find.byKey(const Key('playback-output-audio')))
          .data!;
      expect(source, contains('杜比视界 Profile 5'));
      expect(source, contains('基础层回退'));
      expect(picture, contains('SDR 映射'));
      expect(picture, isNot(contains('杜比')));
      expect(picture, isNot(contains('Atmos')));
      expect(audio, '实际音频输出  立体声 PCM');
      expect(find.textContaining('这项增强未运行'), findsOneWidget);
      expect(find.textContaining('倍速播放时压缩透传不可用'), findsOneWidget);
      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 5,
          'dolbyVisionCompatibility': 1,
          'videoOutputKind': 2,
          'outputColorSpace': 'BT.2020 PQ',
          'doviReconstruction': 1,
          'audioDelivery': 3,
          'audioChannels': 6,
          'audioAtmos': 0,
          'catalogVideo': '杜比视界',
          'catalogAudio': 'Atmos',
          'requestedInterpolation': 2,
          'effectiveInterpolation': 0,
          'reasonInterpolation': 4,
        }),
      );
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-video')))
            .data,
        contains('HDR（PQ）'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-video')))
            .data,
        isNot(contains('杜比视界')),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-audio')))
            .data,
        contains('6 声道 PCM'),
      );
      expect(find.textContaining('已降低生效档'), findsOneWidget);
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        contains('请求 双倍'),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        contains('生效 关闭'),
      );
      expect(find.textContaining('倍速播放时压缩透传不可用'), findsOneWidget);

      final disable = find.byKey(const Key('playback-output-disable'));
      await tester.ensureVisible(disable);
      await tester.tap(disable);
      await tester.pump();
      await tester.pump();
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      expect(video.rate, 1.5);
      expect(controller.playbackRate, 1.25);
      expect(controller.videoEnhancement.interpolation, FrameInterpolation.off);
      expect(
        (await controller.settingsStore!.read()).frameInterpolation,
        FrameInterpolation.off,
      );

      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 7,
          'dolbyVisionCompatibility': 6,
          'videoOutputKind': 3,
          'outputColorSpace': 'scRGB',
          'audioDelivery': 4,
          'audioChannels': 8,
          'audioAtmos': 0,
        }),
      );
      await tester.pump();
      final mapped = tester
          .widget<Text>(find.byKey(const Key('playback-output-video')))
          .data!;
      expect(mapped, contains('HDR（scRGB）'));
      expect(mapped, isNot(contains('原生杜比')));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-audio')))
            .data,
        contains('压缩透传'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-audio')))
            .data,
        isNot(contains('Atmos')),
      );
    },
  );

  testWidgets(
    'phone playback settings show actual output separately from the source',
    (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = FakeVideoBackend()
        ..isPlaying = true
        ..position = const Duration(seconds: 12);
      final controller = PlayerController(
        client: EmbyClient(device: _device),
        itemId: 'synthetic',
        backend: video,
        window: PlayerWindow(),
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(volume: 40, playbackRate: 1.25),
        ),
      );
      final interaction = PhonePlayerInteraction();
      addTearDown(interaction.dispose);
      addTearDown(controller.dispose);
      controller.loading = false;
      controller.isPlaying = true;
      controller.duration = const Duration(minutes: 20);
      controller.position = const Duration(seconds: 12);
      controller.playbackRate = 1.25;
      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 5,
          'dolbyVisionCompatibility': 1,
          'videoOutputKind': 1,
          'doviReconstruction': 3,
          'audioDelivery': 1,
          'audioChannels': 2,
          'audioAtmos': 1,
          'catalogVideo': '杜比视界',
          'catalogAudio': 'Atmos',
          'requestedInterpolation': 2,
          'effectiveInterpolation': 0,
          'reasonInterpolation': 2,
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: PhonePlayerControls(
              controller: controller,
              danmaku: null,
              interaction: interaction,
              onClose: () {},
              onOpenDanmakuPanel: () {},
              onOpenDanmakuSearch: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final section = find.byKey(
        const ValueKey('mobile-player-section-output'),
      );
      await tester.ensureVisible(section);
      expect(
        tester.widget<ListTile>(section).subtitle,
        isA<Text>().having((text) => text.data, 'data', contains('SDR 映射')),
      );
      expect(
        tester.widget<ListTile>(section).subtitle,
        isA<Text>().having((text) => text.data, 'data', isNot(contains('杜比'))),
      );
      await tester.tap(section);
      await tester.pump();
      final source = tester
          .widget<Text>(find.byKey(const Key('playback-output-source')))
          .data!;
      final audio = tester
          .widget<Text>(find.byKey(const Key('playback-output-audio')))
          .data!;
      expect(source, contains('杜比视界 Profile 5'));
      expect(source, contains('基础层回退'));
      expect(audio, '实际音频输出  立体声 PCM');
      expect(find.textContaining('这项增强未运行'), findsOneWidget);
      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 8,
          'dolbyVisionCompatibility': 1,
          'videoOutputKind': 2,
          'outputColorSpace': 'BT.2020 PQ',
          'audioDelivery': 3,
          'audioChannels': 6,
          'audioAtmos': 0,
          'catalogVideo': '杜比视界',
          'catalogAudio': 'Atmos',
          'requestedInterpolation': 2,
          'effectiveInterpolation': 0,
          'reasonInterpolation': 4,
        }),
      );
      await tester.pump();
      expect(find.textContaining('HDR（PQ）'), findsOneWidget);
      expect(find.textContaining('6 声道 PCM'), findsOneWidget);
      expect(find.textContaining('已降低生效档'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-video')))
            .data,
        isNot(contains('杜比')),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-source')))
            .data,
        contains('杜比视界 Profile 8'),
      );
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      expect(controller.playbackRate, 1.25);
      final disable = find.byKey(const Key('playback-output-disable'));
      await tester.ensureVisible(disable);
      await tester.tap(disable);
      await tester.pump();
      await tester.pump();
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      expect(controller.playbackRate, 1.25);
      expect(controller.videoEnhancement.interpolation, FrameInterpolation.off);
    },
  );

  test('output status reads the core target frame rate', () {
    final missing = PlaybackOutputStatus.fromCoreMap({
      'dolbyVisionProfile': 8,
      'videoOutputKind': 1,
      'audioDelivery': 1,
    });
    expect(missing.outputFrameRate, 0);
    expect(playbackFrameRateText(0), isEmpty);
    expect(playbackFrameRateText(47.952), '48');
    expect(playbackFrameRateText(59.94), '59.94');
    final doubled = PlaybackOutputStatus.fromCoreMap({
      'dolbyVisionProfile': 8,
      'videoOutputKind': 1,
      'audioDelivery': 1,
      'effectiveInterpolation': 2,
      'outputFrameRate': 47.952,
      'catalogVideo': '杜比视界',
    });
    expect(doubled.outputFrameRate, 47.952);
    expect(
      doubled
          .applying(
            const VideoEnhancementSelection(
              interpolation: FrameInterpolation.off,
              anime4k: Anime4kLevel.off,
              superResolution: SuperResolution.off,
              denoise: 0,
              sharpen: 0,
              acceptLeaveNativeDolby: false,
            ),
          )
          .outputFrameRate,
      47.952,
    );
    expect(
      playbackOutputFrameChanged(
        doubled,
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 8,
          'videoOutputKind': 1,
          'audioDelivery': 1,
          'effectiveInterpolation': 2,
          'outputFrameRate': 60,
        }),
      ),
      isTrue,
    );
    expect(playbackOutputIsNativeDolby(doubled), isFalse);
    expect(
      playbackOutputIsNativeDolby(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 5,
          'videoOutputKind': 3,
          'audioDelivery': 4,
          'outputColorSpace': 'scRGB',
        }),
      ),
      isFalse,
    );
    expect(
      playbackOutputIsNativeDolby(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 5,
          'videoOutputKind': 3,
          'audioDelivery': 4,
        }),
      ),
      isTrue,
    );
  });

  testWidgets(
    'playback settings can choose enhancement and cancel keeps the picture',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = FakeVideoBackend()
        ..isPlaying = true
        ..position = const Duration(seconds: 12)
        ..rate = 1.5;
      final controller = PlayerController(
        client: EmbyClient(device: _device),
        itemId: 'synthetic',
        backend: video,
        window: PlayerWindow(),
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(
            volume: 40,
            anime4k: Anime4kLevel.light,
            playbackRate: 1.25,
          ),
        ),
      );
      addTearDown(controller.dispose);
      controller.loading = false;
      controller.playbackRate = 1.25;
      controller.videoEnhancement = const VideoEnhancementSelection(
        interpolation: FrameInterpolation.off,
        anime4k: Anime4kLevel.light,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      );
      final nativeDolby = PlaybackOutputStatus.fromCoreMap({
        'dolbyVisionProfile': 5,
        'videoOutputKind': 3,
        'audioDelivery': 4,
        'audioChannels': 8,
        'audioAtmos': 1,
        'effectiveInterpolation': 0,
        'outputFrameRate': 24,
      });
      controller.applyObservedOutput(nativeDolby);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: PlaybackSettingsMenu(controller: controller)),
        ),
      );
      await tester.tap(find.byKey(PlayerKeys.more));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('player-output-section')));
      await tester.pump();
      expect(find.byKey(const Key('playback-enhance-choices')), findsOneWidget);
      expect(find.text('目标显示帧率 24 fps'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        isNot(contains('24 fps')),
      );

      final before = controller.outputStatus;
      final replace = find.byKey(const Key('playback-select-super-x2'));
      await tester.ensureVisible(replace);
      await tester.tap(replace);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('playback-confirm-exclusive')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('playback-confirm-exclusive-cancel')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.videoEnhancement.anime4k, Anime4kLevel.light);
      expect(controller.videoEnhancement.superResolution, SuperResolution.off);
      expect(controller.outputStatus, before);
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      expect(video.rate, 1.5);

      await tester.ensureVisible(replace);
      await tester.tap(replace);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.byKey(const Key('playback-confirm-exclusive-accept')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('playback-confirm-leave-dolby')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('playback-confirm-leave-dolby-cancel')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.videoEnhancement.anime4k, Anime4kLevel.light);
      expect(controller.videoEnhancement.superResolution, SuperResolution.off);
      expect(controller.videoEnhancement.acceptLeaveNativeDolby, isFalse);
      expect(controller.outputStatus, before);
      expect(controller.outputStatus.videoOutputKind, 3);

      final doubled = find.byKey(
        const Key('playback-select-interpolation-double'),
      );
      await tester.ensureVisible(doubled);
      await tester.tap(doubled);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.byKey(const Key('playback-confirm-leave-dolby-accept')),
      );
      await tester.pump();
      await tester.pump();
      expect(
        controller.videoEnhancement.interpolation,
        FrameInterpolation.doubleRate,
      );
      expect(controller.videoEnhancement.acceptLeaveNativeDolby, isTrue);
      expect(controller.videoEnhancement.anime4k, Anime4kLevel.light);
      expect(
        (await controller.settingsStore!.read()).frameInterpolation,
        FrameInterpolation.doubleRate,
      );
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 5,
          'videoOutputKind': 1,
          'audioDelivery': 1,
          'audioChannels': 2,
          'requestedInterpolation': 2,
          'effectiveInterpolation': 2,
          'outputFrameRate': 47.952,
        }),
      );
      await tester.pump();
      expect(find.textContaining('目标显示帧率 48 fps'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('playback-enhance-interpolation')),
            )
            .data,
        contains('生效 双倍 · 48 fps'),
      );
    },
  );

  testWidgets('phone playback panel can turn super resolution on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = FakeVideoBackend()
      ..isPlaying = true
      ..position = const Duration(seconds: 12);
    final controller = PlayerController(
      client: EmbyClient(device: _device),
      itemId: 'synthetic',
      backend: video,
      window: PlayerWindow(),
      settingsStore: MemoryPlayerSettingsStore(
        const PlayerSettings(volume: 40, sharpen: 12),
      ),
    );
    final interaction = PhonePlayerInteraction();
    addTearDown(interaction.dispose);
    addTearDown(controller.dispose);
    controller.loading = false;
    controller.isPlaying = true;
    controller.duration = const Duration(minutes: 20);
    controller.position = const Duration(seconds: 12);
    controller.videoEnhancement = const VideoEnhancementSelection(
      interpolation: FrameInterpolation.off,
      anime4k: Anime4kLevel.off,
      superResolution: SuperResolution.off,
      denoise: 0,
      sharpen: 12,
      acceptLeaveNativeDolby: false,
    );
    controller.applyObservedOutput(
      PlaybackOutputStatus.fromCoreMap({
        'dolbyVisionProfile': 0,
        'videoOutputKind': 1,
        'audioDelivery': 1,
        'audioChannels': 2,
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: PhonePlayerControls(
            controller: controller,
            danmaku: null,
            interaction: interaction,
            onClose: () {},
            onOpenDanmakuPanel: () {},
            onOpenDanmakuSearch: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('mobile-player-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final section = find.byKey(const ValueKey('mobile-player-section-output'));
    await tester.ensureVisible(section);
    await tester.tap(section);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('playback-enhance-choices')), findsOneWidget);
    final choice = find.byKey(const Key('playback-select-super-x2'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('playback-confirm-exclusive')), findsNothing);
    expect(controller.videoEnhancement.superResolution, SuperResolution.x2);
    expect(controller.videoEnhancement.sharpen, 12);
    expect(controller.outputStatus.videoOutputKind, 1);
    expect(video.isPlaying, isTrue);
    expect(video.position, const Duration(seconds: 12));
    final sharpen = tester.widget<Slider>(
      find.byKey(const Key('playback-select-sharpen')),
    );
    sharpen.onChangeEnd!(30);
    await tester.pump();
    await tester.pump();
    expect(controller.videoEnhancement.sharpen, 30);
    expect(controller.videoEnhancement.denoise, 0);
    expect(controller.videoEnhancement.superResolution, SuperResolution.x2);
    expect(video.isPlaying, isTrue);
  });

  test('closing enhancement does not clear the last effective tier', () {
    final status = PlaybackOutputStatus.fromCoreMap({
      'dolbyVisionProfile': 5,
      'videoOutputKind': 3,
      'audioDelivery': 4,
      'audioChannels': 8,
      'audioAtmos': 1,
      'requestedInterpolation': 2,
      'effectiveInterpolation': 2,
      'reasonInterpolation': 1,
    });
    final next = status.applying(
      const VideoEnhancementSelection(
        interpolation: FrameInterpolation.off,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      ),
    );
    expect(next.requestedInterpolation, 0);
    expect(next.effectiveInterpolation, 2);
    expect(next.reasonInterpolation, 1);
    expect(next.videoOutputKind, 3);
    expect(next.audioDelivery, 4);
    expect(next.audioAtmos, isTrue);
  });

  test(
    'a rejected enhancement command keeps the previous core sample',
    () async {
      final backend = _RejectingOutputBackend();
      final controller = PlayerController(
        client: EmbyClient(device: _device),
        itemId: 'synthetic',
        backend: backend,
        window: PlayerWindow(),
        settingsStore: MemoryPlayerSettingsStore(),
      );
      addTearDown(controller.dispose);
      controller.loading = false;
      controller.state.phase = PlaybackPhase.playing;
      controller.isPlaying = true;
      controller.playbackRate = 1.5;
      controller.position = const Duration(seconds: 12);
      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 7,
          'videoOutputKind': 3,
          'audioDelivery': 4,
          'audioChannels': 8,
          'audioAtmos': 1,
          'requestedInterpolation': 2,
          'effectiveInterpolation': 2,
          'reasonInterpolation': 1,
        }),
      );
      await controller.disableVideoEnhancement();
      expect(controller.outputStatus.videoOutputKind, 3);
      expect(controller.outputStatus.effectiveInterpolation, 2);
      expect(controller.outputStatus.requestedInterpolation, 2);
      expect(controller.outputStatus.audioAtmos, isTrue);
      expect(controller.videoEnhancement.interpolation, FrameInterpolation.off);
      expect(controller.isPlaying, isTrue);
      expect(controller.playbackRate, 1.5);
      expect(controller.position, const Duration(seconds: 12));
      expect(backend.position, Duration.zero);
      expect(backend.isPlaying, isFalse);
    },
  );

  test('playback retry clears overload and a repeat apply does not', () async {
    final backend = _RecordingOutputBackend();
    final controller = PlayerController(
      client: EmbyClient(device: _device),
      itemId: 'synthetic',
      backend: backend,
      window: PlayerWindow(),
      settingsStore: MemoryPlayerSettingsStore(),
    );
    addTearDown(controller.dispose);
    controller.loading = false;
    controller.state.phase = PlaybackPhase.playing;
    const selection = VideoEnhancementSelection(
      interpolation: FrameInterpolation.doubleRate,
      anime4k: Anime4kLevel.off,
      superResolution: SuperResolution.off,
      denoise: 0,
      sharpen: 0,
      acceptLeaveNativeDolby: false,
    );
    await controller.selectVideoEnhancement(selection);
    expect(backend.clearOverload, isFalse);
    expect(backend.applied?.interpolation, FrameInterpolation.doubleRate);
    await controller.retryVideoOutput();
    expect(backend.clearOverload, isTrue);
    expect(backend.applied?.interpolation, FrameInterpolation.doubleRate);
    expect(
      controller.videoEnhancement.interpolation,
      FrameInterpolation.doubleRate,
    );
    await controller.selectVideoEnhancement(selection);
    expect(backend.clearOverload, isFalse);
  });

  test('useAvailableVideoOutput does not save leaving native dolby', () async {
    final video = FakeVideoBackend()
      ..isPlaying = true
      ..position = const Duration(seconds: 12)
      ..rate = 1.5;
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(
        volume: 40,
        frameInterpolation: FrameInterpolation.doubleRate,
        denoise: 8,
        playbackRate: 1.25,
        acceptLeaveNativeDolby: false,
      ),
    );
    final controller = PlayerController(
      client: EmbyClient(device: _device),
      itemId: 'synthetic',
      backend: video,
      window: PlayerWindow(),
      settingsStore: store,
    );
    addTearDown(controller.dispose);
    controller.loading = false;
    controller.playbackRate = 1.25;
    controller.position = const Duration(seconds: 12);
    controller.isPlaying = true;
    controller.videoEnhancement = const VideoEnhancementSelection(
      interpolation: FrameInterpolation.doubleRate,
      anime4k: Anime4kLevel.off,
      superResolution: SuperResolution.off,
      denoise: 8,
      sharpen: 0,
      acceptLeaveNativeDolby: false,
    );

    Future<void> staysUnaccepted(PlaybackOutputStatus status) async {
      await controller.useAvailableVideoOutput();
      expect(controller.videoEnhancement.acceptLeaveNativeDolby, isFalse);
      expect(
        controller.videoEnhancement.interpolation,
        FrameInterpolation.doubleRate,
      );
      expect(controller.videoEnhancement.denoise, 8);
      expect(controller.outputStatus, status);
      expect(controller.playbackRate, 1.25);
      expect(controller.position, const Duration(seconds: 12));
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      expect(video.rate, 1.5);
      final saved = await store.read();
      expect(saved.acceptLeaveNativeDolby, isFalse);
      expect(saved.frameInterpolation, FrameInterpolation.doubleRate);
      expect(saved.denoise, 8);
      expect(saved.volume, 40);
    }

    await staysUnaccepted(PlaybackOutputStatus.unknown);
    final sdr = PlaybackOutputStatus.fromCoreMap({
      'dolbyVisionProfile': 0,
      'videoOutputKind': 1,
      'audioDelivery': 1,
    });
    controller.applyObservedOutput(sdr);
    await staysUnaccepted(sdr);
    final scrgb = PlaybackOutputStatus.fromCoreMap({
      'dolbyVisionProfile': 5,
      'videoOutputKind': 3,
      'audioDelivery': 4,
      'outputColorSpace': 'scRGB',
    });
    controller.applyObservedOutput(scrgb);
    await staysUnaccepted(scrgb);
    final native = PlaybackOutputStatus.fromCoreMap({
      'dolbyVisionProfile': 5,
      'videoOutputKind': 3,
      'audioDelivery': 4,
      'audioChannels': 8,
    });
    controller.applyObservedOutput(native);
    await staysUnaccepted(native);
  });

  testWidgets(
    'use available output asks before leaving a native dolby sample',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = FakeVideoBackend()
        ..isPlaying = true
        ..position = const Duration(seconds: 12)
        ..rate = 1.5;
      final store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          volume: 40,
          frameInterpolation: FrameInterpolation.doubleRate,
          denoise: 8,
          playbackRate: 1.25,
          acceptLeaveNativeDolby: false,
        ),
      );
      final controller = PlayerController(
        client: EmbyClient(device: _device),
        itemId: 'synthetic',
        backend: video,
        window: PlayerWindow(),
        settingsStore: store,
      );
      addTearDown(controller.dispose);
      controller.loading = false;
      controller.playbackRate = 1.25;
      controller.position = const Duration(seconds: 12);
      controller.isPlaying = true;
      controller.videoEnhancement = const VideoEnhancementSelection(
        interpolation: FrameInterpolation.doubleRate,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 8,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlaybackOutputPanelView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      final useAvailable = find.byKey(
        const Key('playback-output-use-available'),
      );
      Future<void> tapUseAvailable() async {
        await tester.ensureVisible(useAvailable);
        expect(tester.widget<TextButton>(useAvailable).onPressed, isNotNull);
        await tester.tap(useAvailable);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tapUseAvailable();
      expect(
        find.byKey(const Key('playback-confirm-leave-dolby')),
        findsNothing,
      );
      expect(controller.videoEnhancement.acceptLeaveNativeDolby, isFalse);
      expect(controller.outputStatus.sampled, isFalse);
      expect((await store.read()).acceptLeaveNativeDolby, isFalse);

      controller.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 8,
          'videoOutputKind': 1,
          'audioDelivery': 2,
          'audioChannels': 2,
        }),
      );
      await tester.pump();
      await tapUseAvailable();
      expect(
        find.byKey(const Key('playback-confirm-leave-dolby')),
        findsNothing,
      );
      expect(controller.videoEnhancement.acceptLeaveNativeDolby, isFalse);
      expect(controller.outputStatus.videoOutputKind, 1);
      expect(
        (await store.read()).frameInterpolation,
        FrameInterpolation.doubleRate,
      );

      final native = PlaybackOutputStatus.fromCoreMap({
        'dolbyVisionProfile': 5,
        'videoOutputKind': 3,
        'audioDelivery': 4,
        'audioChannels': 8,
        'audioAtmos': 1,
      });
      controller.applyObservedOutput(native);
      await tester.pump();
      await tapUseAvailable();
      expect(find.byKey(const Key('playback-confirm-exclusive')), findsNothing);
      expect(
        find.byKey(const Key('playback-confirm-leave-dolby')),
        findsOneWidget,
      );
      expect(find.textContaining('离开原生杜比视界'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('playback-confirm-leave-dolby-cancel')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.videoEnhancement.acceptLeaveNativeDolby, isFalse);
      expect(
        controller.videoEnhancement.interpolation,
        FrameInterpolation.doubleRate,
      );
      expect(controller.videoEnhancement.denoise, 8);
      expect(controller.outputStatus, native);
      expect(controller.playbackRate, 1.25);
      expect(controller.position, const Duration(seconds: 12));
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      expect(video.rate, 1.5);
      expect((await store.read()).acceptLeaveNativeDolby, isFalse);
      expect((await store.read()).volume, 40);

      await tapUseAvailable();
      await tester.tap(
        find.byKey(const Key('playback-confirm-leave-dolby-accept')),
      );
      await tester.pump();
      await tester.pump();
      expect(controller.videoEnhancement.acceptLeaveNativeDolby, isTrue);
      expect(
        controller.videoEnhancement.interpolation,
        FrameInterpolation.doubleRate,
      );
      expect(controller.videoEnhancement.denoise, 8);
      expect(controller.outputStatus.videoOutputKind, 3);
      expect(controller.outputStatus.audioDelivery, 4);
      expect(controller.playbackRate, 1.25);
      expect(controller.position, const Duration(seconds: 12));
      expect(video.isPlaying, isTrue);
      expect(video.position, const Duration(seconds: 12));
      final saved = await store.read();
      expect(saved.acceptLeaveNativeDolby, isTrue);
      expect(saved.frameInterpolation, FrameInterpolation.doubleRate);
      expect(saved.denoise, 8);
      expect(saved.volume, 40);
    },
  );
}

void _withEpisodeStreams(
  FakeEmbyServer server, {
  required Map<String, int> subtitleIndexById,
  bool subtitleExternal = false,
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
        isExternal: subtitleExternal,
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

class _IndexMissBackend extends FakeVideoBackend {
  @override
  Future<void> setSubtitleIndex(int index) async {
    throw StateError('Requested sub track is unavailable');
  }
}

class _TrackSupportBackend extends FakeVideoBackend
    implements VideoBackendTrackSupport {
  _TrackSupportBackend({
    this.rejectedAudio = const {},
    this.rejectedSubtitles = const {},
  });

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
