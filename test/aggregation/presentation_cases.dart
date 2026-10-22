import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/case_shard.dart';
import '../helpers/server_access_fixture.dart';

import 'dart:async';

import 'package:dio/dio.dart';

import 'dart:ui' as ui;
import 'dart:io';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/widgets/option_pill.dart';
import 'package:rillight/app/source_route_extra_codec.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/library/source_selection.dart';
import 'package:rillight/library/server_library_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/aggregation/query/aggregation_query.dart';
import 'package:rillight/aggregation/query/same_source_query.dart';
import 'package:rillight/library/episode_mapping_dialog.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_process_control.dart';
import 'package:rillight/player/player_process_protocol.dart';

import 'dart:convert';

import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/auth/server_selection_page.dart';
import 'package:rillight/auth/tv_server_selection_page.dart';
import 'package:rillight/player/source_switch_menu.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_mailbox.dart';

class _Movie extends FakeEmbyItem {
  _Movie()
    : super(
        id: 'shared-id',
        name: '合成作品',
        type: 'Movie',
        parentId: 'view-movies',
      );
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'ProviderIds': {'Tmdb': '1234'},
  };
}

class _ConflictMovie extends FakeEmbyItem {
  _ConflictMovie()
    : super(
        id: 'conflict',
        name: '合成作品',
        type: 'Movie',
        parentId: 'view-movies',
      );
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'ProviderIds': {'Tmdb': '9999'},
  };
}

class _ComparisonMovie extends _Movie {
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'MediaSources': [
      for (var version = 0; version < 3; version++)
        {
          'Id': 'internal-version-$version',
          'Name': version == 0 ? '剧场版 1080p' : '收藏版 4K',
          'Width': version == 0 ? 1920 : 3840,
          'Height': version == 0 ? 1080 : 2160,
          'MediaStreams': [
            {'Index': 0, 'Type': 'Video', 'Codec': 'h264'},
            {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'Language': 'eng'},
            for (var subtitle = 0; subtitle < 24; subtitle++)
              {
                'Index': subtitle + 2,
                'Type': 'Subtitle',
                'Codec': 'subrip',
                'Language': 'chi',
              },
          ],
        },
    ],
  };
}

class _ControlledHistoryStore extends MemoryHistoryStore {
  bool fail = false;
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<void> replace(Map<String, dynamic> snapshot) async {
    if (gate != null) {
      entered?.complete();
      await gate!.future;
    }
    if (fail) throw StateError('synthetic disk failure');
    await super.replace(snapshot);
  }
}

class _RecordingHost extends PlayerWindowHost {
  @override
  PlayerOpenRequest? current;
  @override
  bool get embedsPlayerInCaller => false;
  @override
  Future<void> open(PlayerOpenRequest request) async {
    current = request;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    current = null;
    notifyListeners();
  }
}

class _IsolatedHelperControl extends DesktopPlayerProcessControl {
  static const launchTimeout = Duration(seconds: 180);

  _IsolatedHelperControl()
    : super(
        startupTimeout: launchTimeout + const Duration(seconds: 10),
        pollInterval: const Duration(milliseconds: 30),
      );
  final Map<int, Process> children = {};
  final Map<int, PlayerProcessProtocol> protocols = {};
  final Set<int> alive = {};
  final StringBuffer output = StringBuffer();
  final Set<Process> runningChildren = {};

  Future<void> stopChild(Process child) async {
    if (!runningChildren.contains(child)) return;
    if (Platform.isWindows) {
      // Killing only flutter.bat's cmd.exe leaves its compiler/tester running
      // against a launch directory that the parent is about to remove.
      await Process.run('taskkill', ['/PID', '${child.pid}', '/T', '/F']);
    } else {
      child.kill();
    }
    await child.exitCode.timeout(const Duration(seconds: 10));
  }

  // This fixture exercises cold, simulated player windows. It does not host
  // the native prewarmed-engine entry point (covered by process-control tests).
  @override
  Future<void> prepare({required String executable}) async {}

  @override
  Future<int> launch(String executable, String payloadPath) async {
    final json = jsonDecode(
      await File(payloadPath).readAsString(),
    ) as Map<String, dynamic>;
    final launch = PlayerWindowLaunch.fromJson(json);
    // Flutter copies native assets into build/native_assets before each test
    // invocation. Windows cannot replace a DLL loaded by the parent suite.
    // Give only this child a private Flutter config/output directory; keep its
    // source, SDK, native hooks and IPC protocol identical to the parent.
    Directory? childConfig;
    if (Platform.isWindows) {
      childConfig = await Directory.systemTemp.createTemp(
        'rillight-ipc-config-',
      );
      await File('${childConfig.path}/.flutter_settings').writeAsString(
        jsonEncode({
          'build-dir':
              'build/ipc-helper-$pid-${DateTime.now().microsecondsSinceEpoch}',
        }),
      );
    }
    final child = await Process.start(
      'flutter',
      [
        'test',
        '--no-pub',
        '--reporter',
        'expanded',
        'test/helpers/desktop_ipc_fixture.dart',
      ],
      environment: {
        'RILLIGHT_TEST_LAUNCH': payloadPath,
        if (childConfig != null) 'APPDATA': childConfig.path,
      },
      // Flutter is a .bat entrypoint on Windows; direct CreateProcess cannot
      // resolve it as an executable without the command shell.
      runInShell: Platform.isWindows,
    );
    child.stdout.transform(utf8.decoder).listen(output.write);
    child.stderr.transform(utf8.decoder).listen(output.write);
    runningChildren.add(child);
    var finished = false;
    unawaited(
      child.exitCode.then((_) async {
        finished = true;
        runningChildren.remove(child);
        alive.removeWhere((id) => children[id] == child);
        await childConfig?.delete(recursive: true);
      }),
    );
    // Cold native hooks compile in an isolated directory while the full suite
    // is busy. This budget belongs to the test compiler, not product startup.
    final deadline = DateTime.now().add(launchTimeout);
    while (!finished && DateTime.now().isBefore(deadline)) {
      // Unlike native CreateProcess, this launch waits for Flutter to compile
      // the child. Keep the parent's lease alive during that wait; otherwise
      // a compilation over 15 seconds makes the child immediately self-close.
      await launch.protocol!.heartbeat();
      final ready = await launch.protocol!.read('ready', consume: false);
      if (ready != null) {
        final id = ready['pid'] as int;
        children[id] = child;
        protocols[id] = launch.protocol!;
        alive.add(id);
        return id;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await stopChild(child);
    throw StateError('Isolated simulated helper did not start: $output');
  }

  @override
  bool isAlive(int pid) => alive.contains(pid);
  @override
  Future<void> terminate(int pid) async {
    final child = children[pid];
    if (child != null) {
      await stopChild(child);
    } else {
      Process.killPid(pid);
    }
    alive.remove(pid);
  }
}

class _Series extends FakeEmbyItem {
  _Series()
    : super(id: 'series', name: '合成剧集', type: 'Series', parentId: 'view-tv');
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'ProviderIds': {'Tmdb': '77'},
  };
}

class _BlockingCatalogAdapter extends FakeEmbyAdapter {
  _BlockingCatalogAdapter(super.servers);
  String? blockedAuthority;
  String blockedSuffix = '/Items';
  bool entered = false;
  final gate = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.authority == blockedAuthority &&
        options.uri.path.endsWith(blockedSuffix)) {
      entered = true;
      await gate.future;
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

class _PresentationClient extends EmbyClient {
  _PresentationClient({required super.device, required super.dio});

  // The synthetic HTTP adapter does not intercept WebSocket connections.
  // Presentation tests must not resolve fake server hosts on the real network.
  @override
  CatalogNotifications? watchCatalog({
    required Future<void> Function() onUserDataChanged,
    required Future<void> Function() onLibraryChanged,
  }) => null;
}

class _Fixture {
  final a = FakeEmbyServer(
    serverId: 'a',
    serverName: '来源 A',
    baseUrl: Uri.parse('http://a.test'),
    items: [_Movie()],
  );
  final b = FakeEmbyServer(
    serverId: 'b',
    serverName: '来源 B',
    baseUrl: Uri.parse('http://b.test'),
    items: [_Movie()],
  );
  late FakeEmbyAdapter adapter;
  late AuthController auth;
  late HistoryWriter history;
  late PlaybackRuntime runtime;
  late String aId, bId;
  Future<void> open({
    HistoryStore? historyStore,
    FakeEmbyAdapter? sourceAdapter,
  }) async {
    adapter = sourceAdapter ?? FakeEmbyAdapter([a, b]);
    final credentials = MemoryCredentialStore();
    final servers = MemoryServerListStore();
    MediaServerClient client() => _PresentationClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'test',
        version: '1',
      ),
      dio: dioForFakeEmby(adapter),
    );
    final sources = SourceSessionRegistry(
      access: TestServerAccessController(),
      store: servers,
      credentials: credentials,
      createClient: client,
    );
    auth = AuthController(
      client: client(),
      credentials: credentials,
      servers: servers,
      sources: sources,
    );
    for (final server in [a, b]) {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      if (server == a) {
        aId = auth.session!.server.id;
      } else {
        bId = auth.session!.server.id;
      }
    }
    await auth.switchTo(aId);
    history = await HistoryWriter.open(
      registry: sources,
      store: historyStore ?? MemoryHistoryStore(),
    );
    runtime = PlaybackRuntime(auth: auth, history: history);
  }

  Future<void> protect(String id, {bool unlock = false}) async {
    await auth.serverAccess.setPassword(
      id,
      '1234',
      '1234',
      persistReference: (ref) =>
          auth.sources.persistProtectionReference(id, ref),
    );
    if (unlock) expect(await auth.serverAccess.unlock(id, '1234'), isTrue);
  }

  /// Recreate process-owned state from the same persisted configuration. A
  /// protected remembered server retains credentials but has no live session.
  Future<void> reopen() async {
    final credentials = auth.credentials;
    final servers = auth.sources.store;
    final accessStore = auth.serverAccess.store;
    final historyStore = history.store;
    await close();
    MediaServerClient client() => _PresentationClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'test',
        version: '1',
      ),
      dio: dioForFakeEmby(adapter),
    );
    final sources = SourceSessionRegistry(
      access: TestServerAccessController(store: accessStore),
      store: servers,
      credentials: credentials,
      createClient: client,
    );
    await sources.load();
    auth = AuthController(
      client: client(),
      credentials: credentials,
      servers: servers,
      sources: sources,
    );
    await auth.restore();
    history = await HistoryWriter.open(registry: sources, store: historyStore);
    runtime = PlaybackRuntime(auth: auth, history: history);
  }

  RillightApp app(
    PresentationEnvironment environment, {
    FakeVideoBackend? backend,
    PlayerWindowHost? host,
  }) => RillightApp(
    auth: auth,
    environment: environment,
    playerBindings: PlayerBindings(
      windowHost: host,
      createBackend: backend == null ? null : () => backend,
      progressInterval: const Duration(milliseconds: 200),
      runtime: runtime,
      settingsStore: MemoryPlayerSettingsStore(),
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
    ),
  );
  Future<void> close() async {
    await history.close();
    auth.dispose();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 240), EnginePhase.paint);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump(Duration.zero, EnginePhase.sendSemanticsUpdate);
}

Future<void> _drive(WidgetTester tester, Future<void> work) async {
  var finished = false;
  Object? failure;
  unawaited(
    work.then(
      (_) => finished = true,
      onError: (Object error) {
        failure = error;
        finished = true;
      },
    ),
  );
  for (var frame = 0; frame < 80 && !finished; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  if (failure != null) throw failure!;
  if (!finished) throw StateError('playback switch did not finish');
}

Future<void> _typeEntryPassword(
  WidgetTester tester,
  PresentationEnvironment environment,
  String password,
) async {
  final input = find.byKey(const Key('server-unlock-password'));
  expect(input, findsOneWidget);
  if (environment.isTv) {
    await tester.tap(input);
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('tv-input-editor')), password);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
  } else {
    await tester.enterText(input, password);
  }
  await tester.tap(find.byKey(const Key('server-unlock-submit')));
  await _settle(tester);
}

Future<void> _finishRevocation(
  WidgetTester tester,
  Future<void> transaction,
) async {
  var finished = false;
  Object? failure;
  unawaited(
    transaction.then(
      (_) => finished = true,
      onError: (Object error) {
        failure = error;
        finished = true;
      },
    ),
  );
  for (var frame = 0; frame < 100 && !finished; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(finished, isTrue, reason: 'Revocation exceeded ten seconds of frames');
  if (failure != null) throw failure!;
}

Future<void> _openOwnedDetail(
  WidgetTester tester,
  _Fixture f,
  RillightApp app, {
  required String serverId,
  required String itemId,
  String libraryId = 'view-movies',
}) async {
  final account = await tester.runAsync(
    () => f.auth.sources.acquireAccount(serverId, libraryId: libraryId),
  );
  final permit = f.auth.sources.permit(account!, libraryId: libraryId);
  app.router.go(
    '/item/$itemId',
    extra: PlayerHostOpenItemCommand(
      itemId: itemId,
      source: SourceReference(account: account, itemId: itemId),
      libraryId: libraryId,
      accessGeneration: permit.accessGeneration,
    ),
  );
  await _settle(tester);
}

Future<Uint8List> _png(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _confirmSwitch(PlayerController controller) async {
  final plan = controller.switchConfirmation;
  if (plan == null) return;
  await controller.confirmMediaSourceSwitch(
    SwitchResumeChoice.beginning,
    acceptDefaultAudio: plan.audioNeedsChoice,
    turnSubtitlesOff: plan.subtitleNeedsChoice,
  );
}

Future<SameSourceQueryController> _comparisons(
  PlayerController controller,
) async {
  final origin = controller.origin!;
  final runtime = controller.runtime!;
  final dto = await origin.permit.dispatch(
    (client) => client.getItem(origin.work.itemId),
  );
  final comparison = SameSourceQueryController(
    registry: runtime.registry,
    history: runtime.history,
  );
  await comparison.start(
    origin: QueryItem(origin.work, origin.libraryId, dto),
    scope: QueryScope(),
  );
  return comparison;
}

Future<void> _switchConfirmedServer(
  PlayerController controller,
  String serverId,
) async {
  final origin = controller.origin!;
  final runtime = controller.runtime!;
  final comparison = await _comparisons(controller);
  try {
    final candidate = comparison.comparisons.firstWhere(
      (item) =>
          item.decision.confirmed &&
          item.source.reference.account.configuredServerId == serverId,
    );
    final target = await runtime.resolve(
      PlayerOpenRequest(
        itemId: candidate.source.reference.itemId,
        source: candidate.source.reference,
        work: candidate.source.reference.item,
        libraryId: candidate.source.libraryId,
        accessGeneration: origin.permit.accessGeneration,
      ),
    );
    final info = await target.permit.dispatch(
      (client) => client.getPlaybackInfo(itemId: target.source.itemId),
    );
    await controller.switchConfirmedSource(
      candidate,
      info.mediaSources.first.id,
    );
    await _confirmSwitch(controller);
  } finally {
    comparison.dispose();
  }
}

Future<void> _switchMappedEpisode(
  PlayerController controller,
  String serverId,
) async {
  final origin = controller.origin!;
  final runtime = controller.runtime!;
  final item = controller.item!;
  final comparison = await _comparisons(controller);
  try {
    final candidate = comparison.comparisons.firstWhere(
      (entry) =>
          entry.decision.confirmed &&
          entry.source.reference.account.configuredServerId == serverId,
    );
    await comparison.lookupEpisode(
      target: candidate.source,
      episode: withConfirmedEpisodeMapping(
        EpisodeSource.fromMediaItem(origin.source, item),
      ),
      verifiedNumberingScheme: userConfirmedEpisodeNumbering,
    );
    final result = comparison.episodes
        .where((entry) => entry.target == candidate.source.reference)
        .first;
    final reference = result.lookup.source!.reference;
    final target = await runtime.resolve(
      PlayerOpenRequest(
        itemId: reference.itemId,
        source: reference,
        work: candidate.source.reference.item,
        libraryId: candidate.source.libraryId,
        accessGeneration: origin.permit.accessGeneration,
      ),
    );
    final info = await target.permit.dispatch(
      (client) => client.getPlaybackInfo(itemId: target.source.itemId),
    );
    await controller.switchConfirmedSource(
      candidate,
      info.mediaSources.first.id,
      episode: result,
    );
    await _confirmSwitch(controller);
  } finally {
    comparison.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // WebSocket caches its HTTP client on first use. Initialize it under the
  // widget binding's HTTP override, before any runAsync enters the real zone.
  // These catalog fixtures use synthetic .test hosts, never real DNS/sockets.
  WebSocket.userAgent = 'Rillight synthetic catalog tests';
  cases.testWidgets(
    'B album save chooser receipt cannot save bytes after source migration',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.b.items.first.backdropImageTags = ['b-one', 'b-two'];
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      final album = find.byType(DetailAlbumStrip);
      await tester.ensureVisible(album);
      await _settle(tester);
      await tester.tap(
        find
            .descendant(of: album, matching: find.byType(ui.AppSurfaceAction))
            .first,
      );
      await _settle(tester);
      final directory = Directory.systemTemp.createTempSync('t6-revoked-save-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final output = File('${directory.path}/must-not-exist.png');
      final chooser = Completer<String?>();
      var requested = false;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) {
            requested = true;
            return chooser.future;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.tap(find.text('下载原图'));
      await _settle(tester);
      expect(requested, isTrue);
      await tester.runAsync(() async {
        await f.protect(f.bId);
      });
      chooser.complete(output.path);
      await _settle(tester);
      expect(output.existsSync(), isFalse);
      expect(find.byType(ui.AppModalFrame), findsNothing);
      expect(find.text('图片已保存'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      '${environment.presentation.name} real management checks backup line without changing active source',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(() => _drive(tester, f.close()));
        final backup = FakeEmbyServer(
          serverId: 'a',
          serverName: '备用线路',
          baseUrl: Uri.parse('http://backup.test'),
        );
        backup.issuedTokens.addAll(f.a.issuedTokens);
        f.adapter.add(backup);
        late SavedServer saved;
        late SourceSession session;
        await tester.runAsync(() async {
          await f.auth.addLine(f.aId, backup.baseUrl.toString());
          saved = f.auth.sources.project().firstWhere((s) => s.id == f.aId);
          await f.auth.sources.renameLine(f.aId, saved.lines.last.id, '备用线路');
          session = await f.auth.sources.authenticate(f.aId);
        });
        f.auth.sources.permit(session.account, libraryId: 'view-movies');
        final activeClient = f.auth.client;
        final activeUrl = activeClient.baseUrl;
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : environment.isDesktop
            ? const Size(1024, 768)
            : const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final app = f.app(environment);
        await tester.pumpWidget(app);
        await _settle(tester);
        if (environment.isDesktop) {
          await tester.tap(find.byKey(const Key('app-shell-aggregation')));
        } else if (environment.isTv) {
          await tester.tap(find.byKey(const ValueKey('tv-nav-1')));
        } else {
          await tester.tap(
            find.descendant(
              of: find.byType(CupertinoTabBar),
              matching: find.text('聚合'),
            ),
          );
        }
        await _settle(tester);
        app.router.go('/servers');
        await _settle(tester);
        expect(
          find.byType(
            environment.isTv ? TvServerSelectionPage : ServerSelectionPage,
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(Key('server-lines-${f.aId}')));
        await _settle(tester);
        final check = find.byKey(
          Key('server-line-check-${saved.lines.last.id}'),
        );
        await tester.ensureVisible(check);
        await tester.tap(check);
        await _settle(tester);
        final updated = f.auth.sources.server(f.aId);
        expect(updated.lines.last.checkStatus, 'available');
        expect(updated.lines.last.checkedAt, isNotNull);
        expect(find.textContaining('连接正常'), findsWidgets);
        expect(updated.activeLineId, saved.activeLineId);
        expect(
          f.auth.sources
              .permit(session.account, libraryId: 'view-movies')
              .isValid,
          isTrue,
        );
        expect(session.account.configuredServerId, f.aId);
        expect(f.auth.client, same(activeClient));
        expect(f.auth.client.baseUrl, activeUrl);
        expect(
          backup.requests.any((r) => r.contains('/System/Info/Public')),
          isTrue,
        );
        expect(backup.requests.any((r) => r.contains('/Users/')), isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
    cases.testWidgets(
      '${environment.presentation.name} protected entry cancellation preserves selection and success opens target home',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        await tester.runAsync(() => f.protect(f.bId));
        addTearDown(() => _drive(tester, f.close()));
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : environment.isDesktop
            ? const Size(1024, 768)
            : const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final app = f.app(environment);
        await tester.pumpWidget(app);
        await _settle(tester);
        app.router.go('/servers');
        await _settle(tester);
        await tester.tap(find.byKey(Key('server-enter-${f.bId}')));
        await _settle(tester);
        expect(find.byKey(const Key('server-unlock-password')), findsOneWidget);
        expect(f.auth.serverAccess.allows(f.bId), isFalse);
        await tester.tap(
          find.byKey(
            Key(environment.isTv ? 'tv-server-back' : 'server-flow-back'),
          ),
        );
        await _settle(tester);
        expect(find.byKey(const Key('server-unlock-password')), findsNothing);
        expect(f.auth.serverAccess.allows(f.bId), isFalse);
        expect(f.auth.session!.server.id, f.aId);
        expect(
          f.auth.sources.project().map((s) => s.id),
          containsAll([f.aId, f.bId]),
        );
        await tester.tap(find.byKey(Key('server-enter-${f.bId}')));
        await _settle(tester);
        if (environment.isTv) {
          await tester.tap(find.byKey(const Key('server-unlock-password')));
          await _settle(tester);
          await tester.enterText(
            find.byKey(const Key('tv-input-editor')),
            '1234',
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await _settle(tester);
        } else {
          await tester.enterText(
            find.byKey(const Key('server-unlock-password')),
            '1234',
          );
        }
        await tester.tap(find.byKey(const Key('server-unlock-submit')));
        await _settle(tester);
        expect(f.auth.serverAccess.allows(f.bId), isTrue);
        expect(f.auth.session!.server.id, f.bId);
        expect(app.router.state.uri.path, '/');
        expect(find.byType(ServerSelectionPage), findsNothing);
        expect(find.byType(TvServerSelectionPage), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'TV remote actual B detail and controller write seven seconds then protection rejects late observation',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(() async {
        await f.open();
      });
      addTearDown(() => _drive(tester, f.close()));
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeVideoBackend(duration: const Duration(seconds: 120));
      final app = f.app(PresentationEnvironment.tv, backend: backend);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        app.router.dispose();
      });
      await tester.pumpWidget(app);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      expect(find.byType(TvDetailPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _settle(tester);
      expect(find.byType(TvPlayerPage), findsOneWidget);
      expect(backend.isPlaying, isTrue);
      var notifications = 0;
      f.history.addListener(() => notifications++);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
      await _settle(tester);
      final record = f.history.records().single;
      expect(record.source.account.configuredServerId, f.bId);
      expect(record.libraryId, 'view-movies');
      expect(record.positionTicks, 70000000);
      expect(notifications, greaterThan(0));
      expect(f.b.playbackEvents, isNotEmpty);
      expect(f.a.playbackEvents, isEmpty);
      await tester.runAsync(() async {});
      late Future<void> migration;
      await tester.runAsync(() async {
        migration = f.protect(f.bId);
      });
      await _settle(tester);
      await tester.runAsync(() => migration);
      await _settle(tester);
      expect(backend.isPlaying, isFalse);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
      await _settle(tester);
      expect(f.history.records(), isEmpty);
      final persisted = await tester.runAsync(f.history.store.read);
      expect(
        (persisted!['records'] as List).single['position'],
        70000000,
        reason: 'Lock hides history but must retain the committed progress; late frames cannot replace it',
      );
      expect(
        await tester.runAsync(() => f.auth.serverAccess.unlock(f.bId, '1234')),
        isTrue,
      );
      await tester.runAsync(() => f.auth.sources.ensureSession(f.bId));
      expect(f.history.records().single.positionTicks, 70000000);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  cases.testWidgets(
    'phone manually switches actual source then server lock rejects late frames',
    (tester) async {
      final reportError = FlutterError.onError;
      FlutterError.onError = (details) {
        debugPrint(details.stack?.toString());
        reportError?.call(details);
      };
      addTearDown(() => FlutterError.onError = reportError);
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeVideoBackend(duration: const Duration(seconds: 120));
      final app = f.app(PresentationEnvironment.phone, backend: backend);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        app.router.dispose();
      });
      await tester.pumpWidget(app);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      await tester.ensureVisible(find.byKey(const Key('mobile-detail-play')));
      await tester.tap(find.byKey(const Key('mobile-detail-play')));
      await _settle(tester);
      final c = tester
          .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
          .controller!;
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
      await _settle(tester);
      expect(
        f.history.records().single.source.account.configuredServerId,
        f.bId,
      );
      expect(find.text('手动切换'), findsNothing);
      expect(find.byType(PlaybackLineMenu), findsNothing);
      await _drive(tester, _switchConfirmedServer(c, f.aId));
      await _settle(tester);
      // Opening a target is pending, not proof of viewing. The actual backend
      // observation commits active provenance and the sole writer's record.
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 11));
      await _settle(tester);
      expect(
        c.activeOrigin!.source.account.configuredServerId,
        f.aId,
        reason:
            'track=${c.trackFailure} disconnect=${c.disconnectDetail} '
            'confirmation=${c.switchConfirmation} pending=${c.pendingMediaSourceId}',
      );
      expect(
        f.history.records().any(
          (r) =>
              r.source.account.configuredServerId == f.aId &&
              r.positionTicks == 110000000,
        ),
        isTrue,
      );
      // Changing the selected ordinary account must not retarget playback A.
      await tester.runAsync(() => f.auth.switchTo(f.bId));
      await _settle(tester);
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      expect(backend.isPlaying, isTrue);
      expect(c.activeOrigin!.source.account.configuredServerId, f.aId);
      debugPrint('T7 phone: ordinary selection preserves active A');
      await tester.runAsync(() async {});
      late Future<void> moving;
      await tester.runAsync(() async {
        moving = f.protect(f.aId);
      });
      await _settle(tester);
      debugPrint('T7 phone: advancing A membership revocation');
      await _finishRevocation(tester, moving);
      debugPrint('T7 phone: A membership revoked');
      await _settle(tester);
      expect(backend.isPlaying, isFalse);
      expect(find.byType(PlaybackLineMenu), findsNothing);
      debugPrint('T7 phone: entering private A');
      await tester.runAsync(() => f.auth.serverAccess.unlock(f.aId, '1234'));
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.aId,
        itemId: 'shared-id',
      );
      await tester.ensureVisible(find.byKey(const Key('mobile-detail-play')));
      await tester.tap(find.byKey(const Key('mobile-detail-play')));
      await _settle(tester);
      expect(backend.isPlaying, isTrue);
      expect(find.byKey(const Key('player-lock-private')), findsNothing);
      debugPrint('T7 phone: locking actual private player');
      final privatePlayer = tester
          .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
          .controller!;
      await tester.runAsync(privatePlayer.lockCurrentServer);
      debugPrint('T7 phone: lock tap dispatched');
      await _settle(tester);
      debugPrint('T7 phone: lock frame settled');
      expect(f.auth.serverAccess.allows(f.aId), isFalse);
      expect(backend.isPlaying, isFalse);
      expect(find.byType(PlaybackLineMenu), findsNothing);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 29));
      await _settle(tester);
      debugPrint('T7 phone: rejected late frame');
      expect(
        f.history.records().every(
          (r) => r.source.account.configuredServerId != f.aId,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  cases.testWidgets(
    'phone B detail play dispatch reaches actual controller and same writer, protection stops late observations',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      final backend = FakeVideoBackend(duration: const Duration(seconds: 120));
      final app = f.app(PresentationEnvironment.phone, backend: backend);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        app.router.dispose();
      });
      await tester.pumpWidget(app);
      await _settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(CupertinoTabBar),
          matching: find.text('聚合'),
        ),
      );
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      final play = find.byKey(const Key('mobile-detail-play'));
      await tester.ensureVisible(play);
      await tester.pump();
      await tester.tap(play);
      await _settle(tester);
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      expect(backend.isPlaying, isTrue);
      var notifications = 0;
      f.history.addListener(() => notifications++);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
      await _settle(tester);
      final record = f.history.records().single;
      expect(record.source.account.configuredServerId, f.bId);
      expect(record.libraryId, 'view-movies');
      expect(record.positionTicks, 7 * 10000000);
      expect(notifications, greaterThan(0));
      expect(f.b.playbackEvents, isNotEmpty);
      expect(f.a.playbackEvents, isEmpty);
      expect(f.auth.session!.server.id, f.bId);
      await tester.runAsync(() async {});
      late Future<void> migration;
      await tester.runAsync(() async {
        migration = f.protect(f.bId);
      });
      // Source revocation removes the route; allow its actual controller's
      // retirement/observation queue to run while membership cleanup awaits it.
      await _settle(tester);
      await tester.runAsync(() => migration);
      await _settle(tester);
      expect(backend.isPlaying, isFalse);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
      await _settle(tester);
      expect(f.history.records(), isEmpty);
      final persisted = await tester.runAsync(f.history.store.read);
      expect(
        (persisted!['records'] as List).single['position'],
        70000000,
        reason: 'Lock hides history but must retain the committed progress; late frames cannot replace it',
      );
      expect(
        await tester.runAsync(() => f.auth.serverAccess.unlock(f.bId, '1234')),
        isTrue,
      );
      await tester.runAsync(() => f.auth.sources.ensureSession(f.bId));
      expect(f.history.records().single.positionTicks, 70000000);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  cases.testWidgets(
    'legacy shelf nextup retains zero-progress episode and latest routes constrain actual types',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.a.items.add(
        FakeEmbyItem(
          id: 'zero-next',
          name: '零进度下一集',
          type: 'Episode',
          parentId: 'view-movies',
          nextUp: true,
        ),
      );
      f.a.items.add(
        FakeEmbyItem(
          id: 'new-series',
          name: '最近剧集',
          type: 'Series',
          parentId: 'view-movies',
        ),
      );
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/shelf/nextup');
      await _settle(tester);
      expect(find.text('零进度下一集'), findsOneWidget);
      expect(
        f.a.requests.any(
          (r) => r.contains('/Shows/NextUp') && !r.contains('ParentId='),
        ),
        isTrue,
      );
      for (final pair in [
        ('latest-movies', 'Movie', '合成作品', '最近剧集'),
        ('latest-series', 'Series', '最近剧集', '合成作品'),
      ]) {
        f.a.requests.clear();
        app.router.go('/shelf/${pair.$1}');
        await _settle(tester);
        expect(find.text(pair.$3), findsOneWidget);
        expect(find.text(pair.$4), findsNothing);
        expect(
          f.a.requests.any(
            (r) =>
                r.contains('IncludeItemTypes=${pair.$2}') &&
                r.contains('SortBy=DateLastContentAdded'),
          ),
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
  cases.testWidgets(
    'B album thumbnails and full viewer use B bytes; migration evicts viewer and rejects late B image',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.a.items.first.backdropImageTags = ['a-one', 'a-two'];
      f.b.items.first.backdropImageTags = ['b-one', 'b-two'];
      f.a.itemImageBytes = await tester.runAsync(
        () => _png(const Color(0xffff3b30)),
      );
      f.b.itemImageBytes = await tester.runAsync(
        () => _png(const Color(0xff007aff)),
      );
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      final album = find.byType(DetailAlbumStrip);
      await tester.ensureVisible(album);
      await _settle(tester);
      final thumb = find.descendant(of: album, matching: find.byType(Image));
      expect(thumb, findsWidgets);
      for (final image in tester.widgetList<Image>(thumb)) {
        expect(
          (image.image as MemoryImage).bytes,
          orderedEquals(f.b.itemImageBytes!),
        );
      }
      final thumbnailProviders = tester
          .widgetList<Image>(thumb)
          .map((image) => image.image)
          .toList();
      final beforeA = f.a.requests
          .where((r) => r.contains('/Images/Backdrop'))
          .length;
      final directory = Directory.systemTemp.createTempSync('t6-source-album-');
      addTearDown(() async {
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      final output = File('${directory.path}/b.png');
      const saveChannel = MethodChannel('plugins.flutter.io/file_selector');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(saveChannel, (_) async => output.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(saveChannel, null),
      );
      await tester.tap(
        find
            .descendant(of: album, matching: find.byType(ui.AppSurfaceAction))
            .first,
      );
      await _settle(tester);
      final fullImages = find.descendant(
        of: find.byType(ui.AppModalFrame),
        matching: find.byType(Image),
      );
      expect(fullImages, findsWidgets);
      for (final image in tester.widgetList<Image>(fullImages)) {
        expect(
          (image.image as MemoryImage).bytes,
          orderedEquals(f.b.itemImageBytes!),
        );
      }
      await tester.tap(find.text('下载原图'));
      await _settle(tester);
      final saved = find
          .ancestor(
            of: find.text('下载原图'),
            matching: find.byWidgetPredicate(
              (widget) => widget is ui.AppButton,
            ),
          )
          .first;
      for (
        var turn = 0;
        turn < 100 && tester.widget<ui.AppButton>(saved).onPressed == null;
        turn++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 20), EnginePhase.paint);
      }
      expect(tester.widget<ui.AppButton>(saved).onPressed, isNotNull);
      final written = await tester.runAsync(output.readAsBytes);
      expect(written, orderedEquals(f.b.itemImageBytes!));
      await tester.tap(find.byIcon(ui.CupertinoIcons.xmark).last);
      await _settle(tester);
      f.b.holdItemImage = Completer<void>();
      await tester.tap(
        find
            .descendant(of: album, matching: find.byType(ui.AppSurfaceAction))
            .first,
      );
      await _settle(tester);
      expect(find.byType(ui.AppModalFrame), findsOneWidget);
      expect(
        f.b.requests.any(
          (r) => r.contains('/Images/Backdrop/0') && !r.contains('MaxWidth'),
        ),
        isTrue,
      );
      expect(
        f.a.requests.where((r) => r.contains('/Images/Backdrop')).length,
        beforeA,
      );
      await tester.runAsync(() => f.protect(f.bId));
      f.b.holdItemImage!.complete();
      await _settle(tester);
      expect(find.byType(ui.AppModalFrame), findsNothing);
      for (final provider in thumbnailProviders) {
        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isFalse,
        );
      }
      expect(find.text('下载原图'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'TV D-pad enters aggregation and retains Cupertino control focus for multiple frames',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = f.app(PresentationEnvironment.tv);
      await tester.pumpWidget(app);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      final target = FocusManager.instance.primaryFocus;
      expect(target, isNotNull);
      expect(
        target!.context!.findAncestorWidgetOfExactType<AggregationPage>(),
        isNotNull,
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(FocusManager.instance.primaryFocus, same(target));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      final control = FocusManager.instance.primaryFocus;
      expect(
        control!.context!.findAncestorWidgetOfExactType<AggregationPage>(),
        isNotNull,
      );
      expect(find.text('继续播放'), findsWidgets);
      expect(find.text('收藏'), findsWidgets);
      expect(find.text('媒体库'), findsWidgets);
      expect(
        find.byKey(const Key('aggregation-source-management')),
        findsNothing,
      );
      expect(find.byKey(const Key('aggregation-private-entry')), findsNothing);
      expect(find.text('选择影片来源'), findsNothing);
      expect(find.byType(ui.AppChoiceChip), findsNothing);
      await tester.tap(find.byKey(const Key('aggregation-segment-libraries')));
      await _settle(tester);
      expect(find.text('来源 A'), findsWidgets);
      expect(find.text('来源 B'), findsWidgets);
      expect(find.byType(ItemDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
  cases.testWidgets(
    'desktop shell search focuses input, closes on Escape and result, returns allowed scope',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      Future<void> openSearch() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await _settle(tester);
      }

      await openSearch();
      final input = find.byKey(const Key('aggregation-keyword'));
      expect(tester.widget<ui.AppTextField>(input).focusNode?.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(input, findsNothing);
      await openSearch();
      await tester.enterText(input, '合成');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      expect(find.text('来源 A'), findsWidgets);
      expect(find.text('来源 B'), findsWidgets);
      expect(find.byType(ui.AppChoiceChip), findsNothing);
      expect(find.text('媒体库范围'), findsNothing);
      await tester.ensureVisible(find.text('合成作品').last);
      await tester.pump();
      await tester.tap(find.text('合成作品').last);
      await _settle(tester);
      expect(input, findsNothing);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(f.auth.session!.server.id, f.bId);
      app.router.pop();
      await _settle(tester);
      expect(find.text('继续播放'), findsWidgets);
      expect(find.text('选择影片来源'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
  cases.test('writer notifies committed records only; failed storage and failing observer cannot corrupt observation order', () async {
    final store = _ControlledHistoryStore();
    final f = _Fixture();
    await f.open(historyStore: store);
    addTearDown(f.close);
    final account = await f.auth.sources.acquireAccount(
      f.bId,
      libraryId: 'view-movies',
    );
    final source = SourceReference(
      account: account,
      itemId: 'shared-id',
      mediaSourceId: 'v',
    );
    final session = await f.history.beginSession(
      source: source,
      work: source.item,
      libraryId: 'view-movies',
    );
    var notifications = 0;
    f.history.addListener(() => notifications++);
    store.fail = true;
    await expectLater(
      f.history.observe(
        session: session,
        eventSequence: 1,
        positionTicks: 10,
        actuallyPlaying: true,
        timeline: const WatchTimeline(durationTicks: 100),
      ),
      throwsStateError,
    );
    expect(notifications, 0);
    expect(f.history.records(), isEmpty);
    store.fail = false;
    expect(
      await f.history.observe(
        session: session,
        eventSequence: 1,
        positionTicks: 10,
        actuallyPlaying: true,
        timeline: const WatchTimeline(durationTicks: 100),
      ),
      isNotNull,
    );
    expect(notifications, 1);
    final previous = FlutterError.onError;
    f.history.addListener(() => throw StateError('synthetic observer'));
    FlutterError.onError = (_) =>
        throw StateError('synthetic observer reporter');
    try {
      expect(
        await f.history.observe(
          session: session,
          eventSequence: 2,
          positionTicks: 20,
          actuallyPlaying: true,
          timeline: const WatchTimeline(durationTicks: 100),
        ),
        isNotNull,
      );
      expect(
        await f.history.observe(
          session: session,
          eventSequence: 2,
          positionTicks: 30,
          actuallyPlaying: true,
          timeline: const WatchTimeline(durationTicks: 100),
        ),
        isNull,
      );
      expect(f.history.records().single.eventSequence, 2);
      expect(notifications, 2);
    } finally {
      FlutterError.onError = previous;
    }
  });

  cases.test('writer close drains accepted storage without late notifications and rejects new observations', () async {
    final store = _ControlledHistoryStore();
    final f = _Fixture();
    await f.open(historyStore: store);
    addTearDown(f.close);
    final account = await f.auth.sources.acquireAccount(
      f.bId,
      libraryId: 'view-movies',
    );
    final source = SourceReference(
      account: account,
      itemId: 'shared-id',
      mediaSourceId: 'v',
    );
    final session = await f.history.beginSession(
      source: source,
      work: source.item,
      libraryId: 'view-movies',
    );
    var notifications = 0;
    f.history.addListener(() => notifications++);
    store.gate = Completer<void>();
    store.entered = Completer<void>();
    final accepted = f.history.observe(
      session: session,
      eventSequence: 1,
      positionTicks: 10,
      actuallyPlaying: true,
      timeline: const WatchTimeline(durationTicks: 100),
    );
    await store.entered!.future;
    final closing = f.history.close();
    store.gate!.complete();
    await accepted;
    await closing;
    expect(notifications, 0);
    await expectLater(
      f.history.observe(
        session: session,
        eventSequence: 2,
        positionTicks: 20,
        actuallyPlaying: true,
        timeline: const WatchTimeline(durationTicks: 100),
      ),
      throwsStateError,
    );
  });

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      '${environment.presentation.name} real entry shows server rows and retries only the failed server',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(() => _drive(tester, f.close()));
        f.b.viewsStatus = 503;
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : environment.isDesktop
            ? const Size(640, 900)
            : const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final app = f.app(environment);
        await tester.pumpWidget(app);
        await _settle(tester);
        if (environment.isDesktop) {
          await tester.tap(find.byKey(const Key('app-shell-aggregation')));
        } else if (environment.isTv) {
          await tester.tap(find.byKey(const ValueKey('tv-nav-1')));
        } else {
          await tester.tap(
            find.descendant(
              of: find.byType(CupertinoTabBar),
              matching: find.text('聚合'),
            ),
          );
        }
        await _settle(tester);
        expect(find.byType(AggregationPage), findsOneWidget);
        expect(find.text('继续播放'), findsWidgets);
        expect(find.text('收藏'), findsWidgets);
        expect(find.text('媒体库'), findsWidgets);
        // 聚合保留服务器入口，旧私密区域入口已删除。
        expect(
          find.byKey(const Key('aggregation-source-management')),
          environment.isTv ? findsNothing : findsOneWidget,
        );
        expect(
          find.byKey(const Key('aggregation-private-entry')),
          findsNothing,
        );
        expect(find.text('选择影片来源'), findsNothing);
        expect(find.text('媒体库范围'), findsNothing);
        expect(find.byType(ui.AppChoiceChip), findsNothing);
        await tester.tap(
          find.byKey(const Key('aggregation-segment-libraries')),
        );
        await _settle(tester);
        expect(find.text('来源 A'), findsWidgets);
        expect(find.text('来源 B'), findsWidgets);
        expect(find.text('电影'), findsWidgets);
        final libraryImage = tester.widget<MediaImage>(
          find.byType(MediaImage).first,
        );
        expect(libraryImage.preferBackdrop, isFalse);
        expect(libraryImage.height, libraryImage.width! * 9 / 16);
        final aggregation = find.byType(AggregationPage);
        if (environment.isDesktop) {
          expect(
            find.descendant(of: aggregation, matching: find.byType(MediaShelf)),
            findsWidgets,
          );
          expect(
            find.descendant(
              of: aggregation,
              matching: find.byType(PhoneSectionHeader),
            ),
            findsNothing,
          );
        } else if (environment.isTv) {
          expect(
            find.descendant(of: aggregation, matching: find.byType(TvItemRow)),
            findsWidgets,
          );
          expect(
            find.descendant(of: aggregation, matching: find.byType(MediaShelf)),
            findsNothing,
          );
        } else {
          expect(
            find.descendant(
              of: aggregation,
              matching: find.byType(PhoneSectionHeader),
            ),
            findsWidgets,
          );
          expect(
            find.descendant(of: aggregation, matching: find.byType(MediaShelf)),
            findsNothing,
          );
          expect(
            find.descendant(of: aggregation, matching: find.byType(TvItemRow)),
            findsNothing,
          );
          expect(
            tester
                .getSize(find.byKey(const Key('aggregation-segment-libraries')))
                .height,
            greaterThanOrEqualTo(48),
          );
        }
        expect(find.text('重试'), findsOneWidget);
        f.b.viewsStatus = null;
        await tester.tap(find.text('重试'));
        await _settle(tester);
        expect(find.text('来源 A'), findsWidgets);
        expect(find.text('来源 B'), findsWidgets);
        expect(find.text('重试'), findsNothing);
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('aggregation-server-${f.bId}')),
            matching: find.text('电影'),
          ),
        );
        await tester.pump();
        expect(find.byType(ServerSelectionPage), findsNothing);
        expect(find.byType(TvServerSelectionPage), findsNothing);
        expect(find.byKey(const Key('server-search')), findsNothing);
        await _settle(tester);
        expect(
          find.byType(
            environment.isDesktop
                ? LibraryPage
                : environment.isTv
                ? TvLibraryPage
                : MobileLibraryPage,
          ),
          findsOneWidget,
        );
        expect(app.router.state.uri.path, '/library/view-movies');
        expect(f.auth.session!.server.id, f.bId);
        expect(find.text('合成作品'), findsWidgets);
        app.router.go('/library/view-movies');
        await _settle(tester);
        expect(find.byType(AggregationPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'continue watching opens the recorded B version and timeline on server B',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      late SourceReference source;
      await tester.runAsync(() async {
        final account = await f.auth.sources.acquireAccount(
          f.bId,
          libraryId: 'view-movies',
        );
        source = SourceReference(
          account: account,
          itemId: 'shared-id',
          mediaSourceId: 'recorded-version',
        );
        await f.history.beginSession(
          source: source,
          work: source.item,
          libraryId: 'view-movies',
        );
      });
      final host = _RecordingHost();
      final app = RillightApp(
        auth: f.auth,
        playerBindings: PlayerBindings(
          runtime: f.runtime,
          windowHost: host,
          settingsStore: MemoryPlayerSettingsStore(),
          snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        ),
      );
      f.a.items.first.playbackPosition = Duration(
        microseconds: 150000000 ~/ 10,
      );
      f.a.items.first.productionYear = 2010;
      f.b.items.first.playbackPosition = Duration(
        microseconds: 350000000 ~/ 10,
      );
      f.b.items.first.productionYear = 2011;
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      expect(find.text('来源 A'), findsWidgets);
      expect(find.text('来源 B'), findsWidgets);
      expect(
        tester
            .widgetList<PosterCard>(find.byType(PosterCard))
            .map((card) => card.item.productionYear),
        containsAll([2010, 2011]),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              (widget is ui.AppTooltip && widget.message == '从本机记录的实际来源继续') ||
              (widget is AppTooltip && widget.message == '从本机记录的实际来源继续'),
        ),
        findsNothing,
      );
      final row = find.byKey(ValueKey('aggregation-server-${f.bId}'));
      final card = find.descendant(of: row, matching: find.byType(PosterCard));
      await tester.ensureVisible(card.first);
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: tester.getCenter(card.first));
      addTearDown(pointer.removePointer);
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byKey(PosterCard.playButtonKey('shared-id')),
        ),
      );
      await _settle(tester);
      expect(find.byType(ServerSelectionPage), findsNothing);
      expect(find.byType(ItemDetailPage), findsNothing);
      expect(host.current?.itemId, 'shared-id');
      expect(host.current?.source?.account.configuredServerId, f.bId);
      expect(f.auth.session!.server.id, f.aId);
      await host.close();
      final poster = find.descendant(of: row, matching: find.text('合成作品'));
      await tester.ensureVisible(poster);
      await tester.pump();
      await tester.tap(poster);
      await tester.pump();
      expect(find.byType(ServerSelectionPage), findsNothing);
      expect(find.byKey(const Key('server-search')), findsNothing);
      await _settle(tester);
      expect(
        DetailSourceScope.maybeOf(tester.element(find.byType(ItemDetailPage)))!
            .source
            .account
            .configuredServerId,
        f.bId,
      );
      expect(host.current, isNull);
      expect(f.auth.session!.server.id, f.bId);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      host.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'remote-only resume with unknown times asks for an actual source rather than maximum progress',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.a.items.first.playbackPosition = Duration(
        microseconds: 150000000 ~/ 10,
      );
      f.a.items.first.productionYear = 1999;
      f.b.items.first.playbackPosition = Duration(
        microseconds: 350000000 ~/ 10,
      );
      f.b.items.first.productionYear = 2001;
      f.b.items.first.overview = 'B续播来源';
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      expect(
        tester
            .widgetList<PosterCard>(find.byType(PosterCard))
            .map((card) => card.item.productionYear),
        containsAll([1999, 2001]),
      );
      expect(find.textContaining('不取最大进度'), findsNothing);
      final poster = find.descendant(
        of: find.byKey(ValueKey('aggregation-server-${f.bId}')),
        matching: find.text('合成作品'),
      );
      await tester.ensureVisible(poster);
      await tester.pump();
      await tester.tap(poster);
      await _settle(tester);
      expect(find.text('B续播来源'), findsOneWidget);
      expect(
        DetailSourceScope.maybeOf(tester.element(find.byType(ItemDetailPage)))!
            .source
            .account
            .configuredServerId,
        f.bId,
      );
      expect(f.auth.session!.server.id, f.bId);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'same server route updates its library and cross-server route uses the new source',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      f.b.items.add(
        FakeEmbyItem(
          id: 'b-series',
          name: '乙服剧集',
          type: 'Series',
          parentId: 'view-tv',
        ),
      );
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go(
        '/server/${Uri.encodeComponent(f.bId)}/library/view-movies',
      );
      await _settle(tester);
      expect(
        tester.widget<ShelfGridPage>(find.byType(ShelfGridPage)).parentId,
        'view-movies',
      );
      app.router.go('/server/${Uri.encodeComponent(f.bId)}/library/view-tv');
      await _settle(tester);
      expect(
        tester.widget<ShelfGridPage>(find.byType(ShelfGridPage)).parentId,
        'view-tv',
      );
      expect(find.text('乙服剧集'), findsOneWidget);
      expect(f.auth.session!.server.id, f.bId);
      app.router.go(
        '/server/${Uri.encodeComponent(f.aId)}/library/view-movies',
      );
      await _settle(tester);
      final grid = find.byType(ShelfGridPage);
      expect(tester.widget<ShelfGridPage>(grid).parentId, 'view-movies');
      expect(
        DetailSourceScope.maybeOf(tester.element(grid))!
            .source
            .account
            .configuredServerId,
        f.aId,
      );
      expect(find.text('乙服剧集'), findsNothing);
      expect(f.auth.session!.server.id, f.aId);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'aggregation favorites more opens that server favorites and same route can return to resume',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      f.a.items.first.favorite = true;
      f.b.items.first.favorite = true;
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      await tester.tap(find.byKey(const Key('aggregation-segment-favorites')));
      await _settle(tester);
      final row = find.byKey(ValueKey('aggregation-server-${f.bId}'));
      final more = find.descendant(of: row, matching: find.text('更多'));
      await Scrollable.ensureVisible(tester.element(more), alignment: .5);
      await _settle(tester);
      final beforeB = f.b.requests.length;
      await tester.tap(more);
      await _settle(tester);
      expect(app.router.state.uri.queryParameters['section'], 'favorites');
      final grid = find.byType(ShelfGridPage);
      expect(tester.widget<ShelfGridPage>(grid).source, 'favorites');
      expect(
        DetailSourceScope.maybeOf(tester.element(grid))!
            .source
            .account
            .configuredServerId,
        f.bId,
      );
      expect(
        f.b.requests
            .skip(beforeB)
            .any((request) => request.contains('IsFavorite')),
        isTrue,
      );
      expect(f.auth.session!.server.id, f.bId);
      app.router.go('/server/${Uri.encodeComponent(f.bId)}/resume');
      await _settle(tester);
      expect(
        tester.widget<ShelfGridPage>(find.byType(ShelfGridPage)).source,
        'resume',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'ordinary library navigation stays in the selected server',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/library/view-movies');
      await _settle(tester);
      app.router.go('/library/view-tv');
      await _settle(tester);
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(find.byType(AggregationPage), findsNothing);
      expect(find.text('查找同源 · 1'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      'catalog and playback are available without participation setup ${environment.presentation.name}',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(() => _drive(tester, f.close()));
        tester.view.physicalSize = environment.isDesktop || environment.isTv
            ? const Size(1440, 900)
            : const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = FakeVideoBackend(
          duration: const Duration(seconds: 120),
        );
        final app = f.app(environment, backend: backend);
        await tester.pumpWidget(app);
        await _settle(tester);
        app.router.go('/library/view-movies');
        await _settle(tester);
        expect(find.byType(AggregationPage), findsNothing);
        expect(
          find.byType(
            environment.isDesktop
                ? LibraryPage
                : environment.isTv
                ? TvLibraryPage
                : MobileLibraryPage,
          ),
          findsOneWidget,
        );
        for (final source in ['resume', 'latest-movies', 'nextup']) {
          app.router.go('/shelf/$source');
          await _settle(tester);
          expect(find.byType(AggregationPage), findsNothing);
          expect(tester.takeException(), isNull);
        }
        app.router.go('/item/shared-id');
        await _settle(tester);
        expect(
          find.byType(
            environment.isDesktop
                ? ItemDetailPage
                : environment.isTv
                ? TvDetailPage
                : MobileDetailPage,
          ),
          findsOneWidget,
        );
        if (!environment.isDesktop) {
          app.router.push('/play/shared-id');
          await _settle(tester);
          expect(backend.openedUrl, isNotNull);
          expect(backend.isPlaying, isTrue);
        }
        expect(
          f.auth.sources.project().every(
            (s) => f.auth.serverAccess.allows(s.id),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        if (!environment.isDesktop) {
          app.router.pop();
          await _settle(tester);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'selected detail opens without configuring aggregation libraries',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/item/shared-id');
      await _settle(tester);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(
        f.a.requests.where(
          (r) => r.contains('/Users/user-alice/Items/shared-id'),
        ),
        isNotEmpty,
      );
      expect(
        f.auth.sources.project().every((s) => f.auth.serverAccess.allows(s.id)),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'comparison retains B scope while ordinary detail uses selected A',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.b.items.first.overview = 'B实际来源正文';
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      expect(find.text('B实际来源正文'), findsOneWidget);
      final origin = DetailSourceScope.maybeOf(
        tester.element(find.byType(ItemDetailPage)),
      );
      expect(origin!.source.account.configuredServerId, f.bId);
      expect(f.auth.session!.server.id, f.bId);
      await tester.runAsync(() => f.auth.switchTo(f.aId));
      app.router.go('/item/shared-id');
      await _settle(tester);
      expect(
        DetailSourceScope.maybeOf(tester.element(find.byType(ItemDetailPage))),
        isNull,
      );
      expect(find.text('B实际来源正文'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      '${environment.presentation.name} comparison verifies locked target privately and commits only chosen detail',
      (tester) async {
        isolateImageCache();
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : environment.isDesktop
            ? const Size(1024, 900)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = _Fixture();
        f.b.items = [_ComparisonMovie()];
        await tester.runAsync(f.open);
        addTearDown(() => _drive(tester, f.close()));
        await tester.runAsync(() async {
          await f.protect(f.aId, unlock: true);
          await f.auth.switchTo(f.aId);
          await f.protect(f.bId);
        });
        final backend = FakeVideoBackend();
        final app = f.app(environment, backend: backend);
        await tester.pumpWidget(app);
        await _settle(tester);
        await _openOwnedDetail(
          tester,
          f,
          app,
          serverId: f.aId,
          itemId: 'shared-id',
        );
        final detailType = environment.isDesktop
            ? ItemDetailPage
            : environment.isTv
            ? TvDetailPage
            : MobileDetailPage;
        final original = DetailSourceScope.maybeOf(
          tester.element(find.byType(detailType)),
        )!;
        f.b.requests.clear();
        Future<void> showComparison() async {
          // Each platform styles the in-content entry as its own action.
          final action = find.byKey(const Key('source-selection-open'));
          await tester.ensureVisible(action);
          await tester.tap(action);
          await _settle(tester);
        }

        Future<void> verifyTarget() async {
          final action = find.byKey(Key('source-selection-verify-${f.bId}'));
          await tester.ensureVisible(action);
          await tester.tap(action);
          await _settle(tester);
          expect(find.text('输入访问密码'), findsOneWidget);
          expect(find.text('输入这台服务器的本机密码，查看可选来源。'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const Key('server-unlock-submit')),
              matching: find.text('解锁'),
            ),
            findsOneWidget,
          );
          await _typeEntryPassword(tester, environment, '1234');
        }

        void expectOriginalAccess() {
          expect(f.auth.session!.server.id, f.aId);
          expect(original.permit.isValid, isTrue);
          expect(f.auth.serverAccess.allows(f.aId), isTrue);
          expect(f.auth.serverAccess.allows(f.bId), isFalse);
          expect(backend.openCount, 0);
        }

        await showComparison();
        expect(
          find.byKey(Key('source-selection-server-${f.bId}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('source-selection-item-${f.bId}-shared-id')),
          findsNothing,
        );
        expect(f.b.requests, isEmpty);
        await tester.tap(find.byKey(Key('source-selection-verify-${f.bId}')));
        await _settle(tester);
        await tester.tap(
          find.byKey(const Key('source-selection-verification-cancel')),
        );
        await _settle(tester);
        expectOriginalAccess();
        expect(f.b.requests, isEmpty);
        if (environment.isTv) {
          await tester.binding.handlePopRoute();
          await _settle(tester);
          expect(find.byKey(const Key('source-selection-title')), findsNothing);
          expectOriginalAccess();
          await showComparison();
        }
        await verifyTarget();
        expect(
          find.byKey(Key('source-selection-item-${f.bId}-shared-id')),
          findsOneWidget,
        );
        expectOriginalAccess();
        expect(find.textContaining('1080p'), findsOneWidget);
        expect(find.text('共 3 个版本'), findsNothing);
        expect(find.textContaining('音轨 1 条'), findsNothing);
        expect(find.textContaining('查找完成'), findsNothing);
        final visibleCopy = tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data ?? '')
            .join('\n');
        for (final internal in [
          'commonProvider',
          'providerConflict',
          'view-movies',
          'internal-version-',
          'Video:',
          'Audio:',
          'Subtitle:',
        ]) {
          expect(visibleCopy, isNot(contains(internal)));
        }
        final resolutionFilter = find.byKey(
          const Key('source-selection-filter-resolution'),
        );
        expect(resolutionFilter, findsOneWidget);
        expect(
          find.byKey(const Key('source-selection-filter-range')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('source-selection-filter-video')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('source-selection-filter-subtitle')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('source-selection-filter-audio')),
          findsNothing,
        );
        await tester.ensureVisible(resolutionFilter);
        await tester.tap(resolutionFilter);
        await _settle(tester);
        expect(
          find.byKey(const Key('app-menu-content')),
          findsOneWidget,
          reason: '筛选从按钮向下展开，不再套一层对话框',
        );
        expect(find.text('清晰度'), findsNothing);
        expect(
          find.byKey(const Key('source-selection-filter-option-1080p')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('source-selection-filter-option-4K')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('source-selection-filter-option-1080p')),
        );
        await _settle(tester);
        expect(find.byKey(const Key('app-menu-content')), findsNothing);
        expect(
          find.descendant(of: resolutionFilter, matching: find.text('1080p')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('source-selection-item-${f.bId}-shared-id')),
          findsOneWidget,
        );
        final clearFilters = find.byKey(
          const Key('source-selection-filter-clear'),
        );
        await tester.ensureVisible(clearFilters);
        await tester.tap(clearFilters);
        await _settle(tester);
        expect(clearFilters, findsNothing);
        expect(
          find.descendant(of: resolutionFilter, matching: find.text('不限')),
          findsOneWidget,
        );
        final titlePosition = tester.getTopLeft(
          find.byKey(const Key('source-selection-title')),
        );
        final closePosition = tester.getTopLeft(
          find.byKey(const Key('source-selection-close')),
        );
        await tester.drag(
          find.byKey(const Key('source-selection-content')),
          const Offset(0, -300),
        );
        await _settle(tester);
        expect(
          tester.getTopLeft(find.byKey(const Key('source-selection-title'))),
          titlePosition,
        );
        expect(
          tester.getTopLeft(find.byKey(const Key('source-selection-close'))),
          closePosition,
        );
        expect(
          find.byKey(const Key('source-selection-close')).hitTestable(),
          findsOneWidget,
        );
        // Another query cannot consume the comparison's private entry ticket.
        final global = AggregationQueryController(
          registry: f.auth.sources,
          history: f.history,
        );
        await _drive(tester, global.start(QueryScope()));
        expect(
          global.items.any(
            (item) => item.reference.account.configuredServerId == f.bId,
          ),
          isFalse,
        );
        global.dispose();
        final close = find.byKey(const Key('source-selection-close'));
        if (environment.isTv) {
          bool closeHasFocus() {
            var found = false;
            FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
              element,
            ) {
              if (element.widget.key == const Key('source-selection-close')) {
                found = true;
              }
              return !found;
            });
            return found;
          }

          for (var step = 0; step < 16 && !closeHasFocus(); step++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await _settle(tester);
          }
          expect(
            closeHasFocus(),
            isTrue,
            reason: 'The remote must reach the close button without a pointer',
          );
          expect(
            (Offset.zero & tester.view.physicalSize).contains(
              tester.getCenter(close),
            ),
            isTrue,
            reason: 'Directional focus must scroll the close action into view',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.ensureVisible(close);
          await tester.tap(close);
        }
        await _settle(tester);
        expectOriginalAccess();
        await showComparison();
        // Closing discarded the previous candidate authorization.
        expect(
          find.byKey(Key('source-selection-server-${f.bId}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('source-selection-item-${f.bId}-shared-id')),
          findsNothing,
        );
        await verifyTarget();
        expectOriginalAccess();
        final target = find.byKey(
          Key('source-selection-item-${f.bId}-shared-id'),
        );
        await tester.ensureVisible(target);
        await tester.tap(target);
        await _settle(tester);
        expect(f.auth.session!.server.id, f.bId);
        expect(f.auth.serverAccess.allows(f.aId), isFalse);
        expect(original.permit.isValid, isFalse);
        expect(f.auth.serverAccess.allows(f.bId), isTrue);
        expect(find.byKey(const Key('source-selection-title')), findsNothing);
        expect(find.byType(detailType), findsOneWidget);
        final destination = DetailSourceScope.maybeOf(
          tester.element(find.byType(detailType)),
        )!;
        expect(destination.source.account.configuredServerId, f.bId);
        expect(destination.permit.isValid, isTrue);
        expect(app.router.state.uri.path, '/item/shared-id');
        expect(backend.openCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'comparison target proof failure preserves original protected server and cancels target entry',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      await tester.runAsync(() async {
        await f.protect(f.aId, unlock: true);
        await f.auth.switchTo(f.aId);
        await f.protect(f.bId);
      });
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.aId,
        itemId: 'shared-id',
      );
      final original = DetailSourceScope.maybeOf(
        tester.element(find.byType(ItemDetailPage)),
      )!;
      await tester.tap(find.byKey(const Key('source-selection-open')));
      await _settle(tester);
      await tester.tap(find.byKey(Key('source-selection-verify-${f.bId}')));
      await _settle(tester);
      await _typeEntryPassword(tester, PresentationEnvironment.desktop, '1234');
      final target = find.byKey(
        Key('source-selection-item-${f.bId}-shared-id'),
      );
      expect(target, findsOneWidget);
      f.b.itemStatus = 503;
      await tester.ensureVisible(target);
      await tester.tap(target);
      await _settle(tester);
      expect(f.auth.session!.server.id, f.aId);
      expect(original.permit.isValid, isTrue);
      expect(f.auth.serverAccess.allows(f.aId), isTrue);
      expect(f.auth.serverAccess.allows(f.bId), isFalse);
      expect(
        find.byKey(Key('source-selection-server-${f.bId}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('source-selection-item-${f.bId}-shared-id')),
        findsNothing,
      );
      expect(app.router.state.uri.path, '/item/shared-id');
      await tester.tap(find.byKey(const Key('source-selection-close')));
      await _settle(tester);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      app.router.dispose();
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    for (final protected in [false, true]) {
      cases.testWidgets(
        '${environment.presentation.name} ${protected ? 'protected' : 'unprotected'} ordinary detail exposes manual source selection without synthetic route extras',
        (tester) async {
          isolateImageCache();
          tester.view.physicalSize = environment.isDesktop || environment.isTv
              ? const Size(1280, 900)
              : const Size(412, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final f = _Fixture();
          await tester.runAsync(f.open);
          if (protected) {
            await tester.runAsync(() => f.protect(f.aId, unlock: true));
          }
          addTearDown(() => _drive(tester, f.close()));
          final app = f.app(environment);
          await tester.pumpWidget(app);
          await _settle(tester);
          app.router.go('/item/shared-id');
          await _settle(tester);
          final entry = find.byKey(const Key('source-selection-open'));
          expect(entry, findsOneWidget);
          // The entry is part of the detail content, not an overlay stacked
          // above the page: it scrolls with the page and has no Positioned
          // ancestor between it and the detail page.
          final page = environment.isTv
              ? find.byType(TvDetailPage)
              : environment.isDesktop
              ? find.byType(ItemDetailPage)
              : find.byType(MobileDetailPage);
          expect(find.descendant(of: page, matching: entry), findsOneWidget);
          if (environment.isDesktop || environment.isTv) {
            expect(
              find.ancestor(of: entry, matching: find.byType(Scrollable)),
              findsWidgets,
            );
            expect(
              find.ancestor(of: entry, matching: find.byType(Positioned)),
              findsNothing,
            );
          } else {
            // 手机端「其他来源」是作品级操作，固定在详情页自己的顶栏右上角
            // （页面 chrome，不是叠在内容上的悬浮钮）。
            expect(
              find.ancestor(of: entry, matching: find.byType(PhoneTopBar)),
              findsOneWidget,
            );
          }
          if (environment.isTv) {
            // D-pad reaches the entry from the header play action。入口是
            // 图标钮（无 Text 子节点），以「主焦点落在入口子树内」判定。
            final entryElement = tester.element(entry);
            bool entryFocused() {
              final context = tester.binding.focusManager.primaryFocus?.context;
              if (context is! Element) return false;
              var inside = false;
              context.visitAncestorElements((element) {
                if (identical(element, entryElement)) {
                  inside = true;
                  return false;
                }
                return true;
              });
              return inside;
            }

            for (var i = 0; i < 6 && !entryFocused(); i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
              await tester.pump();
            }
            expect(entryFocused(), isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
          } else {
            await tester.ensureVisible(entry);
            await tester.tap(entry);
          }
          await _settle(tester);
          expect(
            find.byKey(Key('source-selection-item-${f.bId}-shared-id')),
            findsOneWidget,
          );
          expect(
            find.byKey(Key('source-selection-item-${f.aId}-shared-id')),
            findsNothing,
          );
          expect(f.auth.session!.server.id, f.aId);
          expect(find.text('查找同源'), findsNothing);
          expect(find.text('全部服务器'), findsNothing);
          await tester.binding.handlePopRoute();
          await _settle(tester);
          expect(find.byKey(const Key('source-selection-title')), findsNothing);
          expect(
            find.byKey(const Key('source-selection-open')),
            findsOneWidget,
          );
          expect(f.auth.session!.server.id, f.aId);
          // Aggregation/search entries keep showComparison=0: the same
          // detail page renders without the in-content entry.
          app.router.go('/item/shared-id?showComparison=0');
          await _settle(tester);
          expect(page, findsOneWidget);
          expect(find.byKey(const Key('source-selection-open')), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          app.router.dispose();
        },
        tags: ['integration'],
      );
    }
    for (final change in ['lock', 'switch']) {
      cases.testWidgets(
        '${environment.presentation.name} protected ordinary source resolution rejects late overlay after $change',
        (tester) async {
          isolateImageCache();
          tester.view.physicalSize = environment.isDesktop || environment.isTv
              ? const Size(1280, 900)
              : const Size(412, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final f = _Fixture();
          final adapter = _BlockingCatalogAdapter([f.a, f.b]);
          await tester.runAsync(() => f.open(sourceAdapter: adapter));
          addTearDown(() => _drive(tester, f.close()));
          addTearDown(() {
            if (!adapter.gate.isCompleted) adapter.gate.complete();
          });
          await tester.runAsync(() => f.protect(f.aId, unlock: true));
          final app = f.app(environment);
          await tester.pumpWidget(app);
          await _settle(tester);
          app.router.go('/item/shared-id');
          await _settle(tester);
          adapter.blockedAuthority = 'a.test';
          adapter.blockedSuffix = '/Items/shared-id';
          await tester.tap(find.byKey(const Key('source-selection-open')));
          await _settle(tester);
          expect(adapter.entered, isTrue);
          if (change == 'lock') {
            await tester.runAsync(() => f.auth.serverAccess.lock(f.aId));
          } else {
            await tester.runAsync(() => f.auth.switchTo(f.bId));
          }
          await _settle(tester);
          adapter.gate.complete();
          await _settle(tester);
          expect(find.byKey(const Key('source-selection-title')), findsNothing);
          expect(
            find.byKey(Key('source-selection-item-${f.bId}-shared-id')),
            findsNothing,
          );
          expect(f.auth.serverAccess.allows(f.aId), isFalse);
          if (change == 'switch') expect(f.auth.session!.server.id, f.bId);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          app.router.dispose();
        },
        tags: ['integration'],
      );
    }
    cases.testWidgets(
      '${environment.presentation.name} sourced shelf preserves genre and child queries without legacy aggregation or current-server fallback',
      (tester) async {
        isolateImageCache();
        tester.view.physicalSize = environment.isDesktop || environment.isTv
            ? const Size(1280, 900)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(() => _drive(tester, f.close()));
        f.b.items.addAll([
          FakeEmbyItem(
            id: 'b-season',
            name: 'B 第二季',
            type: 'Season',
            parentId: 'view-movies',
          ),
          FakeEmbyItem(
            id: 'b-episode',
            name: 'B 专属第二集',
            type: 'Episode',
            parentId: 'b-season',
            indexNumber: 2,
            parentIndexNumber: 2,
          ),
          FakeEmbyItem(
            id: 'b-album',
            name: 'B 相册',
            type: 'PhotoAlbum',
            parentId: 'view-movies',
          ),
          FakeEmbyItem(
            id: 'b-photo',
            name: 'B 专属剧照',
            type: 'Photo',
            parentId: 'b-album',
          ),
        ]);
        f.b.items.first.genres = ['冒险'];
        await tester.runAsync(() => f.protect(f.bId, unlock: true));
        final app = f.app(environment);
        await tester.pumpWidget(app);
        await _settle(tester);
        final account = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(f.bId, libraryId: 'view-movies'),
        ))!;
        final command = PlayerHostOpenItemCommand(
          itemId: 'shared-id',
          source: SourceReference(account: account, itemId: 'shared-id'),
          libraryId: 'view-movies',
          accessGeneration: f.auth.serverAccess.generation(f.bId),
        );
        for (final spec in [
          ('view-movies', 'Movie', '冒险', '合成作品'),
          ('b-season', 'Episode', '', 'B 专属第二集'),
          ('b-album', 'Photo', '', 'B 专属剧照'),
        ]) {
          f.a.requests.clear();
          f.b.requests.clear();
          app.router.go(
            Uri(
              path: '/shelf/items',
              queryParameters: {
                'parentId': spec.$1,
                'includeItemTypes': spec.$2,
                'title': '来源 B 列表',
                if (spec.$3.isNotEmpty) 'genre': spec.$3,
              },
            ).toString(),
            extra: command,
          );
          await _settle(tester);
          expect(find.textContaining(spec.$4), findsWidgets);
          expect(find.text('全部服务器'), findsNothing);
          expect(find.textContaining('未选择可参与'), findsNothing);
          expect(find.byType(SourceSelectionAction), findsNothing);
          final requests = f.b.requests
              .map(
                (request) =>
                    Uri.parse(request.substring(request.indexOf(' ') + 1)),
              )
              .where(
                (uri) =>
                    uri.queryParameters['ParentId'] == spec.$1 &&
                    uri.queryParameters['IncludeItemTypes'] == spec.$2,
              )
              .toList();
          expect(requests, isNotEmpty);
          if (spec.$3.isNotEmpty) {
            expect(
              requests.any((uri) => uri.queryParameters['Genres'] == spec.$3),
              isTrue,
            );
          }
          expect(
            f.a.requests.where(
              (r) =>
                  r.contains('ParentId=${spec.$1}') &&
                  r.contains('IncludeItemTypes=${spec.$2}'),
            ),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.runAsync(() => f.auth.serverAccess.lock(f.bId));
        await _settle(tester);
        expect(find.text('B 专属剧照'), findsNothing);
        f.a.requests.clear();
        f.b.requests.clear();
        app.router.go(
          '/shelf/items?parentId=b-album&includeItemTypes=Photo',
          extra: command,
        );
        await _settle(tester);
        expect(find.text('B 专属剧照'), findsNothing);
        expect(
          f.a.requests.where((r) => r.contains('ParentId=b-album')),
          isEmpty,
        );
        expect(
          f.b.requests.where((r) => r.contains('ParentId=b-album')),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'leaving ordinary detail cancels a pending source selector without a late overlay',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      final adapter = _BlockingCatalogAdapter([f.a, f.b]);
      await tester.runAsync(() => f.open(sourceAdapter: adapter));
      addTearDown(() => _drive(tester, f.close()));
      addTearDown(() {
        if (!adapter.gate.isCompleted) adapter.gate.complete();
      });
      f.a.items.add(
        FakeEmbyItem(
          id: 'other',
          name: '另一部影片',
          type: 'Movie',
          parentId: 'view-movies',
        ),
      );
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/item/shared-id');
      await _settle(tester);
      adapter.blockedAuthority = 'a.test';
      adapter.blockedSuffix = '/Items/shared-id';
      await tester.tap(find.byKey(const Key('source-selection-open')));
      await _settle(tester);
      expect(adapter.entered, isTrue);
      app.router.push('/item/other');
      await _settle(tester);
      adapter.gate.complete();
      await _settle(tester);
      expect(app.router.state.uri.path, '/item/other');
      expect(find.byKey(const Key('source-selection-title')), findsNothing);
      expect(find.text('另一部影片'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  for (final failure in [false, true]) {
    cases.testWidgets(
      'source selection stops spinning and exposes ${failure ? 'retry' : 'pagination'} with no matches',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(() => _drive(tester, f.close()));
        f.b.items = [
          for (var i = 0; i < 60; i++)
            FakeEmbyItem(
              id: 'other-$i',
              name: '合成作品 extra $i',
              type: 'Movie',
              parentId: 'view-movies',
            ),
        ];
        if (failure) {
          f.b.itemsStatus = 503;
          f.b.searchStatus = 503;
        }
        final app = f.app(PresentationEnvironment.desktop);
        await tester.pumpWidget(app);
        await _settle(tester);
        await _openOwnedDetail(
          tester,
          f,
          app,
          serverId: f.aId,
          itemId: 'shared-id',
        );
        await tester.tap(find.byKey(const Key('source-selection-open')));
        await _settle(tester);
        final dialog = find.byType(AppModalFrame);
        expect(dialog, findsOneWidget);
        expect(
          find.descendant(
            of: dialog,
            matching: find.byType(CupertinoActivityIndicator),
          ),
          findsNothing,
        );
        final action = find.widgetWithText(
          AppButton,
          failure ? '部分来源加载失败，重试' : '继续查找',
        );
        expect(action, findsOneWidget);
        if (failure) {
          f.b.itemsStatus = null;
          f.b.searchStatus = null;
        }
        await tester.tap(action);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('source-selection-close')));
        await _settle(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'source comparison distinguishes title candidate and unknown metadata without confirmed resume',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.b.items = [
        FakeEmbyItem(
          id: 'candidate',
          name: '合成作品',
          type: 'Movie',
          parentId: 'view-movies',
        ),
      ];
      f.b.items.add(_ConflictMovie());
      f.a.items.add(
        FakeEmbyItem(
          id: 'same-server-copy',
          name: '合成作品',
          type: 'Movie',
          parentId: 'view-movies',
        ),
      );
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.aId,
        itemId: 'shared-id',
      );
      await tester.tap(find.byKey(const Key('source-selection-open')));
      await _settle(tester);
      expect(
        find.byKey(Key('source-selection-item-${f.bId}-candidate')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('source-selection-item-${f.bId}-conflict')),
        findsNothing,
      );
      expect(
        find.byKey(Key('source-selection-item-${f.aId}-same-server-copy')),
        findsNothing,
      );
      expect(find.textContaining('请核对影片详情'), findsOneWidget);
      expect(find.text('已确认是同一作品'), findsNothing);
      expect(find.textContaining('音轨'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byKey(const Key('source-selection-title')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'concrete episode comparison renders missing target separately from failed query',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.a.items = [
        _Series(),
        FakeEmbyItem(
          id: 'episode',
          name: '合成剧集第一集',
          type: 'Episode',
          parentId: 'series',
          seriesId: 'series',
          indexNumber: 1,
          parentIndexNumber: 1,
        ),
      ];
      f.b.items = [_Series()];
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      final account = await tester.runAsync(
        () => f.auth.sources.acquireAccount(f.aId, libraryId: 'view-tv'),
      );
      app.router.go(
        '/item/episode',
        extra: PlayerHostOpenItemCommand(
          itemId: 'episode',
          source: SourceReference(account: account!, itemId: 'episode'),
          libraryId: 'view-tv',
          accessGeneration: f.auth.sources
              .permit(account, libraryId: 'view-tv')
              .accessGeneration,
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('source-selection-open')));
      await _settle(tester);
      expect(find.text('查找此集'), findsNothing);
      expect(find.text('已核对，按季与集对应'), findsNothing);
      expect(find.text('这台服务器上没有这一集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'protected server keeps its aggregation row while lock removes its content and image access',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      await tester.runAsync(() => f.protect(f.bId, unlock: true));
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      await tester.tap(find.byKey(const Key('aggregation-segment-libraries')));
      await _settle(tester);
      final row = find.byKey(ValueKey('aggregation-server-${f.bId}'));
      expect(row, findsOneWidget);
      final image = find
          .descendant(of: row, matching: find.byType(MediaImage))
          .first;
      final policy = DetailSourceScope.imagePolicyOf(tester.element(image))!;
      expect(policy.allowsDisk, isTrue);
      expect(policy.permit.account.configuredServerId, f.bId);
      expect(policy.isValid, isTrue);
      await tester.runAsync(() => f.auth.serverAccess.lock(f.bId));
      await _settle(tester);
      expect(find.byType(AggregationPage), findsOneWidget);
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('来源 B')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('已锁定')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.byType(MediaImage)),
        findsNothing,
      );
      expect(policy.isValid, isFalse);
      expect(
        find.byKey(ValueKey('aggregation-server-${f.aId}')),
        findsOneWidget,
      );
      expect(f.auth.session!.server.id, f.aId);
      final requestsWhileLocked = f.b.requests.length;
      await _settle(tester);
      expect(
        f.b.requests.length,
        requestsWhileLocked,
        reason: 'A locked aggregation row must not fetch content or images',
      );
      await tester.tap(find.descendant(of: row, matching: find.text('进入服务器')));
      await _settle(tester);
      expect(find.byKey(const Key('server-unlock-password')), findsOneWidget);
      expect(find.byType(ServerSelectionPage), findsNothing);
      expect(find.byKey(const Key('server-search')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('server-unlock-password')),
        '1234',
      );
      await tester.tap(find.byKey(const Key('server-unlock-submit')));
      await _settle(tester);
      expect(f.auth.session!.server.id, f.bId);
      expect(f.auth.serverAccess.allows(f.bId), isTrue);
      expect(
        find.descendant(of: row, matching: find.byType(MediaImage)),
        findsWidgets,
      );
      app.router.go('/library/view-movies');
      await _settle(tester);
      expect(find.byType(LibraryPage), findsOneWidget);
      app.router.go('/aggregation');
      await _settle(tester);
      expect(f.auth.serverAccess.allows(f.bId), isTrue);
      expect(find.byKey(const Key('server-unlock-password')), findsNothing);
      await tester.runAsync(() => f.auth.switchTo(f.aId));
      await _settle(tester);
      expect(f.auth.serverAccess.allows(f.bId), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'lock clears a protected detail and comparison overlay plus deep route extras/history',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      await tester.runAsync(() async {
        await f.auth.sources.rename(f.bId, '私密来源名');
        await f.protect(f.bId, unlock: true);
      });
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      await tester.tap(find.byKey(const Key('source-selection-open')));
      await _settle(tester);
      expect(find.byKey(const Key('source-selection-title')), findsOneWidget);
      await tester.runAsync(() => f.auth.serverAccess.lock(f.bId));
      await _settle(tester);
      expect(find.byKey(const Key('source-selection-title')), findsNothing);
      expect(find.byType(ItemDetailPage), findsNothing);
      expect(
        app.router.routeInformationProvider.value.uri.path,
        '/aggregation',
      );
      expect(app.router.canPop(), isFalse);
      expect(app.router.routerDelegate.currentConfiguration.extra, isNull);
      expect(find.byType(ItemDetailPage), findsNothing);
      expect(find.textContaining('私密区域已锁定'), findsNothing);
      // Both navigator history and the desktop shell's forward extras must
      // be gone, not merely the comparison dialog or its visible pixels.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await _settle(tester);
      expect(
        app.router.routeInformationProvider.value.uri.path,
        '/aggregation',
      );
      await tester.runAsync(() => f.auth.serverAccess.unlock(f.bId, '1234'));
      await _settle(tester);
      expect(find.byType(ItemDetailPage), findsNothing);
      expect(find.byType(ItemDetailPage), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      '${environment.presentation.name} server lock during stalled preflight and rejects late receipt',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        f.b.items.single.extraSources = const [
          FakeMediaSource(id: 'private-alternate', name: '私密替代版本'),
        ];
        final adapter = _BlockingCatalogAdapter([f.a, f.b]);
        await tester.runAsync(() => f.open(sourceAdapter: adapter));
        addTearDown(() async => _finishRevocation(tester, f.close()));
        addTearDown(() {
          if (!adapter.gate.isCompleted) adapter.gate.complete();
        });
        await tester.runAsync(() async {
          await f.protect(f.bId, unlock: true);
        });
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final b = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(f.bId, libraryId: 'view-movies'),
        ))!;
        final backend = FakeVideoBackend(
          duration: const Duration(seconds: 120),
        );
        final app = f.app(environment, backend: backend);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          app.router.dispose();
        });
        await tester.pumpWidget(app);
        await _settle(tester);
        unawaited(
          app.router.push(
            '/play/shared-id',
            extra: PlayerOpenRequest(
              itemId: 'shared-id',
              source: SourceReference(account: b, itemId: 'shared-id'),
              libraryId: 'view-movies',
              accessGeneration: f.auth.sources.permit(b).accessGeneration,
            ),
          ),
        );
        await _settle(tester);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
        await _settle(tester);
        expect(
          f.history.records().single.source.account.configuredServerId,
          f.bId,
        );
        if (environment.isTv) {
          // Startup pumps longer than the OSD hide delay. Reveal controls
          // before asserting the line button, same as the TV control tests.
          final tv = tester.state<TvPlayerPageState>(find.byType(TvPlayerPage));
          if (!tv.controller!.controlsVisible) {
            tv.controller!.onUserActivity();
            await tester.pump();
          }
          expect(
            find.byKey(const Key('player-playback-lines')),
            findsOneWidget,
          );
        }
        expect(find.byKey(const Key('player-lock-private')), findsNothing);
        expect(find.text('手动切换'), findsNothing);
        final c = environment.isTv
            ? tester
                  .state<TvPlayerPageState>(find.byType(TvPlayerPage))
                  .controller!
            : tester
                  .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
                  .controller!;
        adapter.blockedAuthority = f.b.baseUrl.authority;
        adapter.blockedSuffix = '/PlaybackInfo';
        final switching = c.switchMediaSource('private-alternate');
        for (var frame = 0; frame < 40 && !adapter.entered; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(adapter.entered, isTrue);
        expect(adapter.gate.isCompleted, isFalse);
        unawaited(c.lockCurrentServer());
        for (
          var frame = 0;
          frame < 100 && f.auth.serverAccess.allows(f.bId);
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(f.auth.serverAccess.allows(f.bId), isFalse);
        expect(
          adapter.gate.isCompleted,
          isFalse,
          reason: 'Lock completed independently of stalled source IO',
        );
        expect(backend.isPlaying, isFalse);
        // Revocation removes the redacted imperative dialog on the next frame.
        await _settle(tester);
        expect(find.byType(PlaybackLineMenu), findsNothing);
        expect(adapter.gate.isCompleted, isFalse);
        adapter.gate.complete();
        await _drive(tester, switching);
        await _settle(tester);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 29));
        await _settle(tester);
        expect(f.history.records(), isEmpty);
        expect(find.byType(DetailSourceScope), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
      },
      tags: ['integration'],
    );
  }

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      '${environment.presentation.name} actual episode mapping menu switches only concrete target version after viewing receipt',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        f.a.items = [
          _Series(),
          FakeEmbyItem(
            id: 'season-a',
            name: '第1季',
            type: 'Season',
            parentId: 'series',
            seriesId: 'series',
            indexNumber: 1,
          ),
        ];
        f.b.items = [
          _Series(),
          FakeEmbyItem(
            id: 'season-b',
            name: '第1季',
            type: 'Season',
            parentId: 'series',
            seriesId: 'series',
            indexNumber: 1,
          ),
        ];
        f.a.setEpisodes('series', [
          const FakeEpisode(
            id: 'episode-a-2',
            name: 'A 第2集',
            seasonId: 'season-a',
            indexNumber: 2,
            parentIndexNumber: 1,
            runtime: Duration(microseconds: (1200000000) ~/ 10),
          ),
        ]);
        f.b.setEpisodes('series', [
          const FakeEpisode(
            id: 'episode-b-2',
            name: 'B 第2集',
            seasonId: 'season-b',
            indexNumber: 2,
            parentIndexNumber: 1,
            runtime: Duration(microseconds: (1200000000) ~/ 10),
          ),
        ]);
        await tester.runAsync(f.open);
        addTearDown(() async => _finishRevocation(tester, f.close()));
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final a = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(f.aId, libraryId: 'view-tv'),
        ))!;
        final backend = FakeVideoBackend(
          duration: const Duration(seconds: 120),
        );
        final app = f.app(environment, backend: backend);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          app.router.dispose();
        });
        await tester.pumpWidget(app);
        await _settle(tester);
        unawaited(
          app.router.push(
            '/play/episode-a-2',
            extra: PlayerOpenRequest(
              itemId: 'episode-a-2',
              source: SourceReference(account: a, itemId: 'episode-a-2'),
              libraryId: 'view-tv',
              accessGeneration: f.auth.sources.permit(a).accessGeneration,
            ),
          ),
        );
        await _settle(tester);
        final c = environment.isTv
            ? tester
                  .state<TvPlayerPageState>(find.byType(TvPlayerPage))
                  .controller!
            : tester
                  .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
                  .controller!;
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
        await _settle(tester);
        expect(find.text('手动切换'), findsNothing);
        expect(find.byType(PlaybackLineMenu), findsNothing);
        await _drive(tester, _switchMappedEpisode(c, f.bId));
        await _settle(tester);
        expect(c.origin!.source.itemId, 'episode-b-2');
        expect(c.origin!.source.account.configuredServerId, f.bId);
        expect(
          f.history.records().every((r) => r.source.itemId != 'episode-b-2'),
          isTrue,
        );
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 11));
        await _settle(tester);
        expect(c.activeMediaSourceId, 'episode-b-2');
        final receipt = f.history.records().first;
        expect(receipt.source.itemId, 'episode-b-2');
        expect(receipt.source.mediaSourceId, 'episode-b-2');
        expect(receipt.source.account.configuredServerId, f.bId);
        expect(receipt.work.itemId, 'series');
        expect(receipt.timeline.episode, 2);
        expect(receipt.positionTicks, 110000000);
        // Retire while the test can still advance fake timers and real IO;
        // automatic post-body unmount is too late for player close receipts.
        await _finishRevocation(tester, c.close());
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    cases.testWidgets(
      '${environment.presentation.name} covered B detail revocation preserves actual A player and source-owned reports',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        await tester.runAsync(() async {
          await f.auth.switchTo(f.bId);
        });
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final a = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(f.aId, libraryId: 'view-movies'),
        ))!;
        final b = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(f.bId, libraryId: 'view-movies'),
        ))!;
        final backend = FakeVideoBackend(
          duration: const Duration(seconds: 120),
        );
        final app = f.app(environment, backend: backend);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          app.router.dispose();
          var closed = false;
          unawaited(f.close().then((_) => closed = true));
          for (var frame = 0; frame < 60 && !closed; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(
            closed,
            isTrue,
            reason: 'History teardown exceeded six seconds',
          );
        });
        await tester.pumpWidget(app);
        await _settle(tester);
        unawaited(
          app.router.push(
            '/item/shared-id',
            extra: PlayerHostOpenItemCommand(
              itemId: 'shared-id',
              source: SourceReference(account: b, itemId: 'shared-id'),
              libraryId: 'view-movies',
              accessGeneration: f.auth.sources.permit(b).accessGeneration,
            ),
          ),
        );
        await _settle(tester);
        unawaited(
          app.router.push(
            '/play/shared-id',
            extra: PlayerOpenRequest(
              itemId: 'shared-id',
              source: SourceReference(account: a, itemId: 'shared-id'),
              libraryId: 'view-movies',
              accessGeneration: f.auth.sources.permit(a).accessGeneration,
            ),
          ),
        );
        await _settle(tester);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
        await _settle(tester);
        expect(backend.isPlaying, isTrue);
        expect(
          f.history.records().single.source.account.configuredServerId,
          f.aId,
        );
        late Future<void> moving;
        await tester.runAsync(() async {
          moving = f.protect(f.bId);
        });
        await _finishRevocation(tester, moving);
        await _settle(tester);
        expect(
          f.auth.isLoggedIn,
          isTrue,
          reason: 'Entering playback selected A; revoking covered B must preserve A',
        );
        expect(app.router.state.uri.path, '/play/shared-id');
        expect(backend.isPlaying, isTrue);
        expect(
          find.byType(environment.isTv ? TvPlayerPage : MobilePlayerPage),
          findsOneWidget,
        );
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 11));
        await _settle(tester);
        final record = f.history.records().single;
        expect(record.source.account.configuredServerId, f.aId);
        expect(record.positionTicks, 110000000);
        expect(
          f.b.requests.where((r) => r.contains('/Sessions/Playing')),
          isEmpty,
        );
        expect(
          f.a.requests.where((r) => r.contains('/Sessions/Playing')),
          isNotEmpty,
        );
        // The selected-auth exception must not authorize revoked actual A.
        late Future<void> revokingA;
        await tester.runAsync(() async {
          revokingA = f.protect(f.aId);
        });
        await _finishRevocation(tester, revokingA);
        await _settle(tester);
        expect(backend.isPlaying, isFalse);
        expect(app.router.state.uri.path.startsWith('/play/'), isFalse);
        expect(find.byType(MobilePlayerPage), findsNothing);
        expect(find.byType(TvPlayerPage), findsNothing);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 29));
        await _settle(tester);
        expect(f.history.records(), isEmpty);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'forged protected detail cannot switch selection or unlock its target during reauthorization',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      final b = (await tester.runAsync(
        () => f.auth.sources.ensureSession(f.bId),
      ))!.account;
      await tester.runAsync(() async {
        await f.protect(f.aId, unlock: true);
        await f.auth.switchTo(f.aId);
        await f.protect(f.bId);
      });
      final a = (await tester.runAsync(
        () => f.auth.sources.ensureSession(f.aId),
      ))!;
      final originalPermit = f.auth.sources.permit(a.account);
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      final before = f.b.requests.length;
      app.router.go(
        '/item/shared-id',
        extra: PlayerHostOpenItemCommand(
          itemId: 'shared-id',
          source: SourceReference(
            account: SourceAccount(
              configuredServerId: f.bId,
              verifiedServerId: 'forged-server',
              userId: b.userId,
            ),
            itemId: 'shared-id',
          ),
          libraryId: 'view-movies',
          accessGeneration: f.auth.serverAccess.generation(f.bId),
        ),
      );
      await _settle(tester);
      if (find
          .byKey(const Key('server-unlock-password'))
          .evaluate()
          .isNotEmpty) {
        await _typeEntryPassword(
          tester,
          PresentationEnvironment.desktop,
          '1234',
        );
      }
      expect(f.auth.session!.server.id, f.aId);
      expect(originalPermit.isValid, isTrue);
      expect(f.auth.serverAccess.allows(f.aId), isTrue);
      expect(f.auth.serverAccess.allows(f.bId), isFalse);
      expect(find.byType(DetailSourceScope), findsNothing);
      expect(
        f.b.requests.skip(before).where((r) => r.contains('/Items/shared-id')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'detail without a remembered server offers selection and preserves the original destination',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      await tester.runAsync(() async {
        await f.protect(f.bId);
        final persisted = await f.auth.sources.store.load();
        await f.auth.sources.store.save(
          ServerListSnapshot(servers: persisted.servers),
        );
        await f.reopen();
      });
      expect(f.auth.session, isNull);
      expect(f.auth.prefill, isNull);
      f.a.requests.clear();
      f.b.requests.clear();
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      const destination = '/item/shared-id?showComparison=0';
      app.router.go(destination);
      await _settle(tester);
      expect(find.byKey(const Key('detail-choose-server')), findsOneWidget);
      expect(find.text('合成作品'), findsNothing);
      await tester.tap(find.byKey(const Key('detail-choose-server')));
      await _settle(tester);
      await tester.tap(find.byKey(Key('server-enter-${f.bId}')));
      await _settle(tester);
      await _typeEntryPassword(tester, PresentationEnvironment.desktop, '1234');
      expect(app.router.state.uri.toString(), destination);
      expect(f.auth.session!.server.id, f.bId);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(f.b.requests.any((r) => r.contains('/Items/shared-id')), isTrue);
      expect(
        f.a.requests.where((r) => r.contains('/Items/shared-id')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      app.router.dispose();
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    for (final withExtra in [false, true]) {
      cases.testWidgets(
        '${environment.presentation.name} cold protected detail restores its destination after local verification extra=$withExtra',
        (tester) async {
          isolateImageCache();
          tester.view.physicalSize = environment.isTv
              ? const Size(1920, 1080)
              : environment.isDesktop
              ? const Size(1024, 900)
              : const Size(412, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final f = _Fixture();
          await tester.runAsync(f.open);
          addTearDown(() => _drive(tester, f.close()));
          await tester.runAsync(() async {
            await f.protect(f.bId, unlock: true);
            await f.auth.switchTo(f.bId);
          });
          final account = (await tester.runAsync(
            () =>
                f.auth.sources.acquireAccount(f.bId, libraryId: 'view-movies'),
          ))!;
          final oldGeneration = f.auth.serverAccess.generation(f.bId);
          final source = SourceReference(account: account, itemId: 'shared-id');
          const codec = SourceRouteExtraCodec();
          final oldDetail = codec.decode(
            jsonDecode(
              jsonEncode(
                codec.encode(
                  PlayerHostOpenItemCommand(
                    itemId: 'shared-id',
                    source: source,
                    libraryId: 'view-movies',
                    accessGeneration: oldGeneration,
                  ),
                ),
              ),
            ),
          );
          final oldPlayback = PlayerOpenRequest(
            itemId: 'shared-id',
            source: source,
            libraryId: 'view-movies',
            accessGeneration: oldGeneration,
          );
          final credentials = await tester.runAsync(
            () => f.auth.credentials.read(f.bId),
          );
          await tester.runAsync(f.reopen);
          expect(f.auth.session, isNull);
          expect(f.auth.serverAccess.allows(f.bId), isFalse);
          expect(
            (await tester.runAsync(() => f.auth.credentials.read(f.bId)))!
                .accessToken,
            credentials!.accessToken,
          );
          f.a.requests.clear();
          f.b.requests.clear();
          final backend = FakeVideoBackend();
          final app = f.app(environment, backend: backend);
          await tester.pumpWidget(app);
          await _settle(tester);
          expect(
            find.byKey(const Key('server-unlock-password')),
            findsOneWidget,
          );
          await tester.binding.handlePopRoute();
          await _settle(tester);
          const destination = '/item/shared-id?showComparison=0';
          app.router.go(destination, extra: withExtra ? oldDetail : null);
          await _settle(tester);
          expect(
            find.byKey(const Key('server-unlock-password')),
            findsOneWidget,
          );
          expect(
            f.b.requests.where((r) => r.contains('/Items/shared-id')),
            isEmpty,
          );
          expect(find.text('合成作品'), findsNothing);
          // Back cancels this attempt, not the original detail destination.
          for (
            var step = 0;
            step < 3 &&
                (find.byType(ServerSelectionPage).evaluate().isNotEmpty ||
                    find.byType(TvServerSelectionPage).evaluate().isNotEmpty ||
                    find
                        .byKey(const Key('server-unlock-password'))
                        .evaluate()
                        .isNotEmpty);
            step++
          ) {
            await tester.binding.handlePopRoute();
            await _settle(tester);
          }
          expect(app.router.state.uri.toString(), destination);
          expect(f.auth.session, isNull);
          expect(f.auth.serverAccess.allows(f.bId), isFalse);
          await tester.tap(find.text('进入服务器'));
          await _settle(tester);
          await _typeEntryPassword(tester, environment, 'wrong');
          expect(f.auth.session, isNull);
          expect(f.auth.serverAccess.allows(f.bId), isFalse);
          expect(
            f.b.requests.where((r) => r.contains('/Items/shared-id')),
            isEmpty,
          );
          // The form and access controller share the production wall clock.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2100)),
          );
          await _settle(tester);
          await _typeEntryPassword(tester, environment, '1234');
          expect(app.router.state.uri.toString(), destination);
          expect(f.auth.session!.server.id, f.bId);
          expect(f.auth.serverAccess.allows(f.bId), isTrue);
          expect(
            find.byType(
              environment.isDesktop
                  ? ItemDetailPage
                  : environment.isTv
                  ? TvDetailPage
                  : MobileDetailPage,
            ),
            findsOneWidget,
          );
          expect(find.text('合成作品'), findsWidgets);
          expect(
            f.b.requests.any((r) => r.contains('/Items/shared-id')),
            isTrue,
          );
          expect(
            f.a.requests.where((r) => r.contains('/Items/shared-id')),
            isEmpty,
          );
          expect(f.auth.serverAccess.generation(f.bId), isNot(oldGeneration));
          Object? rejected;
          await tester.runAsync(() async {
            try {
              await f.runtime.resolve(oldPlayback);
            } catch (error) {
              rejected = error;
            }
          });
          expect(rejected, isA<StateError>());
          expect(backend.openCount, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          app.router.dispose();
        },
        tags: ['integration'],
      );
    }
    cases.testWidgets(
      '${environment.presentation.name} old playback leases and forged accounts stay rejected after detail reauthorization',
      (tester) async {
        isolateImageCache();
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : environment.isDesktop
            ? const Size(1024, 900)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(() => _drive(tester, f.close()));
        await tester.runAsync(() async {
          await f.auth.sources.rename(f.bId, '私密不可恢复名');
          await f.protect(f.bId, unlock: true);
        });
        final account = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(f.bId, libraryId: 'view-movies'),
        ))!;
        final source = SourceReference(
          account: account,
          itemId: 'shared-id',
          mediaSourceId: 'private-version',
        );
        final generation = f.auth.sources.permit(account).accessGeneration;
        const codec = SourceRouteExtraCodec();
        Object? restore(Object? extra) =>
            codec.decode(jsonDecode(jsonEncode(codec.encode(extra))));
        final detail = restore(
          PlayerHostOpenItemCommand(
            itemId: 'shared-id',
            source: source.item,
            libraryId: 'view-movies',
            accessGeneration: generation,
          ),
        ) as PlayerHostOpenItemCommand;
        final request = restore(
          PlayerOpenRequest(
            itemId: 'shared-id',
            source: source,
            libraryId: 'view-movies',
            accessGeneration: generation,
            mediaSourceId: 'private-version',
            startPosition: Duration(microseconds: 70000000 ~/ 10),
          ),
        ) as PlayerOpenRequest;
        final backend = FakeVideoBackend();
        final app = f.app(environment, backend: backend);
        await tester.pumpWidget(app);
        await _settle(tester);
        app.router.go('/item/shared-id', extra: detail);
        await _settle(tester);
        expect(find.byType(SourceDetailGate), findsOneWidget);
        await tester.runAsync(() => f.auth.serverAccess.lock(f.bId));
        await _settle(tester);
        expect(app.router.canPop(), isFalse);
        expect(app.router.routerDelegate.currentConfiguration.extra, isNull);
        expect(find.byType(ItemDetailPage), findsNothing);
        await tester.runAsync(() => f.auth.serverAccess.unlock(f.bId, '1234'));
        await _settle(tester);
        final before = f.b.requests.length;
        Object? rejected;
        await tester.runAsync(() async {
          try {
            await f.runtime.resolve(request);
          } catch (error) {
            rejected = error;
          }
        });
        expect(rejected, isA<StateError>());
        expect(
          f.b.requests.length,
          before,
          reason:
              'Old generation must be rejected before private item dispatch',
        );
        app.router.go('/item/shared-id', extra: detail);
        await _settle(tester);
        final refreshed = tester.widget<DetailSourceScope>(
          find.byType(DetailSourceScope),
        );
        expect(refreshed.origin.source.account, account);
        expect(refreshed.origin.permit.isValid, isTrue);
        expect(refreshed.origin.permit.accessGeneration, isNot(generation));
        app.router.go('/play/shared-id', extra: request);
        await _settle(tester);
        expect(app.router.state.uri.path.startsWith('/play/'), isFalse);
        expect(backend.openCount, 0);
        final forged = restore(
          PlayerOpenRequest(
            itemId: 'shared-id',
            source: SourceReference(
              account: SourceAccount(
                configuredServerId: account.configuredServerId,
                verifiedServerId: 'forged-server',
                userId: account.userId,
              ),
              itemId: 'shared-id',
            ),
            libraryId: 'view-movies',
            accessGeneration: f.auth.serverAccess.generation(f.bId),
          ),
        ) as PlayerOpenRequest;
        final beforeForgedDetail = f.b.requests.length;
        app.router.go(
          '/item/shared-id',
          extra: PlayerHostOpenItemCommand(
            itemId: 'shared-id',
            source: forged.source,
            libraryId: 'view-movies',
            accessGeneration: forged.accessGeneration,
          ),
        );
        await _settle(tester);
        expect(find.byType(DetailSourceScope), findsNothing);
        expect(
          f.b.requests
              .skip(beforeForgedDetail)
              .where((request) => request.contains('/Items/shared-id')),
          isEmpty,
          reason: 'A detail destination can renew permission only for the same verified account',
        );
        app.router.go('/play/shared-id', extra: forged);
        await _settle(tester);
        expect(app.router.state.uri.path.startsWith('/play/'), isFalse);
        expect(backend.openCount, 0);
        await tester.binding.handlePopRoute();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await _settle(tester);
        // Back/forward may revisit a legitimate detail destination, but each
        // visible subtree must own a freshly authorized, matching account.
        for (final scope in tester.widgetList<DetailSourceScope>(
          find.byType(DetailSourceScope),
        )) {
          expect(scope.origin.source.account, account);
          expect(scope.origin.permit.isValid, isTrue);
          expect(
            scope.origin.permit.accessGeneration,
            f.auth.serverAccess.generation(f.bId),
          );
        }
        expect(find.byType(MobilePlayerPage), findsNothing);
        expect(find.byType(TvPlayerPage), findsNothing);
        expect(backend.openCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'revoked detail cleanup cannot erase a new different-source navigation in the same frame',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      await tester.runAsync(() async {
        await f.protect(f.bId, unlock: true);
      });
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(
        DetailSourceScope.maybeOf(tester.element(find.byType(ItemDetailPage)))!
            .source
            .account
            .configuredServerId,
        f.bId,
      );
      final account = (await tester.runAsync(
        () => f.auth.sources.acquireAccount(f.aId, libraryId: 'view-movies'),
      ))!;
      await tester.runAsync(() => f.auth.serverAccess.lock(f.bId));
      final command = PlayerHostOpenItemCommand(
        itemId: 'shared-id',
        source: SourceReference(account: account, itemId: 'shared-id'),
        libraryId: 'view-movies',
        accessGeneration: f.auth.sources.permit(account).accessGeneration,
      );
      // No frame between revocation and this explicit new navigation.
      app.router.go('/item/shared-id', extra: command);
      await _settle(tester);
      expect(app.router.state.uri.path, '/item/shared-id');
      expect(
        app.router.routerDelegate.currentConfiguration.extra,
        isA<PlayerHostOpenItemCommand>()
            .having((c) => c.source, 'source', command.source)
            .having(
              (c) => c.accessGeneration,
              'generation',
              command.accessGeneration,
            ),
      );
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(
        DetailSourceScope.maybeOf(tester.element(find.byType(ItemDetailPage)))!
            .source
            .account
            .configuredServerId,
        f.aId,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'desktop search keeps its draft while protected server content is revoked',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/search');
      await _settle(tester);
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.byType(ui.AppChoiceChip), findsNothing);
      expect(find.text('媒体库范围'), findsNothing);
      expect(find.byKey(const Key('aggregation-year')), findsNothing);
      expect(find.byKey(const Key('aggregation-genre')), findsNothing);
      await tester.enterText(find.byKey(const Key('aggregation-keyword')), ' ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      expect(
        f.a.requests.where((request) => request.contains('SearchTerm=')),
        isEmpty,
      );
      expect(
        f.b.requests.where((request) => request.contains('SearchTerm=')),
        isEmpty,
      );
      expect(find.text('输入片名后搜索'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        '合成',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      expect(find.text('来源 A'), findsWidgets);
      expect(find.text('来源 B'), findsWidgets);
      await tester.runAsync(() async {
        await f.auth.sources.rename(f.bId, '秘密名称地址');
        await f.protect(f.bId);
      });
      await _settle(tester);
      final lockedRow = find.byKey(ValueKey('aggregation-search-${f.bId}'));
      expect(
        find.descendant(of: lockedRow, matching: find.byType(MediaImage)),
        findsNothing,
      );
      expect(
        find.descendant(of: lockedRow, matching: find.byType(PosterCard)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('aggregation-search-${f.aId}')),
          matching: find.byType(PosterCard),
        ),
        findsWidgets,
      );
      final lockedRequests = f.b.requests.length;
      await _settle(tester);
      expect(f.b.requests.length, lockedRequests);
      expect(find.byKey(ValueKey('aggregation-source-${f.bId}')), findsNothing);
      expect(
        tester
            .widget<ui.AppTextField>(
              find.byKey(const Key('aggregation-keyword')),
            )
            .controller!
            .text,
        '合成',
      );
      expect(find.text('来源 A'), findsWidgets);
      expect(find.byType(ItemDetailPage), findsNothing);
      await tester.runAsync(() => f.auth.serverAccess.lock(f.bId));
      await _settle(tester);
      expect(find.text('来源 A'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets('desktop search keeps server filters hidden until opened', (
    tester,
  ) async {
    isolateImageCache();
    final f = _Fixture();
    await tester.runAsync(f.open);
    addTearDown(() => _drive(tester, f.close()));
    final app = f.app(PresentationEnvironment.desktop);
    await tester.pumpWidget(app);
    await _settle(tester);
    app.router.go('/search');
    await _settle(tester);
    expect(find.byType(ui.AppChoiceChip), findsNothing);
    await tester.tap(find.byKey(const Key('aggregation-search-filters')));
    await _settle(tester);
    expect(find.byType(ui.AppChoiceChip), findsNothing);
    expect(find.byType(OptionPill), findsWidgets);
    expect(
      find.byKey(ValueKey('aggregation-search-server-${f.aId}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('aggregation-search-server-${f.bId}')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(ValueKey('aggregation-search-server-${f.bId}')),
    );
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('aggregation-keyword')), '合成');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(
      f.a.requests.where((request) => request.contains('SearchTerm=')),
      isNotEmpty,
    );
    expect(
      f.b.requests.where((request) => request.contains('SearchTerm=')),
      isEmpty,
    );
    expect(find.byKey(ValueKey('aggregation-search-${f.aId}')), findsOneWidget);
    expect(find.byKey(ValueKey('aggregation-search-${f.bId}')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AggregationPage),
        matching: find.byType(MediaShelf),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(AggregationPage),
        matching: find.byType(PhonePosterCard),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('aggregation-search-filters')));
    await _settle(tester);
    expect(find.byType(ui.AppChoiceChip), findsNothing);
    expect(find.text('来源 A'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.router.dispose();
  }, tags: ['integration']);

  cases.testWidgets(
    'each server poster and its source selector retain the actual server',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.a.items.first
        ..playbackPosition = Duration(microseconds: (100) ~/ 10)
        ..primaryImageTag = 'a-poster';
      f.b.items.first
        ..playbackPosition = Duration(microseconds: (200) ~/ 10)
        ..primaryImageTag = 'b-poster';
      for (final view in f.a.views) {
        if (view.id == 'view-movies') view.primaryImageTag = 'a-library';
      }
      for (final view in f.b.views) {
        if (view.id == 'view-movies') view.primaryImageTag = 'b-library';
      }
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      expect(
        f.b.requests.any(
          (request) => request.contains('/Items/shared-id/Images/'),
        ),
        isFalse,
      );
      app.router.go('/aggregation');
      await _settle(tester);
      expect(_posterServer(tester, 'aggregation-server-${f.aId}'), f.aId);
      expect(_posterServer(tester, 'aggregation-server-${f.bId}'), f.bId);
      expect(
        f.a.requests.any(
          (request) => request.contains('/Items/shared-id/Images/'),
        ),
        isTrue,
      );
      expect(
        f.b.requests.any(
          (request) => request.contains('/Items/shared-id/Images/'),
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const Key('aggregation-segment-libraries')));
      await _settle(tester);
      expect(_posterServer(tester, 'aggregation-server-${f.bId}'), f.bId);
      expect(
        f.b.requests.any(
          (request) => request.contains('/Items/view-movies/Images/'),
        ),
        isTrue,
      );
      app.router.go(
        '/server/${Uri.encodeComponent(f.bId)}/library/view-movies',
      );
      await _settle(tester);
      expect(find.byType(ServerLibraryPage), findsOneWidget);
      final gridImage = find.descendant(
        of: find.byType(ServerLibraryPage),
        matching: find.byType(MediaImage),
      );
      expect(gridImage, findsWidgets);
      expect(
        DetailSourceScope.maybeOf(tester.element(gridImage.first))!
            .source
            .account
            .configuredServerId,
        f.bId,
      );
      expect(
        f.b.requests.any(
          (request) => request.contains('/Items/shared-id/Images/'),
        ),
        isTrue,
      );
      app.router.go('/search');
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        '合成',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      expect(_posterServer(tester, 'aggregation-search-${f.bId}'), f.bId);
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('aggregation-search-${f.bId}')),
          matching: find.text('合成作品'),
        ),
      );
      await _settle(tester);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(find.byType(SourceSelectionAction), findsOneWidget);
      expect(app.router.state.uri.queryParameters['showComparison'], isNull);
      expect(
        tester
            .widget<SourceDetailGate>(find.byType(SourceDetailGate))
            .showComparison,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'server detail stays open after unrelated selection and metadata notifications',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      f.b.items.first
        ..playbackPosition = Duration(microseconds: (200) ~/ 10)
        ..primaryImageTag = 'b-poster';
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      final homeImages = f.a.requests
          .where((request) => request.contains('/Items/shared-id/Images/'))
          .length;
      app.router.go('/aggregation');
      await _settle(tester);
      expect(_posterServer(tester, 'aggregation-server-${f.bId}'), f.bId);
      expect(
        f.b.requests.any(
          (request) => request.contains('/Items/shared-id/Images/'),
        ),
        isTrue,
      );
      expect(
        f.a.requests
            .where((request) => request.contains('/Items/shared-id/Images/'))
            .length,
        homeImages,
      );
      await tester.ensureVisible(
        find.descendant(
          of: find.byKey(ValueKey('aggregation-server-${f.bId}')),
          matching: find.text('合成作品'),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('aggregation-server-${f.bId}')),
          matching: find.text('合成作品'),
        ),
      );
      await _settle(tester);
      expect(
        find.byType(ItemDetailPage),
        findsOneWidget,
        reason: app.router.state.uri.toString(),
      );
      expect(find.byType(SourceSelectionAction), findsOneWidget);
      expect(
        DetailSourceScope.maybeOf(tester.element(find.byType(ItemDetailPage)))!
            .source
            .account
            .configuredServerId,
        f.bId,
      );
      await tester.runAsync(() => f.auth.selectSavedServer(f.aId));
      await _settle(tester);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(app.router.state.uri.path, '/item/shared-id');
      await tester.runAsync(() => f.auth.sources.rename(f.aId, '来源 A 已重命名'));
      await _settle(tester);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(app.router.state.uri.path, '/item/shared-id');
      expect(find.byType(SourceSelectionAction), findsOneWidget);
      expect(f.auth.session!.server.id, f.bId);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'phone search opens a known title, shows no results, and retries one failed server',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(() => _drive(tester, f.close()));
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = f.app(PresentationEnvironment.phone);
      await tester.pumpWidget(app);
      await _settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(CupertinoTabBar),
          matching: find.text('搜索'),
        ),
      );
      await _settle(tester);
      expect(find.text('想看点什么？'), findsOneWidget);
      expect(find.text('没有结果'), findsNothing);
      expect(find.byType(MediaShelf), findsNothing);
      expect(find.byType(TvItemRow), findsNothing);

      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        '合成',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      final serverA = find.byKey(ValueKey('aggregation-search-${f.aId}'));
      final serverB = find.byKey(ValueKey('aggregation-search-${f.bId}'));
      expect(
        find.descendant(of: serverA, matching: find.text('合成作品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: serverA, matching: find.text('来源 A')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: serverB, matching: find.text('来源 B')),
        findsOneWidget,
      );
      final search = find.ancestor(
        of: find.byKey(const Key('aggregation-keyword')),
        matching: find.byType(AggregationPage),
      );
      expect(
        find.descendant(of: search, matching: find.byType(PhonePosterCard)),
        findsWidgets,
      );
      expect(
        find.descendant(of: search, matching: find.byType(MediaShelf)),
        findsNothing,
      );
      await tester.tap(
        find.descendant(of: serverA, matching: find.text('合成作品')),
      );
      await _settle(tester);
      expect(find.byType(MobileDetailPage), findsOneWidget);

      app.router.pop();
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        '不可能命中xyz',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      expect(find.text('没有结果'), findsOneWidget);
      expect(serverA, findsNothing);
      expect(serverB, findsNothing);

      f.b.searchStatus = 503;
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        '合成',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      expect(find.text('部分来源失败，已保留成功结果'), findsOneWidget);
      expect(
        find.descendant(of: serverA, matching: find.text('合成作品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: serverB, matching: find.text('来源 B')),
        findsOneWidget,
      );
      final retry = find.widgetWithText(AppButton, '重试');
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.drag(
        find.byKey(const PageStorageKey('aggregation-search')),
        const Offset(0, -120),
      );
      await tester.pump();
      expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(retry).width, greaterThanOrEqualTo(48));
      f.b.searchStatus = null;
      await tester.tap(retry);
      await _settle(tester);
      expect(find.text('重试'), findsNothing);
      expect(
        find.descendant(of: serverA, matching: find.text('合成作品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: serverB, matching: find.text('合成作品')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  cases.testWidgets('tv search stays on the television field and rows', (
    tester,
  ) async {
    isolateImageCache();
    final f = _Fixture();
    await tester.runAsync(f.open);
    addTearDown(() => _drive(tester, f.close()));
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = f.app(PresentationEnvironment.tv);
    await tester.pumpWidget(app);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('tv-nav-2')));
    await _settle(tester);
    expect(find.byType(TvInput), findsOneWidget);
    expect(find.byKey(const Key('aggregation-keyword')), findsOneWidget);
    expect(find.byType(PhonePosterCard), findsNothing);
    expect(find.byType(PhoneSectionHeader), findsNothing);
    expect(find.text('想看点什么？'), findsNothing);
    await tester.tap(find.byKey(const Key('aggregation-keyword')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('tv-input-editor')), '合成');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    final search = find.ancestor(
      of: find.byKey(const Key('aggregation-keyword')),
      matching: find.byType(AggregationPage),
    );
    expect(
      find.descendant(of: search, matching: find.byType(TvItemRow)),
      findsWidgets,
    );
    expect(
      find.descendant(of: search, matching: find.byType(MediaShelf)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.router.dispose();
  }, tags: ['integration']);
}

String _posterServer(WidgetTester tester, String shelfKey) {
  final image = find.descendant(
    of: find.byKey(ValueKey(shelfKey)),
    matching: find.byType(MediaImage),
  );
  expect(image, findsWidgets);
  return DetailSourceScope.maybeOf(tester.element(image.first))!
      .source
      .account
      .configuredServerId;
}

/// Explicit subprocess regression; see tool/test_execution/README.md.
void desktopProcessMain() {
  TestWidgetsFlutterBinding.ensureInitialized();
  cases.testWidgets(
    'desktop helper hides lines on one server then private lock rejects a stale writer',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      final blockedAdapter = _BlockingCatalogAdapter([f.a, f.b]);
      await tester.runAsync(() => f.open(sourceAdapter: blockedAdapter));
      addTearDown(() async => _finishRevocation(tester, f.close()));
      addTearDown(() {
        if (!blockedAdapter.gate.isCompleted) blockedAdapter.gate.complete();
      });
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final control = _IsolatedHelperControl();
      final host = DesktopPlayerWindowHost(
        auth: f.auth,
        runtime: f.runtime,
        processControl: control,
        closeTimeout: const Duration(milliseconds: 500),
        reportTimeout: const Duration(milliseconds: 500),
        watchInterval: const Duration(milliseconds: 30),
      );
      final app = f.app(PresentationEnvironment.desktop, host: host);
      addTearDown(() async {
        await tester.runAsync(control.terminateAll);
        late Future<void> closing;
        await tester.runAsync(() async {
          closing = host.close();
        });
        for (var i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        await tester.runAsync(() => closing);
        host.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      });
      await tester.pumpWidget(app);
      await _settle(tester);
      await tester.tap(find.text('聚合').first);
      await _settle(tester);
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.bId,
        itemId: 'shared-id',
      );
      final play = find.widgetWithText(ui.AppButton, '播放').first;
      await tester.ensureVisible(play);
      await tester.tap(play);
      final positions = <int>[];
      f.history.addListener(() {
        final records = f.history.records();
        if (records.isNotEmpty) positions.add(records.first.positionTicks);
      });
      for (var i = 0; i < 3800; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        if (positions.contains(70000000)) break;
      }
      expect(
        host.current?.source?.account.configuredServerId,
        f.bId,
        reason: control.output.toString(),
      );
      expect(positions, contains(70000000), reason: control.output.toString());
      final record = f.history.records().single;
      expect(record.libraryId, 'view-movies');
      final pid = control.activePids.single;
      await tester.runAsync(() async {
        await File(
          '${control.protocols[pid]!.directory.path}/synthetic-position.json',
        ).writeAsString(jsonEncode({'seconds': 11}));
      });
      for (var i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        if (positions.contains(110000000)) break;
      }
      expect(
        positions.indexOf(70000000),
        lessThan(positions.indexOf(110000000)),
        reason: 'positions=$positions\n${control.output}',
      );
      // A one-line server hides 线路. The helper must not offer another server,
      // a version, or a timeline confirmation.
      await tester.runAsync(
        () => File(
          '${control.protocols[pid]!.directory.path}/synthetic-menu.json',
        ).writeAsString(jsonEncode({'action': 'lines'})),
      );
      Map<String, dynamic>? lineReceipt;
      final menuDeadline = DateTime.now().add(const Duration(seconds: 12));
      while (lineReceipt == null && DateTime.now().isBefore(menuDeadline)) {
        await tester.pump(const Duration(milliseconds: 30));
        lineReceipt = await tester.runAsync<Map<String, dynamic>?>(() async {
          final file = File(
            '${control.protocols[pid]!.directory.path}/synthetic-menu-receipt.json',
          );
          final receipt = await consumeSyntheticMessage(file);
          // The helper polls in a real process; fake Flutter time cannot
          // guarantee it has processed the menu request under parallel load.
          if (receipt == null) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          return receipt;
        });
      }
      expect(lineReceipt, isNotNull, reason: control.output.toString());
      expect(lineReceipt!['lines'], lessThan(2));
      expect(
        host.current?.source?.account.configuredServerId,
        f.bId,
        reason: control.output.toString(),
      );
      expect(
        f.history.records().any(
          (r) =>
              r.source.account.configuredServerId == f.bId &&
              r.positionTicks == 110000000,
        ),
        isTrue,
      );
      expect(
        f.history.records().every(
          (r) => r.source.account.configuredServerId != f.aId,
        ),
        isTrue,
      );
      late Future<void> closingPlayback;
      await tester.runAsync(() async {
        closingPlayback = host.close();
      });
      for (var i = 0; i < 120 && host.current != null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      await tester.runAsync(() => closingPlayback);
      await tester.runAsync(() async {});
      late Future<void> moving;
      await tester.runAsync(() async {
        moving = f.protect(f.aId);
      });
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      await tester.runAsync(() => moving);
      await _settle(tester);
      expect(host.current, isNull);
      expect(control.activePids, isEmpty);
      expect(
        f.history.records().every(
          (r) => r.source.account.configuredServerId != f.aId,
        ),
        isTrue,
      );
      await tester.runAsync(() => f.auth.switchTo(f.bId));
      await tester.runAsync(() => f.auth.serverAccess.unlock(f.aId, '1234'));
      await _openOwnedDetail(
        tester,
        f,
        app,
        serverId: f.aId,
        itemId: 'shared-id',
      );
      await tester.ensureVisible(find.widgetWithText(ui.AppButton, '播放').first);
      await tester.tap(find.widgetWithText(ui.AppButton, '播放').first);
      // Include the helper's native asset/Flutter compilation budget, then
      // allow its first observation to reach the parent.
      final privateHelperDeadline = DateTime.now().add(
        _IsolatedHelperControl.launchTimeout + const Duration(seconds: 20),
      );
      while (DateTime.now().isBefore(privateHelperDeadline)) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        if (f.history.records().any((r) => r.positionTicks == 70000000)) {
          break;
        }
      }
      final privateRecords = f.history
          .records()
          .where((r) => r.source.account.configuredServerId == f.aId)
          .toList();
      expect(privateRecords, isNotEmpty, reason: control.output.toString());
      final privateRecord = privateRecords.first;
      expect(
        privateRecord.source.account.configuredServerId,
        f.aId,
        reason: control.output.toString(),
      );
      final oldToken = f.history.sessionById(privateRecord.sessionId)!;
      final privatePid = control.activePids.single;
      blockedAdapter.blockedAuthority = f.a.baseUrl.authority;
      await tester.runAsync(
        () => File(
          '${control.protocols[privatePid]!.directory.path}/synthetic-menu.json',
        ).writeAsString(jsonEncode({'action': 'open-lock'})),
      );
      for (var frame = 0; frame < 120 && !blockedAdapter.entered; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      expect(blockedAdapter.entered, isTrue, reason: control.output.toString());
      expect(blockedAdapter.gate.isCompleted, isFalse);
      final privateEndpoint = control.protocols[privatePid]!;
      final lockSource = encodeSource(privateRecord.source);
      final invalidLocks = <Map<String, dynamic>>[
        {'pid': privatePid + 1},
        {'generation': f.auth.serverAccess.generation(f.aId) - 1},
        {'sequence': -1},
        {'action': 'inspect'},
        for (final field in ['server', 'verifiedServer', 'user'])
          {
            'source': {...lockSource, field: 'forged-$field'},
          },
        {
          'source': {...lockSource, 'provider': 'plex'},
        },
      ];
      for (var index = 0; index < invalidLocks.length; index++) {
        final command = <String, dynamic>{
          'sessionId': privateEndpoint.sessionId,
          'pid': privatePid,
          'sequence': 1000 + index,
          'action': 'lock',
          'generation': f.auth.serverAccess.generation(f.aId),
          'source': lockSource,
          ...invalidLocks[index],
        };
        await tester.runAsync(
          () =>
              File('${privateEndpoint.directory.path}/lock-request.json')
                  .writeAsString(jsonEncode(command)),
        );
        Map<String, dynamic>? receipt;
        final receiptDeadline = DateTime.now().add(const Duration(seconds: 4));
        while (receipt == null && DateTime.now().isBefore(receiptDeadline)) {
          await tester.pump(const Duration(milliseconds: 50));
          receipt = await tester.runAsync<Map<String, dynamic>?>(() async {
            final reply = await privateEndpoint.read('lock-reply');
            // The helper is a real process; pumping Flutter's fake clock
            // alone does not give its filesystem polling time to run.
            if (reply == null) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            return reply;
          });
        }
        expect(receipt?['sequence'], command['sequence']);
        expect(receipt?['accepted'], isFalse, reason: 'Invalid lock $index');
        expect(f.auth.serverAccess.allows(f.aId), isTrue);
        expect(host.current?.source?.account, privateRecord.source.account);
        expect(blockedAdapter.gate.isCompleted, isFalse);
      }
      await tester.runAsync(
        () => File(
          '${control.protocols[privatePid]!.directory.path}/synthetic-menu.json',
        ).writeAsString(jsonEncode({'action': 'lock'})),
      );
      for (var i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        if (!f.auth.serverAccess.allows(f.aId) &&
            host.current == null &&
            control.activePids.isEmpty) {
          break;
        }
      }
      expect(
        f.auth.serverAccess.allows(f.aId),
        isFalse,
        reason: control.output.toString(),
      );
      expect(host.current, isNull);
      expect(control.activePids, isEmpty);
      expect(
        blockedAdapter.gate.isCompleted,
        isFalse,
        reason: 'Urgent lock cannot wait for the serialized catalogue RPC',
      );
      blockedAdapter.gate.complete();
      await _settle(tester);
      expect(
        f.history.records().where(
          (r) => r.source.account.configuredServerId == f.aId,
        ),
        isEmpty,
      );
      final lateRecord = await tester.runAsync(
        () => f.history.observe(
          session: oldToken,
          eventSequence: 999,
          positionTicks: 290000000,
          actuallyPlaying: true,
          timeline: const WatchTimeline(durationTicks: 1200000000),
        ),
      );
      expect(lateRecord, isNull);
      // Dispose application/socket/query scopes before Flutter checks pending
      // timers; bounded report/close deadlines are advanced, never disabled.
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      expect(
        f.history.records().every(
          (r) => r.source.account.configuredServerId != f.aId,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

final cases = CaseShard(6);

void mainShard(int part, int expectedParts) =>
    cases.register(part, main, expectedParts: expectedParts);
