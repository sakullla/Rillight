import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/case_shard.dart';
import '../helpers/settle.dart';
import '../helpers/server_access_fixture.dart';

import 'package:dio/dio.dart';
import 'package:rillight/player/playback_persistence.dart';
import 'package:rillight/emby/emby_codec.dart';

import 'dart:async';
import 'dart:io';

import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/router.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/player/phone_orientation.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/playback_ended_panel.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/aggregation/query/aggregation_query.dart';
import 'package:rillight/aggregation/query/same_source_query.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_process_control.dart';

import '../player/fake_player_process_control.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/playback_state.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

class _Client extends EmbyClient {
  _Client(this.reports, {this.trackChoices = false})
    : super(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'runtime',
          version: '1',
        ),
      );
  final List<PlaybackReport> reports;
  void Function()? _requestGuard;
  final bool trackChoices;
  final progressReports = <PlaybackReport>[];
  bool failProgress = false;
  bool failStopped = false;
  int playbackRequests = 0;
  Future<void>? playbackGate;
  bool failPublic = false;
  bool failTargetPublic = false;
  bool targetMetadataMismatch = false;
  bool offerNext = false;
  bool catalogVersions = false;
  final itemRequests = <String>[];

  /// Every item read across all guarded client copies, for cross-instance
  /// call counting.
  static final allItemRequests = <String>[];
  @override
  MediaServerClient withRequestGuard(void Function() guard) {
    final probe = _Client(reports, trackChoices: trackChoices)
      ..catalogVersions = catalogVersions
      ..failProgress = failProgress
      ..failStopped = failStopped
      ..failPublic = failPublic
      ..failTargetPublic = failTargetPublic
      ..targetMetadataMismatch = targetMetadataMismatch
      ..offerNext = offerNext
      ..playbackGate = playbackGate
      .._requestGuard = () {
        _requestGuard?.call();
        guard();
      };
    probe.attachSession(
      baseUrl: baseUrl!,
      accessToken: accessToken!,
      userId: userId!,
      userAgent: customUserAgent,
    );
    probe.onSessionExpired = onSessionExpired;
    probe.onRefreshSession = onRefreshSession;
    return probe;
  }

  @override
  Future<void> logout() async => clearSession();

  /// The auth client would otherwise call the live extension endpoint.
  /// Widget tests await restore without pumping, so a real socket plus the
  /// four-second discovery timeout never elapses.
  @override
  Future<List<ExtendedServerDomain>> loadExtendedServerDomains({
    bool plainSidecar = false,
    Duration probeTimeout = const Duration(seconds: 2),
  }) async => const [];

  @override
  Future<List<MediaItem>> getViews() async => [await getItem('library')];

  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    _requestGuard?.call();
    if (failPublic || (failTargetPublic && baseUrl.host == 'b')) {
      throw StateError('synthetic offline');
    }
    return PublicServerInfo(
      id: baseUrl.host == 'wrong'
          ? 'foreign'
          : baseUrl.host == 'b'
          ? 'b'
          : 'a',
      serverName: 'test',
    );
  }

  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async {
    _requestGuard?.call();
    return MediaUser(id: userId!, name: 'test');
  }

  @override
  Future<MediaItem> getItem(
    String id, {
    String? fields,
    CancelToken? cancelToken,
  }) async {
    _requestGuard?.call();
    itemRequests.add(id);
    allItemRequests.add(id);
    return decodeEmbyMediaItem({
      'Id': id,
      'Name': id,
      'Type': id == 'library'
          ? 'CollectionFolder'
          : id.startsWith('episode')
          ? 'Episode'
          : id == 'season' || id == 'season2'
          ? 'Season'
          : id == 'series'
          ? 'Series'
          : 'Movie',
      if (id.startsWith('episode')) ...{
        'SeriesId': 'series',
        'SeasonId': id == 'episode-next-season' ? 'season2' : 'season',
        'ParentIndexNumber': id == 'episode-next-season' ? 2 : 1,
        'IndexNumber': id == 'episode1' ? 1 : 2,
      },
      if (id == 'season' || id == 'season2') 'SeriesId': 'series',
      if (id != 'library' && id != 'season' && id != 'episode-no-parent')
        'ParentId': id == 'episode-next-season'
            ? 'season2'
            : id == 'season2'
            ? 'series'
            : (id == 'foreign' || id == 'other')
            ? 'other'
            : 'library',
      'RunTimeTicks': 120 * kLegacyTicksPerSecond,
      'ProviderIds': {
        'Tmdb': targetMetadataMismatch && baseUrl?.host == 'b' ? '2' : '1',
      },
      if (catalogVersions)
        'MediaSources': [
          {'Id': 'v', 'Name': 'v', 'Container': 'mp4'},
        ],
    });
  }

  @override
  Future<PlaybackInfo> getPlaybackInfo({
    required String itemId,
    String? mediaSourceId,
    int? maxStreamingBitrate,
    Duration? startPosition,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackCapabilities? capabilities,
    bool forceTranscode = false,
  }) async {
    _requestGuard?.call();
    playbackRequests++;
    await playbackGate;
    _requestGuard?.call();
    return decodeEmbyPlaybackInfo({
      'PlaySessionId': 'play-${baseUrl!.host}-$itemId',
      'MediaSources': [
        for (final id in ['v', 'v2'])
          {
            'Id': id,
            'Name': id,
            'Container': 'mp4',
            'SupportsDirectPlay': true,
            'SupportsDirectStream': true,
            'RunTimeTicks': 120 * kLegacyTicksPerSecond,
            'MediaStreams': [
              {'Index': id == 'v' ? 1 : 7, 'Type': 'Audio', 'Language': 'jpn'},
              if (trackChoices) ...[
                {'Index': 8, 'Type': 'Audio', 'Language': 'eng'},
                {
                  'Index': 10,
                  'Type': 'Audio',
                  'Language': 'jpn',
                  'Codec': 'eac3',
                  'Channels': 6,
                },
                {
                  'Index': 9,
                  'Type': 'Subtitle',
                  'Language': 'eng',
                  'Codec': 'srt',
                  'IsDefault': true,
                },
              ],
            ],
          },
      ],
    });
  }

  @override
  Future<MediaItem?> getNextEpisode(MediaItem current) async {
    _requestGuard?.call();
    return offerNext ? getItem('episode2') : null;
  }

  @override
  Future<void> markPlayed(String itemId) async {
    _requestGuard?.call();
    if (failStopped) throw StateError('synthetic played failure');
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) async {
    _requestGuard?.call();
  }

  @override
  Future<void> reportProgress(PlaybackReport report) async {
    _requestGuard?.call();
    progressReports.add(report);
    if (failProgress) throw StateError('synthetic report failure');
  }

  @override
  Future<void> reportStopped(PlaybackReport report) async {
    _requestGuard?.call();
    reports.add(report);
    if (failStopped) throw StateError('synthetic stop failure');
  }
}

class _Backend extends FakeVideoBackend {
  _Backend() : super(duration: const Duration(seconds: 120));
  bool failNextOpen = false;
  Completer<void>? openGate;
  Completer<void>? openEntered;
  Completer<void>? stopGate;
  bool stopEntered = false;
  bool failStop = false;
  bool failDispose = false;
  Duration? hangStop;
  bool stopFinished = false;
  Completer<void>? subtitleGate;
  bool subtitleEntered = false;
  Completer<void>? rateGate;
  bool rateEntered = false;
  bool failRate = false;
  @override
  Future<void> setRate(double rate) async {
    rateEntered = true;
    await rateGate?.future;
    if (failRate) throw StateError('synthetic required setting failure');
    await super.setRate(rate);
  }

  @override
  Future<void> setSubtitleOff({int slot = 0}) async {
    if (slot == 0 && subtitleGate != null) {
      subtitleEntered = true;
      await subtitleGate!.future;
    }
    await super.setSubtitleOff(slot: slot);
  }

  @override
  Future<void> stop() async {
    stopEntered = true;
    stopFinished = false;
    final hang = hangStop;
    if (hang != null) {
      hangStop = null;
      await Future<void>.delayed(hang);
    }
    stopFinished = true;
    await stopGate?.future;
    if (failStop) {
      failStop = false;
      throw StateError('synthetic stop failure');
    }
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    if (failDispose) {
      failDispose = false;
      throw StateError('synthetic dispose failure');
    }
    await super.dispose();
  }

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

class _CapabilitiesBackend extends _Backend
    implements VideoBackendCapabilities, VideoBackendSourceRenewal {
  late Completer<void> entered;
  Completer<PlaybackCapabilities>? gate;
  int renewals = 0;
  void delayNextProfile() {
    entered = Completer<void>();
    gate = Completer<PlaybackCapabilities>();
  }

  @override
  Future<PlaybackCapabilities> playbackCapabilities(int bitrate) {
    if (gate == null) return Future.value(const PlaybackCapabilities());
    if (!entered.isCompleted) entered.complete();
    return gate!.future;
  }

  @override
  Future<void> refreshSourceUrl(Uri url) async {
    renewals++;
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
  Object? startupFailure;
  final List<Object> startupFailures = [];
  @override
  Future<int> spawn({
    required String executable,
    required String arguments,
    Future<Map<String, dynamic>>? startup,
  }) async {
    final pid = await super.spawn(
      executable: executable,
      arguments: arguments,
      startup: startup,
    );
    final failure =
        startupFailure ??
        (startupFailures.isEmpty ? null : startupFailures.removeAt(0));
    startupFailure = null;
    if (failure != null) {
      alive.remove(pid);
      throw PlayerProcessStartupException(pid, failure);
    }
    return pid;
  }

  PlayerHostOpenItemCommand? openDetail;
  @override
  Future<PlayerHostOpenItemCommand?> consumeOpenItem(int pid) async {
    final value = openDetail;
    openDetail = null;
    return value;
  }

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
    if (value['pending'] == true) {
      pendingReceipt = value;
    } else {
      receipt = value;
    }
  }

  Map<String, dynamic>? pendingReceipt;
  int heartbeats = 0;
  @override
  Future<void> heartbeat(int pid) async => heartbeats++;

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
  var cleanupFails = false;

  Future<void> setup({
    bool private = false,
    bool entryLifecycle = false,
    bool protectedTarget = true,
    bool targetOffline = false,
    bool targetMetadataMismatch = false,
    Future<String?> Function(SavedServer)? requestSourcePassword,
    String itemId = 'movie',
    String libraryId = 'library',
    bool selectedEntry = false,
    bool trackChoices = false,
    String? preferredSource,
    _Backend? videoBackend,
    WidgetTester? widgetTester,
  }) async {
    reports = [];
    cleanupFails = false;
    _Client.allItemRequests.clear();
    final access = TestServerAccessController(
      passwords: {
        if (private || entryLifecycle) 'a': '1234',
        if (private || (entryLifecycle && protectedTarget)) 'b': '1234',
      },
    );
    final store = MemoryServerListStore(
      ServerListSnapshot(
        lastServerId: 'a',
        servers: [
          SavedServer(
            id: 'a',
            name: 'a',
            username: 'test',
            protectionRef: private || entryLifecycle ? 'test:a' : null,
            activeLineId: 'line',
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
            protectionRef: private || (entryLifecycle && protectedTarget)
                ? 'test:b'
                : null,
            activeLineId: 'line',
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
      createClient: () => _Client(reports, trackChoices: trackChoices)
        ..failStopped = cleanupFails
        ..failTargetPublic = targetOffline
        ..targetMetadataMismatch = targetMetadataMismatch,
    );
    await registry.load();
    if (private && !entryLifecycle) {
      await access.unlock('a', '1234');
    }
    auth = AuthController(
      serverAccess: access,
      client: _Client(reports),
      credentials: credentials,
      servers: store,
      sources: registry,
    );
    await auth.restore();
    if (entryLifecycle) {
      expect(auth.session, isNull);
      final entered = await auth.serverEntry.enter<String>(
        server: registry.project().firstWhere((s) => s.id == 'a'),
        destination: '/play/$itemId',
        requestPassword: () async => '1234',
        connect: (guard) => auth.prepareServerEntry('a', guard: guard),
        navigate: (destination) async {
          expect(destination, '/play/$itemId');
        },
      );
      expect(entered, isTrue);
      expect(auth.session?.server.id, 'a');
      expect(access.allows('a'), isTrue);
      expect(access.allows('b'), !protectedTarget);
    }
    account = (await registry.authenticate('a')).account;
    runtime = PlaybackRuntime(
      auth: auth,
      history: await HistoryWriter.open(
        registry: registry,
        store: MemoryHistoryStore(),
      ),
    );
    backend = videoBackend ?? _Backend();
    snapshots = MemoryPlaybackSessionSnapshotStore();
    controller = PlayerController(
      client: auth.client,
      itemId: itemId,
      preferredMediaSourceId: preferredSource,
      backend: backend,
      window: PlayerWindow(),
      runtime: runtime,
      requestSourcePassword: requestSourcePassword,
      snapshotStore: snapshots,
      settingsStore: MemoryPlayerSettingsStore(),
      progressInterval: const Duration(milliseconds: 30),
      openRequest: selectedEntry
          ? PlayerOpenRequest(
              itemId: itemId,
              accessGeneration: access.generation('a'),
            )
          : PlayerOpenRequest(
              itemId: itemId,
              libraryId: libraryId,
              accessGeneration: registry.permit(account).accessGeneration,
              source: SourceReference(account: account, itemId: itemId),
            ),
    );
    Future<void> cleanup() async {
      if (widgetTester != null) {
        controller.dispose();
        auth.dispose();
        return;
      }
      await controller.disposeAsync();
      controller.dispose();
      await runtime.history.close();
      auth.dispose();
    }

    addTearDown(cleanup);
  }

  for (final explicitSource in <String?>[null, 'v', 'v2']) {
    cases.test(
      'scoped track memory with explicit source $explicitSource',
      () async {
        await setup(trackChoices: true, preferredSource: explicitSource);
        await runtime.history.savePreference(
          SourcePreference(
            owner: SourceReference(account: account, itemId: 'movie'),
            target: SourceReference(
              account: account,
              itemId: 'movie',
              mediaSourceId: 'v',
            ),
            libraryId: 'library',
            lineId: 'line',
            settings: const PlayerSeriesPreference(
              audioLanguage: 'eng',
              subtitleOff: true,
            ),
          ),
        );
        await controller.start();
        expect(controller.error, isNull);
        expect(controller.resolved?.mediaSource.id, explicitSource ?? 'v');
        expect(controller.audioStreamIndex, explicitSource == 'v2' ? 7 : 8);
        expect(
          controller.subtitleStreamIndex,
          explicitSource == 'v2' ? 9 : null,
        );
      },
    );
  }

  cases.test(
    'scoped manual audio selection survives reopening identical source',
    () async {
      await setup(trackChoices: true);
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 1));
      await _eventually(() => controller.activeMediaSourceId != null);
      await controller.setAudio(10);
      expect(controller.audioStreamIndex, 10);
      await controller.disposeAsync();
      controller.dispose();
      controller = PlayerController(
        client: auth.client,
        itemId: 'movie',
        backend: _Backend(),
        window: PlayerWindow(),
        runtime: runtime,
        settingsStore: MemoryPlayerSettingsStore(),
        openRequest: PlayerOpenRequest(
          itemId: 'movie',
          libraryId: 'library',
          accessGeneration: runtime.registry.permit(account).accessGeneration,
          source: SourceReference(account: account, itemId: 'movie'),
        ),
      );
      await controller.start();
      expect(controller.error, isNull);
      expect(controller.audioStreamIndex, 10);
    },
  );

  cases.test(
    'current private snapshot recovers Stopped and failed report retries',
    () async {
      await setup(private: true);
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 17));
      await _eventually(() => controller.activeMediaSourceId != null);
      await _eventually(
        () => snapshots.snapshot?.position == const Duration(seconds: 17),
      );
      final snapshot = (await snapshots.read())!;
      expect(runtime.canRecoverSnapshot(snapshot), isTrue);
      cleanupFails = true;
      await expectLater(runtime.recoverSnapshot(snapshot), throwsStateError);
      expect(runtime.canRecoverSnapshot(snapshot), isTrue);
      cleanupFails = false;
      expect(await runtime.recoverSnapshot(snapshot), isTrue);
      expect(
        reports.last.position.inMicroseconds * 10,
        17 * kLegacyTicksPerSecond,
      );
      expect(reports.last.playSessionId, snapshot.playSessionId);
      final recoveryStore = MemoryPlaybackSessionSnapshotStore();
      await recoveryStore.write(snapshot);
      cleanupFails = true;
      await expectLater(
        recoverAndroidSession(auth.client, recoveryStore, runtime: runtime),
        throwsStateError,
      );
      expect(await recoveryStore.read(), isNotNull);
      cleanupFails = false;
      expect(
        await recoverAndroidSession(
          auth.client,
          recoveryStore,
          runtime: runtime,
        ),
        isTrue,
      );
      expect(await recoveryStore.read(), isNull);
      final beforeInvalid = reports.length;
      for (final edit in [
        {'userId': 'wrong'},
        {'libraryId': ''},
      ]) {
        final invalid = PlaybackSessionSnapshot.fromJson({
          ...snapshot.toJson(),
          ...edit,
        })!;
        expect(await runtime.recoverSnapshot(invalid), isFalse);
      }
      expect(reports.length, beforeInvalid);
      await auth.serverAccess.lock('a');
      final count = reports.length;
      expect(await runtime.recoverSnapshot(snapshot), isFalse);
      await auth.serverAccess.unlock('a', '1234');
      expect(await runtime.recoverSnapshot(snapshot), isFalse);
      expect(reports.length, count);
    },
  );

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    for (final sameId in [true, false]) {
      cases.testWidgets(
        '${environment.presentation.name} mounted manual B lease survives startup A migration sameId=$sameId',
        (tester) async {
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            const MethodChannel('rillight/android_core'),
            (_) async => null,
          );
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              const MethodChannel('rillight/android_core'),
              null,
            ),
          );
          await setup(widgetTester: tester);
          await auth.restore();
          await tester.runAsync(() async {
            // Protection is enabled later while the other source is playing.
          });
          final router = createAppRouter(auth: auth, environment: environment);
          backend = _Backend();
          controller.dispose();
          final request = PlayerOpenRequest(
            itemId: 'movie',
            source: SourceReference(account: account, itemId: 'movie'),
            libraryId: 'library',
            accessGeneration: runtime.registry.permit(account).accessGeneration,
          );
          tester.view.physicalSize = environment.isTv
              ? const Size(1920, 1080)
              : const Size(412, 915);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            RillightApp(
              auth: auth,
              router: router,
              environment: environment,
              playerBindings: PlayerBindings(
                runtime: runtime,
                createBackend: () => backend,
                progressInterval: const Duration(milliseconds: 30),
                settingsStore: MemoryPlayerSettingsStore(),
                snapshotStore: MemoryPlaybackSessionSnapshotStore(),
              ),
            ),
          );
          Future<void> drain() async {
            for (var frame = 0; frame < 3; frame++) {
              await tester.pump(
                const Duration(milliseconds: 500),
                EnginePhase.paint,
              );
              await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            }
            // Reports are throttled by a real 30ms clock; one bounded wait
            // replaces eight unconditional waits while preserving the report.
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 35)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }

          router.go(
            '/item/movie',
            extra: PlayerHostOpenItemCommand(
              itemId: 'movie',
              source: request.source,
              libraryId: 'library',
              accessGeneration: request.accessGeneration,
            ),
          );
          await drain();
          router.push('/play/movie', extra: request);
          await drain();
          final c = environment.isTv
              ? tester
                    .state<TvPlayerPageState>(find.byType(TvPlayerPage))
                    .controller!
              : tester
                    .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
                    .controller!;
          expect(c.origin!.source.account, account);
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 10),
          );
          await drain();
          final b = (await runtime.registry.authenticate('b')).account;
          final targetId = sameId ? 'movie' : 'movie-b';
          final reference = SourceReference(account: b, itemId: targetId);
          final item = await runtime.registry
              .permit(b, libraryId: 'library')
              .dispatch((client) => client.getItem(targetId));
          await tester.runAsync(() async {
            await c.switchConfirmedSource(
              SourceComparison(
                QueryItem(reference, 'library', item),
                const MatchDecision(
                  MatchKind.confirmed,
                  MatchReason.commonProvider,
                ),
              ),
              'v2',
            );
            unawaited(
              c.confirmMediaSourceSwitch(SwitchResumeChoice.currentPosition),
            );
          });
          await drain();
          expect(
            c.origin!.source.account,
            b,
            reason: '${c.error} / ${c.trackFailure}',
          );
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 11),
          );
          await drain();
          expect(c.activeOrigin!.source.account, b);
          await tester.runAsync(
            () => auth.serverAccess.setPassword(
              'a',
              '1234',
              '1234',
              persistReference: (ref) =>
                  runtime.registry.persistProtectionReference('a', ref),
            ),
          );
          await drain();
          expect(c.permissionRevoked, isFalse);
          expect(router.state.uri.path, '/play/movie');
          expect(
            (router.state.extra as PlayerOpenRequest).source!.account,
            account,
          );
          expect(
            runtime.mountedPlayerOrigin(router.state.pageKey)!.source.account,
            b,
          );
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 12),
          );
          await drain();
          expect(c.position, const Duration(seconds: 12));
          expect(runtime.history.records().single.source.account, b);
          expect(
            runtime.history.records().single.positionTicks,
            12 * kLegacyTicksPerSecond,
          );
          expect(c.client.baseUrl!.host, 'b');
          final bClient = c.client as _Client;
          expect(
            bClient.progressReports.last.playSessionId,
            'play-b-$targetId',
          );
          expect(
            bClient.progressReports.last.position.inMicroseconds * 10,
            12 * kLegacyTicksPerSecond,
          );
          final progressCount = bClient.progressReports.length;
          await tester.runAsync(() => runtime.registry.logoutSource('b'));
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 99),
          );
          await drain();
          expect(c.permissionRevoked, isTrue);
          expect(c.activeOrigin, isNull);
          expect(runtime.history.records(), isEmpty);
          expect(bClient.progressReports.length, progressCount);
          expect(find.byType(MobilePlayerPage), findsNothing);
          expect(find.byType(TvPlayerPage), findsNothing);
          expect(runtime.hasMountedPlayer(c.routeLeaseKey!), isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await controller.disposeAsync();
            await runtime.history.close();
          });
          router.dispose();
        },
        tags: ['integration'],
      );
    }
  }

  cases.testWidgets(
    'playback line menu lists only this server and keeps the saved line',
    (tester) async {
      await tester.runAsync(() async {
        await setup(widgetTester: tester);
        await controller.start();
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
        await _eventually(() => controller.activeMediaSourceId == 'v');
      });
      await tester.pumpWidget(
        CupertinoTestApp(
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: SourceSwitchButton(controller: controller),
          ),
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      expect(find.text('手动切换'), findsNothing);
      expect(find.text('立即锁定'), findsNothing);
      expect(find.byKey(const Key('player-playback-lines')), findsOneWidget);
      await tester.tap(find.byKey(const Key('player-playback-lines')));
      await settle(tester);
      expect(find.byKey(const ValueKey('playback-line-line')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('playback-line-mirror')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('playback-line-wrong')), findsOneWidget);
      expect(find.text('正在使用'), findsOneWidget);
      expect(find.text('v2'), findsNothing);
      expect(find.text('连接线路（同一服务）'), findsNothing);
      expect(find.text('跨服务来源（已确认作品）'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('playback-line-line')));
      await settle(tester);
      expect(controller.client.baseUrl?.host, 'a');
      await tester.tap(find.byKey(const ValueKey('playback-line-mirror')));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        if (controller.activeLineId == 'mirror' &&
            controller.pendingLineId == null) {
          break;
        }
      }
      expect(controller.client.baseUrl?.host, 'mirror');
      expect(backend.openedStart, const Duration(seconds: 9));
      expect(auth.sources.project().first.activeLineId, 'mirror');
      controller.dispose();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  cases.test('Playing and native open do not commit history; real advancement does, even if progress fails', () async {
    await setup();
    await controller.start();
    expect(controller.error, isNull);
    expect(runtime.history.records(), isEmpty);
    expect(controller.activeMediaSourceId, isNull);
    (controller.client as _Client).failProgress = true;
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 5));
    await _eventually(() => runtime.history.records().isNotEmpty);
    expect(controller.activeMediaSourceId, 'v');
    expect(
      runtime.history.records().single.positionTicks,
      5 * kLegacyTicksPerSecond,
    );
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 8));
    await Future<void>.delayed(Duration.zero);
    await controller.close();
    expect(
      runtime.history.records().single.positionTicks,
      8 * kLegacyTicksPerSecond,
    );
    expect(reports.last.itemId, 'movie');
  });

  cases.test('aggregation item plays from the server session when its library needs no participation selection', () async {
    await setup();
    final origin = await runtime.resolve(
      PlayerOpenRequest(
        itemId: 'movie',
        libraryId: 'library',
        source: SourceReference(account: account, itemId: 'movie'),
      ),
    );
    expect(origin.permit.isValid, isTrue);
    expect(origin.libraryId, 'library');
    expect(
      (await origin.permit.dispatch((client) => client.getItem('movie'))).id,
      'movie',
    );
    final session = await runtime.begin(origin, 'v');
    expect(session.permit.isValid, isTrue);
  });

  cases.test(
    'local session keeps search and poster playback off the home redirect',
    () async {
      await setup();
      // Search hits and poster play pass the immediate parent, which is often
      // a folder or season rather than a checked library id.
      expect(
        localSessionAllowsRoute(
          runtime.registry,
          account,
          libraryId: 'folder-not-checked',
        ),
        isTrue,
      );
      expect(
        localSessionAllowsRoute(
          runtime.registry,
          account,
          libraryId: 'library',
          accessGeneration: null,
        ),
        isTrue,
      );
    },
  );

  for (final protected in [false, true]) {
    cases.test(
      'selected home playback needs only server authorization protected=$protected',
      () async {
        await setup(private: protected, selectedEntry: true);
        await auth.restore();
        expect(auth.isLoggedIn, isTrue);
        final origin = await runtime.resolve(
          PlayerOpenRequest(
            itemId: 'movie',
            accessGeneration: auth.serverAccess.generation('a'),
          ),
        );
        expect(origin.source.account, account);
        expect(origin.libraryId, 'library');
        expect(origin.permit.isValid, isTrue);
        final session = await runtime.begin(origin, 'v');
        expect(session.permit.isValid, isTrue);
        // Android can display frames while optional subtitle restoration is
        // still in flight. Preference persistence must not stop that stream.
        final subtitleGate = backend.subtitleGate = Completer<void>();
        final starting = controller.start();
        await _eventually(() => backend.subtitleEntered);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 1));
        await _eventually(() => controller.activeMediaSourceId == 'v');
        subtitleGate.complete();
        await starting;
        expect(controller.error, isNull);
        expect(controller.isPlaying, isTrue);
        expect(controller.openStageTimings, contains('ready'));
        expect(controller.progressSyncFailed, isFalse);
        await controller.start();
        expect(controller.error, isNull);
        expect(controller.isPlaying, isTrue);
      },
    );
  }

  for (final private in [false, true]) {
    cases.test(
      'season-scoped playback changes season on the same work private=$private',
      () async {
        await setup(
          private: private,
          itemId: 'episode-no-parent',
          libraryId: 'season',
        );
        await controller.start();
        expect(controller.error, isNull);
        final first = controller.origin!;
        expect(first.permit.isValid, isTrue);
        final next = await first.client.getItem('episode-next-season');
        await controller.playEpisode(next);
        expect(controller.itemId, next.id);
        expect(controller.error, isNull);
        expect(controller.origin!.libraryId, 'season2');
        expect(controller.origin!.work, first.work);
        expect(backend.openCount, 2);
        await expectLater(
          runtime.resolveItem(first, 'movie'),
          throwsStateError,
        );
        if (private) {
          await runtime.registry.access.lock('a');
          final count = _Client.allItemRequests.length;
          await expectLater(
            runtime.resolveItem(first, next.id),
            throwsStateError,
          );
          expect(_Client.allItemRequests.length, count);
        }
      },
    );
  }

  cases.test(
    'local season playback keeps a saved version from its checked library',
    () async {
      await setup(itemId: 'episode-no-parent', libraryId: 'season');
      await runtime.history.savePreference(
        SourcePreference(
          owner: SourceReference(account: account, itemId: 'series'),
          target: SourceReference(
            account: account,
            itemId: 'episode-no-parent',
            mediaSourceId: 'v',
          ),
          libraryId: 'library',
          settings: const PlayerSeriesPreference(mediaSourceName: 'v'),
        ),
      );
      await controller.start();
      expect(controller.error, isNull);
      await controller.playEpisode(
        await controller.client.getItem('episode-next-season'),
      );
      expect(controller.error, isNull);
      expect(controller.resolved?.mediaSource.id, 'v');
    },
  );

  cases.test(
    'private playback route still rejects a stale or locked generation',
    () async {
      await setup(private: true);
      final generation = runtime.registry
          .permit(account, libraryId: 'library')
          .accessGeneration;
      expect(
        localSessionAllowsRoute(
          runtime.registry,
          account,
          libraryId: 'view-not-checked',
          accessGeneration: generation,
        ),
        isTrue,
      );
      expect(
        localSessionAllowsRoute(
          runtime.registry,
          account,
          libraryId: 'library',
          accessGeneration: generation + 1,
        ),
        isFalse,
      );
      await runtime.registry.access.lock('a');
      expect(
        localSessionAllowsRoute(
          runtime.registry,
          account,
          libraryId: 'library',
          accessGeneration: generation,
        ),
        isFalse,
      );
    },
  );

  cases.test('membership proof is cached across repeated resolves', () async {
    await setup();
    final request = PlayerOpenRequest(
      itemId: 'movie',
      libraryId: 'library',
      source: SourceReference(account: account, itemId: 'movie'),
    );
    await runtime.resolve(request);
    expect(_Client.allItemRequests, contains('library'));
    final countAfterFirst = _Client.allItemRequests.length;
    final second = await runtime.resolve(request);
    expect(second.libraryId, 'library');
    // The item is re-read for freshness, but the ancestor membership walk
    // must not repeat while the proof is fresh.
    expect(_Client.allItemRequests.length, countAfterFirst + 1);
    expect(_Client.allItemRequests.last, 'movie');
  });

  cases.test(
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

  for (final explicitSource in [false, true]) {
    cases.test(
      'episode without ParentId resolves its library, explicit=$explicitSource',
      () async {
        await setup();
        if (!explicitSource) await auth.restore();
        final origin = await runtime.resolve(
          PlayerOpenRequest(
            itemId: 'episode-no-parent',
            libraryId: explicitSource ? 'library' : null,
            source: explicitSource
                ? SourceReference(account: account, itemId: 'episode-no-parent')
                : null,
          ),
        );
        expect(origin.libraryId, explicitSource ? 'library' : 'season');
        expect(origin.work.itemId, 'series');
        expect(origin.source.account, account);
      },
    );
  }

  cases.test(
    'backup management checks never reopen or reassign source-owned playback',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 12));
      await _eventually(() => controller.activeMediaSourceId != null);
      await controller.togglePlay();
      final original = controller.activeOrigin;
      final originalClient = controller.client;
      final originalUrl = backend.openedUrl;
      final opens = backend.openCount;
      final credentials = await auth.sources.credentials.read('a');
      final permit = auth.sources.permit(account, libraryId: 'library');
      for (final target in ['mirror', 'wrong']) {
        final result = await auth.sources.check('a', lineId: target);
        expect(
          result.status,
          target == 'mirror'
              ? ManualCheckStatus.available
              : ManualCheckStatus.identityMismatch,
        );
        expect(controller.activeOrigin, same(original));
        expect(controller.client, same(originalClient));
        expect(controller.activeLineId, 'line');
        expect(controller.pendingLineId, isNull);
        expect(controller.activeMediaSourceId, 'v');
        expect(controller.position, const Duration(seconds: 12));
        expect(backend.isPlaying, isFalse);
        expect(backend.openCount, opens);
        expect(backend.openedUrl, originalUrl);
        expect(permit.isValid, isTrue);
        expect(
          (await auth.sources.credentials.read('a'))?.accessToken,
          credentials?.accessToken,
        );
        expect(auth.sources.project().first.activeLineId, 'line');
      }
      await controller.togglePlay();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 13));
      await _eventually(
        () => controller.position == const Duration(seconds: 13),
      );
      expect(controller.activeOrigin, same(original));
      expect(backend.isPlaying, isTrue);
      await controller.close();
      expect(reports.last.itemId, 'movie');
      expect(
        reports.last.position.inMicroseconds * 10,
        13 * kLegacyTicksPerSecond,
      );
    },
  );

  cases.test('line identity failure keeps current source and credentials; mirror preserves pause and position', () async {
    await setup();
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 12));
    await _eventually(() => controller.activeMediaSourceId != null);
    final original = controller.origin;
    await expectLater(
      controller.switchLine('wrong'),
      throwsA(isA<MediaServerException>()),
    );
    expect(controller.origin, same(original));
    await controller.togglePlay();
    await controller.switchLine('mirror');
    expect(controller.client.baseUrl?.host, 'mirror');
    expect(backend.openedStart, const Duration(seconds: 12));
    expect(backend.openedPaused, isTrue);
    expect(controller.activeOrigin!.source, original!.source);
    expect(controller.activeOrigin!.permit, same(original.permit));
    expect(controller.pendingLineId, isNull);
    await controller.togglePlay();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 13));
    await _eventually(
      () => controller.activeOrigin?.client.baseUrl?.host == 'mirror',
    );
    expect(controller.activeOrigin?.client.baseUrl?.host, 'mirror');
    expect(auth.sources.project().first.activeLineId, 'mirror');
    expect(
      auth.sources.project().first.lineSelection,
      LineSelection.fixed('mirror'),
    );
  });

  cases.test('line open failure continues on the original line', () async {
    await setup();
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 12));
    await _eventually(() => controller.activeMediaSourceId != null);
    await controller.togglePlay();
    final original = controller.client;
    backend.failNextOpen = true;
    await expectLater(controller.switchLine('mirror'), throwsA(anything));
    expect(controller.playbackLineFailure, isNotNull);
    expect(controller.state.phase, isNot(PlaybackPhase.failed));
    expect(controller.client, same(original));
    expect(controller.client.baseUrl?.host, 'a');
    expect(backend.openedStart, const Duration(seconds: 12));
    expect(auth.sources.project().first.activeLineId, 'line');
  });

  cases.test('persisted line switch never mutates shared client when stop or dispose fails', () async {
    for (final failure in ['stop', 'dispose']) {
      final reports = <PlaybackReport>[];
      final client = _Client(reports);
      client.attachSession(
        baseUrl: Uri.parse('https://a'),
        accessToken: 'token',
        userId: 'user',
        userAgent: 'Rillight',
      );
      final video = _Backend();
      final playing = PlayerController(
        client: client,
        itemId: 'movie',
        backend: video,
        window: PlayerWindow(),
        settingsStore: MemoryPlayerSettingsStore(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        progressInterval: const Duration(milliseconds: 30),
        playbackLineSnapshot: const [
          ServerLine(id: 'line', address: 'https://a'),
          ServerLine(id: 'mirror', address: 'https://mirror'),
        ],
        verifiedPlaybackServerId: 'a',
        switchDispatcher: (command) async {
          expect(command['action'], 'commitLine');
          return <String, dynamic>{};
        },
      );
      try {
        await playing.start();
        await playing.switchLine('mirror');
        expect(playing.client.baseUrl?.host, 'mirror');
        expect(client.baseUrl?.host, 'a');
        if (failure == 'stop') {
          video.failStop = true;
        } else {
          video.failDispose = true;
        }
        await playing.close();
        expect(client.baseUrl?.host, 'a');
        expect(client.accessToken, 'token');
        expect(client.userId, 'user');
        expect(client.customUserAgent, 'Rillight');
      } finally {
        try {
          await playing.disposeAsync();
        } catch (_) {}
        playing.dispose();
      }
    }
  });

  cases.test('persisted line switch leaves shared client untouched when close stop hangs', () async {
    final reports = <PlaybackReport>[];
    final client = _Client(reports);
    client.attachSession(
      baseUrl: Uri.parse('https://a'),
      accessToken: 'token',
      userId: 'user',
      userAgent: 'Rillight',
    );
    final video = _Backend();
    final playing = PlayerController(
      client: client,
      itemId: 'movie',
      backend: video,
      window: PlayerWindow(),
      settingsStore: MemoryPlayerSettingsStore(),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      progressInterval: const Duration(milliseconds: 30),
      disposeTimeout: const Duration(milliseconds: 50),
      playbackLineSnapshot: const [
        ServerLine(id: 'line', address: 'https://a'),
        ServerLine(id: 'mirror', address: 'https://mirror'),
      ],
      verifiedPlaybackServerId: 'a',
      switchDispatcher: (command) async {
        expect(command['action'], 'commitLine');
        return <String, dynamic>{};
      },
    );
    try {
      await playing.start();
      await playing.switchLine('mirror');
      expect(playing.client.baseUrl?.host, 'mirror');
      expect(client.baseUrl?.host, 'a');
      video.hangStop = const Duration(milliseconds: 150);
      await playing.close();
      expect(video.stopFinished, isFalse);
      expect(client.baseUrl?.host, 'a');
      expect(client.accessToken, 'token');
      expect(client.userId, 'user');
      expect(client.customUserAgent, 'Rillight');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } finally {
      try {
        await playing.disposeAsync();
      } catch (_) {}
      playing.dispose();
    }
  });

  cases.test(
    'playback line label uses a nickname, otherwise host and port',
    () {
      expect(
        playbackLineLabel(
          const ServerLine(
            id: 'home',
            address: 'https://play.example:443',
            nickname: '家里',
          ),
        ),
        '家里',
      );
      expect(
        playbackLineLabel(
          const ServerLine(id: 'plain', address: 'https://play.example:8443'),
        ),
        'play.example:8443',
      );
      expect(
        playbackLineLabel(
          const ServerLine(id: 'https', address: 'https://play.example:443'),
        ),
        const ServerLine(
          id: 'https',
          address: 'https://play.example:443',
        ).hostLabel,
      );
      expect(
        playbackLineLabel(const ServerLine(id: 'raw', address: 'not a uri')),
        'not a uri',
      );
    },
  );

  cases.test('lock freezes latest real position, clears presentation and rejects snapshots after unlock', () async {
    await setup(private: true);
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 17));
    await _eventually(() => controller.activeMediaSourceId != null);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final snapshot = await snapshots.read();
    expect(snapshot, isNotNull);
    await auth.serverAccess.lock('a');
    expect(controller.resolved, isNull);
    expect(controller.activeOrigin, isNull);
    expect(controller.activeMediaSourceId, isNull);
    expect(backend.isPlaying, isFalse);
    expect(
      reports.last.position.inMicroseconds * 10,
      17 * kLegacyTicksPerSecond,
    );
    expect(await snapshots.read(), isNull);
    expect(await runtime.recoverSnapshot(snapshot!), isFalse);
    await auth.serverAccess.unlock('a', '1234');
    await runtime.registry.acquireAccount('a', libraryId: 'library');
    expect(await runtime.recoverSnapshot(snapshot), isFalse);
    final count = reports.length;
    await expectLater(controller.restoreOriginalSource(), throwsStateError);
    expect(reports.length, count);
  });

  cases.test('version confirmation keeps intent and language and commits only after resumed viewing', () async {
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
  });

  cases.test(
    'mirror episode picker retains line, pause, bitrate and report ownership',
    () async {
      await setup(itemId: 'episode1');
      controller.maxStreamingBitrate = 8000000;
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 12));
      await _eventually(() => controller.activeMediaSourceId != null);
      await controller.switchLine('mirror');
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 13));
      await _eventually(() => controller.activeLineId == 'mirror');
      await controller.togglePlay();
      final bitrate = controller.maxStreamingBitrate;
      await controller.playEpisode(await controller.client.getItem('episode2'));
      expect(controller.loading, isFalse);
      expect(controller.client.baseUrl?.host, 'mirror');
      expect(backend.openedPaused, isTrue);
      expect(controller.maxStreamingBitrate, bitrate);
      expect(reports.last.itemId, 'episode1');
      await controller.togglePlay();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 2));
      await _eventually(
        () => controller.activeOrigin?.source.itemId == 'episode2',
      );
      expect(controller.activeOrigin?.client.baseUrl?.host, 'mirror');
    },
  );

  cases.test('delayed capabilities cannot dispatch PlaybackInfo after account revocation', () async {
    final delayed = _CapabilitiesBackend()..delayNextProfile();
    await setup(videoBackend: delayed);
    final starting = controller.start();
    await delayed.entered.future;
    final client = controller.client as _Client;
    final count = client.playbackRequests;
    await runtime.registry.logoutSource('a');
    delayed.gate!.complete(const PlaybackCapabilities());
    await starting;
    expect(client.playbackRequests, count);
  });

  for (final prefix in [false, true]) {
    cases.test(
      'delayed ${prefix ? 'next prefix' : 'URL renewal'} has zero dispatch after account logout',
      () async {
        final delayed = _CapabilitiesBackend();
        await setup(
          itemId: prefix ? 'episode1' : 'movie',
          videoBackend: delayed,
        );
        await controller.start();
        final client = controller.client as _Client;
        delayed.delayNextProfile();
        if (prefix) {
          client.offerNext = true;
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 120),
          );
          backend.emitEvent(VideoEventKind.completed, true);
        } else {
          backend.emitEvent(VideoEventKind.sourceRefreshRequired, true);
        }
        await delayed.entered.future.timeout(const Duration(seconds: 2));
        final count = client.playbackRequests;
        await runtime.registry.logoutSource('a');
        delayed.gate!.complete(const PlaybackCapabilities());
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(client.playbackRequests, count);
        expect(delayed.renewals, 0);
      },
    );
  }

  cases.test('finish-current picker records played before remote failures and keeps playback intent', () async {
    await setup(itemId: 'episode1');
    await controller.start();
    (controller.client as _Client).failStopped = true;
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 119));
    await _eventually(() => controller.activeMediaSourceId != null);
    await controller.playEpisode(await controller.client.getItem('episode2'));
    expect(runtime.history.records().single.played, isTrue);
    expect(controller.itemId, 'episode2');
    expect(controller.loading, isFalse);
    expect(backend.openedPaused, isFalse);
  });

  cases.test(
    'natural EOF persists local played even when Stopped fails',
    () async {
      await setup();
      await controller.start();
      (controller.client as _Client).failStopped = true;
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 120));
      backend.emitEvent(VideoEventKind.completed, true);
      await _eventually(() => controller.playbackEnded);
      await controller.close();
      final record = runtime.history.records().single;
      expect(record.positionTicks, 120 * kLegacyTicksPerSecond);
      expect(record.played, isTrue);
      final query = AggregationQueryController(
        registry: runtime.registry,
        history: runtime.history,
      );
      expect(query.localContinueWatching, isEmpty);
      query.dispose();
    },
  );

  cases.test('fresh ordinary recovery only cleans original session and retries transient failure', () async {
    await setup();
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
    await _eventually(() => controller.activeMediaSourceId != null);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final saved = (await snapshots.read())!;
    final freshReports = <PlaybackReport>[];
    var failCleanup = true;
    final freshRegistry = SourceSessionRegistry(
      access: TestServerAccessController(),
      store: MemoryServerListStore(
        ServerListSnapshot(servers: runtime.registry.project()),
      ),
      credentials: MemoryCredentialStore({
        'a': const StoredCredentials(
          accessToken: 'token',
          userId: 'user',
          username: 'test',
        ),
      }),
      createClient: () => _Client(freshReports)
        ..failPublic = true
        ..failStopped = failCleanup,
    );
    await freshRegistry.load();
    final freshAuth = AuthController(
      serverAccess: freshRegistry.access,
      client: _Client(freshReports),
      sources: freshRegistry,
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    final fresh = PlaybackRuntime(
      auth: freshAuth,
      history: await HistoryWriter.open(
        registry: freshRegistry,
        store: MemoryHistoryStore(),
      ),
    );
    addTearDown(() async {
      await fresh.history.close();
      freshAuth.dispose();
    });
    final store = MemoryPlaybackSessionSnapshotStore();
    await store.write(saved);
    await expectLater(
      recoverAndroidSession(freshAuth.client, store, runtime: fresh),
      throwsStateError,
    );
    expect(await store.read(), isNotNull);
    expect(freshRegistry.sessionAccount('a', libraryId: 'library'), isNull);
    await expectLater(
      recoverAndroidSession(freshAuth.client, store, runtime: fresh),
      throwsStateError,
    );
    expect(await store.read(), isNotNull);
    failCleanup = false;
    expect(
      await recoverAndroidSession(freshAuth.client, store, runtime: fresh),
      isTrue,
    );
    expect(await store.read(), isNull);
    expect(freshRegistry.sessionAccount('a', libraryId: 'library'), isNull);
    expect(
      freshReports.last.position.inMicroseconds * 10,
      saved.position.inMicroseconds * 10,
    );
  });

  cases.test('fresh protected registry rejects prior snapshot before and after normal login', () async {
    await setup(private: true);
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
    await _eventually(() => controller.activeMediaSourceId != null);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final saved = (await snapshots.read())!;
    final access = TestServerAccessController(
      passwords: const {'a': '1234', 'b': '1234'},
    );
    var acquisitions = 0;
    final registry = SourceSessionRegistry(
      access: access,
      store: MemoryServerListStore(
        ServerListSnapshot(servers: runtime.registry.project()),
      ),
      credentials: runtime.registry.credentials,
      createClient: () {
        acquisitions++;
        return _Client([]);
      },
    );
    await registry.load();
    final freshAuth = AuthController(
      serverAccess: registry.access,
      client: _Client([]),
      sources: registry,
      credentials: runtime.registry.credentials,
      servers: MemoryServerListStore(),
    );
    final fresh = PlaybackRuntime(
      auth: freshAuth,
      history: await HistoryWriter.open(
        registry: registry,
        store: MemoryHistoryStore(),
      ),
    );
    addTearDown(() async {
      await fresh.history.close();
      freshAuth.dispose();
    });
    final store = MemoryPlaybackSessionSnapshotStore();
    await store.write(saved);
    expect(
      await recoverAndroidSession(freshAuth.client, store, runtime: fresh),
      isFalse,
    );
    expect(await store.read(), isNull);
    expect(acquisitions, 0);
    expect(await access.unlock('a', '1234'), isTrue);
    await registry.authenticate('a');
    expect(
      registry.sessionAccount('a', libraryId: 'library'),
      saved.source!.account,
    );
    expect(access.generation('a'), isNot(saved.accessGeneration));
    final acquired = acquisitions;
    await store.write(saved);
    expect(
      await recoverAndroidSession(freshAuth.client, store, runtime: fresh),
      isFalse,
    );
    expect(
      acquisitions,
      acquired,
      reason: 'Old generation must not reacquire a cleanup client',
    );
    expect(await store.read(), isNull);
  });

  for (final acceptNext in [true, false]) {
    cases.testWidgets(
      'real helper next episode waits for verification ($acceptNext) and drains close',
      (tester) async {
        const account = SourceAccount(
          configuredServerId: 'a',
          verifiedServerId: 'a',
          userId: 'user',
        );
        final endpoint = await tester.runAsync(
          () => PlayerProcessProtocol.create(),
        );
        final protocol = endpoint!;
        var exited = false;
        final helperBackend = _Backend();
        final helperClient = _Client([]);
        await tester.pumpWidget(
          PlayerWindowApp.testing(
            clock: () => tester.binding.clock.now(),
            launch: PlayerWindowLaunch(
              request: PlayerOpenRequest(
                itemId: 'movie',
                source: SourceReference(account: account, itemId: 'movie'),
                libraryId: 'library',
              ),
              baseUrl: 'https://a',
              accessToken: 'token',
              userId: 'user',
              device: helperClient.device,
              protocol: protocol,
              accessGeneration: 0,
            ),
            client: helperClient,
            bindings: PlayerBindings(
              createBackend: () => helperBackend,
              window: PlayerWindow(),
              settingsStore: MemoryPlayerSettingsStore(),
              progressInterval: const Duration(hours: 1),
            ),
            onExit: () => exited = true,
          ),
        );
        final helper = tester
            .state<PlayerPageState>(find.byType(PlayerPage))
            .controller!;
        try {
          await tester.runAsync(() async {
            await _eventually(() => helper.resolved != null && !helper.loading);
          });
          await tester.pump();
          expect(helper.error, isNull);
          expect(helper.isPlaying, isTrue);
          helperBackend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 10),
          );
          await tester.pump();
          Future<Map<String, dynamic>?> readEvent([
            String kind = 'watch-event',
          ]) async {
            for (var i = 0; i < 100; i++) {
              await tester.pump(const Duration(milliseconds: 20));
              final event = await tester.runAsync(() async {
                await Future<void>.delayed(const Duration(milliseconds: 5));
                return protocol.read(kind);
              });
              if (event != null) return event;
            }
            return null;
          }

          final first = await readEvent();
          expect(first?['position'], 10 * kLegacyTicksPerSecond);
          await tester.runAsync(
            () => protocol.write('watch-ack', {
              'sequence': first!['sequence'],
              'accepted': true,
            }),
          );
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          late Future<void> switching;
          await tester.runAsync(() async {
            switching = helper.playEpisode(
              await helperClient.getItem('episode2'),
            );
          });
          final authorization = await readEvent('switch-request');
          expect(authorization?['action'], 'authorizeItem');
          await tester.runAsync(
            () => protocol.write('switch-reply', {
              'sequence': authorization!['sequence'],
              'accepted': true,
            }),
          );
          for (var i = 0; i < 200; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            if (helper.itemId == 'episode2' && !helper.loading) break;
            // The retiring episode still needs its final durable observation.
            final retiring = await tester.runAsync(
              () => protocol.read('watch-event'),
            );
            if (retiring != null) {
              expect(retiring['item'], 'movie');
              await tester.runAsync(
                () => protocol.write('watch-ack', {
                  'sequence': retiring['sequence'],
                  'accepted': true,
                }),
              );
            }
          }
          await tester.runAsync(() => switching);
          expect(helper.itemId, 'episode2');
          expect(helper.isPlaying, isTrue);
          helperBackend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 1),
          );
          await tester.pump();
          final next = await readEvent();
          expect(next?['item'], 'episode2');
          await tester.runAsync(
            () => protocol.write('watch-pending', {
              'sequence': next!['sequence'],
            }),
          );
          // Wait for the real mailbox to be consumed, then cross the original
          // three-second budget on the injected widget clock. Disk IO remains
          // real; unrelated CPU load no longer costs 4.5 seconds per variant.
          final pending = File('${protocol.directory.path}/watch-pending.json');
          for (var turn = 0; turn < 100 && pending.existsSync(); turn++) {
            await tester.pump(
              const Duration(milliseconds: 20),
              EnginePhase.paint,
            );
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          expect(pending.existsSync(), isFalse);
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(seconds: 1), EnginePhase.paint);
          }
          expect(helper.progressSyncFailed, isFalse);
          await tester.runAsync(
            () => protocol.write('watch-ack', {
              'sequence': next!['sequence'],
              'accepted': acceptNext,
            }),
          );
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            if (acceptNext
                ? helper.activeMediaSourceId != null
                : helper.progressSyncFailed) {
              break;
            }
          }
          expect(helper.progressSyncFailed, !acceptNext);
          if (acceptNext) expect(helper.activeMediaSourceId, isNotNull);
          helperBackend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 18),
          );
          await tester.pump();
          await tester.runAsync(() => protocol.write('close'));
          await tester.pump(const Duration(milliseconds: 100));
          final finalEvent = await readEvent();
          expect(finalEvent?['position'], 18 * kLegacyTicksPerSecond);
          expect(exited, isFalse);
          await tester.runAsync(
            () => protocol.write('watch-ack', {
              'sequence': finalEvent!['sequence'],
              'accepted': true,
            }),
          );
          for (var i = 0; i < 100 && !exited; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          expect(exited, isTrue);
        } finally {
          unawaited(helper.revokeFromHost(reportStopped: false));
          await tester.pump(const Duration(seconds: 10));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(protocol.dispose);
        }
      },
      tags: ['integration'],
    );
  }

  for (final outcome in [
    'playing',
    'paused',
    'open-failure',
    'settings-failure',
  ]) {
    cases.testWidgets(
      'real helper pending entry reports $outcome only after backend result',
      (tester) async {
        const targetAccount = SourceAccount(
          configuredServerId: 'b',
          verifiedServerId: 'b',
          userId: 'user-b',
        );
        final protocol = (await tester.runAsync(PlayerProcessProtocol.create))!;
        final helperBackend = _Backend();
        final helperClient = _Client([]);
        final openEntered = Completer<void>();
        if (outcome == 'open-failure') {
          helperBackend.failNextOpen = true;
        } else {
          helperBackend.openEntered = openEntered;
          helperBackend.openGate = Completer<void>();
          helperBackend.rateGate = Completer<void>();
          helperBackend.failRate = outcome == 'settings-failure';
        }
        await tester.pumpWidget(
          PlayerWindowApp.testing(
            clock: () => tester.binding.clock.now(),
            launch: PlayerWindowLaunch(
              request: PlayerOpenRequest(
                itemId: 'movie-b',
                source: SourceReference(
                  account: targetAccount,
                  itemId: 'movie-b',
                ),
                libraryId: 'library',
                mediaSourceId: 'v2',
                startPaused: outcome == 'paused',
              ),
              baseUrl: 'https://b',
              accessToken: 'token-b',
              userId: 'user-b',
              device: helperClient.device,
              protocol: protocol,
              accessGeneration: 123,
              entryPending: true,
            ),
            client: helperClient,
            bindings: PlayerBindings(
              createBackend: () => helperBackend,
              window: PlayerWindow(),
              settingsStore: MemoryPlayerSettingsStore(),
              snapshotStore: MemoryPlaybackSessionSnapshotStore(),
              progressInterval: const Duration(hours: 1),
            ),
            onExit: () {},
          ),
        );
        final helper = tester
            .state<PlayerPageState>(find.byType(PlayerPage))
            .controller!;
        Future<void> pumpUntil(bool Function() predicate) async {
          for (var i = 0; i < 150 && !predicate(); i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 3)),
            );
          }
          expect(predicate(), isTrue);
        }

        try {
          if (outcome != 'open-failure') {
            await pumpUntil(() => openEntered.isCompleted);
            expect(
              await tester.runAsync(() => protocol.read('switch-request')),
              isNull,
            );
            helperBackend.openGate!.complete();
            await pumpUntil(() => helperBackend.rateEntered);
            expect(
              await tester.runAsync(() => protocol.read('switch-request')),
              isNull,
              reason: 'A successful open still waits for required settings',
            );
            helperBackend.rateGate!.complete();
          }
          Map<String, dynamic>? signal;
          for (var i = 0; i < 150 && signal == null; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            signal = await tester.runAsync<Map<String, dynamic>?>(() async {
              await Future<void>.delayed(const Duration(milliseconds: 3));
              return protocol.read('switch-request');
            });
          }
          expect(signal, isNotNull);
          expect(
            signal!['action'],
            outcome.endsWith('failure') ? 'openFailed' : 'opened',
          );
          expect(signal['item'], 'movie-b');
          expect(signal['version'], 'v2');
          expect(signal['generation'], 123);
          expect(
            decodeAuthorizedSource(
              Map<String, dynamic>.from(signal['source'] as Map),
            ).account,
            targetAccount,
          );
          await tester.runAsync(
            () => protocol.write('switch-reply', {
              'sequence': signal!['sequence'],
              'accepted': true,
            }),
          );
          await pumpUntil(() => !helper.loading);
          expect(
            helper.error,
            outcome.endsWith('failure') ? isNotNull : isNull,
          );
          if (outcome == 'paused') expect(helper.isPlaying, isFalse);
          if (outcome == 'playing') expect(helper.isPlaying, isTrue);
          expect(
            await tester.runAsync(() => protocol.read('switch-request')),
            isNull,
            reason: 'One pending launch emits exactly one result',
          );
        } finally {
          if (helperBackend.openGate?.isCompleted == false) {
            helperBackend.openGate!.complete();
          }
          if (helperBackend.rateGate?.isCompleted == false) {
            helperBackend.rateGate!.complete();
          }
          unawaited(helper.revokeFromHost(reportStopped: false));
          await tester.pump(const Duration(seconds: 10));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(protocol.dispose);
        }
      },
      tags: ['integration'],
    );
  }

  SourceComparison lockedTargetCandidate() {
    const target = SourceReference(
      account: SourceAccount(
        configuredServerId: 'b',
        verifiedServerId: 'b',
        userId: 'user-b',
      ),
      itemId: 'movie-b',
    );
    return SourceComparison(
      QueryItem(
        target,
        'library',
        decodeEmbyMediaItem({
          'Id': 'movie-b',
          'Name': 'Known target',
          'Type': 'Movie',
          'ParentId': 'library',
          'ProviderIds': {'Tmdb': '1'},
        }),
      ),
      const MatchDecision(MatchKind.confirmed, MatchReason.commonProvider),
    );
  }

  for (final targetProtected in [false, true]) {
    for (final outcome in ['success', 'cancel', 'open-failure']) {
      cases.test(
        'real server entry cross-source commit $outcome protectedTarget=$targetProtected',
        () async {
          var passwordRequests = 0;
          await setup(
            entryLifecycle: true,
            protectedTarget: targetProtected,
            requestSourcePassword: (server) async {
              expect(server.id, 'b');
              passwordRequests++;
              return '1234';
            },
          );
          await controller.start();
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 10),
          );
          await _eventually(() => controller.activeMediaSourceId != null);
          final old = controller.activeOrigin!;
          final oldGeneration = old.permit.accessGeneration;
          await controller.switchConfirmedSource(lockedTargetCandidate(), 'v2');
          expect(controller.switchConfirmation, isNotNull);
          expect(auth.session!.server.id, 'a');
          expect(old.permit.isValid, isTrue);
          expect(auth.serverAccess.allows('b'), !targetProtected);
          expect(passwordRequests, targetProtected ? 1 : 0);
          if (outcome == 'open-failure') backend.failNextOpen = true;
          await controller.confirmMediaSourceSwitch(
            outcome == 'cancel'
                ? SwitchResumeChoice.cancel
                : SwitchResumeChoice.currentPosition,
          );
          if (outcome == 'success') {
            expect(auth.session!.server.id, 'b');
            expect(auth.serverAccess.allows('a'), isFalse);
            expect(old.permit.isValid, isFalse);
            expect(auth.serverAccess.generation('a'), isNot(oldGeneration));
            expect(auth.serverAccess.allows('b'), isTrue);
            expect(controller.origin!.source.account.configuredServerId, 'b');
            expect(controller.permissionRevoked, isFalse);
            expect(controller.isPlaying, isTrue);
            backend.emitEvent(
              VideoEventKind.position,
              const Duration(seconds: 12),
            );
            await _eventually(
              () =>
                  controller.activeOrigin?.source.account.configuredServerId ==
                  'b',
            );
            expect(controller.activeOrigin!.permit.isValid, isTrue);
            await controller.close();
            expect(
              reports.where(
                (report) => report.playSessionId == 'play-b-movie-b',
              ),
              isNotEmpty,
            );
          } else {
            expect(auth.session!.server.id, 'a');
            expect(auth.serverAccess.allows('a'), isTrue);
            expect(old.permit.isValid, isTrue);
            expect(auth.serverAccess.allows('b'), !targetProtected);
            if (outcome == 'cancel') expect(controller.isPlaying, isTrue);
          }
        },
      );
    }
  }

  for (final refusal in [
    'password-cancel',
    'password-wrong',
    'offline',
    'different-work',
    'missing-version',
  ]) {
    cases.test(
      'real protected target entry $refusal preserves original playback authority',
      () async {
        await setup(
          entryLifecycle: true,
          targetOffline: refusal == 'offline',
          targetMetadataMismatch: refusal == 'different-work',
          requestSourcePassword: (_) async => refusal == 'password-cancel'
              ? null
              : refusal == 'password-wrong'
              ? 'wrong'
              : '1234',
        );
        await controller.start();
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
        await _eventually(() => controller.activeMediaSourceId != null);
        final original = controller.activeOrigin!;
        final opens = backend.openCount;
        final preparing = controller.switchConfirmedSource(
          lockedTargetCandidate(),
          refusal == 'missing-version' ? 'not-a-version' : 'v2',
        );
        if (refusal == 'different-work') {
          await expectLater(preparing, throwsStateError);
        } else {
          await preparing;
        }
        expect(controller.switchConfirmation, isNull);
        expect(controller.origin!.source.account, original.source.account);
        expect(original.permit.isValid, isTrue);
        expect(auth.session!.server.id, 'a');
        expect(auth.serverAccess.allows('a'), isTrue);
        expect(auth.serverAccess.allows('b'), isFalse);
        expect(backend.openCount, opens);
        expect(controller.isPlaying, isTrue);
        if (refusal != 'different-work' && refusal != 'missing-version') {
          expect(_Client.allItemRequests, isNot(contains('movie-b')));
        }
        expect((await auth.credentials.read('a'))!.accessToken, 'token');
        expect((await auth.credentials.read('b'))!.accessToken, 'token-b');
      },
    );
  }

  Future<SourceComparison> candidate() async {
    final b = await runtime.registry.acquireAccount('b', libraryId: 'library');
    final reference = SourceReference(account: b, itemId: 'movie-b');
    final item = await runtime.registry
        .permit(b, libraryId: 'library')
        .dispatch((c) => c.getItem('movie-b'));
    return SourceComparison(
      QueryItem(reference, 'library', item),
      const MatchDecision(MatchKind.confirmed, MatchReason.commonProvider),
    );
  }

  cases.test('confirmed switch keeps a live session when the target library needs no participation selection', () async {
    await setup();
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
    await _eventually(() => controller.activeMediaSourceId != null);
    final original = controller.origin;
    final comparison = await candidate();
    await controller.switchConfirmedSource(comparison, 'v2');
    expect(controller.trackFailure, isNull);
    expect(controller.switchConfirmation, isNotNull);
    expect(controller.origin, same(original));
    expect(controller.error, isNull);
  });

  cases.test('cross-server failed target keeps old history and automatically restores permitted original', () async {
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
    expect(controller.error, isNull);
    expect(controller.origin, same(original));
    expect(controller.isPlaying, isTrue);
    expect(auth.session?.server.id, 'a');
    expect(runtime.history.records().single.source.account, account);
    expect(reports.single.playSessionId, 'play-a-movie');
    expect(original!.permit.isValid, isTrue);
    expect(backend.openedStart, const Duration(seconds: 9));
    expect(controller.client.baseUrl?.host, 'a');
  });

  cases.test(
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
      expect(runtime.history.records(), hasLength(1));
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 11));
      await _eventually(() => runtime.history.records().length == 2);
      expect(controller.activeOrigin?.source.account.configuredServerId, 'b');
      await controller.close();
      expect(reports.map((r) => r.playSessionId), [
        'play-a-movie',
        'play-b-movie-b',
      ]);
      expect(runtime.history.records().map((r) => r.source.itemId).toSet(), {
        'movie',
        'movie-b',
      });
    },
  );

  cases.test('lock retires an in-flight target open before publishing locked; no late resurrection', () async {
    await setup(
      entryLifecycle: true,
      requestSourcePassword: (_) async => '1234',
    );
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
    await _eventually(() => controller.activeMediaSourceId != null);
    await controller.switchConfirmedSource(lockedTargetCandidate(), 'v2');
    backend.openGate = Completer<void>();
    final entered = backend.openEntered = Completer<void>();
    final switching = controller.confirmMediaSourceSwitch(
      SwitchResumeChoice.currentPosition,
    );
    await entered.future;
    final locking = auth.serverAccess.lock('b');
    backend.openGate!.complete();
    await Future.wait([locking, switching]);
    expect(backend.isPlaying, isFalse);
    expect(controller.activeOrigin, isNull);
    expect(auth.session?.server.id, 'a');
    expect(auth.serverAccess.allows('a'), isTrue);
    expect(auth.serverAccess.allows('b'), isFalse);
    expect(controller.switchConfirmation, isNull);
    await expectLater(controller.restoreOriginalSource(), throwsStateError);
    expect(
      (await snapshots.read())?.source?.account.configuredServerId,
      isNot('b'),
    );
    expect(
      runtime.history.records().single.source.account.configuredServerId,
      'a',
    );
  });

  cases.test('account logout stops ordinary native session and forbids restore and snapshot dispatch', () async {
    await setup();
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
    await _eventually(() => controller.activeMediaSourceId != null);
    await runtime.registry.logoutSource('a');
    await _eventually(() => !backend.isPlaying);
    expect(controller.permissionRevoked, isTrue);
    expect(controller.activeOrigin, isNull);
    // Native retirement and resource cleanup are independent futures.
    await _eventually(() => snapshots.snapshot == null);
    expect(await snapshots.read(), isNull);
    await expectLater(controller.restoreOriginalSource(), throwsStateError);
  });

  Future<DesktopPlayerWindowHost> desktop(
    _IpcControl ipc, {
    Future<String?> Function(SavedServer)? requestSourcePassword,
    Duration entryOpenTimeout = const Duration(seconds: 150),
  }) async {
    final host = DesktopPlayerWindowHost(
      auth: auth,
      runtime: runtime,
      processControl: ipc,
      requestSourcePassword: requestSourcePassword,
      entryOpenTimeout: entryOpenTimeout,
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

  cases.test(
    'desktop launch reuses catalog versions without playback negotiation',
    () async {
      await setup();
      final origin = await runtime.resolve(controller.openRequest!);
      final client = origin.client as _Client;
      client.catalogVersions = true;
      final before = client.playbackRequests;
      final itemsBefore = client.itemRequests
          .where((id) => id == 'movie')
          .length;
      final ipc = _IpcControl();
      await desktop(ipc);
      expect(ipc.spawnedArguments, hasLength(1));
      expect(client.playbackRequests, before);
      expect(
        client.itemRequests.where((id) => id == 'movie').length,
        itemsBefore + 1,
      );
    },
  );

  cases.test(
    'desktop crash reconciles current unlocked private snapshot',
    () async {
      await setup(private: true);
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 14));
      await _eventually(() => controller.activeMediaSourceId != null);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final saved = (await snapshots.read())!;
      final store = MemoryPlaybackSessionSnapshotStore();
      await store.write(saved);
      final ipc = _IpcControl();
      final host = DesktopPlayerWindowHost(
        auth: auth,
        runtime: runtime,
        processControl: ipc,
        snapshotStoreForPid: (_) => store,
        watchInterval: const Duration(milliseconds: 5),
        closeTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(() async {
        await host.close();
        host.dispose();
      });
      await host.open(controller.openRequest!);
      final before = reports.length;
      ipc.exit(ipc.lastPid);
      await _eventually(() => reports.length > before);
      await _eventually(() => host.current == null);
      expect(await store.read(), isNull);
      expect(reports.last.playSessionId, saved.playSessionId);
      expect(
        reports.last.position.inMicroseconds * 10,
        saved.position.inMicroseconds * 10,
      );
    },
  );

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      '${environment.presentation.name} close revocation drops actual B series navigation',
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('rillight/android_core'),
          (_) async => null,
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            const MethodChannel('rillight/android_core'),
            null,
          ),
        );
        await setup(itemId: 'episode1', widgetTester: tester);
        backend = _Backend();
        addTearDown(() {
          if (backend.stopGate?.isCompleted == false) {
            backend.stopGate!.complete();
          }
        });
        await auth.restore();
        final b = (await runtime.registry.authenticate('b')).account;
        final request = PlayerOpenRequest(
          itemId: 'episode1',
          source: SourceReference(account: b, itemId: 'episode1'),
          libraryId: 'library',
        );
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const Text('root')),
            GoRoute(
              path: '/play/:id',
              builder: (_, _) => environment.isTv
                  ? TvPlayerPage(itemId: request.itemId, sourceRequest: request)
                  : MobilePlayerPage(
                      itemId: request.itemId,
                      sourceRequest: request,
                      orientation: PhoneOrientation(request: (_) async {}),
                      systemBars: PhoneSystemBars(request: (_) async {}),
                      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
                    ),
            ),
            GoRoute(
              path: '/item/:id',
              builder: (_, _) => const Text('unexpected detail'),
            ),
          ],
        );
        await tester.pumpWidget(
          RillightApp(
            auth: auth,
            router: router,
            environment: environment,
            playerBindings: PlayerBindings(
              runtime: runtime,
              createBackend: () => backend,
              settingsStore: MemoryPlayerSettingsStore(),
            ),
          ),
        );
        await settle(tester);
        router.push('/play/episode1', extra: request);
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final c = environment.isTv
            ? tester
                  .state<TvPlayerPageState>(find.byType(TvPlayerPage))
                  .controller!
            : tester
                  .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
                  .controller!;
        expect(c.origin!.source.account, b);
        expect(auth.session!.server.id, 'a');
        c.playbackEnded = true;
        c.onUserActivity();
        await tester.pump();
        final panel = tester.widget<PlaybackEndedPanel>(
          find.byType(PlaybackEndedPanel),
        );
        backend.stopGate = Completer<void>();
        backend.stopEntered = false;
        panel.onViewSeries!();
        for (var i = 0; i < 40 && !backend.stopEntered; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(backend.stopEntered, isTrue);
        var loggedOut = false;
        final logout = runtime.registry
            .logoutSource('b')
            .then((_) => loggedOut = true);
        backend.stopGate!.complete();
        for (var i = 0; i < 60 && !loggedOut; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(loggedOut, isTrue);
        await logout;
        for (
          var i = 0;
          i < 60 &&
              (find.byType(MobilePlayerPage).evaluate().isNotEmpty ||
                  find.byType(TvPlayerPage).evaluate().isNotEmpty);
          i++
        ) {
          await tester.pump(
            const Duration(milliseconds: 50),
            EnginePhase.paint,
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(find.text('unexpected detail'), findsNothing);
        expect(find.byType(MobilePlayerPage), findsNothing);
        expect(find.byType(TvPlayerPage), findsNothing);
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        var cleaned = false;
        final cleanup = c
            .disposeAsync()
            .then((_) => controller.disposeAsync())
            .then((_) => runtime.history.close())
            .then((_) {
              cleaned = true;
            });
        for (var i = 0; i < 40 && !cleaned; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(cleaned, isTrue);
        await cleanup;
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
      },
      tags: ['integration'],
    );
  }

  for (final sameId in [true, false]) {
    cases.test(
      'actual B ended-series command and desktop consumer retain source (same ID=$sameId)',
      () async {
        await setup(itemId: 'episode1');
        final b = (await runtime.registry.authenticate('b')).account;
        final request = PlayerOpenRequest(
          itemId: sameId ? 'episode1' : 'episode-b',
          source: SourceReference(
            account: b,
            itemId: sameId ? 'episode1' : 'episode-b',
          ),
          libraryId: 'library',
        );
        await controller.disposeAsync();
        controller.dispose();
        controller = PlayerController(
          client: auth.client,
          itemId: request.itemId,
          backend: _Backend(),
          window: PlayerWindow(),
          runtime: runtime,
          openRequest: request,
          settingsStore: MemoryPlayerSettingsStore(),
        );
        await controller.start();
        final command = controller.endedSeriesCommand!;
        expect(command.source!.account, b);
        expect(command.itemId, 'series');
        expect(command.libraryId, 'library');
        final ipc = _IpcControl();
        final host = await desktop(ipc);
        PlayerHostOpenItemCommand? routed;
        host.onOpenItemRoute = (_, {seasonId, command}) => routed = command;
        ipc.openDetail = command;
        ipc.exit(ipc.lastPid);
        await _eventually(() => routed != null);
        expect(routed!.source!.account, b);
        expect(routed!.accessGeneration, command.accessGeneration);
      },
    );
  }

  cases.test('desktop close rechecks revoked lease before delivering a queued detail command', () async {
    await setup(itemId: 'episode1');
    await controller.start();
    final ipc = _IpcControl();
    final host = await desktop(ipc);
    var routed = false;
    host.onOpenItemRoute = (_, {seasonId, command}) => routed = true;
    ipc.openDetail = controller.endedSeriesCommand;
    ipc.requestCloseHold = Completer<void>();
    final closing = host.close();
    await _eventually(
      () => ipc.calls.any((c) => c.startsWith('requestClose:')),
    );
    await runtime.registry.logoutSource('a');
    ipc.requestCloseHold!.complete();
    await closing;
    expect(routed, isFalse);
    expect(controller.endedSeriesCommand, isNull);
  });

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
        runtime.registry.permit(account, libraryId: 'library').accessGeneration,
    'source': encodeSource(
      SourceReference(account: account, itemId: 'movie', mediaSourceId: 'v'),
    ),
    'item': 'movie',
    'version': 'v',
    'position': 10 * kLegacyTicksPerSecond,
    'actuallyPlaying': true,
    'timeline': const WatchTimeline(durationTicks: 120 * kLegacyTicksPerSecond)
        .toJson(),
  };

  cases.test(
    'desktop season-scoped player authorizes and records another season',
    () async {
      await setup(itemId: 'episode-no-parent', libraryId: 'season');
      final ipc = _IpcControl();
      await desktop(ipc);
      final envelope = {
        'pid': ipc.lastPid,
        'source': encodeSource(controller.openRequest!.source!),
        'generation': PlayerWindowLaunch.fromArguments(
          ipc.spawnedArguments.single,
        ).accessGeneration,
      };
      ipc.command = {
        ...envelope,
        'sequence': 1,
        'action': 'authorizeItem',
        'item': 'episode-next-season',
      };
      await _eventually(() => ipc.switchReply != null);
      expect(ipc.switchReply!['accepted'], isTrue);
      ipc.event = {
        ...event(ipc, 1),
        'source': encodeSource(
          SourceReference(
            account: account,
            itemId: 'episode-next-season',
            mediaSourceId: 'v',
          ),
        ),
        'item': 'episode-next-season',
      };
      await _eventually(() => ipc.receipt != null);
      expect(ipc.receipt!['accepted'], isTrue);
      ipc.switchReply = null;
      ipc.command = {
        ...envelope,
        'sequence': 2,
        'action': 'authorizeItem',
        'item': 'movie',
      };
      await _eventually(() => ipc.switchReply != null);
      expect(ipc.switchReply!['accepted'], isFalse);
    },
  );

  cases.test('desktop main writer validates source/generation and rejects old IPC sequences', () async {
    await setup();
    final ipc = _IpcControl();
    await desktop(ipc);
    ipc.event = event(ipc, 1);
    await _eventually(() => ipc.receipt != null);
    expect(ipc.receipt!['accepted'], isTrue);
    expect(runtime.history.records(), hasLength(1));
    ipc.receipt = null;
    ipc.event = event(ipc, 1);
    await _eventually(() => ipc.receipt != null);
    expect(ipc.receipt!['accepted'], isFalse);
    ipc.receipt = null;
    ipc.event = event(ipc, 2, generation: -1);
    await _eventually(() => ipc.receipt != null);
    expect(ipc.receipt!['accepted'], isFalse);
    expect(runtime.history.records().single.eventSequence, 1);
    ipc.receipt = null;
    ipc.event = event(ipc, 3)..['played'] = true;
    await _eventually(() => ipc.receipt != null);
    expect(ipc.receipt!['accepted'], isTrue);
    expect(runtime.history.records().single.played, isTrue);
  });

  cases.test('desktop slow observation verification acknowledges pending and keeps heartbeat alive', () async {
    await setup();
    final ipc = _IpcControl();
    await desktop(ipc);
    final owner =
        (await runtime.resolve(controller.openRequest!)).client as _Client;
    final gate = Completer<void>();
    owner.playbackGate = gate.future;
    try {
      ipc.event = event(ipc, 1);
      await _eventually(() => ipc.pendingReceipt != null);
      expect(ipc.pendingReceipt!['sequence'], 1);
      expect(ipc.receipt, isNull);
      final before = ipc.heartbeats;
      await _eventually(() => ipc.heartbeats > before);
      expect(ipc.receipt, isNull);
      gate.complete();
      await _eventually(() => ipc.receipt != null);
      expect(ipc.receipt!['accepted'], isTrue);
      expect(runtime.history.records(), hasLength(1));
    } finally {
      if (!gate.isCompleted) gate.complete();
      owner.playbackGate = null;
    }
  });

  cases.test(
    'desktop account replacement drains the retiring child context',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 14));
      await _eventually(() => snapshots.snapshot?.position.inSeconds == 14);
      final saved = (await snapshots.read())!;
      final store = MemoryPlaybackSessionSnapshotStore(saved);
      final ipc = _IpcControl();
      final host = DesktopPlayerWindowHost(
        auth: auth,
        runtime: runtime,
        processControl: ipc,
        snapshotStoreForPid: (_) => store,
        watchInterval: const Duration(milliseconds: 5),
        closeTimeout: const Duration(seconds: 5),
      );
      addTearDown(() async {
        ipc.requestCloseHold = null;
        await host.close();
        host.dispose();
      });
      await host.open(controller.openRequest!);
      final retiringPid = ipc.lastPid;
      ipc.event = event(ipc, 1);
      await _eventually(() => ipc.receipt != null);
      expect(ipc.receipt!['accepted'], isTrue);

      final b = (await runtime.registry.authenticate('b')).account;
      final closeGate = ipc.requestCloseHold = Completer<void>();
      final before = reports.length;
      final opening = host.open(
        PlayerOpenRequest(
          itemId: 'movie-b',
          libraryId: 'library',
          source: SourceReference(account: b, itemId: 'movie-b'),
        ),
      );
      try {
        await _eventually(
          () => ipc.calls.contains('requestClose:$retiringPid'),
        );
        ipc.receipt = null;
        ipc.event = event(ipc, 2);
        await _eventually(() => ipc.receipt != null);
        expect(ipc.receipt!['accepted'], isTrue);
        expect(ipc.spawnedArguments, hasLength(1));
      } finally {
        closeGate.complete();
        await opening;
      }
      expect(reports, hasLength(before + 1));
      expect(reports.last.playSessionId, saved.playSessionId);
      expect(reports.last.position, saved.position);
      expect(await store.read(), isNull);
      expect(host.current?.source?.account, b);
      expect(ipc.spawnedArguments, hasLength(2));
    },
  );

  cases.test(
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
            .accessGeneration,
        'item': 'movie',
        'version': 'v',
        'succeeded': succeeded,
      };
      ipc.reportOutcome = outcome(1, false);
      await _eventually(
        () =>
            runtime.history.records().single.remoteStatus ==
            RemoteSyncStatus.failed,
      );
      ipc.receipt = null;
      ipc.event = event(ipc, 2);
      await _eventually(() => ipc.receipt != null);
      ipc.reportOutcome = outcome(1, true);
      await _eventually(() => ipc.reportOutcome == null);
      expect(
        runtime.history.records().single.remoteStatus,
        RemoteSyncStatus.pending,
      );
      ipc.reportOutcome = outcome(2, true);
      await _eventually(
        () =>
            runtime.history.records().single.remoteStatus ==
            RemoteSyncStatus.succeeded,
      );
    },
  );

  for (final targetProtected in [false, true]) {
    for (final outcome in [
      'success',
      'paused-success',
      'cancel',
      'helper-failure',
      'backend-failure',
      'open-timeout',
      'child-exit',
      'close-before-open',
      'force-close-before-open',
    ]) {
      cases.test(
        'desktop cross-source entry $outcome protectedTarget=$targetProtected preserves commit boundary',
        () async {
          await setup(entryLifecycle: true, protectedTarget: targetProtected);
          final ipc = _IpcControl();
          var passwordRequests = 0;
          final host = await desktop(
            ipc,
            entryOpenTimeout: const Duration(milliseconds: 250),
            requestSourcePassword: (server) async {
              expect(server.id, 'b');
              passwordRequests++;
              return '1234';
            },
          );
          final originalPermit = runtime.registry.permit(account);
          final target = lockedTargetCandidate().source.reference;
          final envelope = {
            'pid': ipc.lastPid,
            'source': encodeSource(controller.openRequest!.source!),
            'generation': host.current!.accessGeneration,
          };
          ipc.command = {
            ...envelope,
            'sequence': 1,
            'action': 'inspect',
            'target': encodeSource(target),
            'work': encodeSource(target.item),
            'library': 'library',
            'targetVersion': 'v2',
            'item': 'movie',
            'version': 'v',
            'position': 10 * kLegacyTicksPerSecond,
            'paused': outcome == 'paused-success',
            'bitrate': 80000000,
            'audio': 1,
          };
          await _eventually(() => ipc.switchReply != null);
          expect(ipc.switchReply!['accepted'], isTrue);
          expect(passwordRequests, targetProtected ? 1 : 0);
          expect(auth.session!.server.id, 'a');
          expect(originalPermit.isValid, isTrue);
          expect(auth.serverAccess.allows('b'), !targetProtected);
          expect(ipc.spawnedArguments, hasLength(1));
          ipc.switchReply = null;
          if (outcome == 'helper-failure') {
            ipc.startupFailure = 'exited before ready';
          }
          ipc.command = {
            ...envelope,
            'sequence': 2,
            'action': outcome == 'cancel' ? 'cancel' : 'confirm',
            if (outcome != 'cancel') 'choice': 'currentPosition',
          };
          await _eventually(() => ipc.switchReply != null);
          if (outcome == 'success' ||
              outcome == 'paused-success' ||
              outcome == 'backend-failure' ||
              outcome == 'open-timeout' ||
              outcome == 'child-exit' ||
              outcome == 'close-before-open' ||
              outcome == 'force-close-before-open') {
            await _eventually(
              () =>
                  ipc.spawnedArguments.length == 2 &&
                  host.current?.source?.account.configuredServerId == 'b',
            );
            final launch = PlayerWindowLaunch.fromArguments(
              ipc.spawnedArguments.last,
            );
            expect(
              auth.session!.server.id,
              'a',
              reason: 'Helper window ready is not backend-open success',
            );
            expect(originalPermit.isValid, isTrue);
            expect(auth.serverAccess.allows('b'), !targetProtected);
            final openedEnvelope = {
              'pid': ipc.lastPid,
              'source': encodeSource(launch.request.source!),
              'generation': launch.accessGeneration,
              'item': launch.request.itemId,
              'version': launch.request.mediaSourceId,
            };
            if (outcome == 'open-timeout' ||
                outcome == 'child-exit' ||
                outcome == 'close-before-open' ||
                outcome == 'force-close-before-open') {
              final closed = outcome.contains('close-before-open');
              if (outcome == 'child-exit') ipc.alive.remove(ipc.lastPid);
              if (outcome == 'close-before-open') await host.close();
              if (outcome == 'force-close-before-open') await host.forceClose();
              if (closed) {
                expect(host.current, isNull);
              } else {
                await _eventually(() => host.switchFailure != null);
                await _eventually(
                  () => host.current?.source?.account.configuredServerId == 'a',
                );
              }
              expect(auth.session!.server.id, 'a');
              expect(originalPermit.isValid, isTrue);
              expect(auth.serverAccess.allows('b'), !targetProtected);
              final spawnCount = ipc.spawnedArguments.length;
              expect(spawnCount, closed ? 2 : 3);
              ipc.switchReply = null;
              ipc.command = {
                ...openedEnvelope,
                'sequence': 1,
                'action': 'opened',
              };
              await Future<void>.delayed(const Duration(milliseconds: 300));
              expect(
                auth.session!.server.id,
                'a',
                reason: 'Late opened cannot authorize a cancelled entry',
              );
              expect(originalPermit.isValid, isTrue);
              expect(auth.serverAccess.allows('b'), !targetProtected);
              expect(
                ipc.spawnedArguments,
                hasLength(spawnCount),
                reason: 'Cancelled timeout must not reopen a closed player',
              );
              if (closed) expect(host.current, isNull);
              return;
            }
            ipc.switchReply = null;
            ipc.command = {
              ...openedEnvelope,
              'sequence': 1,
              'action': outcome == 'backend-failure' ? 'openFailed' : 'opened',
            };
            await _eventually(() => ipc.switchReply != null);
            if (outcome == 'backend-failure') {
              await _eventually(() => host.switchFailure != null);
              expect(auth.session!.server.id, 'a');
              expect(originalPermit.isValid, isTrue);
              expect(auth.serverAccess.allows('b'), !targetProtected);
              ipc.switchReply = null;
              ipc.command = {
                ...openedEnvelope,
                'sequence': 2,
                'action': 'opened',
              };
              await Future<void>.delayed(const Duration(milliseconds: 30));
              expect(
                auth.session!.server.id,
                'a',
                reason: 'Late success cannot revive failed target entry',
              );
              expect(originalPermit.isValid, isTrue);
              expect(auth.serverAccess.allows('b'), !targetProtected);
              return;
            }
            expect(launch.request.startPaused, outcome == 'paused-success');
            await _eventually(() => auth.session?.server.id == 'b');
            expect(host.current?.source?.account.configuredServerId, 'b');
            expect(auth.serverAccess.allows('b'), isTrue);
            expect(auth.serverAccess.allows('a'), isFalse);
            expect(originalPermit.isValid, isFalse);
            expect(ipc.spawnedArguments, hasLength(2));
            expect(launch.request.source!.account.configuredServerId, 'b');
            expect(launch.request.itemId, 'movie-b');
            expect(launch.request.mediaSourceId, 'v2');
          } else {
            if (outcome == 'helper-failure') {
              await _eventually(() => host.switchFailure != null);
            }
            expect(auth.session!.server.id, 'a');
            expect(originalPermit.isValid, isTrue);
            expect(auth.serverAccess.allows('a'), isTrue);
            expect(auth.serverAccess.allows('b'), !targetProtected);
            if (outcome == 'cancel') expect(ipc.spawnedArguments, hasLength(1));
          }
        },
      );
    }
  }

  cases.test('desktop line RPC preflights without changing active and launches paused target only on confirm', () async {
    await setup();
    final ipc = _IpcControl();
    final host = await desktop(ipc);
    final envelope = {
      'pid': ipc.lastPid,
      'source': encodeSource(controller.openRequest!.source!),
      'generation': PlayerWindowLaunch.fromArguments(
        ipc.spawnedArguments.single,
      ).accessGeneration,
    };
    ipc.command = {
      ...envelope,
      'sequence': 1,
      'action': 'inspect',
      'line': 'wrong',
      'item': 'movie',
      'version': 'v',
      'position': 10 * kLegacyTicksPerSecond,
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
      'position': 10 * kLegacyTicksPerSecond,
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
    final launch = PlayerWindowLaunch.fromArguments(ipc.spawnedArguments.last);
    expect(Uri.parse(launch.baseUrl).host, 'mirror');
    expect(launch.request.startPaused, isTrue);
    expect(
      launch.request.startPosition,
      Duration(microseconds: (10 * kLegacyTicksPerSecond) ~/ 10),
    );
    expect(launch.request.audioStreamIndex, 1);
    expect(launch.request.maxStreamingBitrate, 80000000);
    expect(host.current?.source?.account, account);
  });

  for (final failure in [
    'spawn threw',
    'exited before ready',
    'ready timeout',
  ]) {
    for (final revokeOriginal in [false, true]) {
      cases.testWidgets(
        'desktop main window exposes retry after target and automatic recovery $failure revoke=$revokeOriginal',
        (tester) async {
          await setup(widgetTester: tester);
          final ipc = _IpcControl();
          late DesktopPlayerWindowHost host;
          await tester.runAsync(() async {
            host = await desktop(ipc);
          });
          final router = GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) =>
                    const CupertinoPageScaffold(child: Text('main window')),
              ),
            ],
          );
          await tester.pumpWidget(
            RillightApp(
              auth: auth,
              router: router,
              playerBindings: PlayerBindings(
                runtime: runtime,
                windowHost: host,
              ),
            ),
          );
          await settle(tester);
          final originalPid = ipc.lastPid;
          await tester.runAsync(() async {
            final b = (await runtime.registry.authenticate('b')).account;
            final envelope = {
              'pid': originalPid,
              'source': encodeSource(controller.openRequest!.source!),
              'generation': host.current!.accessGeneration,
            };
            ipc.command = {
              ...envelope,
              'sequence': 1,
              'action': 'inspect',
              'target': encodeSource(
                SourceReference(account: b, itemId: 'movie-b'),
              ),
              'work': encodeSource(
                SourceReference(account: b, itemId: 'movie-b'),
              ),
              'library': 'library',
              'targetVersion': 'v2',
              'item': 'movie',
              'version': 'v',
              'position': 17 * kLegacyTicksPerSecond,
              'paused': true,
              'bitrate': 80000000,
              'audio': 1,
            };
            await _eventually(() => ipc.switchReply != null);
            expect(ipc.switchReply!['accepted'], isTrue);
            expect(ipc.alive, contains(originalPid));
            ipc.startupFailures.addAll([failure, failure]);
            ipc.command = {
              ...envelope,
              'sequence': 2,
              'action': 'confirm',
              'choice': 'currentPosition',
            };
            await _eventually(() => host.switchFailure != null);
            expect(ipc.alive, isEmpty);
            expect(host.current, isNull);
          });
          await settle(tester);
          expect(find.textContaining('来源切换失败'), findsOneWidget);
          expect(find.text('播放进度未能同步'), findsNothing);
          final button = find.byKey(const Key('desktop-restore-original'));
          expect(tester.widget<AppButton>(button).onPressed, isNotNull);
          if (revokeOriginal) {
            await tester.runAsync(() => runtime.registry.logoutSource('a'));
            await settle(tester);
            expect(find.textContaining('来源切换失败'), findsNothing);
            expect(button, findsNothing);
            expect(host.canRestoreOriginal, isFalse);
            expect(host.current, isNull);
            await tester.runAsync(() async {
              await expectLater(host.restoreOriginalSource(), throwsStateError);
            });
            expect(ipc.spawnedArguments, hasLength(3));
          } else {
            await tester.runAsync(() async {
              await tester.tap(button);
              await _eventually(() => host.current != null);
            });
            await settle(tester);
            final restored = PlayerWindowLaunch.fromArguments(
              ipc.spawnedArguments.last,
            );
            expect(Uri.parse(restored.baseUrl).host, 'a');
            expect(
              restored.request.startPosition,
              Duration(microseconds: (17 * kLegacyTicksPerSecond) ~/ 10),
            );
            expect(restored.request.startPaused, isTrue);
            expect(restored.request.audioStreamIndex, 1);
            expect(restored.request.subtitleOff, isTrue);
            expect(restored.request.maxStreamingBitrate, 80000000);
            expect(restored.request.mediaSourceId, 'v');
            expect(find.textContaining('来源切换失败'), findsNothing);
            expect(reports, isEmpty);
          }
          await tester.runAsync(() => host.close());
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
        },
        tags: ['integration'],
      );
    }
  }

  cases.test('desktop lock redacts a saved failed-switch transaction and late startup error', () async {
    await setup(private: true);
    final ipc = _IpcControl();
    final host = await desktop(ipc);
    final envelope = {
      'pid': ipc.lastPid,
      'source': encodeSource(controller.openRequest!.source!),
      'generation': host.current!.accessGeneration,
    };
    ipc.command = {
      ...envelope,
      'sequence': 1,
      'action': 'inspect',
      'line': 'mirror',
      'item': 'movie',
      'version': 'v',
      'position': 10 * kLegacyTicksPerSecond,
      'paused': true,
      'bitrate': 80000000,
      'audio': 1,
    };
    await _eventually(() => ipc.switchReply != null);
    expect(ipc.switchReply!['accepted'], isTrue);
    ipc.spawnHold = Completer<void>();
    ipc.startupFailure = 'late ready timeout';
    ipc.command = {
      ...envelope,
      'sequence': 2,
      'action': 'confirm',
      'choice': 'currentPosition',
    };
    await _eventually(() => ipc.spawnedArguments.length == 2);
    final locking = auth.serverAccess.lock('a');
    expect(host.switchFailure, isNull);
    expect(host.canRestoreOriginal, isFalse);
    ipc.spawnHold!.complete();
    await locking;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(host.switchFailure, isNull);
    expect(host.current, isNull);
    await auth.serverAccess.unlock('a', '1234');
    await expectLater(host.restoreOriginalSource(), throwsStateError);
    expect(ipc.spawnedArguments, hasLength(2));
    expect(reports, isEmpty);
  });

  cases.test(
    'desktop lock closes private helper and does not reconcile an old snapshot',
    () async {
      await setup(private: true);
      final ipc = _IpcControl();
      final host = await desktop(ipc);
      await auth.serverAccess.lock('a');
      await _eventually(() => ipc.alive.isEmpty);
      expect(ipc.revoked, isTrue);
      expect(host.current, isNull);
      expect(reports, isEmpty);
    },
  );
}

final cases = CaseShard(3);

void mainShard(int part, int expectedParts) =>
    cases.register(part, main, expectedParts: expectedParts);
