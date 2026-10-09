import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/playback_state.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight test',
  deviceName: 'recovery',
  deviceId: 'recovery-test',
  version: '0.1.0',
);

void _addMovieSubtitles(FakeEmbyServer server) {
  final movie = server.items.firstWhere((item) => item.id == 'movie-up');
  movie.mediaStreams = const [
    FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
    FakeMediaStream(index: 1, type: 'Audio', codec: 'aac'),
    FakeMediaStream(
      index: 2,
      type: 'Subtitle',
      codec: 'subrip',
      language: 'chi',
      isDefault: true,
      isTextSubtitleStream: true,
    ),
    FakeMediaStream(
      index: 3,
      type: 'Subtitle',
      codec: 'subrip',
      language: 'eng',
      isTextSubtitleStream: true,
    ),
  ];
  movie.extraSources = [
    // Identical labels prove that reopening restores the exact source ID.
    FakeMediaSource(
      id: 'alternate',
      name: movie.name,
      mediaStreams: movie.mediaStreams,
    ),
  ];
}

class _RecoveryBackend extends FakeVideoBackend
    implements VideoBackendSourceRenewal {
  final renewedUrls = <Uri>[];
  @override
  Future<void> refreshSourceUrl(Uri url) async => renewedUrls.add(url);
  Completer<void>? stopGate;
  Completer<void>? openGate;
  String? rejectedSource;
  final openDelays = <String, Duration>{};
  bool rejectNextVolume = false;
  bool selectDefaultAudioOnOpen = false;
  int audioSelections = 0;
  final restoreGates = <String, Completer<void>>{};
  int stopCount = 0;
  int openBegins = 0;
  int activeOpens = 0;
  int maxConcurrentOpens = 0;
  final List<String> nativeOrder = [];
  final List<double> volumeCommands = [];
  final List<double> rateCommands = [];
  Object? seekFailure;
  Completer<void>? seekGate;
  bool cancelSeekOnStop = true;

  @override
  Future<void> seek(Duration value) async {
    final failure = seekFailure;
    final gate = seekGate;
    if (failure == null && gate == null) return super.seek(value);
    emitEvent(VideoEventKind.buffering, true);
    emitEvent(VideoEventKind.playing, false);
    await gate?.future;
    if (failure != null) throw failure;
    await super.seek(value);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final gate = seekGate;
    if (cancelSeekOnStop && gate != null && !gate.isCompleted) {
      gate.complete();
    }
    await stopGate?.future;
    await super.stop();
    nativeOrder.add('stop');
  }

  @override
  Future<void> open(VideoOpenRequest request) async {
    final openNumber = ++openBegins;
    nativeOrder.add('open-start-$openNumber');
    activeOpens++;
    if (activeOpens > maxConcurrentOpens) {
      maxConcurrentOpens = activeOpens;
    }
    try {
      await openGate?.future;
      final delay = openDelays[request.url.queryParameters['MediaSourceId']];
      if (delay != null) await Future<void>.delayed(delay);
      if (request.url.queryParameters['MediaSourceId'] == rejectedSource) {
        throw StateError('Source rejected');
      }
      await super.open(request);
      if (selectDefaultAudioOnOpen) {
        audioIndex = request.mediaStreams
            .where((stream) => stream.type == 'Audio')
            .firstOrNull
            ?.index;
      }
    } finally {
      activeOpens--;
      nativeOrder.add('open-end-$openNumber');
    }
  }

  @override
  Future<void> setVolume(double value) async {
    volumeCommands.add(value);
    await restoreGates['volume']?.future;
    if (rejectNextVolume) {
      rejectNextVolume = false;
      throw StateError('Volume restore failed');
    }
    await super.setVolume(value);
  }

  @override
  Future<void> setRate(double value) async {
    rateCommands.add(value);
    await restoreGates['rate']?.future;
    await super.setRate(value);
  }

  @override
  Future<void> setAudioIndex(int index) async {
    audioSelections++;
    await super.setAudioIndex(index);
  }
}

class _DelayedSettingsStore extends MemoryPlayerSettingsStore {
  Completer<void>? readGate;
  int reads = 0;

  @override
  Future<PlayerSettings> read() async {
    reads++;
    final snapshot = await super.read();
    await readGate?.future;
    return snapshot;
  }
}

void main() {
  late FakeEmbyServer server;
  late _RecoveryBackend backend;
  late PlayerController controller;
  late _DelayedSettingsStore settings;
  Completer<void>? metadataGate;
  Completer<void>? catalogGate;

  setUp(() async {
    server = FakeEmbyServer();
    final movie = server.items.firstWhere((item) => item.id == 'movie-up');
    movie.extraSources = const [
      FakeMediaSource(id: 'alternate', name: 'Alternate'),
    ];
    backend = _RecoveryBackend();
    settings = _DelayedSettingsStore();
    final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path.contains('/PlaybackInfo')) {
            await metadataGate?.future;
          }
          if (options.path.contains('/Items/missing')) {
            await catalogGate?.future;
          }
          handler.next(options);
        },
      ),
    );
    final client = EmbyClient(device: _device, dio: dio);
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
    controller = PlayerController(
      client: client,
      itemId: 'movie-up',
      backend: backend,
      window: PlayerWindow(),
      recoveryTimeout: const Duration(milliseconds: 300),
      seekTimeout: const Duration(milliseconds: 40),
      disposeTimeout: const Duration(milliseconds: 50),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      settingsStore: settings,
    );
    await controller.start();
    addTearDown(() async {
      if (settings.readGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      settings.readGate = null;
      for (final gate in backend.restoreGates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      backend.restoreGates.clear();
      if (backend.stopGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      backend.stopGate = null;
      if (backend.openGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      backend.openGate = null;
      if (backend.seekGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      backend.seekGate = null;
      if (metadataGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      metadataGate = null;
      if (catalogGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      catalogGate = null;
      if (server.sessionsHold case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      server.sessionsHold = null;
      await controller.disposeAsync();
      controller.dispose();
    });
  });

  for (final paused in [false, true]) {
    test(
      'next episode intro seek failure recovers with paused=$paused',
      () async {
        final episode = server.items.firstWhere(
          (i) => i.id == 'episode-friends-s1e2',
        );
        episode.chapters = const [
          FakeChapter(
            name: 'Intro',
            startPositionTicks: 0,
            markerType: 'IntroStart',
          ),
          FakeChapter(
            name: 'Intro End',
            startPositionTicks: 1140000000,
            markerType: 'IntroEnd',
          ),
        ];
        controller.nextEpisode = NextEpisodeOffer(
          item: await controller.client.getItem(episode.id),
        );
        await controller.playNextEpisode();
        expect(controller.loading, isFalse);
        expect(controller.isPlaying, isTrue);
        if (paused) await controller.togglePlay();
        expect(controller.activeSkipSegment, isNotNull);
        final opened = backend.openCount;
        backend.seekFailure = TimeoutException('Core did not confirm seek');
        await controller.skipCurrentSegment();
        expect(backend.openCount, opened + 1);
        expect(backend.openedStart, const Duration(seconds: 114));
        expect(backend.openedPaused, paused);
        expect(controller.itemId, episode.id);
        expect(controller.loading, isFalse);
        expect(controller.isRecovering, isFalse);
        expect(controller.error, isNull);
        expect(controller.state.buffering, isFalse);
        expect(controller.isPlaying, !paused);
      },
    );
  }

  test(
    'failed seek recovery terminates with a retryable error if reopen fails',
    () async {
      backend.seekFailure = StateError('Core command failed');
      backend.rejectedSource = 'movie-up';
      final opened = backend.openBegins;
      await controller.seekTo(const Duration(seconds: 114));
      expect(backend.openBegins, opened + 1);
      expect(controller.loading, isFalse);
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.error, isNotNull);
      expect(controller.state.buffering, isFalse);
      backend.rejectedSource = null;
      await controller.retryPlayback();
      expect(controller.error, isNull);
    },
  );

  test(
    'seek without a reply is cancelled before reopening at its target',
    () async {
      backend.seekGate = Completer<void>();
      final opened = backend.openCount;
      await controller.seekTo(const Duration(seconds: 114));
      expect(backend.seekGate!.isCompleted, isTrue);
      expect(backend.openCount, opened + 1);
      expect(backend.openedStart, const Duration(seconds: 114));
      expect(controller.isPlaying, isTrue);
      expect(controller.error, isNull);
    },
  );

  test(
    'unretired seek fails boundedly without opening a second native session',
    () async {
      backend.seekGate = Completer<void>();
      backend.cancelSeekOnStop = false;
      final opened = backend.openBegins;
      await controller
          .seekTo(const Duration(seconds: 114))
          .timeout(const Duration(seconds: 2));
      expect(backend.openBegins, opened);
      expect(controller.loading, isFalse);
      expect(controller.isRecovering, isFalse);
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.disconnectDetail, contains('timed out during stop'));
      expect(controller.state.buffering, isFalse);
    },
  );

  test(
    'a newer seek supersedes a delayed seek failure in the same episode',
    () async {
      final gate = Completer<void>();
      backend.seekGate = gate;
      backend.seekFailure = TimeoutException('Old seek');
      final opened = backend.openCount;
      final old = controller.seekTo(const Duration(seconds: 114));
      await Future<void>.delayed(Duration.zero);
      backend.seekGate = null;
      backend.seekFailure = null;
      final latest = controller.seekTo(const Duration(seconds: 180));
      gate.complete();
      await Future.wait([old, latest]);
      expect(backend.openCount, opened);
      expect(controller.position, const Duration(seconds: 180));
      expect(controller.error, isNull);
    },
  );

  test('a delayed seek failure cannot reopen a superseded episode', () async {
    final gate = Completer<void>();
    backend.seekGate = gate;
    backend.seekFailure = TimeoutException('Old episode');
    final opened = backend.openCount;
    controller.nextEpisode = NextEpisodeOffer(
      item: await controller.client.getItem('episode-friends-s1e2'),
    );
    final old = controller.seekTo(const Duration(seconds: 114));
    await Future<void>.delayed(Duration.zero);
    final next = controller.playNextEpisode();
    await Future.wait([old, next]);
    expect(backend.openCount, opened + 1);
    expect(controller.itemId, 'episode-friends-s1e2');
    expect(backend.openedStart, Duration.zero);
    expect(controller.error, isNull);
  });

  for (final selectedSubtitle in <int?>[null, 3]) {
    test(
      'movie reopening restores its exact source and subtitle $selectedSubtitle',
      () async {
        _addMovieSubtitles(server);
        await controller.start();
        expect(controller.subtitleStreamIndex, 2);
        await controller.switchMediaVersion('alternate');
        await controller.setSubtitle(selectedSubtitle);
        final saved = PlayerSettings.fromJson((await settings.read()).toJson());
        expect(saved.itemPreferences.values.single.mediaSourceId, 'alternate');
        final reopened = PlayerController(
          client: controller.client,
          itemId: 'movie-up',
          backend: _RecoveryBackend(),
          window: PlayerWindow(),
          snapshotStore: MemoryPlaybackSessionSnapshotStore(),
          settingsStore: MemoryPlayerSettingsStore(saved),
        );
        try {
          await reopened.start();
          expect(reopened.activeMediaSourceId, 'alternate');
          expect(reopened.subtitleStreamIndex, selectedSubtitle);
          expect(reopened.error, isNull);
        } finally {
          await reopened.disposeAsync();
          reopened.dispose();
        }
      },
    );
  }

  test(
    'an explicit subtitle choice overrides remembered subtitle off',
    () async {
      _addMovieSubtitles(server);
      await controller.start();
      expect(controller.subtitleStreamIndex, 2);
      await controller.setSubtitle(null);
      final reopened = PlayerController(
        client: controller.client,
        itemId: 'movie-up',
        preferredSubtitleStreamIndex: 2,
        backend: _RecoveryBackend(),
        window: PlayerWindow(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(await settings.read()),
      );
      try {
        await reopened.start();
        expect(reopened.subtitleStreamIndex, 2);
        expect(reopened.error, isNull);
      } finally {
        await reopened.disposeAsync();
        reopened.dispose();
      }
    },
  );

  test(
    'slow source switch uses the open budget after retiring the old session',
    () async {
      final freshBackend = _RecoveryBackend();
      final fresh = PlayerController(
        client: controller.client,
        itemId: 'movie-up',
        backend: freshBackend,
        window: PlayerWindow(),
        recoveryTimeout: const Duration(milliseconds: 40),
        recoveryOpenTimeout: const Duration(seconds: 2),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      );
      final gate = Completer<void>();
      try {
        await fresh.start();
        freshBackend.openGate = gate;
        final switchWork = fresh.switchMediaVersion('alternate');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(fresh.isRecovering, isTrue);
        expect(fresh.error, isNull);
        gate.complete();
        await switchWork;
        expect(fresh.activeMediaSourceId, 'alternate');
        expect(fresh.isPlaying, isTrue);
        expect(fresh.error, isNull);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await fresh.disposeAsync();
        fresh.dispose();
      }
    },
  );

  test(
    'restoring the previous source gets its own bounded open budget',
    () async {
      final restoringBackend = _RecoveryBackend();
      final restoring = PlayerController(
        client: controller.client,
        itemId: 'movie-up',
        backend: restoringBackend,
        window: PlayerWindow(),
        recoveryTimeout: const Duration(seconds: 1),
        recoveryOpenTimeout: const Duration(milliseconds: 350),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      );
      try {
        await restoring.start();
        restoringBackend.rejectedSource = 'alternate';
        restoringBackend.openDelays.addAll({
          'alternate': const Duration(milliseconds: 220),
          'movie-up': const Duration(milliseconds: 220),
        });
        await restoring.switchMediaVersion('alternate');
        expect(restoring.activeMediaSourceId, 'movie-up');
        expect(restoring.isPlaying, isTrue);
        expect(restoring.error, isNull);
        expect(restoring.isRecovering, isFalse);
        expect(restoring.trackFailure, contains('previous source restored'));
        expect(restoringBackend.maxConcurrentOpens, 1);
      } finally {
        await restoring.disposeAsync();
        restoring.dispose();
      }
    },
  );

  test(
    'local version switches immediately at the current position without preflight',
    () async {
      await controller.seekTo(const Duration(seconds: 35));
      final requests = server.requests
          .where((r) => r.contains('/PlaybackInfo'))
          .length;
      final opens = backend.openCount;
      await controller.switchMediaVersion('alternate');
      expect(controller.switchConfirmation, isNull);
      expect(controller.activeMediaSourceId, 'alternate');
      expect(backend.openCount, opens + 1);
      expect(backend.openedStart, const Duration(seconds: 35));
      expect(
        server.requests.where((r) => r.contains('/PlaybackInfo')).length,
        requests + 1,
      );
      expect(controller.error, isNull);
    },
  );

  test(
    'local version uses target audio default and disables unmatched subtitles',
    () async {
      server.items
          .firstWhere((item) => item.id == 'movie-up')
          .extraSources = const [
        FakeMediaSource(
          id: 'alternate',
          name: 'Alternate',
          mediaStreams: [
            FakeMediaStream(
              index: 9,
              type: 'Audio',
              codec: 'aac',
              isDefault: true,
            ),
          ],
        ),
      ];
      await controller.start();
      await controller.seekTo(const Duration(seconds: 35));
      await controller.togglePlay();
      await controller.switchMediaVersion('alternate');
      expect(controller.switchConfirmation, isNull);
      expect(controller.audioStreamIndex, 9);
      expect(controller.subtitleStreamIndex, isNull);
      expect(backend.openedStart, const Duration(seconds: 35));
      expect(backend.isPlaying, isFalse);
      expect(controller.error, isNull);
    },
  );

  test(
    'recovery keeps a confirmed audio track without selecting it again',
    () async {
      backend.selectDefaultAudioOnOpen = true;
      final selections = backend.audioSelections;
      await controller.retryPlayback();
      expect(controller.error, isNull);
      expect(controller.loading, isFalse);
      expect(controller.audioStreamIndex, backend.selectedAudioIndex);
      expect(backend.selectedAudioIndex, isNotNull);
      expect(backend.audioSelections, selections);
    },
  );

  for (final selectedRate in [1.0, 1.5]) {
    test(
      'an earlier settings read does not replace loading user choices at $selectedRate',
      () async {
        await settings.write(
          const PlayerSettings(volume: 20, playbackRate: .75),
        );
        settings.readGate = Completer<void>();
        final reads = settings.reads;
        final restart = controller.start();
        for (
          var attempt = 0;
          settings.reads == reads && attempt < 50;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(settings.reads, greaterThan(reads));
        await controller
            .setVolume(65)
            .timeout(const Duration(milliseconds: 100));
        await controller
            .setRate(selectedRate)
            .timeout(const Duration(milliseconds: 100));
        settings.readGate!.complete();
        settings.readGate = null;
        await restart;
        expect(controller.volume, 65);
        expect(controller.playbackRate, selectedRate);
        expect(backend.volume, mpvVolumeForPercent(65));
        expect(backend.rate, selectedRate);
      },
    );
  }

  test(
    'loading volume and rate changes wait for the open to complete',
    () async {
      backend.openGate = Completer<void>();
      final recovery = controller.switchMediaSource('alternate');
      for (
        var attempt = 0;
        backend.activeOpens == 0 && attempt < 50;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(backend.activeOpens, 1);
      final volumes = backend.volumeCommands.length;
      final rates = backend.rateCommands.length;
      await controller.setVolume(65).timeout(const Duration(milliseconds: 100));
      await controller.setRate(1.5).timeout(const Duration(milliseconds: 100));
      expect(controller.volume, 65);
      expect(controller.playbackRate, 1.5);
      expect(backend.volumeCommands.length, volumes);
      expect(backend.rateCommands.length, rates);
      backend.openGate!.complete();
      backend.openGate = null;
      await recovery;
      expect(backend.volume, mpvVolumeForPercent(65));
      expect(backend.rate, 1.5);
      expect(controller.error, isNull);
    },
  );

  test(
    'expired source renewal keeps the decoder position and playback intent',
    () async {
      final opens = backend.openCount;
      final position = controller.position;
      backend.emitEvent(VideoEventKind.sourceRefreshRequired, 403);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (backend.renewedUrls.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(backend.renewedUrls, hasLength(1));
      expect(backend.openCount, opens);
      expect(controller.position, position);
      expect(controller.isPlaying, isTrue);
      expect(controller.disconnected, isFalse);
    },
  );

  test(
    'missing original language needs explicit default audio acceptance',
    () async {
      final oldAudio = controller.audioStreamIndex;
      server.items
          .firstWhere((item) => item.id == 'movie-up')
          .extraSources = const [
        FakeMediaSource(
          id: 'alternate',
          name: 'Alternate',
          mediaStreams: [
            FakeMediaStream(
              index: 9,
              type: 'Audio',
              codec: 'aac',
              isDefault: true,
            ),
          ],
        ),
      ];
      final opens = backend.openCount;
      await controller.switchMediaSource('alternate');
      expect(controller.switchConfirmation?.audioNeedsChoice, isTrue);
      expect(backend.openCount, opens);
      await expectLater(
        controller.confirmMediaSourceSwitch(SwitchResumeChoice.currentPosition),
        throwsStateError,
      );
      await controller.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
        acceptDefaultAudio: true,
        turnSubtitlesOff: true,
      );
      expect(oldAudio, isNot(9));
      expect(controller.audioStreamIndex, 9);
      expect(controller.trackFailure, isNull);
      expect(controller.error, isNull);
      expect(controller.canSwitchAudioTrack, isFalse);
    },
  );

  test(
    'retry announces recovery before a blocked stop and coalesces taps',
    () async {
      final opens = backend.openCount;
      backend.stopGate = Completer<void>();
      final first = controller.retryPlayback();
      expect(controller.isRecovering, isTrue);
      expect(controller.loading, isTrue);
      expect(controller.state.phase, PlaybackPhase.loading);
      final second = controller.retryPlayback();
      expect(backend.stopCount, 2); // startup plus the immediate retry stop
      backend.stopGate!.complete();
      backend.stopGate = null;
      await Future.wait([first, second]);
      expect(backend.openCount, opens + 1);
      expect(controller.isRecovering, isFalse);
      expect(controller.state.phase, isNot(PlaybackPhase.failed));
    },
  );

  test(
    'deadline fails visibly and does not reuse an unretired native handle',
    () async {
      backend.stopGate = Completer<void>();
      final opens = backend.openCount;
      await controller.retryPlayback();
      expect(controller.loading, isFalse);
      expect(controller.isRecovering, isFalse);
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.disconnectDetail, contains('timed out'));
      await controller.retryPlayback();
      expect(backend.openCount, opens);
      expect(controller.disconnectDetail, contains('still being released'));
      backend.stopGate!.complete();
      backend.stopGate = null;
    },
  );

  test(
    'source is pending until success and failed source restores once',
    () async {
      final original = controller.activeMediaSourceId;
      final opens = backend.openCount;
      backend.openGate = Completer<void>();
      final switchFuture = controller.switchMediaSource('alternate');
      for (var i = 0; controller.pendingMediaSourceId == null && i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(controller.pendingMediaSourceId, 'alternate');
      expect(controller.activeMediaSourceId, original);
      backend.openGate!.complete();
      backend.openGate = null;
      await switchFuture;
      expect(controller.activeMediaSourceId, 'alternate');
      expect(controller.pendingMediaSourceId, isNull);
      expect(backend.openCount, opens + 1);

      backend.rejectedSource = original;
      await controller.switchMediaSource(original!);
      expect(controller.activeMediaSourceId, 'alternate');
      expect(controller.state.phase, isNot(PlaybackPhase.failed));
      expect(controller.trackFailure, contains('previous source restored'));
      expect(backend.openCount, opens + 2);
    },
  );

  test(
    'late open after deadline cannot commit or survive native retirement',
    () async {
      backend.openGate = Completer<void>();
      final source = controller.activeMediaSourceId;
      final attempt = controller.switchMediaSource('alternate');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await attempt;
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.activeMediaSourceId, source);
      expect(controller.pendingMediaSourceId, isNull);
      final opens = backend.openCount;
      await controller.retryPlayback();
      expect(backend.openCount, opens);
      backend.openGate!.complete();
      backend.openGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.activeMediaSourceId, source);
      expect(backend.isPlaying, isFalse);
    },
  );

  test('blocked report and metadata share the recovery deadline', () async {
    server.sessionsHold = Completer<void>();
    final first = controller.retryPlayback();
    expect(controller.loading, isTrue);
    await first;
    expect(controller.disconnectDetail, contains('during stop'));
    server.sessionsHold!.complete();
    server.sessionsHold = null;

    metadataGate = Completer<void>();
    final opens = backend.openCount;
    final second = controller.retryPlayback();
    expect(controller.loading, isTrue);
    await second;
    expect(controller.disconnectDetail, contains('during metadata'));
    metadataGate!.complete();
    metadataGate = null;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(backend.openCount, opens);
  });

  test(
    'initial catalog retry announces loading and expires at the deadline',
    () async {
      final freshBackend = _RecoveryBackend();
      final fresh = PlayerController(
        client: controller.client,
        itemId: 'missing',
        backend: freshBackend,
        window: PlayerWindow(),
        recoveryTimeout: const Duration(milliseconds: 80),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      );
      addTearDown(() async {
        await fresh.disposeAsync();
        fresh.dispose();
      });
      await fresh.start();
      expect(fresh.error, PlayerErrorKind.load);
      catalogGate = Completer<void>();
      final attempt = fresh.retryPlayback();
      expect(fresh.isRecovering, isTrue);
      expect(fresh.loading, isTrue);
      await attempt;
      expect(fresh.state.phase, PlaybackPhase.failed);
      expect(fresh.disconnectDetail, contains('catalog metadata'));
      catalogGate!.complete();
      catalogGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(freshBackend.openCount, 0);
    },
  );

  test(
    'out-of-range switch requires beginning or cancel, never clamps',
    () async {
      final movie = server.items.firstWhere((item) => item.id == 'movie-up');
      movie.runTimeTicks = 30 * 10000000;
      movie.extraSources = const [
        FakeMediaSource(
          id: 'alternate',
          name: 'Alternate',
          mediaStreams: [
            FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
            FakeMediaStream(
              index: 5,
              type: 'Audio',
              codec: 'aac',
              isDefault: true,
            ),
          ],
        ),
      ];
      await backend.seek(const Duration(minutes: 5));
      await Future<void>.delayed(Duration.zero);
      final original = controller.activeMediaSourceId;
      final opens = backend.openCount;
      await controller.switchMediaSource('alternate');
      expect(controller.switchConfirmation?.canTryCurrentPosition, isFalse);
      expect(controller.activeMediaSourceId, original);
      expect(backend.openCount, opens);
      await expectLater(
        controller.confirmMediaSourceSwitch(
          SwitchResumeChoice.currentPosition,
          acceptDefaultAudio: true,
          turnSubtitlesOff: true,
        ),
        throwsStateError,
      );
      await controller.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
      expect(controller.switchConfirmation, isNull);
      expect(controller.activeMediaSourceId, original);
      expect(backend.openCount, opens);
      await controller.switchMediaSource('alternate');
      await controller.confirmMediaSourceSwitch(
        SwitchResumeChoice.beginning,
        acceptDefaultAudio: true,
        turnSubtitlesOff: true,
      );
      expect(backend.openedStart, Duration.zero);
      expect(controller.audioStreamIndex, 5);
      expect(controller.activeMediaSourceId, 'alternate');
    },
  );

  test(
    'timeline confirmation preserves pause and cancel keeps native mounted',
    () async {
      await controller.togglePlay();
      await backend.seek(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      final original = controller.activeMediaSourceId;
      final opens = backend.openCount;
      final stops = backend.stopCount;
      await controller.switchMediaSource('alternate');
      final plan = controller.switchConfirmation!;
      expect(plan.timelineConfirmed, isFalse);
      expect(plan.positionTicks, 10 * 10000000);
      expect(plan.paused, isTrue);
      expect(backend.openCount, opens);
      expect(backend.stopCount, stops);
      await controller.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
      expect(controller.activeMediaSourceId, original);
      expect(backend.stopCount, stops);
      expect(controller.isPlaying, isFalse);
      await controller.switchMediaSource('alternate');
      await controller.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
      );
      expect(backend.openedStart, const Duration(seconds: 10));
      expect(controller.isPlaying, isFalse);
      expect(controller.activeMediaSourceId, 'alternate');
    },
  );

  test(
    'failed target and failed original restore do not choose a third version',
    () async {
      server.items.firstWhere((i) => i.id == 'movie-up').extraSources = const [
        FakeMediaSource(id: 'alternate', name: 'Alternate'),
        FakeMediaSource(id: 'third', name: 'Unselected'),
      ];
      backend.rejectNextVolume = true;
      backend.rejectedSource = controller.activeMediaSourceId;
      await controller.switchMediaSource('alternate');
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.activeMediaSourceId, isNot('third'));
      expect(backend.openedUrl?.queryParameters['MediaSourceId'], 'alternate');
    },
  );

  test(
    'retry retires a pending confirmation without starting that target',
    () async {
      await backend.seek(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      final original = controller.activeMediaSourceId;
      await controller.switchMediaSource('alternate');
      expect(controller.switchConfirmation, isNotNull);
      await controller.retryPlayback();
      expect(controller.switchConfirmation, isNull);
      await controller.confirmMediaSourceSwitch(SwitchResumeChoice.beginning);
      expect(controller.activeMediaSourceId, original);
    },
  );

  test('a newer recovery intent invalidates blocked source metadata', () async {
    metadataGate = Completer<void>();
    final original = controller.activeMediaSourceId;
    final opens = backend.openCount;
    final sourceAttempt = controller.switchMediaSource('alternate');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final retry = controller.retryPlayback();
    expect(controller.isRecovering, isTrue);
    expect(controller.pendingMediaSourceId, isNull);
    metadataGate!.complete();
    metadataGate = null;
    await Future.wait([sourceAttempt, retry]);
    expect(controller.activeMediaSourceId, original);
    expect(backend.openCount, opens + 1);
    expect(backend.openedUrl?.queryParameters['MediaSourceId'], original);
  });

  test(
    'source does not commit when a required playback setting fails',
    () async {
      final original = controller.activeMediaSourceId;
      backend.rejectNextVolume = true;
      await controller.switchMediaSource('alternate');
      expect(controller.activeMediaSourceId, original);
      expect(controller.state.phase, isNot(PlaybackPhase.failed));
      expect(controller.trackFailure, contains('previous source restored'));
    },
  );

  for (final parameter in ['volume', 'rate']) {
    test(
      'recovery timeout identifies the blocked $parameter command',
      () async {
        backend.restoreGates[parameter] = Completer<void>();
        await controller.retryPlayback();
        expect(controller.state.phase, PlaybackPhase.failed);
        expect(
          controller.disconnectDetail,
          contains(
            parameter == 'volume' ? 'restore volume' : 'restore playback rate',
          ),
        );
        backend.restoreGates[parameter]!.complete();
        backend.restoreGates.clear();
      },
    );
  }

  test('close during recovery prevents a late source commit', () async {
    backend.openGate = Completer<void>();
    final source = controller.activeMediaSourceId;
    final attempt = controller.switchMediaSource('alternate');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final close = controller.close();
    backend.openGate!.complete();
    backend.openGate = null;
    await Future.wait([attempt, close]);
    expect(controller.activeMediaSourceId, source);
    expect(controller.state.phase, PlaybackPhase.closed);
  });

  test(
    'suspend timeout waits for old open to retire before foreground open',
    () async {
      backend.openGate = Completer<void>();
      final retry = controller.retryPlayback();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (backend.openBegins < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(backend.openBegins, 2);

      await controller.suspendPlayback().timeout(const Duration(seconds: 1));
      expect(controller.backgroundReleased, isTrue);
      expect(controller.state.phase, PlaybackPhase.failed);
      expect(controller.disconnectDetail, contains('still being released'));
      await controller.retryPlayback();
      expect(backend.openBegins, 2);

      var restored = false;
      final foreground = controller.restorePlayback().then((_) {
        restored = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(restored, isFalse);
      expect(backend.openBegins, 2);
      backend.openGate!.complete();
      backend.openGate = null;
      await Future.wait([
        retry,
        foreground,
      ]).timeout(const Duration(seconds: 2));
      expect(backend.openBegins, 3);
      expect(backend.maxConcurrentOpens, 1);
      final oldOpenEnd = backend.nativeOrder.indexOf('open-end-2');
      final foregroundOpenStart = backend.nativeOrder.indexOf('open-start-3');
      expect(oldOpenEnd, isNonNegative);
      expect(foregroundOpenStart, greaterThan(oldOpenEnd));
      expect(
        backend.nativeOrder.sublist(oldOpenEnd + 1, foregroundOpenStart),
        contains('stop'),
      );
      expect(controller.backgroundReleased, isFalse);
      expect(backend.openedPaused, isTrue);
      expect(backend.isPlaying, isFalse);
    },
  );

  test(
    'a second background transition cancels the older foreground return',
    () async {
      backend.openGate = Completer<void>();
      final retry = controller.retryPlayback();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (backend.openBegins < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(backend.openBegins, 2);
      await controller.suspendPlayback();
      final oldForeground = controller.restorePlayback();
      await controller.suspendPlayback();
      final newForeground = controller.restorePlayback();
      backend.openGate!.complete();
      backend.openGate = null;
      await Future.wait([retry, oldForeground, newForeground]);
      expect(backend.openBegins, 3);
      expect(backend.maxConcurrentOpens, 1);
      expect(controller.backgroundReleased, isFalse);
    },
  );
}
