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
import 'package:rillight/player/player_process_protocol.dart';
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

class _ConfirmationProcess extends _Process {
  _ConfirmationProcess(this.helper);
  final PlayerController helper;
  final pending = Completer<void>();
  Map<String, dynamic>? result;
  @override
  Future<Map<String, dynamic>?> lineSelectionResult(int pid) async => result;
  @override
  Future<void> requestLineSelection(
    int pid,
    Map<String, dynamic> command,
  ) async {
    if (command['cancel'] == true) {
      helper.cancelPendingPlaybackLineRequest();
      return;
    }
    unawaited(_run(command));
  }

  Future<void> _run(Map<String, dynamic> command) async {
    try {
      await helper.selectPlaybackLineWithConfirmation(
        LineSelection.fromJson(command['selection']),
        deadlineUtc: DateTime.parse(command['deadlineUtc'] as String),
        guard: () {},
        onNeedsSelection: () async {
          result = {
            'sequence': command['sequence'],
            'status': 'needsSelection',
            'accepted': false,
          };
          pending.complete();
        },
      );
      result = {
        'sequence': command['sequence'],
        'status': 'committed',
        'accepted': true,
      };
    } catch (_) {
      result = {
        'sequence': command['sequence'],
        'status': 'failed',
        'accepted': false,
      };
    }
  }
}

class _MailboxProcess extends _ConfirmationProcess {
  _MailboxProcess(super.helper, this.endpoint);
  final PlayerProcessProtocol endpoint;
  final firstEntered = Completer<void>();
  final firstWritten = Completer<void>();
  final secondWritten = Completer<void>();
  Completer<void>? firstWriteGate;

  @override
  Future<void> requestLineSelection(
    int pid,
    Map<String, dynamic> command,
  ) async {
    if (command['sequence'] == 1 && command['cancel'] != true) {
      firstEntered.complete();
      await firstWriteGate?.future;
    }
    await endpoint.write('line-selection', command);
    if (command['sequence'] == 1 && command['cancel'] != true) {
      firstWritten.complete();
    }
    if (command['sequence'] == 2 && command['cancel'] != true) {
      secondWritten.complete();
    }
  }

  Future<void> pollHelper() async {
    final command = await endpoint.read('line-selection');
    if (command != null) await super.requestLineSelection(lastPid, command);
  }
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
  int? playbackStatus;
  Completer<void>? gate;
  String? gatedHost;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    if (options.uri.host == gatedHost) await gate?.future;
    if (playbackStatus != null && options.uri.path.endsWith('/PlaybackInfo')) {
      return ResponseBody.fromString('{}', playbackStatus!);
    }
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

class _Backend extends FakeVideoBackend
    implements
        VideoBackendRecoveryBudget,
        VideoBackendSourceRenewal,
        VideoBackendSourceRenewalFeedback {
  final renewalResults = <bool>[];
  final renewals = <Uri>[];
  Completer<void>? renewalGate;
  bool rejectRenewal = false;
  @override
  Future<void> refreshSourceUrl(Uri url) async {
    renewals.add(url);
    await renewalGate?.future;
    if (rejectRenewal) throw StateError('Synthetic renewal failure');
  }

  @override
  void finishSourceRenewal({required bool succeeded}) =>
      renewalResults.add(succeeded);
  PlaybackRecoveryBudget? attachedBudget;
  final attachedRemaining = <Duration>[];
  @override
  set recoveryBudget(PlaybackRecoveryBudget? value) {
    attachedBudget = value;
    if (value != null) attachedRemaining.add(value.remaining);
  }

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

  for (final automatic in [false, true]) {
    for (final missingStream in [false, true]) {
      test(
        'initial content failure stays actionable without trying backup automatic=$automatic missingStream=$missingStream',
        () async {
          final runtime = player.runtime!;
          await player.disposeAsync();
          player.dispose();
          if (automatic) {
            await auth.selectLine(serverId, const LineSelection.auto());
          }
          final item = a.items.firstWhere((item) => item.id == 'movie-up');
          if (missingStream) {
            item.supportsDirectPlay = false;
            item.supportsDirectStream = false;
          } else {
            item.type = 'Folder';
          }
          final backupRequests = b.requests.length;
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
          expect(
            player.error,
            missingStream
                ? PlayerErrorKind.noStream
                : PlayerErrorKind.notPlayable,
          );
          expect(player.disconnected, isFalse);
          expect(player.isRecovering, isFalse);
          expect(player.loading, isFalse);
          expect(player.playbackLineFailure, isNull);
          expect(backend.opens, isEmpty);
          expect(b.requests.length, backupRequests);
          expect(auth.savedServers.single.activeLineId, aId);
          expect(backend.attachedBudget, isNull);
        },
      );
    }
  }

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

  test(
    'cancelling a line confirmation leaves no stale confirm-me failure',
    () async {
      await player.seekTo(const Duration(minutes: 4));
      b.items.firstWhere((m) => m.id == 'movie-up').runtime = const Duration(
        minutes: 2,
      );
      await expectLater(player.switchLine(bId), throwsA(anything));
      expect(player.switchConfirmation, isNotNull);
      // 确认面板本身就是提示，不再叠一条「请确认后继续」。
      expect(player.playbackLineFailure, isNull);
      await player.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
      expect(player.switchConfirmation, isNull);
      expect(player.playbackLineFailure, isNull);
      expect(player.switchingLineId, isNull);
      expect(player.isPlaying, true);
    },
  );

  test(
    'a secondary subtitle the target lacks is dropped, not a dead-end',
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
        FakeMediaStream(
          index: 3,
          type: 'Subtitle',
          codec: 'subrip',
          language: 'eng',
          isTextSubtitleStream: true,
        ),
      ];
      a.items.firstWhere((m) => m.id == 'movie-up').mediaStreams = tracks;
      b.items.firstWhere((m) => m.id == 'movie-up').mediaStreams = tracks
          .take(3)
          .toList();
      await player.start();
      await player.setSubtitle(2);
      await player.setSecondarySubtitle(3);
      expect(player.secondarySubtitleStreamIndex, 3);
      await player.switchLine(bId);
      expect(player.activeLineId, bId);
      expect(player.client.baseUrl, b.baseUrl);
      expect(player.subtitleStreamIndex, 2);
      expect(player.secondarySubtitleStreamIndex, isNull);
      expect(player.switchConfirmation, isNull);
      expect(player.playbackLineFailure, isNull);
      expect(player.isPlaying, true);
    },
  );

  test('a line switch reports the tapped line while it is checked', () async {
    adapter.gatedHost = b.baseUrl.host;
    adapter.gate = Completer<void>();
    final work = player.switchLine(bId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // 预检还在等网络：点下去马上就有「正在切换」，不是没反应。
    expect(player.switchingLineId, bId);
    adapter.gate!.complete();
    await work;
    expect(player.switchingLineId, isNull);
    expect(player.activeLineId, bId);
  });

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

  test(
    'helper startup preserves missing stream without requesting line recovery',
    () async {
      await player.disposeAsync();
      player.dispose();
      final item = a.items.firstWhere((item) => item.id == 'movie-up');
      item.supportsDirectPlay = false;
      item.supportsDirectStream = false;
      backend = _Backend();
      var commands = 0;
      player = PlayerController(
        client: auth.client,
        itemId: 'movie-up',
        backend: backend,
        window: PlayerWindow(),
        playbackLineSnapshot: auth.savedServers.single.lines,
        initialLineSelection: const LineSelection.auto(),
        recoveryDeadlineUtc: DateTime.now().toUtc().add(
          const Duration(seconds: 45),
        ),
        recoveryAttemptDeadlineUtc: DateTime.now().toUtc().add(
          const Duration(seconds: 5),
        ),
        switchDispatcher: (_) async {
          commands++;
          return <String, dynamic>{};
        },
        autoResume: false,
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      );
      await player.start();
      expect(player.error, PlayerErrorKind.noStream);
      expect(player.disconnected, isFalse);
      expect(player.isRecovering, isFalse);
      expect(player.loading, isFalse);
      expect(player.playbackLineFailure, isNull);
      expect(backend.attachedBudget, isNull);
      expect(backend.opens, isEmpty);
      expect(commands, 0);
    },
  );

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

  test(
    'desktop auto on the playing line saves without probing that line',
    () async {
      final runtime = player.runtime!;
      await player.disposeAsync();
      final item = a.items.firstWhere((entry) => entry.id == 'movie-up');
      item.mediaStreams = const [
        FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
      ];
      final process = _Process();
      final host = DesktopPlayerWindowHost(
        auth: auth,
        runtime: runtime,
        processControl: process,
        watchInterval: const Duration(milliseconds: 5),
      );
      try {
        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        final launch = PlayerWindowLaunch.fromArguments(
          process.spawnedArguments.single,
        );
        process.command = {
          'pid': process.lastPid,
          'source': encodeSource(launch.request.source!),
          'generation': launch.accessGeneration,
          'sequence': 1,
          'action': 'commitLine',
          'line': aId,
          'selection': const LineSelection.auto().toJson(),
          'item': 'movie-up',
          // The playing source is absent from the item catalogue. Re-resolving
          // would reject the preference even though this line is already open.
          'version': 'playing-source',
          'deadlineUtc': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 2))
              .toIso8601String(),
        };
        final reply = await process.receipt.future.timeout(
          const Duration(seconds: 2),
        );
        expect(reply['accepted'], true);
        expect(reply['selection'], const LineSelection.auto().toJson());
        expect(
          (await store.load()).servers.single.lineSelection.isAutomatic,
          isTrue,
        );
        expect(auth.client.baseUrl, a.baseUrl);
      } finally {
        await host.close();
        host.dispose();
      }
    },
  );

  for (final outcome in [
    'commit',
    'cancel',
    'expire',
    'save failure',
    'save timeout',
    'supersede',
  ]) {
    test('desktop list confirmation stays pending until $outcome', () async {
      await player.seekTo(const Duration(minutes: 4));
      b.items.firstWhere((m) => m.id == 'movie-up').runtime = const Duration(
        minutes: 2,
      );
      final process = _ConfirmationProcess(player);
      final host = DesktopPlayerWindowHost(
        auth: auth,
        runtime: player.runtime!,
        processControl: process,
        watchInterval: const Duration(milliseconds: 5),
        lineSelectionTimeout: Duration(
          milliseconds: outcome == 'expire' || outcome == 'save timeout'
              ? 400
              : 2000,
        ),
      );
      try {
        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        var settled = false;
        final work = auth.chooseConnection(serverId, LineSelection.fixed(bId));
        final receipt = outcome == 'commit'
            ? work.then((_) => settled = true)
            : expectLater(work, throwsA(anything)).then((_) => settled = true);
        await process.pending.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(settled, false);
        expect(player.switchConfirmation, isNotNull);
        expect(player.isPlaying, true);
        expect(player.position, const Duration(minutes: 4));
        expect(
          (await store.load()).servers.single.lineSelection,
          LineSelection.fixed(aId),
        );
        if (outcome == 'commit') {
          final gate = store.gate = Completer<void>();
          final entered = store.entered = Completer<void>();
          final confirmation = player.confirmMediaSourceSwitch(
            SwitchResumeChoice.beginning,
          );
          await entered.future;
          expect(settled, false);
          expect(process.result!['accepted'], false);
          gate.complete();
          await confirmation;
        } else if (outcome == 'save timeout') {
          final gate = store.gate = Completer<void>();
          final entered = store.entered = Completer<void>();
          final rolledBack = Completer<void>();
          store.onSaved = (snapshot) {
            if (snapshot.servers.single.lineSelection ==
                    LineSelection.fixed(aId) &&
                !rolledBack.isCompleted) {
              rolledBack.complete();
            }
          };
          final confirmation = expectLater(
            player.confirmMediaSourceSwitch(SwitchResumeChoice.beginning),
            throwsA(anything),
          );
          await entered.future;
          await receipt.timeout(const Duration(seconds: 1));
          expect(player.isPlaying, false);
          gate.complete();
          await confirmation;
          await rolledBack.future.timeout(const Duration(seconds: 1));
        } else if (outcome == 'cancel') {
          await player.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
        } else if (outcome == 'save failure') {
          store.rejectNext = true;
          await expectLater(
            player.confirmMediaSourceSwitch(SwitchResumeChoice.beginning),
            throwsA(anything),
          );
        } else if (outcome == 'supersede') {
          await player.start();
        }
        await receipt.timeout(const Duration(seconds: 3));
        expect(
          (await store.load()).servers.single.lineSelection,
          LineSelection.fixed(outcome == 'commit' ? bId : aId),
        );
        expect(player.isPlaying, outcome != 'save timeout');
        expect(player.activeLineId, outcome == 'commit' ? bId : aId);
        expect(player.switchConfirmation, isNull);
      } finally {
        await host.close();
        host.dispose();
      }
    });
  }

  test('automatic selection saves while the current line is down', () async {
    backend.emitEvent(VideoEventKind.error, 'Connection lost');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(player.disconnected, isTrue);
    expect(player.state.phase, PlaybackPhase.failed);
    final opens = backend.opens.length;
    await player.selectPlaybackLine(const LineSelection.auto());
    expect(player.playbackLineSelection.isAutomatic, isTrue);
    expect(
      (await store.load()).servers.single.lineSelection.isAutomatic,
      isTrue,
    );
    expect(player.disconnected, isTrue);
    expect(player.state.phase, PlaybackPhase.failed);
    expect(player.isPlaying, isFalse);
    expect(player.activeLineId, aId);
    expect(backend.opens.length, opens);
  });

  test(
    'automatic line order uses measured latency before fallback preference',
    () {
      const lines = [
        ServerLine(id: 'last', address: 'http://last.test', latencyMs: 180),
        ServerLine(id: 'fast', address: 'http://fast.test', latencyMs: 24),
        ServerLine(id: 'unknown', address: 'http://unknown.test'),
      ];
      expect(
        automaticPlaybackLineOrder(
          lines: lines,
          lastSuccessfulLineId: 'last',
          activeLineId: 'last',
        ).map((line) => line.id),
        ['fast', 'last', 'unknown'],
      );
    },
  );

  test(
    'automatic playback tries the last successful line before the others',
    () async {
      final runtime = player.runtime!;
      await player.switchLine(bId);
      expect(auth.savedServers.single.lastSuccessfulLineId, bId);
      final server = auth.savedServers.single;
      await player.disposeAsync();
      player.dispose();
      Future<void> save(LineSelection selection) => auth.saveConfiguration(
        serverId,
        nickname: server.nickname ?? '',
        iconId: server.iconId,
        userAgent: server.userAgent ?? '',
        lines: server.lines,
        lineSelection: selection,
      );
      await save(LineSelection.fixed(aId));
      await save(const LineSelection.auto());
      expect(auth.savedServers.single.activeLineId, aId);
      expect(auth.savedServers.single.lastSuccessfulLineId, bId);
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
      await player.start();
      expect(backend.opens, [b.baseUrl.host]);
      expect(player.activeLineId, bId);
      expect(player.playbackLineSelection.isAutomatic, isTrue);
      expect(player.disconnected, isFalse);
      expect(player.error, isNull);
      expect(player.state.phase, isNot(PlaybackPhase.failed));
      expect(player.isPlaying, isTrue);
    },
  );

  test('failed automatic start still runs the ordinary open', () async {
    final runtime = player.runtime!;
    await player.disposeAsync();
    player.dispose();
    await auth.selectLine(serverId, const LineSelection.auto());
    backend = _Backend();
    backend.reject.addAll([a.baseUrl.host, b.baseUrl.host]);
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
    await player.start();
    expect(player.state.phase, PlaybackPhase.failed);
    expect(player.playbackLineSelection.isAutomatic, isTrue);
    expect(backend.opens.length, greaterThan(2));
  });

  test(
    'automatic failure keeps the watch position for retry or line choice',
    () async {
      await player.seekTo(const Duration(minutes: 4));
      await player.selectPlaybackLine(const LineSelection.auto());
      adapter.offline.add(a.baseUrl.host);
      adapter.offline.add(b.baseUrl.host);
      backend.emitEvent(VideoEventKind.error, 'Connection lost');
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline) &&
          (!player.disconnected || player.isRecovering)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(player.isRecovering, isFalse);
      expect(player.position, const Duration(minutes: 4));
      expect(player.state.phase, PlaybackPhase.failed);
      expect(player.disconnected, isTrue);
      expect(player.playbackLineSelection.isAutomatic, isTrue);
      expect(player.activeLineId, aId);
      expect(backend.opens.where((host) => host == b.baseUrl.host), isEmpty);
    },
  );

  for (final commit in [true, false]) {
    test(
      'automatic recovery asks before a shorter backup commit=$commit',
      () async {
        await player.seekTo(const Duration(minutes: 4));
        b.items.firstWhere((m) => m.id == 'movie-up').runtime = const Duration(
          minutes: 2,
        );
        await player.selectPlaybackLine(const LineSelection.auto());
        adapter.offline.add(a.baseUrl.host);
        backend.emitEvent(VideoEventKind.error, 'Connection lost');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline) &&
            (player.switchConfirmation == null || player.isRecovering)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(player.switchConfirmation, isNotNull);
        expect(player.isRecovering, isFalse);
        expect(player.position, const Duration(minutes: 4));
        expect(backend.opens.where((host) => host == b.baseUrl.host), isEmpty);
        if (commit) {
          await player.confirmMediaSourceSwitch(SwitchResumeChoice.beginning);
          expect(player.activeLineId, bId);
          expect(player.isPlaying, isTrue);
          expect(player.disconnected, isFalse);
          expect(player.state.phase, isNot(PlaybackPhase.failed));
        } else {
          await player.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
          expect(player.activeLineId, aId);
          expect(player.isPlaying, isFalse);
        }
        expect(player.playbackLineSelection.isAutomatic, isTrue);
        expect(player.switchConfirmation, isNull);
      },
    );
  }

  for (final delayedWrite in [false, true]) {
    test(
      'late helper reads latest selection after supersession delayedWrite=$delayedWrite',
      () async {
        final endpoint = await PlayerProcessProtocol.create();
        final process = _MailboxProcess(player, endpoint);
        if (delayedWrite) process.firstWriteGate = Completer<void>();
        final host = DesktopPlayerWindowHost(
          auth: auth,
          runtime: player.runtime!,
          processControl: process,
          lineSelectionTimeout: const Duration(seconds: 2),
        );
        try {
          await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
          final first = expectLater(
            auth.chooseConnection(serverId, LineSelection.fixed(bId)),
            throwsA(anything),
          );
          await process.firstEntered.future;
          if (!delayedWrite) await process.firstWritten.future;
          final second = auth.chooseConnection(
            serverId,
            const LineSelection.auto(),
          );
          // Neither helper read nor first write completion is required for the
          // newer user intent to take ownership of the command slot.
          await Future<void>.delayed(const Duration(milliseconds: 60));
          process.firstWriteGate?.complete();
          await process.secondWritten.future.timeout(
            const Duration(seconds: 1),
          );
          await first;
          final message = await endpoint.read('line-selection', consume: false);
          expect(message!['sequence'], 2);
          expect(message['cancel'], isNull);
          await process.pollHelper();
          await second.timeout(const Duration(seconds: 1));
          expect(
            (await store.load()).servers.single.lineSelection,
            const LineSelection.auto(),
          );
          expect(player.activeLineId, aId);
          expect(backend.opens, [a.baseUrl.host]);
        } finally {
          if (process.firstWriteGate != null &&
              !process.firstWriteGate!.isCompleted) {
            process.firstWriteGate!.complete();
          }
          await host.close();
          host.dispose();
          await endpoint.dispose();
        }
      },
    );
  }

  test(
    'current expired host request still replaces its mailbox with cancellation',
    () async {
      final endpoint = await PlayerProcessProtocol.create();
      final process = _MailboxProcess(player, endpoint);
      final host = DesktopPlayerWindowHost(
        auth: auth,
        runtime: player.runtime!,
        processControl: process,
        lineSelectionTimeout: const Duration(milliseconds: 150),
      );
      try {
        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        await expectLater(
          auth.chooseConnection(serverId, LineSelection.fixed(bId)),
          throwsA(isA<TimeoutException>()),
        );
        final message = await endpoint.read('line-selection', consume: false);
        expect(message!['sequence'], 1);
        expect(message['cancel'], true);
        await process.pollHelper();
        expect(
          (await store.load()).servers.single.lineSelection,
          LineSelection.fixed(aId),
        );
        expect(backend.opens, [a.baseUrl.host]);
      } finally {
        await host.close();
        host.dispose();
        await endpoint.dispose();
      }
    },
  );

  test(
    'superseded confirmation cannot settle or cancel the next confirmation',
    () async {
      await player.seekTo(const Duration(minutes: 4));
      b.items.firstWhere((m) => m.id == 'movie-up').runtime = const Duration(
        minutes: 2,
      );
      final firstPending = Completer<void>();
      final secondPending = Completer<void>();
      final first = expectLater(
        player.selectPlaybackLineWithConfirmation(
          LineSelection.fixed(bId),
          deadlineUtc: DateTime.now().toUtc().add(const Duration(seconds: 2)),
          guard: () {},
          onNeedsSelection: () async => firstPending.complete(),
        ),
        throwsA(anything),
      );
      await firstPending.future;
      var committed = false;
      final second = player
          .selectPlaybackLineWithConfirmation(
            LineSelection.fixed(bId),
            deadlineUtc: DateTime.now().toUtc().add(const Duration(seconds: 2)),
            guard: () {},
            onNeedsSelection: () async => secondPending.complete(),
          )
          .then((_) => committed = true);
      await secondPending.future;
      await first;
      expect(committed, false);
      expect(player.switchConfirmation, isNotNull);
      expect(player.isPlaying, true);
      await player.confirmMediaSourceSwitch(SwitchResumeChoice.beginning);
      await second;
      expect(committed, true);
      expect(player.activeLineId, bId);
      expect(
        (await store.load()).servers.single.lineSelection,
        LineSelection.fixed(bId),
      );
    },
  );

  test('completed host policy does not lend its deadline to a later local confirmation', () async {
    await player.seekTo(const Duration(minutes: 4));
    b.items.firstWhere((m) => m.id == 'movie-up').runtime = const Duration(
      minutes: 2,
    );
    await player.selectPlaybackLineWithConfirmation(
      const LineSelection.auto(),
      deadlineUtc: DateTime.now().toUtc().add(
        const Duration(milliseconds: 100),
      ),
      guard: () {},
      onNeedsSelection: () async =>
          fail('Healthy policy change needs no confirmation'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    adapter.offline.add(a.baseUrl.host);
    backend.emitEvent(VideoEventKind.error, 'Connection lost');
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    do {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    } while (player.isRecovering && DateTime.now().isBefore(deadline));
    expect(player.switchConfirmation, isNotNull);
    await player.confirmMediaSourceSwitch(SwitchResumeChoice.beginning);
    expect(player.activeLineId, bId);
    expect(player.isPlaying, true);
  });

  for (final mandatory in [false, true]) {
    for (final automatic in [false, true]) {
      test(
        'failed source renewal mandatory=$mandatory automatic=$automatic settles',
        () async {
          if (automatic) {
            await player.selectPlaybackLine(const LineSelection.auto());
          }
          adapter.offline.add(a.baseUrl.host);
          backend.emitEvent(
            VideoEventKind.sourceRefreshRequired,
            mandatory ? const RequiredSourceRenewal(403) : 404,
          );
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          do {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          } while ((player.isRecovering ||
                  (mandatory && backend.renewalResults.isEmpty)) &&
              DateTime.now().isBefore(deadline));
          expect(player.isRecovering, false);
          expect(backend.renewalResults, mandatory ? [false] : isEmpty);
          if (!mandatory) {
            expect(player.isPlaying, true);
            expect(player.disconnected, false);
            expect(backend.opens, [a.baseUrl.host]);
          } else if (automatic) {
            expect(player.activeLineId, bId);
            expect(player.isPlaying, true);
            expect(backend.opens, [a.baseUrl.host, b.baseUrl.host]);
          } else {
            expect(player.state.phase, PlaybackPhase.failed);
            expect(player.disconnected, true);
            expect(player.playbackLineFailure, isNotNull);
            expect(backend.opens, [a.baseUrl.host]);
          }
        },
      );
    }
  }

  test(
    'successful mandatory source renewal preserves playing session',
    () async {
      backend.emitEvent(
        VideoEventKind.sourceRefreshRequired,
        const RequiredSourceRenewal(403),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (backend.renewalResults.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(backend.renewalResults, [true]);
      expect(backend.renewals, hasLength(1));
      expect(backend.opens, [a.baseUrl.host]);
      expect(player.isRecovering, false);
      expect(player.isPlaying, true);
    },
  );

  test(
    'mandatory renewal timeout shares root deadline and ignores late result',
    () async {
      await player.selectPlaybackLine(const LineSelection.auto());
      backend.renewalGate = Completer<void>();
      backend.emitEvent(
        VideoEventKind.sourceRefreshRequired,
        const RequiredSourceRenewal(403),
      );
      final elapsed = Stopwatch()..start();
      do {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      } while ((backend.renewalResults.isEmpty || player.isRecovering) &&
          elapsed.elapsed < const Duration(seconds: 3));
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 2600)));
      expect(backend.renewalResults, [false]);
      expect(player.isRecovering, false);
      expect(player.state.phase, PlaybackPhase.failed);
      expect(backend.opens, [a.baseUrl.host]);
      backend.renewalGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.state.phase, PlaybackPhase.failed);
      expect(backend.opens, [a.baseUrl.host]);
    },
  );

  test('foreground request escalates optional renewal and core failure uses remaining budget', () async {
    await player.selectPlaybackLine(const LineSelection.auto());
    backend.attachedRemaining.clear();
    backend.renewalGate = Completer<void>();
    backend.emitEvent(VideoEventKind.sourceRefreshRequired, 404);
    while (backend.renewals.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(player.isRecovering, false);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    backend.emitEvent(
      VideoEventKind.sourceRefreshRequired,
      const RequiredSourceRenewal(403),
    );
    backend.emitEvent(VideoEventKind.error, 'Connection lost');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(player.isRecovering, true);
    expect(backend.opens, [a.baseUrl.host]);
    adapter.offline.add(a.baseUrl.host);
    backend.renewalGate!.complete();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (player.isRecovering && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(backend.renewals, hasLength(1));
    expect(backend.renewalResults, [true]);
    expect(player.activeLineId, bId);
    expect(player.isPlaying, true);
    expect(backend.attachedRemaining, isNotEmpty);
    expect(
      backend.attachedRemaining.first,
      lessThan(const Duration(milliseconds: 1500)),
    );
  });

  for (final status in [401, 403]) {
    test(
      'mandatory renewal HTTP $status terminates without probing backup',
      () async {
        await player.selectPlaybackLine(const LineSelection.auto());
        adapter.playbackStatus = status;
        backend.emitEvent(
          VideoEventKind.sourceRefreshRequired,
          const RequiredSourceRenewal(403),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (backend.renewalResults.isEmpty &&
            !player.sessionExpired &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(backend.renewalResults, status == 401 ? isEmpty : [false]);
        expect(player.isRecovering, false);
        expect(player.state.phase, PlaybackPhase.failed);
        expect(player.sessionExpired, status == 401);
        if (status == 403) {
          expect(
            PlaybackRecoveryCoordinator.classify(player.loadFailure!),
            PlaybackRecoveryFailureKind.rateLimited,
          );
        }
        expect(backend.opens, [a.baseUrl.host]);
      },
    );
  }

  for (final intent in ['restart', 'cancel', 'dispose']) {
    test('mandatory renewal cannot change playback after $intent', () async {
      backend.renewalGate = Completer<void>();
      backend.emitEvent(
        VideoEventKind.sourceRefreshRequired,
        const RequiredSourceRenewal(403),
      );
      while (backend.renewals.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(player.isRecovering, true);
      if (intent == 'restart') {
        await player.start();
        expect(player.isPlaying, true);
        expect(player.isRecovering, false);
      } else if (intent == 'cancel') {
        player.cancelLineRecovery();
      } else {
        await player.disposeAsync();
      }
      final opens = backend.opens.length;
      backend.renewalGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(backend.opens, hasLength(opens));
      expect(backend.renewalResults, isEmpty);
      if (intent == 'restart') {
        expect(player.isPlaying, true);
        expect(player.isRecovering, false);
      } else if (intent == 'cancel') {
        expect(player.state.phase, PlaybackPhase.failed);
        expect(player.isRecovering, false);
      }
    });
  }

  for (final kind in [
    PlaybackRecoveryFailureKind.forbidden,
    PlaybackRecoveryFailureKind.certificate,
    PlaybackRecoveryFailureKind.rateLimited,
  ]) {
    test(
      '${kind.name} successful retry clears cause for later network recovery',
      () async {
        await player.selectPlaybackLine(const LineSelection.auto());
        backend.emitEvent(
          VideoEventKind.error,
          PlaybackRecoveryFailure(
            kind,
            retryAfter: kind == PlaybackRecoveryFailureKind.rateLimited
                ? const Duration(milliseconds: 10)
                : null,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(player.loadFailure, isNotNull);
        expect(player.playbackLineFailure, isNotNull);
        await player.retryPlayback();
        expect(player.isPlaying, true);
        expect(player.loadFailure, isNull);
        expect(player.playbackLineFailure, isNull);
        expect(player.playbackRetryAfter, isNull);
        adapter.offline.add(a.baseUrl.host);
        backend.emitEvent(VideoEventKind.error, 'Connection lost');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        do {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        } while (player.isRecovering && DateTime.now().isBefore(deadline));
        expect(player.activeLineId, bId);
        expect(player.isPlaying, true);
        expect(
          backend.opens.where((host) => host == b.baseUrl.host),
          hasLength(1),
        );
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
