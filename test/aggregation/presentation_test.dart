import 'dart:async';
import 'package:dio/dio.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/source_route_extra_codec.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/library/server_library_page.dart';
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
import 'package:rillight/aggregation/query/aggregation_query.dart'
    show SourceReference;
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
import 'package:rillight/auth/source_management.dart';
import 'package:rillight/player/source_switch_menu.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

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
  _IsolatedHelperControl()
    : super(
        startupTimeout: const Duration(seconds: 70),
        pollInterval: const Duration(milliseconds: 30),
      );
  final Map<int, Process> children = {};
  final Map<int, PlayerProcessProtocol> protocols = {};
  final Set<int> alive = {};
  final StringBuffer output = StringBuffer();
  @override
  Future<int> launch(String executable, String payloadPath) async {
    final json =
        jsonDecode(await File(payloadPath).readAsString())
            as Map<String, dynamic>;
    final launch = PlayerWindowLaunch.fromJson(json);
    final child = await Process.start(
      'flutter',
      [
        'test',
        '--no-pub',
        '--reporter',
        'expanded',
        'test/helpers/desktop_ipc_fixture.dart',
      ],
      environment: {'RILLIGHT_TEST_LAUNCH': payloadPath},
      // Flutter is a .bat entrypoint on Windows; direct CreateProcess cannot
      // resolve it as an executable without the command shell.
      runInShell: Platform.isWindows,
    );
    child.stdout.transform(utf8.decoder).listen(output.write);
    child.stderr.transform(utf8.decoder).listen(output.write);
    var finished = false;
    unawaited(
      child.exitCode.then((_) {
        finished = true;
        alive.removeWhere((id) => children[id] == child);
      }),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 65));
    while (!finished && DateTime.now().isBefore(deadline)) {
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
    child.kill();
    throw StateError('Isolated simulated helper did not start: $output');
  }

  @override
  bool isAlive(int pid) => alive.contains(pid);
  @override
  Future<void> terminate(int pid) async {
    Process.killPid(pid);
    children[pid]?.kill();
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
    bool configure = true,
    HistoryStore? historyStore,
    FakeEmbyAdapter? sourceAdapter,
  }) async {
    adapter = sourceAdapter ?? FakeEmbyAdapter([a, b]);
    final credentials = MemoryCredentialStore();
    final servers = MemoryServerListStore();
    EmbyClient client() => EmbyClient(
      device: const EmbyDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'test',
        version: '1',
      ),
      dio: dioForFakeEmby(adapter),
    );
    final sources = SourceSessionRegistry(
      access: RegionAccessController(),
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
      if (configure) {
        await sources.configureScope(
          auth.session!.server.id,
          participates: true,
          libraryIds: {'view-movies'},
        );
      }
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
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 80));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
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
    () => f.auth.sources.acquireAccount(
      serverId,
      region: AccessRegion.ordinary,
      libraryId: libraryId,
    ),
  );
  final permit = f.auth.sources.permit(account!, libraryId: libraryId);
  app.router.go(
    '/item/$itemId',
    extra: PlayerHostOpenItemCommand(
      itemId: itemId,
      source: SourceReference(account: account, itemId: itemId),
      libraryId: libraryId,
      regionGeneration: permit.regionGeneration,
    ),
  );
  await _settle(tester);
}

Future<Uint8List> _png(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets(
    'B album save chooser receipt cannot save bytes after source migration',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
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
        find.descendant(of: album, matching: find.byType(InkWell)).first,
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
        await f.auth.regionAccess.setPin('1234', '1234', (_) async {});
        await f.auth.regionAccess.unlock('1234');
        await f.auth.sources.move(f.bId, AccessRegion.private);
      });
      chooser.complete(output.path);
      await _settle(tester);
      expect(output.existsSync(), isFalse);
      expect(find.byType(Dialog), findsNothing);
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
    testWidgets(
      '${environment.presentation.name} real management checks backup line without changing active source',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(f.close);
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
          saved = f.auth.sources
              .project(AccessRegion.ordinary)
              .firstWhere((s) => s.id == f.aId);
          await f.auth.sources.renameLine(f.aId, saved.lines.last.id, '备用线路');
          session = await f.auth.sources.authenticate(f.aId);
        });
        final permit = f.auth.sources.permit(
          session.account,
          libraryId: 'view-movies',
        );
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
          await tester.tap(find.byType(NavigationDestination).at(1));
        }
        await _settle(tester);
        expect(
          find.byKey(const Key('aggregation-source-management')),
          findsNothing,
        );
        showSourceManagement(tester.element(find.byType(AggregationPage)));
        await _settle(tester);
        expect(find.byType(SourceManagement), findsOneWidget);
        final check = find.byKey(
          Key('source-line-check-${f.aId}-${saved.lines.last.id}'),
        );
        await tester.scrollUntilVisible(
          check,
          120,
          scrollable: find
              .descendant(
                of: find.byType(SourceManagement),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await _settle(tester);
        if (environment.isTv) {
          final focus = find
              .descendant(of: check, matching: find.byType(Focus))
              .first;
          Focus.of(
            tester.element(
              find
                  .descendant(of: focus, matching: find.byType(Semantics))
                  .first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(check);
        }
        await _settle(tester);
        final updated = f.auth.sources
            .project(AccessRegion.ordinary)
            .firstWhere((s) => s.id == f.aId);
        expect(updated.lines.last.checkStatus, 'available');
        expect(updated.lines.last.checkedAt, isNotNull);
        final tile = find.ancestor(of: check, matching: find.byType(ListTile));
        expect(
          find.descendant(
            of: tile,
            matching: find.textContaining('available · '),
          ),
          findsOneWidget,
        );
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
    testWidgets(
      '${environment.presentation.name} real management opens anonymous PIN gate and cancels without widening scope',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(() => f.open(configure: false));
        addTearDown(f.close);
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
        app.router.go('/private');
        await _settle(tester);
        await tester.tap(find.text('解锁'));
        await _settle(tester);
        expect(find.byType(PrivateAccessDialog), findsOneWidget);
        await tester.enterText(find.byKey(const Key('private-pin')), '1234');
        await tester.enterText(
          find.byKey(const Key('private-pin-confirm')),
          '5678',
        );
        await tester.tap(find.byKey(const Key('private-unlock')));
        await _settle(tester);
        expect(find.byKey(const Key('private-pin-error')), findsOneWidget);
        expect(f.auth.regionAccess.hasPin, isFalse);
        await tester.tap(find.text('取消'));
        await _settle(tester);
        expect(find.byType(PrivateAccessDialog), findsNothing);
        expect(
          f.auth.sources
              .project(AccessRegion.ordinary)
              .every((s) => !s.scopeKnown && s.libraryIds.isEmpty),
          isTrue,
        );
        expect(f.auth.regionAccess.allows(AccessRegion.private), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }
  testWidgets(
    'desktop actual helper menu file IPC switches B to A viewing receipt then migration busy private lock rejects old writer token',
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
      final play = find.widgetWithText(FilledButton, '播放').first;
      await tester.ensureVisible(play);
      await tester.tap(play);
      final positions = <int>[];
      f.history.addListener(() {
        final records = f.history.records(AccessRegion.ordinary);
        if (records.isNotEmpty) positions.add(records.first.positionTicks);
      });
      for (var i = 0; i < 1400; i++) {
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
      final record = f.history.records(AccessRegion.ordinary).single;
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
      // Drive the actual SourceSwitchMenu in the isolated Flutter helper. Its
      // controller sends real file RPC; the main process retains one writer.
      await tester.runAsync(
        () => File(
          '${control.protocols[pid]!.directory.path}/synthetic-menu.json',
        ).writeAsString(jsonEncode({'action': 'switch', 'targetId': f.aId})),
      );
      for (var i = 0; i < 1200; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        if (f.history
            .records(AccessRegion.ordinary)
            .any(
              (r) =>
                  r.source.account.configuredServerId == f.aId &&
                  r.positionTicks == 70000000,
            )) {
          break;
        }
      }
      expect(
        host.current?.source?.account.configuredServerId,
        f.aId,
        reason: control.output.toString(),
      );
      final targetRecord = f.history.records(AccessRegion.ordinary).first;
      expect(targetRecord.source.account.configuredServerId, f.aId);
      expect(targetRecord.source.itemId, 'shared-id');
      expect(targetRecord.source.mediaSourceId, 'shared-id');
      expect(targetRecord.positionTicks, 70000000);
      expect(
        f.history
            .records(AccessRegion.ordinary)
            .any(
              (r) =>
                  r.source.account.configuredServerId == f.bId &&
                  r.positionTicks == 110000000,
            ),
        isTrue,
      );
      await tester.runAsync(() async {
        await f.auth.setPrivatePin('1234', '1234');
        await f.auth.regionAccess.unlock('1234');
      });
      late Future<void> moving;
      await tester.runAsync(() async {
        moving = f.auth.sources.move(f.aId, AccessRegion.private);
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
        f.history
            .records(AccessRegion.ordinary)
            .every((r) => r.source.account.configuredServerId != f.aId),
        isTrue,
      );
      await tester.runAsync(() => f.auth.switchTo(f.bId));
      app.router.go('/private');
      await _settle(tester);
      await tester.ensureVisible(find.text('合成作品'));
      await tester.pump();
      await tester.tap(find.text('合成作品'));
      await _settle(tester);
      await tester.ensureVisible(find.widgetWithText(FilledButton, '播放').first);
      await tester.tap(find.widgetWithText(FilledButton, '播放').first);
      for (var i = 0; i < 1200; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        if (f.history
            .records(AccessRegion.private)
            .any((r) => r.positionTicks == 70000000)) {
          break;
        }
      }
      final privateRecord = f.history.records(AccessRegion.private).first;
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
        {'generation': f.auth.regionAccess.generation - 1},
        {'sequence': -1},
        {'action': 'inspect'},
        for (final field in ['server', 'verifiedServer', 'user'])
          {
            'source': {...lockSource, field: 'forged-$field'},
          },
        {
          'source': {...lockSource, 'region': 'ordinary'},
        },
      ];
      for (var index = 0; index < invalidLocks.length; index++) {
        final command = <String, dynamic>{
          'sessionId': privateEndpoint.sessionId,
          'pid': privatePid,
          'sequence': 1000 + index,
          'action': 'lock',
          'generation': f.auth.regionAccess.generation,
          'source': lockSource,
          ...invalidLocks[index],
        };
        await tester.runAsync(
          () => File(
            '${privateEndpoint.directory.path}/lock-request.json',
          ).writeAsString(jsonEncode(command)),
        );
        Map<String, dynamic>? receipt;
        for (var frame = 0; frame < 80 && receipt == null; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
          receipt = await tester.runAsync<Map<String, dynamic>?>(
            () => privateEndpoint.read('lock-reply'),
          );
        }
        expect(receipt?['sequence'], command['sequence']);
        expect(receipt?['accepted'], isFalse, reason: 'Invalid lock $index');
        expect(f.auth.regionAccess.allows(AccessRegion.private), isTrue);
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
        if (!f.auth.regionAccess.allows(AccessRegion.private) &&
            host.current == null &&
            control.activePids.isEmpty) {
          break;
        }
      }
      expect(
        f.auth.regionAccess.allows(AccessRegion.private),
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
      expect(f.history.records(AccessRegion.private), isEmpty);
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
        f.history
            .records(AccessRegion.ordinary)
            .every((r) => r.source.account.configuredServerId != f.aId),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
    timeout: const Timeout(Duration(seconds: 210)),
  );
  testWidgets(
    'TV remote actual B detail and controller write seven seconds then migration rejects late observation',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(() async {
        await f.open();
        await f.auth.sources.configureScope(
          f.aId,
          participates: false,
          libraryIds: {'view-movies'},
        );
      });
      addTearDown(f.close);
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
      final record = f.history.records(AccessRegion.ordinary).single;
      expect(record.source.account.configuredServerId, f.bId);
      expect(record.libraryId, 'view-movies');
      expect(record.positionTicks, 70000000);
      expect(notifications, greaterThan(0));
      expect(f.b.playbackEvents, isNotEmpty);
      expect(f.a.playbackEvents, isEmpty);
      await tester.runAsync(() async {
        await f.auth.setPrivatePin('1234', '1234');
        await f.auth.regionAccess.unlock('1234');
      });
      late Future<void> migration;
      await tester.runAsync(() async {
        migration = f.auth.sources.move(f.bId, AccessRegion.private);
      });
      await _settle(tester);
      await tester.runAsync(() => migration);
      await _settle(tester);
      expect(backend.isPlaying, isFalse);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
      await _settle(tester);
      expect(f.history.records(AccessRegion.ordinary), isEmpty);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  testWidgets(
    'phone finds compares switches actual source records then private player menu locks and rejects late frames',
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
      addTearDown(f.close);
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
        f.history
            .records(AccessRegion.ordinary)
            .single
            .source
            .account
            .configuredServerId,
        f.bId,
      );
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const Key('player-manual-switch')));
      await tester.tap(find.byKey(const Key('player-manual-switch')));
      await _settle(tester);
      expect(find.byType(SourceSwitchMenu), findsOneWidget);
      final target = find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
              'switch-target-${f.aId}-',
            ),
      );
      await tester.ensureVisible(target);
      await tester.tap(target);
      await _settle(tester);
      if (c.switchConfirmation != null) {
        if (c.switchConfirmation!.audioNeedsChoice) {
          final choice = find.byType(CheckboxListTile).first;
          await tester.ensureVisible(choice);
          await tester.tap(choice);
          await _settle(tester);
        }
        if (c.switchConfirmation!.subtitleNeedsChoice) {
          final choice = find.byType(CheckboxListTile).last;
          await tester.ensureVisible(choice);
          await tester.tap(choice);
          await _settle(tester);
        }
        await tester.ensureVisible(find.text('从头播放'));
        await tester.tap(find.text('从头播放'));
        await _settle(tester);
      }
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
        f.history
            .records(AccessRegion.ordinary)
            .any(
              (r) =>
                  r.source.account.configuredServerId == f.aId &&
                  r.positionTicks == 110000000,
            ),
        isTrue,
      );
      // Changing the selected ordinary account must not retarget playback A.
      await tester.tap(find.text('取消').last);
      await _settle(tester);
      await tester.runAsync(() => f.auth.switchTo(f.bId));
      await _settle(tester);
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      expect(backend.isPlaying, isTrue);
      expect(c.activeOrigin!.source.account.configuredServerId, f.aId);
      debugPrint('T7 phone: ordinary selection preserves active A');
      await tester.runAsync(() async {
        await f.auth.setPrivatePin('1234', '1234');
        await f.auth.regionAccess.unlock('1234');
      });
      late Future<void> moving;
      await tester.runAsync(() async {
        moving = f.auth.sources.move(f.aId, AccessRegion.private);
      });
      await _settle(tester);
      debugPrint('T7 phone: advancing A membership revocation');
      await _finishRevocation(tester, moving);
      debugPrint('T7 phone: A membership revoked');
      await _settle(tester);
      expect(backend.isPlaying, isFalse);
      expect(find.byType(SourceSwitchMenu), findsNothing);
      debugPrint('T7 phone: entering private A');
      app.router.go('/private');
      await _settle(tester);
      await tester.ensureVisible(find.text('合成作品'));
      await tester.tap(find.text('合成作品'));
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const Key('mobile-detail-play')));
      await tester.tap(find.byKey(const Key('mobile-detail-play')));
      await _settle(tester);
      expect(backend.isPlaying, isTrue);
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const Key('player-manual-switch')));
      await tester.tap(find.byKey(const Key('player-manual-switch')));
      await _settle(tester);
      debugPrint('T7 phone: locking actual private player');
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('player-lock-private'))),
      );
      debugPrint('T7 phone: lock tap dispatched');
      await _settle(tester);
      debugPrint('T7 phone: lock frame settled');
      expect(f.auth.regionAccess.allows(AccessRegion.private), isFalse);
      expect(backend.isPlaying, isFalse);
      expect(find.byType(SourceSwitchMenu), findsNothing);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 29));
      await _settle(tester);
      debugPrint('T7 phone: rejected late frame');
      expect(
        f.history
            .records(AccessRegion.ordinary)
            .every((r) => r.source.account.configuredServerId != f.aId),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  testWidgets(
    'phone B detail play dispatch reaches actual controller and same writer, migration stops late observations',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      final backend = FakeVideoBackend(duration: const Duration(seconds: 120));
      final app = f.app(PresentationEnvironment.phone, backend: backend);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        app.router.dispose();
      });
      await tester.pumpWidget(app);
      await _settle(tester);
      await tester.tap(find.byType(NavigationDestination).at(1));
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
      final record = f.history.records(AccessRegion.ordinary).single;
      expect(record.source.account.configuredServerId, f.bId);
      expect(record.libraryId, 'view-movies');
      expect(record.positionTicks, 7 * 10000000);
      expect(notifications, greaterThan(0));
      expect(f.b.playbackEvents, isNotEmpty);
      expect(f.a.playbackEvents, isEmpty);
      expect(f.auth.session!.server.id, f.aId);
      await tester.runAsync(() async {
        await f.auth.regionAccess.setPin('1234', '1234', (_) async {});
        await f.auth.regionAccess.unlock('1234');
      });
      late Future<void> migration;
      await tester.runAsync(() async {
        migration = f.auth.sources.move(f.bId, AccessRegion.private);
      });
      // Source revocation removes the route; allow its actual controller's
      // retirement/observation queue to run while membership cleanup awaits it.
      await _settle(tester);
      await tester.runAsync(() => migration);
      await _settle(tester);
      expect(backend.isPlaying, isFalse);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 9));
      await _settle(tester);
      expect(f.history.records(AccessRegion.ordinary), isEmpty);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
  testWidgets(
    'legacy shelf nextup retains zero-progress episode and latest routes constrain actual types',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
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
  testWidgets(
    'B album thumbnails and full viewer use B bytes; migration evicts viewer and rejects late B image',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      f.a.items.first.backdropImageTags = ['a-one', 'a-two'];
      f.b.items.first.backdropImageTags = ['b-one', 'b-two'];
      f.a.itemImageBytes = await tester.runAsync(() => _png(Colors.red));
      f.b.itemImageBytes = await tester.runAsync(() => _png(Colors.blue));
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
      addTearDown(() => directory.deleteSync(recursive: true));
      final output = File('${directory.path}/b.png');
      const saveChannel = MethodChannel('plugins.flutter.io/file_selector');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(saveChannel, (_) async => output.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(saveChannel, null),
      );
      await tester.tap(
        find.descendant(of: album, matching: find.byType(InkWell)).first,
      );
      await _settle(tester);
      final fullImages = find.descendant(
        of: find.byType(Dialog),
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
      expect(output.readAsBytesSync(), orderedEquals(f.b.itemImageBytes!));
      await tester.tap(find.byIcon(Icons.close_rounded).last);
      await _settle(tester);
      f.b.holdItemImage = Completer<void>();
      await tester.tap(
        find.descendant(of: album, matching: find.byType(InkWell)).first,
      );
      await _settle(tester);
      expect(find.byType(Dialog), findsOneWidget);
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
      await tester.runAsync(
        () => f.auth.regionAccess.setPin('1234', '1234', (_) async {}),
      );
      await tester.runAsync(() => f.auth.regionAccess.unlock('1234'));
      await tester.runAsync(
        () => f.auth.sources.move(f.bId, AccessRegion.private),
      );
      f.b.holdItemImage!.complete();
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);
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

  testWidgets(
    'TV D-pad enters aggregation and retains Material control focus for multiple frames',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
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
      expect(find.text('查找同源'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
      await tester.tap(find.byKey(const Key('aggregation-segment-libraries')));
      await _settle(tester);
      expect(find.text('来源 A'), findsOneWidget);
      expect(find.text('来源 B'), findsOneWidget);
      expect(find.byType(ItemDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
  testWidgets(
    'desktop shell search focuses input, closes on Escape and result, returns allowed scope',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
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
      expect(tester.widget<TextField>(input).focusNode?.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(input, findsNothing);
      await openSearch();
      await tester.enterText(input, '合成');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      expect(find.text('来源 A'), findsOneWidget);
      expect(find.text('来源 B'), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.text('媒体库范围'), findsNothing);
      await tester.ensureVisible(find.text('合成作品').last);
      await tester.pump();
      await tester.tap(find.text('合成作品').last);
      await _settle(tester);
      expect(input, findsNothing);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(f.auth.session!.server.id, f.aId);
      app.router.pop();
      await _settle(tester);
      expect(find.text('继续播放'), findsWidgets);
      expect(find.text('查找同源'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
  test(
    'writer notifies committed records only; failed storage and failing observer cannot corrupt observation order',
    () async {
      final store = _ControlledHistoryStore();
      final f = _Fixture();
      await f.open(historyStore: store);
      addTearDown(f.close);
      final account = await f.auth.sources.acquireAccount(
        f.bId,
        region: AccessRegion.ordinary,
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
      expect(f.history.records(AccessRegion.ordinary), isEmpty);
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
        expect(
          f.history.records(AccessRegion.ordinary).single.eventSequence,
          2,
        );
        expect(notifications, 2);
      } finally {
        FlutterError.onError = previous;
      }
    },
  );

  test(
    'writer close drains accepted storage without late notifications and rejects new observations',
    () async {
      final store = _ControlledHistoryStore();
      final f = _Fixture();
      await f.open(historyStore: store);
      addTearDown(f.close);
      final account = await f.auth.sources.acquireAccount(
        f.bId,
        region: AccessRegion.ordinary,
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
    },
  );

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} real entry shows server rows and retries only the failed server',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(f.close);
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
          await tester.tap(find.byType(NavigationDestination).at(1));
        }
        await _settle(tester);
        expect(find.byType(AggregationPage), findsOneWidget);
        expect(find.text('继续播放'), findsWidgets);
        expect(find.text('收藏'), findsWidgets);
        expect(find.text('媒体库'), findsWidgets);
        expect(
          find.byKey(const Key('aggregation-source-management')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('aggregation-private-entry')),
          findsNothing,
        );
        expect(find.text('查找同源'), findsNothing);
        expect(find.text('媒体库范围'), findsNothing);
        expect(find.byType(FilterChip), findsNothing);
        await tester.tap(
          find.byKey(const Key('aggregation-segment-libraries')),
        );
        await _settle(tester);
        expect(find.text('来源 A'), findsOneWidget);
        expect(find.text('来源 B'), findsOneWidget);
        expect(find.text('电影'), findsWidgets);
        expect(find.text('重试'), findsOneWidget);
        f.b.viewsStatus = null;
        await tester.tap(find.text('重试'));
        await _settle(tester);
        expect(find.text('来源 A'), findsOneWidget);
        expect(find.text('来源 B'), findsOneWidget);
        expect(find.text('重试'), findsNothing);
        final selected = f.auth.session!.server.id;
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('aggregation-server-${f.bId}')),
            matching: find.text('电影'),
          ),
        );
        await _settle(tester);
        expect(find.byType(ServerLibraryPage), findsOneWidget);
        expect(f.auth.session!.server.id, selected);
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

  testWidgets(
    'continue watching dispatches the T3 recorded B version and timeline without changing selected A',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      late SourceReference source;
      late WatchSession session;
      await tester.runAsync(() async {
        final account = await f.auth.sources.acquireAccount(
          f.bId,
          region: AccessRegion.ordinary,
          libraryId: 'view-movies',
        );
        source = SourceReference(
          account: account,
          itemId: 'shared-id',
          mediaSourceId: 'recorded-version',
        );
        session = await f.history.beginSession(
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
      f.a.items.first.playbackPositionTicks = 150000000;
      f.a.items.first.productionYear = 2010;
      f.b.items.first.playbackPositionTicks = 350000000;
      f.b.items.first.productionYear = 2011;
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      expect(find.text('来源 A'), findsOneWidget);
      expect(find.text('来源 B'), findsOneWidget);
      expect(find.text('2010'), findsOneWidget);
      expect(find.text('2011'), findsOneWidget);
      expect(find.byTooltip('从本机记录的实际来源继续'), findsNothing);
      final poster = find.descendant(
        of: find.byKey(ValueKey('aggregation-server-${f.bId}')),
        matching: find.text('合成作品'),
      );
      await tester.ensureVisible(poster);
      await tester.pump();
      await tester.tap(poster);
      await _settle(tester);
      expect(
        DetailSourceScope.maybeOf(
          tester.element(find.byType(ItemDetailPage)),
        )!.source.account.configuredServerId,
        f.bId,
      );
      expect(host.current, isNull);
      expect(f.auth.session!.server.id, f.aId);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      host.dispose();
    },
    tags: ['integration'],
  );

  testWidgets(
    'remote-only resume with unknown times asks for an actual source rather than maximum progress',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      f.a.items.first.playbackPositionTicks = 150000000;
      f.a.items.first.productionYear = 1999;
      f.b.items.first.playbackPositionTicks = 350000000;
      f.b.items.first.productionYear = 2001;
      f.b.items.first.overview = 'B续播来源';
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      expect(find.text('1999'), findsOneWidget);
      expect(find.text('2001'), findsOneWidget);
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
        DetailSourceScope.maybeOf(
          tester.element(find.byType(ItemDetailPage)),
        )!.source.account.configuredServerId,
        f.bId,
      );
      expect(f.auth.session!.server.id, f.aId);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  testWidgets('ordinary library navigation stays in the selected server', (
    tester,
  ) async {
    isolateImageCache();
    final f = _Fixture();
    await tester.runAsync(f.open);
    addTearDown(f.close);
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
  }, tags: ['integration']);

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      'ordinary catalog and playback ignore aggregation scope ${environment.presentation.name}',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(() => f.open(configure: false));
        addTearDown(f.close);
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
          f.auth.sources
              .project(AccessRegion.ordinary)
              .every((s) => !s.scopeKnown),
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

  testWidgets(
    'selected detail opens without configuring aggregation libraries',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(() => f.open(configure: false));
      addTearDown(f.close);
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
        f.auth.sources
            .project(AccessRegion.ordinary)
            .every((s) => !s.scopeKnown),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  testWidgets(
    'comparison retains B scope while ordinary detail uses selected A',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
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
      expect(f.auth.session!.server.id, f.aId);
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

  testWidgets(
    'source comparison distinguishes title candidate and unknown metadata without confirmed resume',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      f.b.items = [
        FakeEmbyItem(
          id: 'candidate',
          name: '合成作品',
          type: 'Movie',
          parentId: 'view-movies',
        ),
      ];
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
      await tester.tap(find.widgetWithText(FilledButton, '查找同源'));
      await _settle(tester);
      expect(find.textContaining('待辨认候选'), findsOneWidget);
      expect(find.textContaining('已确认来源'), findsNothing);
      expect(find.textContaining('未知'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  testWidgets(
    'concrete episode comparison renders missing target separately from failed query',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
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
      await tester.runAsync(() async {
        for (final id in [f.aId, f.bId]) {
          await f.auth.sources.configureScope(
            id,
            participates: true,
            libraryIds: {'view-tv'},
          );
        }
      });
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      final account = await tester.runAsync(
        () => f.auth.sources.acquireAccount(
          f.aId,
          region: AccessRegion.ordinary,
          libraryId: 'view-tv',
        ),
      );
      app.router.go(
        '/item/episode',
        extra: PlayerHostOpenItemCommand(
          itemId: 'episode',
          source: SourceReference(account: account!, itemId: 'episode'),
          libraryId: 'view-tv',
          regionGeneration: f.auth.sources
              .permit(account, libraryId: 'view-tv')
              .regionGeneration,
        ),
      );
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '查找同源'));
      await _settle(tester);
      expect(find.textContaining('已确认来源'), findsOneWidget);
      await tester.tap(find.text('查找此集'));
      await _settle(tester);
      await tester.tap(find.text('已核对，按季与集对应'));
      await _settle(tester);
      expect(find.text('缺少目标集（非查询失败）'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  testWidgets(
    'private route lock removes page semantics and unlocked private is excluded from ordinary sources',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      await tester.runAsync(() async {
        await f.auth.regionAccess.setPin('1234', '1234', (_) async {});
        await f.auth.regionAccess.unlock('1234');
        await f.auth.sources.rename(f.bId, '私密来源名');
        await f.auth.sources.move(f.bId, AccessRegion.private);
      });
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/private');
      await _settle(tester);
      expect(find.text('私密来源名'), findsOneWidget);
      final imagePolicy = DetailSourceScope.imagePolicyOf(
        tester.element(find.byType(MediaImage).first),
      )!;
      expect(imagePolicy.allowsDisk, isFalse);
      expect(imagePolicy.permit.account.configuredServerId, f.bId);
      expect(imagePolicy.isValid, isTrue);
      await tester.runAsync(() => f.auth.regionAccess.lock());
      await _settle(tester);
      expect(find.byType(AggregationPage), findsNothing);
      expect(imagePolicy.isValid, isFalse);
      expect(find.text('私密来源名'), findsNothing);
      expect(find.textContaining('私密区域已锁定'), findsOneWidget);
      app.router.go('/aggregation');
      await _settle(tester);
      expect(find.text('私密来源名'), findsNothing);
      expect(find.byKey(ValueKey('aggregation-source-${f.bId}')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  testWidgets(
    'lock clears a private detail and comparison overlay plus deep route extras/history',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      await tester.runAsync(() async {
        await f.auth.regionAccess.setPin('1234', '1234', (_) async {});
        await f.auth.regionAccess.unlock('1234');
        await f.auth.sources.rename(f.bId, '私密来源名');
        await f.auth.sources.move(f.bId, AccessRegion.private);
      });
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/private');
      await _settle(tester);
      await tester.ensureVisible(find.text('合成作品'));
      await tester.pump();
      await tester.tap(find.text('合成作品'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '查找同源'));
      await _settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.runAsync(() => f.auth.regionAccess.lock());
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('私密来源名'), findsNothing);
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
      await tester.runAsync(() => f.auth.regionAccess.unlock('1234'));
      await _settle(tester);
      expect(find.textContaining('私密来源名'), findsNothing);
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
    testWidgets(
      '${environment.presentation.name} actual private menu locks during stalled preflight and rejects late receipt',
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
          await f.auth.setPrivatePin('1234', '1234');
          await f.auth.regionAccess.unlock('1234');
          await f.auth.sources.move(f.bId, AccessRegion.private);
        });
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final b = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(
            f.bId,
            region: AccessRegion.private,
            libraryId: 'view-movies',
          ),
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
              regionGeneration: f.auth.sources.permit(b).regionGeneration,
            ),
          ),
        );
        await _settle(tester);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
        await _settle(tester);
        expect(
          f.history
              .records(AccessRegion.private)
              .single
              .source
              .account
              .configuredServerId,
          f.bId,
        );
        if (!environment.isTv) {
          await tester.tap(find.byKey(const Key('mobile-player-more')));
          await _settle(tester);
        }
        await tester.ensureVisible(
          find.byKey(const Key('player-manual-switch')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('player-manual-switch')));
        await _settle(tester);
        adapter.blockedAuthority = f.b.baseUrl.authority;
        adapter.blockedSuffix = '/PlaybackInfo';
        final version = find.byKey(
          const ValueKey('switch-version-private-alternate'),
        );
        await tester.ensureVisible(version);
        await tester.pump();
        await tester.tap(version);
        await _settle(tester);
        expect(adapter.entered, isTrue);
        expect(adapter.gate.isCompleted, isFalse);
        expect(
          find.descendant(
            of: find.byType(SourceSwitchMenu),
            matching: find.byType(LinearProgressIndicator),
          ),
          findsOneWidget,
        );
        final lock = find.byKey(const Key('player-lock-private'));
        expect(
          tester.widget<FilledButton>(lock).onPressed,
          isNotNull,
          reason: 'Safety lock must not depend on completing catalogue IO',
        );
        await tester.tap(lock);
        for (
          var frame = 0;
          frame < 100 && f.auth.regionAccess.state != PrivateAccessState.locked;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(f.auth.regionAccess.state, PrivateAccessState.locked);
        expect(
          adapter.gate.isCompleted,
          isFalse,
          reason: 'Lock completed independently of stalled source IO',
        );
        expect(backend.isPlaying, isFalse);
        // Revocation removes the redacted imperative dialog on the next frame.
        await _settle(tester);
        expect(find.byType(SourceSwitchMenu), findsNothing);
        expect(adapter.gate.isCompleted, isFalse);
        adapter.gate.complete();
        await _settle(tester);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 29));
        await _settle(tester);
        expect(f.history.records(AccessRegion.private), isEmpty);
        expect(find.textContaining('来源 B'), findsNothing);
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
    testWidgets(
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
            runTimeTicks: 1200000000,
          ),
        ]);
        f.b.setEpisodes('series', [
          const FakeEpisode(
            id: 'episode-b-2',
            name: 'B 第2集',
            seasonId: 'season-b',
            indexNumber: 2,
            parentIndexNumber: 1,
            runTimeTicks: 1200000000,
          ),
        ]);
        await tester.runAsync(f.open);
        addTearDown(() async => _finishRevocation(tester, f.close()));
        await tester.runAsync(() async {
          for (final id in [f.aId, f.bId]) {
            await f.auth.sources.configureScope(
              id,
              participates: true,
              libraryIds: {'view-tv'},
            );
          }
        });
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final a = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(
            f.aId,
            region: AccessRegion.ordinary,
            libraryId: 'view-tv',
          ),
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
              regionGeneration: f.auth.sources.permit(a).regionGeneration,
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
        if (!environment.isTv) {
          await tester.tap(find.byKey(const Key('mobile-player-more')));
          await _settle(tester);
        }
        await tester.ensureVisible(
          find.byKey(const Key('player-manual-switch')),
        );
        await tester.tap(find.byKey(const Key('player-manual-switch')));
        await _settle(tester);
        expect(find.byType(SourceSwitchMenu), findsOneWidget);
        final mapping = find.byKey(ValueKey('switch-episode-map-${f.bId}'));
        await tester.ensureVisible(mapping);
        await tester.tap(mapping);
        await _settle(tester);
        await tester.tap(find.byKey(const Key('episode-mapping-confirm')));
        await _settle(tester);
        final version = find.byKey(
          ValueKey('switch-target-${f.bId}-episode-b-2'),
        );
        expect(version, findsOneWidget);
        await tester.ensureVisible(version);
        await tester.tap(version);
        await _settle(tester);
        if (c.switchConfirmation != null) {
          if (c.switchConfirmation!.audioNeedsChoice) {
            await tester.ensureVisible(find.byType(CheckboxListTile).first);
            await tester.tap(find.byType(CheckboxListTile).first);
          }
          if (c.switchConfirmation!.subtitleNeedsChoice) {
            await tester.ensureVisible(find.byType(CheckboxListTile).last);
            await tester.tap(find.byType(CheckboxListTile).last);
          }
          await _settle(tester);
          await tester.ensureVisible(find.text('从头播放'));
          await tester.tap(find.text('从头播放'));
          await _settle(tester);
        }
        expect(c.origin!.source.itemId, 'episode-b-2');
        expect(c.origin!.source.account.configuredServerId, f.bId);
        expect(
          f.history
              .records(AccessRegion.ordinary)
              .every((r) => r.source.itemId != 'episode-b-2'),
          isTrue,
        );
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 11));
        await _settle(tester);
        expect(c.activeMediaSourceId, 'episode-b-2');
        final receipt = f.history.records(AccessRegion.ordinary).first;
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
    testWidgets(
      '${environment.presentation.name} covered B detail revocation preserves actual A player and source-owned reports',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        await tester.runAsync(() async {
          await f.auth.setPrivatePin('1234', '1234');
          await f.auth.regionAccess.unlock('1234');
          await f.auth.switchTo(f.bId);
        });
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final a = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(
            f.aId,
            region: AccessRegion.ordinary,
            libraryId: 'view-movies',
          ),
        ))!;
        final b = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(
            f.bId,
            region: AccessRegion.ordinary,
            libraryId: 'view-movies',
          ),
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
              regionGeneration: f.auth.sources.permit(b).regionGeneration,
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
              regionGeneration: f.auth.sources.permit(a).regionGeneration,
            ),
          ),
        );
        await _settle(tester);
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 7));
        await _settle(tester);
        expect(backend.isPlaying, isTrue);
        expect(
          f.history
              .records(AccessRegion.ordinary)
              .single
              .source
              .account
              .configuredServerId,
          f.aId,
        );
        late Future<void> moving;
        await tester.runAsync(() async {
          moving = f.auth.sources.move(f.bId, AccessRegion.private);
        });
        await _finishRevocation(tester, moving);
        await _settle(tester);
        expect(
          f.auth.isLoggedIn,
          isFalse,
          reason: 'Selected B was revoked, not actual A',
        );
        expect(app.router.state.uri.path, '/play/shared-id');
        expect(backend.isPlaying, isTrue);
        expect(
          find.byType(environment.isTv ? TvPlayerPage : MobilePlayerPage),
          findsOneWidget,
        );
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 11));
        await _settle(tester);
        final record = f.history.records(AccessRegion.ordinary).single;
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
          revokingA = f.auth.sources.configureScope(
            f.aId,
            participates: false,
            libraryIds: {'view-movies'},
          );
        });
        await _finishRevocation(tester, revokingA);
        await _settle(tester);
        expect(backend.isPlaying, isFalse);
        expect(app.router.state.uri.path, '/connect');
        backend.emitEvent(VideoEventKind.position, const Duration(seconds: 29));
        await _settle(tester);
        expect(f.history.records(AccessRegion.ordinary), isEmpty);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} decoded private extras cannot revive after lock unlock or forged account restore',
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
        addTearDown(f.close);
        await tester.runAsync(() async {
          await f.auth.setPrivatePin('1234', '1234');
          await f.auth.regionAccess.unlock('1234');
          await f.auth.sources.rename(f.bId, '私密不可恢复名');
          await f.auth.sources.move(f.bId, AccessRegion.private);
        });
        final account = (await tester.runAsync(
          () => f.auth.sources.acquireAccount(
            f.bId,
            region: AccessRegion.private,
            libraryId: 'view-movies',
          ),
        ))!;
        final source = SourceReference(
          account: account,
          itemId: 'shared-id',
          mediaSourceId: 'private-version',
        );
        final generation = f.auth.sources.permit(account).regionGeneration;
        const codec = SourceRouteExtraCodec();
        Object? restore(Object? extra) =>
            codec.decode(jsonDecode(jsonEncode(codec.encode(extra))));
        final detail =
            restore(
                  PlayerHostOpenItemCommand(
                    itemId: 'shared-id',
                    source: source.item,
                    libraryId: 'view-movies',
                    regionGeneration: generation,
                  ),
                )
                as PlayerHostOpenItemCommand;
        final request =
            restore(
                  PlayerOpenRequest(
                    itemId: 'shared-id',
                    source: source,
                    libraryId: 'view-movies',
                    regionGeneration: generation,
                    mediaSourceId: 'private-version',
                    startTimeTicks: 70000000,
                  ),
                )
                as PlayerOpenRequest;
        final backend = FakeVideoBackend();
        final app = f.app(environment, backend: backend);
        await tester.pumpWidget(app);
        await _settle(tester);
        app.router.go('/item/shared-id', extra: detail);
        await _settle(tester);
        expect(find.byType(SourceDetailGate), findsOneWidget);
        await tester.runAsync(() => f.auth.regionAccess.lock());
        await _settle(tester);
        expect(app.router.canPop(), isFalse);
        expect(app.router.routerDelegate.currentConfiguration.extra, isNull);
        expect(find.textContaining('私密不可恢复名'), findsNothing);
        await tester.runAsync(() => f.auth.regionAccess.unlock('1234'));
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
        expect(find.byType(SourceDetailGate), findsNothing);
        app.router.go('/play/shared-id', extra: request);
        await _settle(tester);
        expect(app.router.state.uri.path.startsWith('/play/'), isFalse);
        expect(backend.openCount, 0);
        final forged =
            restore(
                  PlayerOpenRequest(
                    itemId: 'shared-id',
                    source: SourceReference(
                      account: SourceAccount(
                        region: AccessRegion.private,
                        configuredServerId: account.configuredServerId,
                        verifiedServerId: 'forged-server',
                        userId: account.userId,
                      ),
                      itemId: 'shared-id',
                    ),
                    libraryId: 'view-movies',
                    regionGeneration: f.auth.regionAccess.generation,
                  ),
                )
                as PlayerOpenRequest;
        app.router.go('/play/shared-id', extra: forged);
        await _settle(tester);
        expect(app.router.state.uri.path.startsWith('/play/'), isFalse);
        expect(backend.openCount, 0);
        await tester.binding.handlePopRoute();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await _settle(tester);
        expect(find.textContaining('私密不可恢复名'), findsNothing);
        expect(find.byType(SourceDetailGate), findsNothing);
        expect(backend.openCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
      },
      tags: ['integration'],
    );
  }

  testWidgets(
    'revoked detail cleanup cannot erase a new different-source navigation in the same frame',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      await tester.runAsync(() async {
        await f.auth.regionAccess.setPin('1234', '1234', (_) async {});
        await f.auth.regionAccess.unlock('1234');
        await f.auth.sources.move(f.bId, AccessRegion.private);
      });
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/private');
      await _settle(tester);
      await tester.ensureVisible(find.text('合成作品'));
      await tester.pump();
      await tester.tap(find.text('合成作品'));
      await _settle(tester);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(
        DetailSourceScope.maybeOf(
          tester.element(find.byType(ItemDetailPage)),
        )!.source.account.configuredServerId,
        f.bId,
      );
      final account = (await tester.runAsync(
        () => f.auth.sources.acquireAccount(
          f.aId,
          region: AccessRegion.ordinary,
          libraryId: 'view-movies',
        ),
      ))!;
      await tester.runAsync(() => f.auth.regionAccess.lock());
      final command = PlayerHostOpenItemCommand(
        itemId: 'shared-id',
        source: SourceReference(account: account, itemId: 'shared-id'),
        libraryId: 'view-movies',
        regionGeneration: f.auth.sources.permit(account).regionGeneration,
      );
      // No frame between revocation and this explicit new navigation.
      app.router.go('/item/shared-id', extra: command);
      await _settle(tester);
      expect(app.router.state.uri.path, '/item/shared-id');
      expect(
        app.router.routerDelegate.currentConfiguration.extra,
        same(command),
      );
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(
        DetailSourceScope.maybeOf(
          tester.element(find.byType(ItemDetailPage)),
        )!.source.account.configuredServerId,
        f.aId,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  testWidgets(
    'real desktop optional single service search clears old scope and ordinary projection hides unlocked private membership',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/search');
      await _settle(tester);
      expect(find.text('输入片名后搜索'), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
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
      expect(find.text('来源 A'), findsOneWidget);
      expect(find.text('来源 B'), findsOneWidget);
      await tester.runAsync(() async {
        await f.auth.regionAccess.setPin('1234', '1234', (_) async {});
        await f.auth.regionAccess.unlock('1234');
        await f.auth.sources.rename(f.bId, '秘密名称地址');
        await f.auth.sources.move(f.bId, AccessRegion.private);
      });
      await _settle(tester);
      expect(find.textContaining('秘密名称地址'), findsNothing);
      expect(find.byKey(ValueKey('aggregation-source-${f.bId}')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('aggregation-keyword')))
            .controller!
            .text,
        '合成',
      );
      expect(find.text('来源 A'), findsOneWidget);
      expect(find.text('来源 B'), findsNothing);
      await tester.runAsync(() => f.auth.regionAccess.lock());
      await _settle(tester);
      expect(find.text('来源 A'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
}
