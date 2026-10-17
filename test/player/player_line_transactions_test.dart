import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_process_control.dart';
import 'package:rillight/player/playback_recovery_coordinator.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/playback_state.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import 'fake_player_process_control.dart';

class _Process extends FakePlayerProcessControl
    implements PlayerHistoryProcessControl, PlayerLineProcessControl {
  _Process() : super(requestCloseResult: true);
  Map<String, dynamic>? command, cancellation;
  final receipt = Completer<Map<String, dynamic>>();
  final cancelled = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>?> consumeSwitchCommand(int pid) async {
    final next = command;
    command = null;
    return next;
  }

  @override
  Future<Map<String, dynamic>?> consumeLineCancellation(int pid) async {
    final next = cancellation;
    cancellation = null;
    return next;
  }

  @override
  Future<void> replySwitchCommand(int pid, Map<String, dynamic> reply) async =>
      receipt.complete(reply);
  @override
  Future<void> replyLineCancellation(
    int pid,
    Map<String, dynamic> reply,
  ) async => cancelled.complete(reply);
  @override
  Future<Map<String, dynamic>?> consumeWatchEvent(int pid) async => null;
  @override
  Future<Map<String, dynamic>?> consumeReportOutcome(int pid) async => null;
  @override
  Future<Map<String, dynamic>?> lineSelectionResult(int pid) async => null;
  @override
  Future<void> requestLineSelection(
    int pid,
    Map<String, dynamic> command,
  ) async {}
  @override
  Future<void> acknowledgeWatchEvent(
    int pid,
    Map<String, dynamic> receipt,
  ) async {}
  @override
  Future<void> revoke(
    int pid,
    int generation, {
    bool reportStopped = false,
  }) async {}
}

class _Store extends MemoryServerListStore {
  bool rejectNext = false;
  Completer<void>? gate;
  Completer<void>? entered;
  void Function(ServerListSnapshot)? onSaved;
  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    final pending = gate;
    if (pending != null) {
      gate = null;
      entered?.complete();
      await pending.future;
    }
    if (rejectNext) {
      rejectNext = false;
      throw StateError('Synthetic disk failure');
    }
    await super.save(snapshot);
    onSaved?.call(snapshot);
  }
}

class _Lines extends FakeEmbyAdapter {
  _Lines(this.lines) : super(lines);
  final List<FakeEmbyServer> lines;
  final offline = <String>{};
  Completer<void>? gate;
  String? gatedHost;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    if (options.uri.host == gatedHost) await gate?.future;
    if (offline.contains(options.uri.host)) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    for (final line in lines) {
      line.issuedTokens.addAll(lines.expand((s) => s.issuedTokens).toList());
    }
    return super.fetch(options, stream, cancel);
  }
}

class _Backend extends FakeVideoBackend implements VideoBackendRecoveryBudget {
  PlaybackRecoveryBudget? attachedBudget;
  @override
  set recoveryBudget(PlaybackRecoveryBudget? value) => attachedBudget = value;
  final opens = <String>[];
  final reject = <String>{};
  @override
  Future<void> open(VideoOpenRequest request) async {
    opens.add(request.url.host);
    if (reject.contains(request.url.host)) {
      throw StateError('Synthetic open failure');
    }
    await super.open(request);
  }
}

void main() {
  late FakeEmbyServer a, b;
  late _Lines adapter;
  late AuthController auth;
  late _Store store;
  late HistoryWriter history;
  late _Backend backend;
  late PlayerController player;
  late String aId, bId, serverId;
  setUp(() async {
    a = FakeEmbyServer(baseUrl: Uri.parse('http://line-a.test:8096'));
    b = FakeEmbyServer(
      serverId: a.serverId,
      baseUrl: Uri.parse('http://line-b.test:8096'),
    );
    adapter = _Lines([a, b]);
    store = _Store();
    final client = EmbyClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'lines',
        deviceId: 'synthetic-lines',
        version: '1',
      ),
      dio: dioForFakeEmby(adapter),
    );
    auth = AuthController(
      client: client,
      credentials: MemoryCredentialStore(),
      servers: store,
    );
    await auth.connect(
      address: a.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    serverId = auth.savedServers.single.id;
    await auth.addLine(serverId, b.baseUrl.toString());
    await auth.refreshServers();
    final saved = auth.savedServers.single;
    aId = saved.lines.firstWhere((l) => l.address == a.baseUrl.toString()).id;
    bId = saved.lines.firstWhere((l) => l.address == b.baseUrl.toString()).id;
    await auth.selectLine(serverId, LineSelection.fixed(aId));
    history = await HistoryWriter.open(
      registry: auth.sources,
      store: MemoryHistoryStore(),
    );
    backend = _Backend();
    player = PlayerController(
      client: auth.client,
      itemId: 'movie-up',
      backend: backend,
      window: PlayerWindow(),
      runtime: PlaybackRuntime(auth: auth, history: history),
      autoResume: false,
      recoveryTimeout: const Duration(seconds: 2),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      settingsStore: MemoryPlayerSettingsStore(),
    );
    await player.start();
    expect(player.error, isNull);
  });
  tearDown(() async {
    if (adapter.gate != null && !adapter.gate!.isCompleted) {
      adapter.gate!.complete();
    }
    await player.disposeAsync();
    player.dispose();
    await history.close();
    auth.dispose();
  });

  test('healthy auto and current fixed persist without reopening from either entry', () async {
    final opens = backend.opens.length;
    await auth.chooseConnection(serverId, const LineSelection.auto());
    expect(player.playbackLineSelection.isAutomatic, true);
    expect(backend.opens.length, opens);
    await player.selectPlaybackLine(LineSelection.fixed(aId));
    expect(
      (await store.load()).servers.single.lineSelection,
      LineSelection.fixed(aId),
    );
    expect(backend.opens.length, opens);
    expect(player.origin!.permit.isValid, true);
  });

  test('list switches live player and stores fixed actual line', () async {
    await auth.chooseConnection(serverId, LineSelection.fixed(bId));
    expect(player.client.baseUrl, b.baseUrl);
    expect(player.activeLineId, bId);
    expect(player.playbackLineSelection, LineSelection.fixed(bId));
    expect((await store.load()).servers.single.activeLineId, bId);
    expect(player.origin!.permit.isValid, true);
  });

  test(
    'preflight failure preserves live old playback and saved mode',
    () async {
      adapter.offline.add(b.baseUrl.host);
      final count = backend.opens.length;
      await expectLater(player.switchLine(bId), throwsA(anything));
      expect(backend.opens.length, count);
      expect(player.client.baseUrl, a.baseUrl);
      expect(player.isPlaying, true);
      expect(player.playbackLineSelection, LineSelection.fixed(aId));
    },
  );

  test(
    'save failure compensates old playback without claiming target selection',
    () async {
      store.rejectNext = true;
      await expectLater(player.switchLine(bId), throwsA(anything));
      expect(
        backend.opens,
        containsAllInOrder([b.baseUrl.host, a.baseUrl.host]),
      );
      expect(player.client.baseUrl, a.baseUrl);
      expect(player.playbackLineSelection, LineSelection.fixed(aId));
      expect(player.isPlaying, true);
      expect(player.playbackLineFailure, isNotNull);
    },
  );

  test('target and compensation failure remain actually failed', () async {
    backend.reject.addAll([a.baseUrl.host, b.baseUrl.host]);
    await expectLater(player.switchLine(bId), throwsA(anything));
    expect(player.isPlaying, false);
    expect(player.state.phase, PlaybackPhase.failed);
    expect(player.playbackLineSelection, LineSelection.fixed(aId));
  });

  test(
    'cancelled preflight never opens late target or stops healthy old playback',
    () async {
      adapter.gatedHost = b.baseUrl.host;
      adapter.gate = Completer<void>();
      final count = backend.opens.length;
      final work = player.switchLine(bId);
      final failed = expectLater(work, throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      player.cancelLineRecovery();
      adapter.gate!.complete();
      await failed;
      expect(backend.opens.length, count);
      expect(player.isPlaying, true);
      expect(player.client.baseUrl, a.baseUrl);
    },
  );

  test(
    'automatic real failure tries backup once and fixed failure does not',
    () async {
      backend.emitEvent(VideoEventKind.error, 'Connection lost');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.opens, hasLength(1));
      await player.retryPlayback();
      await player.selectPlaybackLine(const LineSelection.auto());
      adapter.offline.add(a.baseUrl.host);
      backend.emitEvent(VideoEventKind.error, 'Connection lost');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (player.isRecovering && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(player.activeLineId, bId);
      expect(player.isPlaying, true);
      expect(player.playbackLineSelection.isAutomatic, true);
      expect(backend.opens.where((h) => h == b.baseUrl.host), hasLength(1));
      expect(backend.attachedBudget, isNull);
    },
  );

  test('first automatic connection uses verified backup when initial metadata is unreachable', () async {
    final runtime = player.runtime!;
    await player.disposeAsync();
    player.dispose();
    await auth.selectLine(serverId, const LineSelection.auto());
    adapter.offline.add(a.baseUrl.host);
    backend = _Backend();
    player = PlayerController(
      client: auth.client,
      itemId: 'movie-up',
      backend: backend,
      window: PlayerWindow(),
      runtime: runtime,
      autoResume: false,
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      settingsStore: MemoryPlayerSettingsStore(),
    );
    await player.start();
    expect(player.error, isNull);
    expect(player.client.baseUrl, b.baseUrl);
    expect(player.activeLineId, bId);
    expect(player.playbackLineSelection.isAutomatic, true);
  });

  test('first-open fault during save rejects its receipt and recovers in the same transaction', () async {
    final runtime = player.runtime!;
    await player.disposeAsync();
    player.dispose();
    await auth.selectLine(serverId, const LineSelection.auto());
    backend = _Backend();
    player = PlayerController(
      client: auth.client,
      itemId: 'movie-up',
      backend: backend,
      window: PlayerWindow(),
      runtime: runtime,
      autoResume: false,
      recoveryTimeout: const Duration(seconds: 2),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      settingsStore: MemoryPlayerSettingsStore(),
    );
    final gate = store.gate = Completer<void>();
    final entered = store.entered = Completer<void>();
    final work = player.start();
    await entered.future;
    expect(player.activeLineId, isNull);
    backend.emitEvent(VideoEventKind.error, 'Connection lost');
    await Future<void>.delayed(Duration.zero);
    expect(player.disconnected, true);
    gate.complete();
    await work.timeout(const Duration(seconds: 3));
    expect(backend.opens, [a.baseUrl.host, b.baseUrl.host]);
    expect(player.activeLineId, bId);
    expect((await store.load()).servers.single.activeLineId, bId);
    expect(player.isPlaying, true);
    expect(player.isRecovering, false);
    expect(player.loading, false);
    expect(player.disconnected, false);
  });

  test(
    'line switch preserves pause, position, mute, rate and subtitle off',
    () async {
      await player.seekTo(const Duration(minutes: 4));
      await player.togglePlay();
      await player.setVolume(0);
      await player.setRate(1.5);
      await player.setSubtitle(null);
      await player.switchLine(bId);
      expect(player.isPlaying, false);
      expect(player.position, const Duration(minutes: 4));
      expect(player.volume, 0);
      expect(player.playbackRate, 1.5);
      expect(player.subtitleStreamIndex, isNull);
    },
  );

  test(
    'shorter target asks before stopping and never silently resets position',
    () async {
      await player.seekTo(const Duration(minutes: 4));
      b.items.firstWhere((m) => m.id == 'movie-up').runtime = const Duration(
        minutes: 2,
      );
      final count = backend.opens.length;
      await expectLater(player.switchLine(bId), throwsA(anything));
      expect(player.switchConfirmation, isNotNull);
      expect(player.switchConfirmation!.canTryCurrentPosition, false);
      expect(backend.opens.length, count);
      expect(player.isPlaying, true);
      await player.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
      expect(player.position, const Duration(minutes: 4));
      expect(player.playbackLineSelection, LineSelection.fixed(aId));
    },
  );

  test(
    'missing selected subtitle requires explicit choice before target open',
    () async {
      const tracks = [
        FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
        FakeMediaStream(index: 1, type: 'Audio', codec: 'aac', language: 'jpn'),
        FakeMediaStream(
          index: 2,
          type: 'Subtitle',
          codec: 'subrip',
          language: 'zho',
          isTextSubtitleStream: true,
        ),
      ];
      a.items.firstWhere((m) => m.id == 'movie-up').mediaStreams = tracks;
      b.items.firstWhere((m) => m.id == 'movie-up').mediaStreams = tracks
          .take(2)
          .toList();
      await player.start();
      await player.setSubtitle(2);
      final count = backend.opens.length;
      await expectLater(player.switchLine(bId), throwsA(anything));
      expect(player.switchConfirmation!.subtitleNeedsChoice, true);
      expect(player.subtitleStreamIndex, 2);
      expect(backend.opens.length, count);
      await player.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
        turnSubtitlesOff: true,
      );
      expect(player.subtitleStreamIndex, isNull);
      expect(player.activeLineId, bId);
    },
  );

  test('cancel during persistence rolls back disk and rejects late target receipt', () async {
    final gate = store.gate = Completer<void>();
    final entered = store.entered = Completer<void>();
    final rolledBack = Completer<void>();
    store.onSaved = (snapshot) {
      if (snapshot.servers.single.lineSelection == LineSelection.fixed(aId)) {
        rolledBack.complete();
      }
    };
    final work = player.switchLine(bId);
    final failed = expectLater(work, throwsA(anything));
    await entered.future;
    player.cancelLineRecovery();
    gate.complete();
    await failed;
    // Cancellation returns promptly even if an in-flight disk write cannot
    // be interrupted. Observe the queued compensation, not an arbitrary delay.
    await rolledBack.future.timeout(const Duration(seconds: 1));
    expect(
      (await store.load()).servers.single.lineSelection,
      LineSelection.fixed(aId),
    );
    expect(player.isPlaying, false);
    expect(player.state.phase, PlaybackPhase.failed);
  });

  test('new playback intent supersedes a blocked line save without late stop or commit', () async {
    final gate = store.gate = Completer<void>();
    final entered = store.entered = Completer<void>();
    final rolledBack = Completer<void>();
    store.onSaved = (snapshot) {
      if (snapshot.servers.single.lineSelection == LineSelection.fixed(aId) &&
          !rolledBack.isCompleted) {
        rolledBack.complete();
      }
    };
    final failed = expectLater(player.switchLine(bId), throwsA(anything));
    await entered.future;
    try {
      await player.start().timeout(const Duration(seconds: 2));
      expect(player.client.baseUrl, a.baseUrl);
      expect(player.isPlaying, true);
    } finally {
      gate.complete();
    }
    await failed;
    await rolledBack.future.timeout(const Duration(seconds: 1));
    expect(player.client.baseUrl, a.baseUrl);
    expect(player.isPlaying, true);
    expect(
      (await store.load()).servers.single.lineSelection,
      LineSelection.fixed(aId),
    );
  });

  test('helper committed client survives the preparation deadline', () async {
    await player.disposeAsync();
    player.dispose();
    backend = _Backend();
    player = PlayerController(
      client: auth.client,
      itemId: 'movie-up',
      backend: backend,
      window: PlayerWindow(),
      playbackLineSnapshot: auth.savedServers.single.lines,
      initialLineSelection: LineSelection.fixed(aId),
      verifiedPlaybackServerId: a.serverId,
      switchDispatcher: (command) async {
        expect(command['action'], 'commitLine');
        return <String, dynamic>{};
      },
      autoResume: false,
      recoveryTimeout: const Duration(milliseconds: 250),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      settingsStore: MemoryPlayerSettingsStore(),
    );
    await player.start();
    await player.switchLine(bId);
    expect(backend.attachedBudget, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect((await player.client.getItem('movie-up')).id, 'movie-up');
    expect(player.client.baseUrl, b.baseUrl);
    expect(auth.client.baseUrl, a.baseUrl);
    expect(player.isPlaying, true);
  });

  for (final cancelled in [true, false]) {
    test(
      'desktop line commit rejects ${cancelled ? 'cancellation during blocked save' : 'expired helper deadline'}',
      () async {
        final runtime = player.runtime!;
        await player.disposeAsync();
        final process = _Process();
        final host = DesktopPlayerWindowHost(
          auth: auth,
          runtime: runtime,
          processControl: process,
          watchInterval: const Duration(milliseconds: 5),
        );
        Completer<void>? gate;
        try {
          await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
          final launch = PlayerWindowLaunch.fromArguments(
            process.spawnedArguments.single,
          );
          final envelope = {
            'pid': process.lastPid,
            'source': encodeSource(launch.request.source!),
            'generation': launch.accessGeneration,
          };
          final entered = store.entered = Completer<void>();
          if (cancelled) gate = store.gate = Completer<void>();
          process.command = {
            ...envelope,
            'sequence': 1,
            'action': 'commitLine',
            'line': bId,
            'selection': LineSelection.fixed(bId).toJson(),
            'item': 'movie-up',
            'version': player.resolved!.mediaSource.id,
            'deadlineUtc': DateTime.now()
                .toUtc()
                .add(Duration(seconds: cancelled ? 2 : -1))
                .toIso8601String(),
          };
          if (cancelled) {
            await entered.future.timeout(const Duration(seconds: 1));
            process.cancellation = {
              ...envelope,
              'sequence': 2,
              'action': 'cancelLine',
            };
            expect(
              (await process.cancelled.future.timeout(
                const Duration(seconds: 1),
              ))['accepted'],
              true,
            );
            // The cancellation receipt must arrive while the ordinary save is held.
            expect(process.receipt.isCompleted, false);
            gate!.complete();
          }
          expect(
            (await process.receipt.future.timeout(
              const Duration(seconds: 2),
            ))['accepted'],
            false,
          );
          expect(
            (await store.load()).servers.single.lineSelection,
            LineSelection.fixed(aId),
          );
          expect(auth.client.baseUrl, a.baseUrl);
          if (!cancelled) expect(entered.isCompleted, false);
        } finally {
          if (gate != null && !gate.isCompleted) gate.complete();
          await host.close();
          host.dispose();
        }
      },
    );
  }

  for (final kind in [
    PlaybackRecoveryFailureKind.forbidden,
    PlaybackRecoveryFailureKind.certificate,
    PlaybackRecoveryFailureKind.rateLimited,
  ]) {
    test('${kind.name} is not retried as a network failure', () async {
      await player.selectPlaybackLine(const LineSelection.auto());
      final count = backend.opens.length;
      backend.emitEvent(
        VideoEventKind.error,
        PlaybackRecoveryFailure(
          kind,
          retryAfter: kind == PlaybackRecoveryFailureKind.rateLimited
              ? const Duration(seconds: 30)
              : null,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.opens.length, count);
      expect(player.isRecovering, false);
      expect(player.state.phase, PlaybackPhase.failed);
      expect(player.loadFailure, isNotNull);
    });
  }
}
