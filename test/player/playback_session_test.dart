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

  test('EOF stays observable while the Playing report is pending', () async {
    client.playingGate = Completer<void>();
    final starting = controller.start();
    await _until(() => client.reports.any((e) => e.$1 == 'Playing'));
    backend.completePlayback();
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
    backend.completePlayback();
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
    if (failAudio) throw StateError('track failed');
    await super.setAudioIndex(index);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await disposeGate?.future;
  }

  void release() {
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
  }

  void release() {
    for (final gate in [...itemGates.values, ?playingGate, ?progressGate]) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}
