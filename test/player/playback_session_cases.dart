import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/playback_state.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'session-test',
  version: '1',
);

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue, reason: 'Expected controlled operation to start');
}

Future<void> _untilElapsed(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: 'Expected controlled operation to start');
}

void main() {
  late _ControlledClient client;
  late _ControlledBackend backend;
  late PlayerController controller;
  late MemoryPlaybackSessionSnapshotStore snapshots;
  late MemoryPlayerSettingsStore settings;
  var closed = 0;

  setUp(() async {
    final server = FakeEmbyServer();
    client = _ControlledClient(FakeEmbyAdapter([server]));
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
    backend = _ControlledBackend();
    snapshots = MemoryPlaybackSessionSnapshotStore();
    settings = MemoryPlayerSettingsStore();
    closed = 0;
    controller = PlayerController(
      client: client,
      itemId: 'movie-up',
      backend: backend,
      window: PlayerWindow(),
      settingsStore: settings,
      snapshotStore: snapshots,
      stoppedTimeout: const Duration(milliseconds: 10),
      onClose: () => closed++,
    );
  });

  tearDown(() async {
    client.release();
    backend.release();
    await controller.disposeAsync();
    controller.dispose();
  });

  EmbyItem episode(String id) =>
      EmbyItem.fromJson({'Id': id, 'Type': 'Episode', 'Name': id});

  // 同一后台释放/恢复旅程的两个断言面合并:先验证正常恢复,
  // 再在同一控制器上验证换凭据后恢复被拒绝。
  test(
    'background release stops once, restores paused, and refuses new credentials',
    () async {
      await controller.start();
      await controller.seekTo(const Duration(seconds: 20));
      final oldSession = backend.sessionId;
      await controller.suspendPlayback();
      await controller.suspendPlayback();
      expect(controller.backgroundReleased, isTrue);
      expect(backend.isPlaying, isFalse);
      expect(client.reports.where((r) => r.$1 == 'Stopped'), hasLength(1));
      await controller.restorePlayback();
      expect(backend.sessionId, isNot(oldSession));
      expect(backend.openedStart, const Duration(seconds: 20));
      expect(backend.openedPaused, isTrue);
      expect(controller.isPlaying, isFalse);
      expect(client.reports.where((r) => r.$1 == 'Playing'), hasLength(2));

      await controller.suspendPlayback();
      final count = backend.openCount;
      client.attachSession(
        baseUrl: client.baseUrl!,
        accessToken: 'new-user-token',
        userId: 'different-user',
      );
      await controller.restorePlayback();
      expect(controller.sessionExpired, isTrue);
      expect(backend.openCount, count);
    },
  );

  test(
    'native authentication failure stops media and exposes reconnect state',
    () async {
      await controller.start();
      backend.emitEvent(VideoEventKind.authenticationRequired, 401);
      await _until(() => controller.sessionExpired);
      expect(controller.disconnected, isTrue);
      expect(controller.controlsVisible, isTrue);
      expect(controller.loading, isFalse);
      expect(backend.isPlaying, isFalse);
    },
  );

  test(
    'immediate item switch preserves debounced volume and rate changes',
    () async {
      await settings.write(
        const PlayerSettings(volume: 80, playbackRate: 1.25),
      );
      await controller.start();
      await controller.setRate(1);
      await controller.setVolume(15);
      await controller.playEpisode(episode('episode-friends-s1e1'));
      expect(controller.playbackRate, 1);
      expect(controller.volume, 15);
      expect(backend.rate, 1);
      expect(backend.volume, 15);
      expect((await settings.read()).playbackRate, 1);
      expect((await settings.read()).volume, 15);
    },
  );

  test(
    'reverse item responses cannot overwrite the newest item or report',
    () async {
      final gate = client.itemGates['movie-up'] = Completer<void>();
      final first = controller.start();
      await _until(() => client.requestedItems.contains('movie-up'));
      await controller.playEpisode(episode('episode-friends-s1e1'));
      gate.complete();
      await first;
      expect(controller.itemId, 'episode-friends-s1e1');
      expect(controller.item?.id, controller.itemId);
      expect(backend.openCount, 1);
      expect(
        client.reports.where((e) => e.$1 == 'Playing').map((e) => e.$2.itemId),
        ['episode-friends-s1e1'],
      );
    },
  );

  test(
    'close during metadata loading never opens or reports Playing',
    () async {
      final gate = client.itemGates['movie-up'] = Completer<void>();
      final starting = controller.start();
      await _until(() => client.requestedItems.contains('movie-up'));
      await controller.close();
      gate.complete();
      await starting;
      expect(backend.openCount, 0);
      expect(client.reports, isEmpty);
      expect(closed, 1);
      expect(controller.state.phase, PlaybackPhase.closed);
    },
  );

  test(
    'switching interrupts an old native open before loading the new item',
    () async {
      backend.openGate = Completer<void>();
      final starting = controller.start();
      await _until(() => backend.openStarted);
      await controller.playEpisode(episode('episode-friends-s1e1'));
      await starting;
      expect(controller.item?.id, 'episode-friends-s1e1');
      expect(controller.isPlaying, isTrue);
      expect(backend.openCount, 1);
      expect(
        client.reports.where((e) => e.$1 == 'Playing').single.$2.itemId,
        'episode-friends-s1e1',
      );
    },
  );

  test(
    'close cancels an in-flight native open and waits for disposal',
    () async {
      backend.openGate = Completer<void>();
      backend.disposeGate = Completer<void>();
      final starting = controller.start();
      await _until(() => backend.openStarted);
      final closing = controller.close();
      await _until(() => backend.disposeCount == 1);
      expect(closed, 0);
      expect(backend.isPlaying, isFalse);
      backend.disposeGate!.complete();
      await Future.wait([starting, closing]);
      expect(client.reports, isEmpty);
      expect(closed, 1);
      await controller.close();
      await controller.disposeAsync();
      expect(backend.disposeCount, 1);
    },
  );

  test(
    'late events retain their old identity and cannot affect a new session',
    () async {
      await controller.start();
      final oldId = backend.sessionId;
      await controller.playEpisode(episode('episode-friends-s1e1'));
      final currentPosition = controller.position;
      backend.emitEvent(
        VideoEventKind.position,
        const Duration(hours: 7),
        forSession: oldId,
      );
      backend.emitEvent(VideoEventKind.playing, false, forSession: oldId);
      backend.emitEvent(VideoEventKind.completed, true, forSession: oldId);
      backend.emitEvent(
        VideoEventKind.error,
        'connection lost',
        forSession: oldId,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.position, currentPosition);
      expect(controller.isPlaying, isTrue);
      expect(controller.playbackEnded, isFalse);
      expect(controller.disconnected, isFalse);
    },
  );

  test(
    'rapid position events do not notify faster than the UI interval',
    () async {
      await controller.start();
      var notifies = 0;
      controller.addListener(() => notifies++);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      final afterFirst = notifies;
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(controller.position, const Duration(seconds: 2));
      expect(notifies, afterFirst);
      await Future<void>.delayed(kPlaybackUiMinInterval);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      expect(notifies, afterFirst + 1);
    },
  );

  test('EOF stays observable while the Playing report is pending', () async {
    client.playingGate = Completer<void>();
    final starting = controller.start();
    await _until(() => client.reports.any((e) => e.$1 == 'Playing'));
    backend.completePlayback(at: controller.duration);
    await Future<void>.delayed(Duration.zero);
    expect(controller.playbackEnded, isTrue);
    expect(controller.state.phase, PlaybackPhase.ended);
    client.playingGate!.complete();
    await starting;
    expect(controller.state.phase, PlaybackPhase.ended);
    await _until(() => client.reports.any((e) => e.$1 == 'Stopped'));
    expect(client.reports.map((e) => e.$1), ['Playing', 'Progress', 'Stopped']);
  });

  test('buffering or pausing near duration is not EOF', () async {
    await controller.start();
    backend.emitBuffering(true);
    backend.pauseAtEndWithoutComplete(at: controller.duration);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isBuffering, isTrue);
    expect(controller.state.phase, PlaybackPhase.buffering);
    expect(controller.playbackEnded, isFalse);
    expect(client.reports.where((e) => e.$1 == 'Stopped'), isEmpty);
    backend.emitBuffering(false);
    backend.completePlayback(at: controller.duration);
    await Future<void>.delayed(Duration.zero);
    expect(controller.playbackEnded, isTrue);
    expect(controller.state.phase, PlaybackPhase.ended);
  });

  test(
    'failed track change neither commits selection nor saves or reports success',
    () async {
      await controller.start();
      final original = controller.audioStreamIndex;
      final before = await settings.read();
      backend.failAudio = true;
      await controller.setAudio(999);
      expect(controller.audioStreamIndex, original);
      expect(controller.trackFailure, contains('track failed'));
      expect(
        (await settings.read()).seriesPreferences,
        before.seriesPreferences,
      );
      expect(
        client.reports.where((e) => e.$2.eventName == 'AudioTrackChange'),
        isEmpty,
      );
    },
  );

  test(
    'a queued failed track keeps the previous successful mutation',
    () async {
      await controller.playEpisode(episode('episode-friends-s1e1'));
      final gate = backend.audioGates[7] = Completer<void>();
      final first = controller.setAudio(7);
      await _until(() => backend.audioRequests.contains(7));
      backend.failedAudioIndices.add(8);
      final second = controller.setAudio(8);
      gate.complete();
      await Future.wait([first, second]);
      expect(backend.audioIndex, 7);
      expect(controller.audioStreamIndex, 7);
      expect(controller.trackFailure, contains('track failed'));
      final preference =
          (await settings.read()).seriesPreferences[controller.item!.seriesId];
      expect(preference?.audioStreamIndex, 7);
      expect(
        client.reports
            .where((e) => e.$2.eventName == 'AudioTrackChange')
            .any((e) => e.$2.audioStreamIndex == 8),
        isFalse,
      );
    },
  );

  test(
    'rejected volume, rate, audio and subtitle restoration keeps ready media and warns',
    () async {
      for (final stage in ['volume', 'rate', 'audio', 'subtitle']) {
        final opensBefore = backend.openCount;
        final playingBefore = client.reports
            .where((e) => e.$1 == 'Playing')
            .length;
        backend.failInitialization = stage;
        await controller.start();
        expect(backend.openCount, opensBefore + 1, reason: stage);
        expect(backend.isPlaying, isTrue, reason: stage);
        expect(controller.isPlaying, isTrue, reason: stage);
        expect(controller.loading, isFalse, reason: stage);
        expect(controller.error, isNull, reason: stage);
        expect(controller.state.phase, PlaybackPhase.playing, reason: stage);
        expect(controller.trackFailure, contains('$stage failed'));
        expect(
          client.reports.where((e) => e.$1 == 'Playing').length,
          playingBefore + 1,
          reason: stage,
        );
        backend.failInitialization = null;
        await controller.start();
        expect(controller.error, isNull, reason: stage);
        expect(backend.isPlaying, isTrue, reason: stage);
      }
    },
  );

  test('stale initialization failure cannot stop the newer open', () async {
    final gate = backend.rateGate = Completer<void>();
    backend.failInitialization = 'rate';
    final starting = controller.start();
    await _until(() => backend.rateStarted);
    final switching = controller.playEpisode(episode('episode-friends-s1e1'));
    gate.complete();
    await Future.wait([starting, switching]);
    expect(controller.itemId, 'episode-friends-s1e1');
    expect(controller.error, isNull);
    expect(backend.isPlaying, isTrue);
    expect(
      client.reports.where((e) => e.$1 == 'Playing').last.$2.itemId,
      'episode-friends-s1e1',
    );
  });

  test(
    'readiness notifies before parameter restoration or reporting',
    () async {
      final gate = backend.rateGate = Completer<void>();
      client.playingGate = Completer<void>();
      var notifiedReady = false;
      controller.addListener(() {
        if (!controller.loading && controller.isPlaying) notifiedReady = true;
      });
      final starting = controller.start();
      await _until(() => backend.rateStarted);
      expect(notifiedReady, isTrue);
      expect(controller.state.phase, PlaybackPhase.playing);
      backend.emitBuffering(true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, PlaybackPhase.buffering);
      gate.complete();
      client.playingGate!.complete();
      await starting;
      expect(controller.state.phase, PlaybackPhase.buffering);
    },
  );

  test(
    'Playing timeout cannot stop ready media or poison report ordering',
    () async {
      final gate = client.playingGate = Completer<void>();
      final starting = controller.start();
      await _until(() => client.reports.any((e) => e.$1 == 'Playing'));
      expect(controller.loading, isFalse);
      gate.completeError(
        TimeoutException('Playing timed out', const Duration(seconds: 15)),
      );
      await starting;
      expect(controller.progressSyncFailed, isTrue);
      expect(controller.error, isNull);
      expect(backend.isPlaying, isTrue);
      await controller.seekTo(const Duration(seconds: 5));
      expect(client.reports.map((e) => e.$1), ['Playing', 'Progress']);
      expect(controller.progressSyncFailed, isFalse);
    },
  );

  for (final failsLate in [false, true]) {
    test(
      'pending restored subtitle allows controls and ignores late ${failsLate ? 'failure' : 'success'} after off',
      () async {
        controller.itemId = 'movie-inception';
        final gate = backend.subtitleGate = Completer<void>();
        final pending = controller.start();
        await _untilElapsed(() => backend.subtitleWaiting);
        expect(controller.loading, isFalse);
        await controller.togglePlay().timeout(const Duration(seconds: 1));
        expect(backend.isPlaying, isFalse);
        await controller
            .seekTo(const Duration(seconds: 5))
            .timeout(const Duration(seconds: 1));
        expect(backend.position, const Duration(seconds: 5));
        await controller.setVolume(35).timeout(const Duration(seconds: 1));
        expect(backend.volume, 35);
        await controller.setSubtitle(null).timeout(const Duration(seconds: 1));
        expect(gate.isCompleted, isFalse);
        expect(controller.subtitleStreamIndex, isNull);
        if (failsLate) {
          gate.completeError(TimeoutException('superseded subtitle'));
        } else {
          gate.complete();
        }
        await pending;
        expect(controller.subtitleStreamIndex, isNull);
        expect(controller.trackFailure, isNull);
        expect(controller.error, isNull);
        expect(backend.isPlaying, isFalse);
      },
    );
  }

  test(
    'switch and close do not wait for a previous subtitle resource',
    () async {
      controller.itemId = 'movie-inception';
      final gate = backend.subtitleGate = Completer<void>();
      final starting = controller.start();
      await _untilElapsed(() => backend.subtitleWaiting);
      await controller
          .playEpisode(episode('episode-friends-s1e1'))
          .timeout(const Duration(seconds: 1));
      expect(controller.itemId, 'episode-friends-s1e1');
      expect(controller.isPlaying, isTrue);
      await controller.close().timeout(const Duration(seconds: 1));
      expect(gate.isCompleted, isFalse);
      gate.completeError(TimeoutException('retired subtitle'));
      await starting;
      expect(controller.state.phase, PlaybackPhase.closed);
      expect(controller.trackFailure, isNull);
    },
  );

  test(
    'a native reply timeout remains fatal after readiness and can retry',
    () async {
      backend.rateGate = Completer<void>();
      final starting = controller.start();
      await _until(() => backend.rateStarted);
      expect(controller.loading, isFalse);
      backend.rateGate!.completeError(
        TimeoutException(
          'libmpv set:speed reply timed out',
          const Duration(seconds: 15),
        ),
      );
      await starting;
      expect(controller.error, PlayerErrorKind.load);
      expect(backend.isPlaying, isFalse);
      backend.emitEvent(VideoEventKind.playing, false);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, PlaybackPhase.failed);
      backend.rateGate = null;
      await controller.start();
      expect(controller.error, isNull);
      expect(controller.isPlaying, isTrue);
    },
  );

  test('rapid A B C exposes only C while old metadata finishes late', () async {
    await controller.start();
    final gate = client.itemGates['episode-friends-s1e1'] = Completer<void>();
    final second = controller.playEpisode(episode('episode-friends-s1e1'));
    expect(controller.itemId, 'episode-friends-s1e1');
    expect(controller.loading, isTrue);
    expect(controller.item, isNull);
    await _until(() => client.requestedItems.contains('episode-friends-s1e1'));
    await controller.playEpisode(episode('episode-friends-s1e2'));
    gate.complete();
    await second;
    expect(controller.itemId, 'episode-friends-s1e2');
    expect(controller.item?.id, controller.itemId);
    expect(
      client.reports.where((e) => e.$1 == 'Playing').map((e) => e.$2.itemId),
      ['movie-up', 'episode-friends-s1e2'],
    );
  });

  test(
    'manual selection cancels an EOF countdown before awaiting Stopped',
    () async {
      await controller.disposeAsync();
      controller.dispose();
      controller = PlayerController(
        client: client,
        itemId: 'episode-friends-s1e1',
        backend: backend,
        window: PlayerWindow(),
        settingsStore: settings,
        snapshotStore: snapshots,
        stoppedTimeout: const Duration(minutes: 1),
        nextEpisodeCountdown: const Duration(milliseconds: 100),
      );
      await controller.start();
      client.stoppedGate = Completer<void>();
      backend.completePlayback(at: controller.duration);
      await _until(() => controller.nextEpisode?.remaining != null);
      var switched = false;
      final switching = controller.playEpisode(episode('movie-up')).then((_) {
        switched = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(switched, isFalse);
      client.stoppedGate!.complete();
      await switching;
      expect(controller.itemId, 'movie-up');
      expect(client.requestedItems, isNot(contains('episode-friends-s1e2')));
    },
  );

  test(
    'superseding list, more and earlier loading releases its busy flag',
    () async {
      await controller.playEpisode(episode('episode-friends-s1e1'));
      for (final direction in ['list', 'more', 'earlier']) {
        if (direction != 'list') {
          await controller.loadEpisodeList();
          controller.episodeWindowStart = 80;
          controller.episodeWindowEnd = 160;
          controller.episodeTotal = 200;
        }
        Future<void> load() => switch (direction) {
          'more' => controller.loadMoreEpisodes(),
          'earlier' => controller.loadEarlierEpisodes(),
          _ => controller.loadEpisodeList(),
        };
        final gate = client.queryGate = Completer<void>();
        final count = client.queryCount;
        final pending = load();
        await _until(() => client.queryCount > count);
        final starting = controller.start();
        expect(controller.episodeListLoading, isFalse, reason: direction);
        expect(controller.episodeLoadingMore, isFalse, reason: direction);
        expect(controller.episodeLoadingEarlier, isFalse, reason: direction);
        await starting;
        gate.complete();
        await pending;
        final beforeRetry = client.queryCount;
        await load();
        expect(client.queryCount, greaterThan(beforeRetry), reason: direction);
        expect(controller.episodeListLoading, isFalse, reason: direction);
        expect(controller.episodeLoadingMore, isFalse, reason: direction);
        expect(controller.episodeLoadingEarlier, isFalse, reason: direction);
      }
    },
  );

  test(
    'a late Progress response cannot resurrect the stopped session snapshot',
    () async {
      await controller.start();
      final gate = client.progressGate = Completer<void>();
      final seeking = controller.seekTo(const Duration(seconds: 42));
      await _until(() => client.reports.any((e) => e.$1 == 'Progress'));
      await controller.playEpisode(episode('episode-friends-s1e1'));
      expect(snapshots.snapshot?.itemId, 'episode-friends-s1e1');
      gate.complete();
      await seeking;
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.snapshot?.itemId, 'episode-friends-s1e1');
      expect(
        client.reports.where((e) => e.$1 == 'Stopped').single.$2.itemId,
        'movie-up',
      );
    },
  );

  test(
    'changing credentials cancels queued reports for the previous account',
    () async {
      await controller.start();
      final gate = client.progressGate = Completer<void>();
      final seeking = controller.seekTo(const Duration(seconds: 12));
      await _until(() => client.reports.any((e) => e.$1 == 'Progress'));
      client.attachSession(
        baseUrl: Uri.parse('http://another.example'),
        accessToken: 'other-token',
        userId: 'other-user',
      );
      final closing = controller.close();
      gate.complete();
      await Future.wait([seeking, closing]);
      expect(client.reports.where((e) => e.$1 == 'Stopped'), isEmpty);
      expect(snapshots.snapshot?.userId, isNot('other-user'));
    },
  );

  test(
    'close joins Playing then sends one Stopped without reviving progress',
    () async {
      client.playingGate = Completer<void>();
      final starting = controller.start();
      await _until(() => client.reports.any((e) => e.$1 == 'Playing'));
      final closing = controller.close();
      client.playingGate!.complete();
      await Future.wait([starting, closing]);
      expect(client.reports.map((e) => e.$1), ['Playing', 'Stopped']);
      expect(snapshots.snapshot, isNull);
      expect(controller.isPlaying, isFalse);
    },
  );
}

class _ControlledBackend extends FakeVideoBackend {
  Completer<void>? openGate;
  Completer<void>? disposeGate;
  bool openStarted = false;
  bool _openCancelled = false;
  bool failAudio = false;
  final audioGates = <int, Completer<void>>{};
  final audioRequests = <int>[];
  final failedAudioIndices = <int>{};
  String? failInitialization;
  Completer<void>? rateGate;
  bool rateStarted = false;
  Completer<void>? subtitleGate;
  bool subtitleWaiting = false;
  int disposeCount = 0;

  @override
  Future<void> open(VideoOpenRequest request) async {
    openStarted = true;
    _openCancelled = false;
    await openGate?.future;
    if (!_openCancelled) await super.open(request);
  }

  @override
  Future<void> stop() async {
    if (openStarted && openGate != null && !openGate!.isCompleted) {
      _openCancelled = true;
      openGate!.complete();
    }
    await super.stop();
  }

  @override
  Future<void> setAudioIndex(int index) async {
    audioRequests.add(index);
    await audioGates[index]?.future;
    if (failAudio || failedAudioIndices.contains(index)) {
      throw StateError('track failed');
    }
    if (failInitialization == 'audio') throw StateError('audio failed');
    await super.setAudioIndex(index);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (isPlaying && failInitialization == 'volume') {
      throw StateError('volume failed');
    }
    await super.setVolume(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    rateStarted = true;
    final fail = failInitialization == 'rate';
    if (fail) failInitialization = null;
    await rateGate?.future;
    if (fail) throw StateError('rate failed');
    await super.setRate(rate);
  }

  @override
  Future<bool> setSubtitleUri(Uri uri, {String? title}) async {
    final applied = await super.setSubtitleUri(uri, title: title);
    final gate = subtitleGate;
    subtitleWaiting = gate != null;
    await gate?.future;
    return applied;
  }

  @override
  Future<void> setSubtitleOff() async {
    if (failInitialization == 'subtitle') throw StateError('subtitle failed');
    await super.setSubtitleOff();
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await disposeGate?.future;
  }

  void release() {
    for (final gate in [...audioGates.values, ?rateGate, ?subtitleGate]) {
      if (!gate.isCompleted) gate.complete();
    }
    if (openGate != null && !openGate!.isCompleted) openGate!.complete();
    if (disposeGate != null && !disposeGate!.isCompleted) {
      disposeGate!.complete();
    }
  }
}

class _ControlledClient extends EmbyClient {
  _ControlledClient(FakeEmbyAdapter adapter)
    : super(device: _device, dio: dioForFakeEmby(adapter));
  final itemGates = <String, Completer<void>>{};
  final requestedItems = <String>[];
  final reports = <(String, PlaybackReport)>[];
  Completer<void>? playingGate;
  Completer<void>? progressGate;
  Completer<void>? stoppedGate;
  Completer<void>? queryGate;
  int queryCount = 0;

  @override
  Future<EmbyItemPage> queryItems({
    String? parentId,
    String? searchTerm,
    String? includeItemTypes,
    bool recursive = false,
    int? limit,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    List<String>? filters,
    List<String>? genres,
    List<int>? years,
    String fields = EmbyClient.gridFields,
  }) async {
    queryCount++;
    final gate = queryGate;
    final page = await super.queryItems(
      parentId: parentId,
      searchTerm: searchTerm,
      includeItemTypes: includeItemTypes,
      recursive: recursive,
      limit: limit,
      startIndex: startIndex,
      sortBy: sortBy,
      sortOrder: sortOrder,
      filters: filters,
      genres: genres,
      years: years,
      fields: fields,
    );
    await gate?.future;
    return page;
  }

  @override
  Future<EmbyItem> getItem(String itemId, {String? fields}) async {
    final result = await super.getItem(itemId, fields: fields);
    requestedItems.add(itemId);
    await itemGates[itemId]?.future;
    return result;
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) async {
    reports.add(('Playing', report));
    await playingGate?.future;
  }

  @override
  Future<void> reportProgress(PlaybackReport report) async {
    reports.add(('Progress', report));
    await progressGate?.future;
  }

  @override
  Future<void> reportStopped(PlaybackReport report) async {
    reports.add(('Stopped', report));
    await stoppedGate?.future;
  }

  void release() {
    for (final gate in [
      ...itemGates.values,
      ?playingGate,
      ?progressGate,
      ?stoppedGate,
      ?queryGate,
    ]) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}
