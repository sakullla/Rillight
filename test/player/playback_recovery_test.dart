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

class _RecoveryBackend extends FakeVideoBackend {
  Completer<void>? stopGate;
  Completer<void>? openGate;
  String? rejectedSource;
  bool rejectNextVolume = false;
  final restoreGates = <String, Completer<void>>{};
  int stopCount = 0;
  int openBegins = 0;
  int activeOpens = 0;
  int maxConcurrentOpens = 0;
  final List<String> nativeOrder = [];
  final List<double> volumeCommands = [];
  final List<double> rateCommands = [];

  @override
  Future<void> stop() async {
    stopCount++;
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
      if (request.url.queryParameters['MediaSourceId'] == rejectedSource) {
        throw StateError('Source rejected');
      }
      await super.open(request);
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
    'source change clamps the resume point and selects a valid audio track',
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
      await controller.switchMediaSource('alternate');
      expect(backend.openedStart, const Duration(seconds: 30));
      expect(controller.audioStreamIndex, 5);
      expect(controller.activeMediaSourceId, 'alternate');
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
