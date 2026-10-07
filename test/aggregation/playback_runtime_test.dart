import 'dart:async';
import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/router.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/player/phone_orientation.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/playback_ended_panel.dart';
import 'package:flutter/material.dart';
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
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_state.dart';
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
  final progressReports = <PlaybackReport>[];
  bool failProgress = false;
  bool failStopped = false;
  int playbackRequests = 0;
  bool failPublic = false;
  bool offerNext = false;
  @override
  EmbyClient withRequestGuard(void Function() guard) {
    final probe = _Client(reports);
    probe.attachSession(
      baseUrl: baseUrl!,
      accessToken: accessToken!,
      userId: userId!,
      userAgent: customUserAgent,
    );
    return probe;
  }

  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    if (failPublic) throw StateError('synthetic offline');
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
  Future<EmbyUser> getUser() async => EmbyUser(id: userId!, name: 'test');
  @override
  Future<EmbyItem> getItem(String id, {String? fields}) async =>
      EmbyItem.fromJson({
        'Id': id,
        'Name': id,
        'Type': id == 'library'
            ? 'CollectionFolder'
            : id.startsWith('episode')
            ? 'Episode'
            : 'Movie',
        if (id.startsWith('episode')) ...{
          'SeriesId': 'series',
          'SeasonId': 'season',
          'ParentIndexNumber': 1,
          'IndexNumber': id == 'episode1' ? 1 : 2,
        },
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
  }) async {
    playbackRequests++;
    return PlaybackInfo.fromJson({
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
  }

  @override
  Future<EmbyItem?> getNextEpisode(EmbyItem current) async =>
      offerNext ? getItem('episode2') : null;
  @override
  Future<void> markPlayed(String itemId) async {
    if (failStopped) throw StateError('synthetic played failure');
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) async {}
  @override
  Future<void> reportProgress(PlaybackReport report) async {
    progressReports.add(report);
    if (failProgress) throw StateError('synthetic report failure');
  }

  @override
  Future<void> reportStopped(PlaybackReport report) async {
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
  Completer<Map<String, dynamic>>? gate;
  int renewals = 0;
  void delayNextProfile() {
    entered = Completer<void>();
    gate = Completer<Map<String, dynamic>>();
  }

  @override
  Future<Map<String, dynamic>> deviceProfile(int bitrate) {
    if (gate == null) return Future.value({});
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
    final failure = startupFailure;
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

  Future<void> setup({
    bool private = false,
    String itemId = 'movie',
    _Backend? videoBackend,
    WidgetTester? widgetTester,
  }) async {
    reports = [];
    final access = RegionAccessController();
    if (private) {
      await access.setPin('1234', '1234', (_) async {});
      await access.unlock('1234');
    }
    final store = MemoryServerListStore(
      ServerListSnapshot(
        lastServerId: 'a',
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
    backend = videoBackend ?? _Backend();
    snapshots = MemoryPlaybackSessionSnapshotStore();
    controller = PlayerController(
      client: auth.client,
      itemId: itemId,
      backend: backend,
      window: PlayerWindow(),
      runtime: runtime,
      snapshotStore: snapshots,
      settingsStore: MemoryPlayerSettingsStore(),
      progressInterval: const Duration(milliseconds: 30),
      openRequest: PlayerOpenRequest(
        itemId: itemId,
        libraryId: 'library',
        regionGeneration: registry.permit(account).regionGeneration,
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

  test(
    'current private snapshot recovers Stopped and failed report retries',
    () async {
      await setup(private: true);
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 17));
      await _eventually(() => controller.activeMediaSourceId != null);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final snapshot = (await snapshots.read())!;
      expect(runtime.canRecoverSnapshot(snapshot), isTrue);
      final client = controller.client as _Client;
      client.failStopped = true;
      await expectLater(runtime.recoverSnapshot(snapshot), throwsStateError);
      expect(runtime.canRecoverSnapshot(snapshot), isTrue);
      client.failStopped = false;
      expect(await runtime.recoverSnapshot(snapshot), isTrue);
      expect(reports.last.positionTicks, 17 * kEmbyTicksPerSecond);
      expect(reports.last.playSessionId, snapshot.playSessionId);
      final recoveryStore = MemoryPlaybackSessionSnapshotStore();
      await recoveryStore.write(snapshot);
      client.failStopped = true;
      await expectLater(
        recoverAndroidSession(auth.client, recoveryStore, runtime: runtime),
        throwsStateError,
      );
      expect(await recoveryStore.read(), isNotNull);
      client.failStopped = false;
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
        {'libraryId': 'wrong'},
      ]) {
        final invalid = PlaybackSessionSnapshot.fromJson({
          ...snapshot.toJson(),
          ...edit,
        })!;
        expect(await runtime.recoverSnapshot(invalid), isFalse);
      }
      expect(reports.length, beforeInvalid);
      await auth.regionAccess.lock();
      final count = reports.length;
      expect(await runtime.recoverSnapshot(snapshot), isFalse);
      await auth.regionAccess.unlock('1234');
      expect(await runtime.recoverSnapshot(snapshot), isFalse);
      expect(reports.length, count);
    },
  );

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    for (final sameId in [true, false]) {
      testWidgets(
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
            await auth.regionAccess.setPin('1234', '1234', (_) async {});
            await auth.regionAccess.unlock('1234');
          });
          final router = createAppRouter(auth: auth, environment: environment);
          backend = _Backend();
          controller.dispose();
          final request = PlayerOpenRequest(
            itemId: 'movie',
            source: SourceReference(account: account, itemId: 'movie'),
            libraryId: 'library',
            regionGeneration: runtime.registry.permit(account).regionGeneration,
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
            for (var i = 0; i < 30; i++) {
              await tester.pump(const Duration(milliseconds: 50));
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
            }
          }

          router.go(
            '/item/movie',
            extra: PlayerHostOpenItemCommand(
              itemId: 'movie',
              source: request.source,
              libraryId: 'library',
              regionGeneration: request.regionGeneration,
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
            () => runtime.registry.move('a', AccessRegion.private),
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
          expect(
            runtime.history
                .records(AccessRegion.ordinary)
                .single
                .source
                .account,
            b,
          );
          expect(
            runtime.history.records(AccessRegion.ordinary).single.positionTicks,
            12 * kEmbyTicksPerSecond,
          );
          expect(c.client.baseUrl!.host, 'b');
          final bClient = c.client as _Client;
          expect(
            bClient.progressReports.last.playSessionId,
            'play-b-$targetId',
          );
          expect(
            bClient.progressReports.last.positionTicks,
            12 * kEmbyTicksPerSecond,
          );
          final progressCount = bClient.progressReports.length;
          await tester.runAsync(
            () => runtime.registry.configureScope(
              'b',
              participates: false,
              libraryIds: {},
            ),
          );
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 99),
          );
          await drain();
          expect(c.permissionRevoked, isTrue);
          expect(c.activeOrigin, isNull);
          expect(runtime.history.records(AccessRegion.ordinary), isEmpty);
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

  testWidgets(
    'playback line menu lists only this server and keeps the saved line',
    (tester) async {
      await tester.runAsync(() async {
        await setup(widgetTester: tester);
        await controller.start();
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
        await _eventually(() => controller.activeMediaSourceId == 'v');
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SourceSwitchButton(controller: controller)),
        ),
      );
      expect(find.text('手动切换'), findsNothing);
      expect(find.text('立即锁定'), findsNothing);
      expect(find.byKey(const Key('player-playback-lines')), findsOneWidget);
      await tester.tap(find.byKey(const Key('player-playback-lines')));
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      expect(controller.client.baseUrl?.host, 'a');
      await tester.tap(find.byKey(const Key('player-playback-lines')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('playback-line-mirror')));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (controller.client.baseUrl?.host == 'mirror') break;
      }
      expect(controller.client.baseUrl?.host, 'mirror');
      expect(backend.openedStart, const Duration(seconds: 9));
      expect(
        auth.sources.project(AccessRegion.ordinary).first.activeLineId,
        'line',
      );
      controller.dispose();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
    'aggregation item plays from the server session when its library is not checked',
    () async {
      await setup();
      await runtime.registry.configureScope(
        'a',
        participates: true,
        libraryIds: {},
      );
      final origin = await runtime.resolve(
        PlayerOpenRequest(
          itemId: 'movie',
          libraryId: 'library',
          source: SourceReference(account: account, itemId: 'movie'),
        ),
      );
      expect(origin.permit.sessionOnly, isTrue);
      expect(origin.libraryId, 'library');
      expect(
        (await origin.permit.dispatch((client) => client.getItem('movie'))).id,
        'movie',
      );
      final session = await runtime.begin(origin, 'v');
      expect(session.permit.sessionOnly, isTrue);
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
        expect(
          auth.sources.project(AccessRegion.ordinary).first.activeLineId,
          'line',
        );
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
      expect(reports.last.positionTicks, 13 * kEmbyTicksPerSecond);
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
      expect(
        auth.sources.project(AccessRegion.ordinary).first.activeLineId,
        'line',
      );
      final remembered = runtime.preference(
        controller.origin!,
        controller.item!,
        controller.mediaSources,
      );
      expect(remembered.preference?.lineId, isNot('mirror'));
    },
  );

  test('line open failure continues on the original line', () async {
    await setup();
    await controller.start();
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 12));
    await _eventually(() => controller.activeMediaSourceId != null);
    await controller.togglePlay();
    final original = controller.client;
    backend.failNextOpen = true;
    await controller.switchLine('mirror');
    expect(controller.playbackLineFailure, isNotNull);
    expect(controller.state.phase, isNot(PlaybackPhase.failed));
    expect(controller.client, same(original));
    expect(controller.client.baseUrl?.host, 'a');
    expect(backend.openedStart, const Duration(seconds: 12));
    expect(
      auth.sources.project(AccessRegion.ordinary).first.activeLineId,
      'line',
    );
  });

  test(
    'in-process line switch restores the shared address when stop or dispose fails',
    () async {
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
        );
        try {
          await playing.start();
          await playing.switchLine('mirror');
          expect(client.baseUrl?.host, 'mirror');
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
    },
  );

  test(
    'in-process line switch restores the shared address when close stop hangs',
    () async {
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
      );
      try {
        await playing.start();
        await playing.switchLine('mirror');
        expect(client.baseUrl?.host, 'mirror');
        video.hangStop = const Duration(seconds: 5);
        await playing.close();
        expect(video.stopFinished, isFalse);
        expect(client.baseUrl?.host, 'a');
        expect(client.accessToken, 'token');
        expect(client.userId, 'user');
        expect(client.customUserAgent, 'Rillight');
        await Future<void>.delayed(const Duration(seconds: 5));
      } finally {
        try {
          await playing.disposeAsync();
        } catch (_) {}
        playing.dispose();
      }
    },
  );

  test('playback line label uses a nickname, otherwise host and port', () {
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
  });

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

  test(
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

  test(
    'delayed capabilities cannot dispatch PlaybackInfo after scope revocation',
    () async {
      final delayed = _CapabilitiesBackend()..delayNextProfile();
      await setup(videoBackend: delayed);
      final starting = controller.start();
      await delayed.entered.future;
      final client = controller.client as _Client;
      final count = client.playbackRequests;
      await runtime.registry.configureScope(
        'a',
        participates: true,
        libraryIds: const {},
      );
      delayed.gate!.complete({});
      await starting;
      expect(client.playbackRequests, count);
    },
  );

  for (final prefix in [false, true]) {
    test(
      'delayed ${prefix ? 'next prefix' : 'URL renewal'} has zero dispatch after scope removal',
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
        await runtime.registry.configureScope(
          'a',
          participates: true,
          libraryIds: const {},
        );
        delayed.gate!.complete({});
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(client.playbackRequests, count);
        expect(delayed.renewals, 0);
      },
    );
  }

  test(
    'finish-current picker records played before remote failures and keeps playback intent',
    () async {
      await setup(itemId: 'episode1');
      await controller.start();
      (controller.client as _Client).failStopped = true;
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 119));
      await _eventually(() => controller.activeMediaSourceId != null);
      await controller.playEpisode(await controller.client.getItem('episode2'));
      expect(runtime.history.records(account.region).single.played, isTrue);
      expect(controller.itemId, 'episode2');
      expect(controller.loading, isFalse);
      expect(backend.openedPaused, isFalse);
    },
  );

  test('natural EOF persists local played even when Stopped fails', () async {
    await setup();
    await controller.start();
    (controller.client as _Client).failStopped = true;
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 120));
    backend.emitEvent(VideoEventKind.completed, true);
    await _eventually(() => controller.playbackEnded);
    await controller.close();
    final record = runtime.history.records(AccessRegion.ordinary).single;
    expect(record.positionTicks, 120 * kEmbyTicksPerSecond);
    expect(record.played, isTrue);
    final query = AggregationQueryController(
      registry: runtime.registry,
      history: runtime.history,
    );
    expect(query.localContinueWatching, isEmpty);
    query.dispose();
  });

  test(
    'fresh ordinary registry recovery acquires session and retries transient failure',
    () async {
      await setup();
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
      await _eventually(() => controller.activeMediaSourceId != null);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final saved = (await snapshots.read())!;
      final freshReports = <PlaybackReport>[];
      var offline = true;
      final freshRegistry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: MemoryServerListStore(
          ServerListSnapshot(
            servers: runtime.registry.project(AccessRegion.ordinary),
          ),
        ),
        credentials: MemoryCredentialStore({
          'a': const StoredCredentials(
            accessToken: 'token',
            userId: 'user',
            username: 'test',
          ),
        }),
        createClient: () => _Client(freshReports)
          ..failPublic = offline
          ..failStopped = true,
      );
      await freshRegistry.load();
      final freshAuth = AuthController(
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
      expect(
        freshRegistry.sessionAccount(
          'a',
          region: AccessRegion.ordinary,
          libraryId: 'library',
        ),
        isNull,
      );
      offline = false;
      await expectLater(
        recoverAndroidSession(freshAuth.client, store, runtime: fresh),
        throwsStateError,
      );
      expect(await store.read(), isNotNull);
      final permit = freshRegistry.permit(account, libraryId: 'library');
      await permit.dispatch((c) async {
        (c as _Client).failStopped = false;
      });
      expect(
        await recoverAndroidSession(freshAuth.client, store, runtime: fresh),
        isTrue,
      );
      expect(await store.read(), isNull);
      expect(freshReports.last.positionTicks, saved.positionTicks);
    },
  );

  test(
    'fresh private registry rejects prior snapshot without acquisition even after unlock',
    () async {
      await setup(private: true);
      await controller.start();
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 10));
      await _eventually(() => controller.activeMediaSourceId != null);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final saved = (await snapshots.read())!;
      final access = RegionAccessController();
      await access.setPin('1234', '1234', (_) async {});
      await access.unlock('1234');
      var acquisitions = 0;
      final registry = SourceSessionRegistry(
        access: access,
        store: MemoryServerListStore(
          ServerListSnapshot(
            servers: runtime.registry.project(AccessRegion.private),
          ),
        ),
        credentials: MemoryCredentialStore(),
        createClient: () {
          acquisitions++;
          return _Client([]);
        },
      );
      await registry.load();
      final freshAuth = AuthController(
        client: _Client([]),
        sources: registry,
        credentials: MemoryCredentialStore(),
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
    },
  );

  testWidgets(
    'real helper close drains final IPC and waits for ack before exit',
    (tester) async {
      const account = SourceAccount(
        region: AccessRegion.ordinary,
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
            regionGeneration: 0,
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
        Future<Map<String, dynamic>?> readEvent() async {
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            final event = await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 5));
              return protocol.read('watch-event');
            });
            if (event != null) return event;
          }
          return null;
        }

        final first = await readEvent();
        expect(first?['position'], 10 * kEmbyTicksPerSecond);
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
        helperBackend.emitEvent(
          VideoEventKind.position,
          const Duration(seconds: 18),
        );
        await tester.pump();
        await tester.runAsync(() => protocol.write('close'));
        await tester.pump(const Duration(milliseconds: 100));
        final finalEvent = await readEvent();
        expect(finalEvent?['position'], 18 * kEmbyTicksPerSecond);
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

  test('desktop crash reconciles current unlocked private snapshot', () async {
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
    expect(reports.last.positionTicks, saved.positionTicks);
  });

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
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
        await tester.pumpAndSettle();
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
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(backend.stopEntered, isTrue);
        await runtime.registry.configureScope(
          'b',
          participates: false,
          libraryIds: {},
        );
        backend.stopGate!.complete();
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
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
        final cleanup = controller
            .disposeAsync()
            .then((_) => runtime.history.close())
            .then((_) {
              cleaned = true;
            });
        for (var i = 0; i < 40 && !cleaned; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
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
    test(
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
        expect(routed!.regionGeneration, command.regionGeneration);
      },
    );
  }

  test(
    'desktop close rechecks revoked lease before delivering a queued detail command',
    () async {
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
      await runtime.registry.configureScope(
        'a',
        participates: false,
        libraryIds: {},
      );
      ipc.requestCloseHold!.complete();
      await closing;
      expect(routed, isFalse);
      expect(controller.endedSeriesCommand, isNull);
    },
  );

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
      ipc.receipt = null;
      ipc.event = event(ipc, 3)..['played'] = true;
      await _eventually(() => ipc.receipt != null);
      expect(ipc.receipt!['accepted'], isTrue);
      expect(runtime.history.records(account.region).single.played, isTrue);
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

  for (final failure in [
    'spawn threw',
    'exited before ready',
    'ready timeout',
  ]) {
    for (final revokeOriginal in [false, true]) {
      testWidgets(
        'desktop main window exposes explicit saved-state recovery after $failure revoke=$revokeOriginal',
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
                builder: (_, _) => const Scaffold(body: Text('main window')),
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
          await tester.pumpAndSettle();
          final originalPid = ipc.lastPid;
          await tester.runAsync(() async {
            final b = (await runtime.registry.authenticate('b')).account;
            final envelope = {
              'pid': originalPid,
              'source': encodeSource(controller.openRequest!.source!),
              'generation': host.current!.regionGeneration,
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
              'position': 17 * kEmbyTicksPerSecond,
              'paused': true,
              'bitrate': 80000000,
              'audio': 1,
            };
            await _eventually(() => ipc.switchReply != null);
            expect(ipc.switchReply!['accepted'], isTrue);
            expect(ipc.alive, contains(originalPid));
            ipc.startupFailure = failure;
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
          await tester.pumpAndSettle();
          expect(find.textContaining('来源切换失败'), findsOneWidget);
          expect(find.text('播放进度未能同步'), findsNothing);
          final button = find.byKey(const Key('desktop-restore-original'));
          expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
          if (revokeOriginal) {
            await tester.runAsync(
              () => runtime.registry.configureScope(
                'a',
                participates: false,
                libraryIds: {'library'},
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('原来源访问许可已失效，无法恢复。'), findsOneWidget);
            expect(tester.widget<FilledButton>(button).onPressed, isNull);
            await tester.runAsync(() async {
              await expectLater(host.restoreOriginalSource(), throwsStateError);
            });
            expect(ipc.spawnedArguments, hasLength(2));
          } else {
            await tester.runAsync(() async {
              await tester.tap(button);
              await _eventually(() => host.current != null);
            });
            await tester.pumpAndSettle();
            final restored = PlayerWindowLaunch.fromArguments(
              ipc.spawnedArguments.last,
            );
            expect(Uri.parse(restored.baseUrl).host, 'a');
            expect(restored.request.startTimeTicks, 17 * kEmbyTicksPerSecond);
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

  test(
    'desktop lock redacts a saved failed-switch transaction and late startup error',
    () async {
      await setup(private: true);
      final ipc = _IpcControl();
      final host = await desktop(ipc);
      final envelope = {
        'pid': ipc.lastPid,
        'source': encodeSource(controller.openRequest!.source!),
        'generation': host.current!.regionGeneration,
      };
      ipc.command = {
        ...envelope,
        'sequence': 1,
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
      ipc.spawnHold = Completer<void>();
      ipc.startupFailure = 'late ready timeout';
      ipc.command = {
        ...envelope,
        'sequence': 2,
        'action': 'confirm',
        'choice': 'currentPosition',
      };
      await _eventually(() => ipc.spawnedArguments.length == 2);
      final locking = auth.regionAccess.lock(
        budget: const Duration(milliseconds: 100),
      );
      expect(host.switchFailure, isNull);
      expect(host.canRestoreOriginal, isFalse);
      ipc.spawnHold!.complete();
      await locking;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(host.switchFailure, isNull);
      expect(host.current, isNull);
      await auth.regionAccess.unlock('1234');
      await expectLater(host.restoreOriginalSource(), throwsStateError);
      expect(ipc.spawnedArguments, hasLength(2));
      expect(reports, isEmpty);
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
