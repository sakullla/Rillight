import 'dart:async';
import 'package:rillight/aggregation/query/aggregation_query.dart';
import 'package:rillight/aggregation/query/same_source_query.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_process_control.dart';
import '../player/fake_player_process_control.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

class _Client extends EmbyClient {
  _Client(this.reports)
    : super(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'runtime',
          version: '1',
        ),
      );
  final List<PlaybackReport> reports;
  bool failProgress = false;
  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async => PublicServerInfo(
    id: baseUrl.host == 'wrong'
        ? 'foreign'
        : baseUrl.host == 'b'
        ? 'b'
        : 'a',
    serverName: 'test',
  );
  @override
  Future<EmbyUser> getUser() async => EmbyUser(id: userId!, name: 'test');
  @override
  Future<EmbyItem> getItem(String id, {String? fields}) async =>
      EmbyItem.fromJson({
        'Id': id,
        'Name': id,
        'Type': id == 'library' ? 'CollectionFolder' : 'Movie',
        if (id != 'library')
          'ParentId': (id == 'foreign' || id == 'other') ? 'other' : 'library',
        'RunTimeTicks': 120 * kEmbyTicksPerSecond,
        'ProviderIds': {'Tmdb': '1'},
      });
  @override
  Future<PlaybackInfo> getPlaybackInfo({
    required String itemId,
    String? mediaSourceId,
    int? maxStreamingBitrate,
    int? startTimeTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    Map<String, dynamic>? deviceProfile,
    bool forceTranscode = false,
  }) async => PlaybackInfo.fromJson({
    'PlaySessionId': 'play-${baseUrl!.host}-$itemId',
    'MediaSources': [
      for (final id in ['v', 'v2'])
        {
          'Id': id,
          'Name': id,
          'Container': 'mp4',
          'SupportsDirectPlay': true,
          'SupportsDirectStream': true,
          'RunTimeTicks': 120 * kEmbyTicksPerSecond,
          'MediaStreams': [
            {'Index': id == 'v' ? 1 : 7, 'Type': 'Audio', 'Language': 'jpn'},
          ],
        },
    ],
  });
  @override
  Future<void> reportPlaying(PlaybackReport report) async {}
  @override
  Future<void> reportProgress(PlaybackReport report) async {
    if (failProgress) throw StateError('synthetic report failure');
  }

  @override
  Future<void> reportStopped(PlaybackReport report) async {
    reports.add(report);
  }
}

class _Backend extends FakeVideoBackend {
  _Backend() : super(duration: const Duration(seconds: 120));
  bool failNextOpen = false;
  Completer<void>? openGate;
  Completer<void>? openEntered;
  @override
  Future<void> open(VideoOpenRequest request) async {
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('synthetic target failure');
    }
    openEntered?.complete();
    openEntered = null;
    await openGate?.future;
    await super.open(request);
  }
}

class _IpcControl extends FakePlayerProcessControl
    implements PlayerHistoryProcessControl {
  _IpcControl() : super(requestCloseResult: true);
  Map<String, dynamic>? event;
  Map<String, dynamic>? command;
  Map<String, dynamic>? receipt;
  Map<String, dynamic>? switchReply;
  bool revoked = false;
  Map<String, dynamic>? reportOutcome;
  @override
  Future<Map<String, dynamic>?> consumeReportOutcome(int pid) async {
    final result = reportOutcome;
    reportOutcome = null;
    return result;
  }

  @override
  Future<Map<String, dynamic>?> consumeWatchEvent(int pid) async {
    final result = event;
    event = null;
    return result;
  }

  @override
  Future<void> acknowledgeWatchEvent(
    int pid,
    Map<String, dynamic> value,
  ) async {
    receipt = value;
  }

  @override
  Future<void> revoke(
    int pid,
    int generation, {
    bool reportStopped = false,
  }) async {
    revoked = true;
  }

  @override
  Future<Map<String, dynamic>?> consumeSwitchCommand(int pid) async {
    final result = command;
    command = null;
    return result;
  }

  @override
  Future<void> replySwitchCommand(int pid, Map<String, dynamic> value) async {
    switchReply = value;
  }
}

Future<void> _eventually(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

void main() {
  late AuthController auth;
  late PlaybackRuntime runtime;
  late PlayerController controller;
  late _Backend backend;
  late SourceAccount account;
  late List<PlaybackReport> reports;
  late MemoryPlaybackSessionSnapshotStore snapshots;

  Future<void> setup({bool private = false}) async {
    reports = [];
    final access = RegionAccessController();
    if (private) {
      await access.setPin('1234', '1234', (_) async {});
      await access.unlock('1234');
    }
    final store = MemoryServerListStore(
      ServerListSnapshot(
        servers: [
          SavedServer(
            id: 'a',
            name: 'a',
            username: 'test',
            region: private ? AccessRegion.private : AccessRegion.ordinary,
            libraryIds: const ['library'],
            scopeKnown: true,
            lines: const [
              ServerLine(id: 'line', address: 'https://a'),
              ServerLine(id: 'wrong', address: 'https://wrong'),
              ServerLine(id: 'mirror', address: 'https://mirror'),
            ],
          ),
          SavedServer(
            id: 'b',
            name: 'b',
            username: 'test',
            region: private ? AccessRegion.private : AccessRegion.ordinary,
            libraryIds: const ['library'],
            scopeKnown: true,
            lines: const [ServerLine(id: 'line', address: 'https://b')],
          ),
        ],
      ),
    );
    final credentials = MemoryCredentialStore({
      'b': const StoredCredentials(
        accessToken: 'token-b',
        userId: 'user-b',
        username: 'test',
      ),
      'a': const StoredCredentials(
        accessToken: 'token',
        userId: 'user',
        username: 'test',
      ),
    });
    final registry = SourceSessionRegistry(
      access: access,
      store: store,
      credentials: credentials,
      createClient: () => _Client(reports),
    );
    await registry.load();
    account = (await registry.authenticate('a')).account;
    auth = AuthController(
      client: _Client(reports),
      credentials: credentials,
      servers: store,
      sources: registry,
    );
    runtime = PlaybackRuntime(
      auth: auth,
      history: await HistoryWriter.open(
        registry: registry,
        store: MemoryHistoryStore(),
      ),
    );
    backend = _Backend();
    snapshots = MemoryPlaybackSessionSnapshotStore();
    controller = PlayerController(
      client: auth.client,
      itemId: 'movie',
      backend: backend,
      window: PlayerWindow(),
      runtime: runtime,
      snapshotStore: snapshots,
      settingsStore: MemoryPlayerSettingsStore(),
      progressInterval: const Duration(milliseconds: 30),
      openRequest: PlayerOpenRequest(
        itemId: 'movie',
        libraryId: 'library',
        source: SourceReference(account: account, itemId: 'movie'),
      ),
    );
    addTearDown(() async {
      await controller.disposeAsync();
      controller.dispose();
      await runtime.history.close();
      auth.dispose();
    });
  }

  test(
    'Playing and native open do not commit history; real advancement does, even if progress fails',
    () async {
      await setup();
      await controller.start();
      expect(controller.error, isNull);
      expect(runtime.history.records(AccessRegion.ordinary), isEmpty);
      expect(controller.activeMediaSourceId, isNull);
      (controller.client as _Client).failProgress = true;
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 5));
      await _eventually(
        () => runtime.history.records(AccessRegion.ordinary).isNotEmpty,
      );
      expect(controller.activeMediaSourceId, 'v');
      expect(
        runtime.history.records(AccessRegion.ordinary).single.positionTicks,
        5 * kEmbyTicksPerSecond,
      );
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 8));
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      expect(
        runtime.history.records(AccessRegion.ordinary).single.positionTicks,
        8 * kEmbyTicksPerSecond,
      );
      expect(reports.last.itemId, 'movie');
    },
  );

  test(
    'foreign library and forged work cannot authorize an explicit source',
    () async {
      await setup();
      await expectLater(
        runtime.resolve(
          PlayerOpenRequest(
            itemId: 'foreign',
            libraryId: 'library',
            source: SourceReference(account: account, itemId: 'foreign'),
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        runtime.resolve(
          PlayerOpenRequest(
            itemId: 'movie',
            libraryId: 'library',
            source: SourceReference(account: account, itemId: 'movie'),
            work: SourceReference(account: account, itemId: 'another'),
          ),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'line identity failure keeps current source and credentials; mirror preserves pause and position',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 12));
      await _eventually(() => controller.activeMediaSourceId != null);
      final original = controller.origin;
      await expectLater(controller.switchLine('wrong'), throwsStateError);
      expect(controller.origin, same(original));
      await controller.togglePlay();
      await controller.switchLine('mirror');
      expect(controller.client.baseUrl?.host, 'mirror');
      expect(backend.openedStart, const Duration(seconds: 12));
      expect(backend.openedPaused, isTrue);
      expect(controller.activeOrigin, same(original));
      expect(controller.pendingLineId, 'mirror');
      await controller.togglePlay();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 13));
      await _eventually(() => controller.activeLineId == 'mirror');
      expect(controller.activeOrigin?.client.baseUrl?.host, 'mirror');
    },
  );

  test(
    'lock freezes latest real position, clears presentation and rejects snapshots after unlock',
    () async {
      await setup(private: true);
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 17));
      await _eventually(() => controller.activeMediaSourceId != null);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final snapshot = await snapshots.read();
      expect(snapshot, isNotNull);
      await auth.regionAccess.lock();
      expect(controller.resolved, isNull);
      expect(controller.activeOrigin, isNull);
      expect(controller.activeMediaSourceId, isNull);
      expect(backend.isPlaying, isFalse);
      expect(reports.last.positionTicks, 17 * kEmbyTicksPerSecond);
      expect(await snapshots.read(), isNull);
      expect(await runtime.recoverSnapshot(snapshot!), isFalse);
      await auth.regionAccess.unlock('1234');
      await runtime.registry.acquireAccount(
        'a',
        region: AccessRegion.private,
        libraryId: 'library',
      );
      expect(await runtime.recoverSnapshot(snapshot), isFalse);
      final count = reports.length;
      await expectLater(controller.restoreOriginalSource(), throwsStateError);
      expect(reports.length, count);
    },
  );

  test(
    'version confirmation keeps intent and language and commits only after resumed viewing',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 20));
      await _eventually(() => controller.activeMediaSourceId != null);
      await controller.togglePlay();
      await controller.switchMediaSource('v2');
      expect(controller.switchConfirmation, isNotNull);
      await controller.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
      );
      expect(backend.openedPaused, isTrue);
      expect(backend.openedStart, const Duration(seconds: 20));
      expect(controller.audioStreamIndex, 7);
      expect(controller.activeMediaSourceId, 'v');
      await controller.togglePlay();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 21));
      await _eventually(() => controller.activeMediaSourceId == 'v2');
    },
  );

  Future<SourceComparison> candidate() async {
    final b = await runtime.registry.acquireAccount(
      'b',
      region: account.region,
      libraryId: 'library',
    );
    final reference = SourceReference(account: b, itemId: 'movie-b');
    final item = await runtime.registry
        .permit(b, libraryId: 'library')
        .dispatch((c) => c.getItem('movie-b'));
    return SourceComparison(
      QueryItem(reference, 'library', item),
      const MatchDecision(MatchKind.confirmed, MatchReason.commonProvider),
    );
  }

  test(
    'cross-server failed target keeps old history and restores original only under its permit',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
      await _eventually(() => controller.activeMediaSourceId != null);
      final original = controller.origin;
      await controller.switchConfirmedSource(await candidate(), 'v2');
      expect(controller.origin, same(original));
      backend.failNextOpen = true;
      await controller.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
      );
      expect(controller.error, isNotNull);
      expect(controller.activeOrigin, same(original));
      expect(
        runtime.history.records(account.region).single.source.account,
        account,
      );
      expect(reports.single.playSessionId, 'play-a-movie');
      await controller.restoreOriginalSource();
      expect(controller.origin, same(original));
      expect(backend.openedStart, const Duration(seconds: 9));
      expect(controller.client.baseUrl?.host, 'a');
    },
  );

  test(
    'target actual viewing commits target account, never a matched copy',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
      await _eventually(() => controller.activeMediaSourceId != null);
      await controller.switchConfirmedSource(await candidate(), 'v2');
      await controller.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
      );
      expect(controller.activeOrigin?.source.account, account);
      expect(runtime.history.records(account.region), hasLength(1));
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 11));
      await _eventually(
        () => runtime.history.records(account.region).length == 2,
      );
      expect(controller.activeOrigin?.source.account.configuredServerId, 'b');
      await controller.close();
      expect(reports.map((r) => r.playSessionId), [
        'play-a-movie',
        'play-b-movie-b',
      ]);
      expect(
        runtime.history
            .records(account.region)
            .map((r) => r.source.itemId)
            .toSet(),
        {'movie', 'movie-b'},
      );
    },
  );

  test(
    'lock retires an in-flight target open before publishing locked; no late resurrection',
    () async {
      await setup(private: true);
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
      await _eventually(() => controller.activeMediaSourceId != null);
      await controller.switchConfirmedSource(await candidate(), 'v2');
      backend.openGate = Completer<void>();
      final entered = backend.openEntered = Completer<void>();
      final switching = controller.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
      );
      await entered.future;
      final locking = auth.regionAccess.lock();
      backend.openGate!.complete();
      await Future.wait([locking, switching]);
      expect(backend.isPlaying, isFalse);
      expect(controller.activeOrigin, isNull);
      expect(controller.switchConfirmation, isNull);
      expect(await snapshots.read(), isNull);
      await expectLater(controller.restoreOriginalSource(), throwsStateError);
      expect(runtime.history.records(AccessRegion.ordinary), isEmpty);
    },
  );

  test(
    'scope removal stops ordinary native session and forbids restore and snapshot dispatch',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
      await _eventually(() => controller.activeMediaSourceId != null);
      await runtime.registry.configureScope(
        'a',
        participates: false,
        libraryIds: {'library'},
      );
      await _eventually(() => !backend.isPlaying);
      expect(controller.permissionRevoked, isTrue);
      expect(controller.activeOrigin, isNull);
      expect(await snapshots.read(), isNull);
      await expectLater(controller.restoreOriginalSource(), throwsStateError);
    },
  );

  Future<DesktopPlayerWindowHost> desktop(_IpcControl ipc) async {
    final host = DesktopPlayerWindowHost(
      auth: auth,
      runtime: runtime,
      processControl: ipc,
      watchInterval: const Duration(milliseconds: 5),
      closeTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(() async {
      await host.close();
      host.dispose();
    });
    await host.open(controller.openRequest!);
    return host;
  }

  Map<String, dynamic> event(
    _IpcControl ipc,
    int sequence, {
    int? generation,
  }) => {
    'pid': ipc.lastPid,
    'sequence': sequence,
    'observationSequence': sequence,
    'generation':
        generation ??
        runtime.registry.permit(account, libraryId: 'library').regionGeneration,
    'source': encodeSource(
      SourceReference(account: account, itemId: 'movie', mediaSourceId: 'v'),
    ),
    'item': 'movie',
    'version': 'v',
    'position': 10 * kEmbyTicksPerSecond,
    'actuallyPlaying': true,
    'timeline': const WatchTimeline(
      durationTicks: 120 * kEmbyTicksPerSecond,
    ).toJson(),
  };

  test(
    'desktop main writer validates source/generation and rejects old IPC sequences',
    () async {
      await setup();
      final ipc = _IpcControl();
      await desktop(ipc);
      ipc.event = event(ipc, 1);
      await _eventually(() => ipc.receipt != null);
      expect(ipc.receipt!['accepted'], isTrue);
      expect(runtime.history.records(account.region), hasLength(1));
      ipc.receipt = null;
      ipc.event = event(ipc, 1);
      await _eventually(() => ipc.receipt != null);
      expect(ipc.receipt!['accepted'], isFalse);
      ipc.receipt = null;
      ipc.event = event(ipc, 2, generation: -1);
      await _eventually(() => ipc.receipt != null);
      expect(ipc.receipt!['accepted'], isFalse);
      expect(runtime.history.records(account.region).single.eventSequence, 1);
    },
  );

  test(
    'desktop report receipts update only the latest persisted observation',
    () async {
      await setup();
      final ipc = _IpcControl();
      await desktop(ipc);
      ipc.event = event(ipc, 1);
      await _eventually(() => ipc.receipt != null);
      Map<String, dynamic> outcome(int sequence, bool succeeded) => {
        'pid': ipc.lastPid,
        'sequence': sequence,
        'generation': runtime.registry
            .permit(account, libraryId: 'library')
            .regionGeneration,
        'item': 'movie',
        'version': 'v',
        'succeeded': succeeded,
      };
      ipc.reportOutcome = outcome(1, false);
      await _eventually(
        () =>
            runtime.history.records(account.region).single.remoteStatus ==
            RemoteSyncStatus.failed,
      );
      ipc.receipt = null;
      ipc.event = event(ipc, 2);
      await _eventually(() => ipc.receipt != null);
      ipc.reportOutcome = outcome(1, true);
      await _eventually(() => ipc.reportOutcome == null);
      expect(
        runtime.history.records(account.region).single.remoteStatus,
        RemoteSyncStatus.pending,
      );
      ipc.reportOutcome = outcome(2, true);
      await _eventually(
        () =>
            runtime.history.records(account.region).single.remoteStatus ==
            RemoteSyncStatus.succeeded,
      );
    },
  );

  test(
    'desktop line RPC preflights without changing active and launches paused target only on confirm',
    () async {
      await setup();
      final ipc = _IpcControl();
      final host = await desktop(ipc);
      final envelope = {
        'pid': ipc.lastPid,
        'source': encodeSource(controller.openRequest!.source!),
        'generation': PlayerWindowLaunch.fromArguments(
          ipc.spawnedArguments.single,
        ).regionGeneration,
      };
      ipc.command = {
        ...envelope,
        'sequence': 1,
        'action': 'inspect',
        'line': 'wrong',
        'item': 'movie',
        'version': 'v',
        'position': 10 * kEmbyTicksPerSecond,
        'paused': true,
        'bitrate': 80000000,
        'audio': 1,
      };
      await _eventually(() => ipc.switchReply != null);
      expect(ipc.switchReply!['accepted'], isFalse);
      expect(ipc.spawnedArguments, hasLength(1));
      ipc.switchReply = null;
      ipc.command = {
        ...ipc.command ?? {},
        ...envelope,
        'sequence': 2,
        'action': 'inspect',
        'line': 'mirror',
        'item': 'movie',
        'version': 'v',
        'position': 10 * kEmbyTicksPerSecond,
        'paused': true,
        'bitrate': 80000000,
        'audio': 1,
      };
      await _eventually(() => ipc.switchReply != null);
      expect(ipc.switchReply!['accepted'], isTrue);
      expect(ipc.spawnedArguments, hasLength(1));
      ipc.switchReply = null;
      ipc.command = {
        ...envelope,
        'sequence': 3,
        'action': 'confirm',
        'choice': 'currentPosition',
      };
      await _eventually(() => ipc.spawnedArguments.length == 2);
      final launch = PlayerWindowLaunch.fromArguments(
        ipc.spawnedArguments.last,
      );
      expect(Uri.parse(launch.baseUrl).host, 'mirror');
      expect(launch.request.startPaused, isTrue);
      expect(launch.request.startTimeTicks, 10 * kEmbyTicksPerSecond);
      expect(launch.request.audioStreamIndex, 1);
      expect(launch.request.maxStreamingBitrate, 80000000);
      expect(host.current?.source?.account, account);
    },
  );

  test(
    'desktop lock closes private helper and does not reconcile an old snapshot',
    () async {
      await setup(private: true);
      final ipc = _IpcControl();
      final host = await desktop(ipc);
      await auth.regionAccess.lock(budget: const Duration(milliseconds: 100));
      await _eventually(() => ipc.alive.isEmpty);
      expect(ipc.revoked, isTrue);
      expect(host.current, isNull);
      expect(reports, isEmpty);
    },
  );
}
