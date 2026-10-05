import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
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
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/aggregation/query/aggregation_query.dart'
    show SourceReference;
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/mobile_player_page.dart';
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

class _Series extends FakeEmbyItem {
  _Series()
    : super(id: 'series', name: '合成剧集', type: 'Series', parentId: 'view-tv');
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'ProviderIds': {'Tmdb': '77'},
  };
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
  Future<void> open({bool configure = true, HistoryStore? historyStore}) async {
    adapter = FakeEmbyAdapter([a, b]);
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
  }) => RillightApp(
    auth: auth,
    environment: environment,
    playerBindings: PlayerBindings(
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
      await tester.ensureVisible(find.text('查找同源 · 2'));
      await tester.pump();
      await tester.tap(find.text('查找同源 · 2'));
      await _settle(tester);
      await tester.tap(find.textContaining('已确认来源'));
      await _settle(tester);
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
      await tester.ensureVisible(find.text('查找同源 · 2'));
      await tester.pump();
      await tester.tap(find.text('查找同源 · 2'));
      await _settle(tester);
      await tester.tap(find.textContaining('已确认来源'));
      await _settle(tester);
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
          (r) =>
              r.contains('/Shows/NextUp') && r.contains('ParentId=view-movies'),
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
                r.contains('SortBy=DateCreated'),
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
      await tester.ensureVisible(find.text('查找同源 · 2'));
      await tester.pump();
      await tester.tap(find.text('查找同源 · 2'));
      await _settle(tester);
      await tester.tap(find.textContaining('已确认来源'));
      await _settle(tester);
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
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _settle(tester);
      expect(
        find.byType(ItemDetailPage),
        findsNothing,
      ); // TV uses its own detail tree.
      expect(find.byType(DetailSourceScope), findsWidgets);
      app.router.pop();
      await _settle(tester);
      expect(FocusManager.instance.primaryFocus, same(control));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(FocusManager.instance.primaryFocus, same(control));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      final compareNode = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _settle(tester);
      expect(find.byType(Dialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(compareNode));
      for (var i = 0; i < 6; i++) {
        if (FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<FilterChip>() !=
            null) {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await _settle(tester);
      }
      final chip = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<FilterChip>();
      expect(chip, isNotNull);
      for (var i = 0; i < 3; i++) {
        if (FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<FilterChip>()
                ?.key ==
            ValueKey('aggregation-source-${f.bId}')) {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await _settle(tester);
      }
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FilterChip>()
            ?.key,
        ValueKey('aggregation-source-${f.bId}'),
      );
      final chipNode = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _settle(tester);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(FocusManager.instance.primaryFocus, same(chipNode));
      }
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(ValueKey('aggregation-source-${f.bId}')),
            )
            .selected,
        isFalse,
      );
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
      await _settle(tester);
      await tester.ensureVisible(find.text('合成作品').last);
      await tester.pump();
      await tester.tap(find.text('合成作品').last);
      await _settle(tester);
      expect(input, findsNothing);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      app.router.pop();
      await _settle(tester);
      expect(find.text('查找同源 · 2'), findsOneWidget);
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
      '${environment.presentation.name} real entry merges allowed sources, filters first, and keeps successful sibling on retry',
      (tester) async {
        isolateImageCache();
        final f = _Fixture();
        await tester.runAsync(f.open);
        addTearDown(f.close);
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
        expect(find.text('查找同源 · 2'), findsOneWidget);
        final bFilter = find.byKey(ValueKey('aggregation-source-${f.bId}'));
        if (environment.isTv) {
          final focus = find
              .descendant(of: bFilter, matching: find.byType(Focus))
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
          await tester.tap(bFilter);
        }
        await _settle(tester);
        expect(find.text('查找同源 · 1'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('aggregation-source-${f.aId}')));
        await _settle(tester);
        expect(find.text('未选择可参与的服务或媒体库'), findsOneWidget);
        f.b.itemsStatus = 503;
        await tester.tap(find.widgetWithText(FilterChip, '全部普通来源'));
        await _settle(tester);
        expect(find.text('部分来源失败，已保留成功结果'), findsOneWidget);
        expect(find.textContaining('已加载作品: 1'), findsOneWidget);
        f.b.itemsStatus = null;
        await tester.ensureVisible(find.text('重试此来源'));
        await tester.pump();
        await tester.tap(find.text('重试此来源'));
        await _settle(tester);
        await tester.scrollUntilVisible(
          find.text('查找同源 · 2'),
          120,
          scrollable: find
              .descendant(
                of: find.byType(AggregationPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.text('查找同源 · 2'), findsOneWidget);
        await tester.ensureVisible(find.text('查找同源 · 2'));
        await tester.pump();
        await tester.tap(find.text('查找同源 · 2'));
        await _settle(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(FocusManager.instance.primaryFocus, isNotNull);
        app.router.go('/library/view-movies');
        await _settle(tester);
        expect(find.byType(AggregationPage), findsOneWidget);
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
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, '继续观看'));
      await _settle(tester);
      final resume = find.byTooltip('从本机记录的实际来源继续');
      expect(resume, findsNothing);
      await tester.runAsync(
        () => f.history.observe(
          session: session,
          eventSequence: 1,
          positionTicks: 170000000,
          actuallyPlaying: true,
          timeline: const WatchTimeline(durationTicks: 600000000),
        ),
      );
      await _settle(tester);
      expect(resume, findsOneWidget);
      await tester.ensureVisible(resume);
      await tester.pump();
      await tester.tap(resume);
      await _settle(tester);
      expect(host.current!.source, source);
      expect(host.current!.work, source.item);
      expect(host.current!.libraryId, 'view-movies');
      expect(host.current!.startTimeTicks, 170000000);
      expect(host.current!.mediaSourceId, 'recorded-version');
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
      f.b.items.first.playbackPositionTicks = 350000000;
      f.b.items.first.overview = 'B续播来源';
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, '继续观看'));
      await _settle(tester);
      await tester.ensureVisible(find.text('合成作品'));
      await tester.pump();
      await tester.tap(find.text('合成作品'));
      await _settle(tester);
      expect(find.textContaining('不取最大进度'), findsOneWidget);
      expect(find.text('来源 A · 15s'), findsOneWidget);
      expect(find.text('来源 B · 35s'), findsOneWidget);
      expect(find.byType(ItemDetailPage), findsNothing);
      await tester.tap(find.text('来源 B · 35s'));
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

  testWidgets(
    'library scope navigation after expanding source libraries cannot restore panel bool as scroll offset',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/library/view-movies');
      await _settle(tester);
      await tester.tap(find.text('媒体库范围'));
      await _settle(tester);
      app.router.go('/library/view-tv');
      await _settle(tester);
      expect(find.text('未选择可参与的服务或媒体库'), findsOneWidget);
      expect(find.text('查找同源 · 1'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );

  testWidgets(
    'legacy detail with unknown participating libraries refuses dispatch rather than falling back to auth',
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
      expect(find.byType(ItemDetailPage), findsNothing);
      expect(
        f.a.requests.where(
          (r) => r.contains('/Users/user-alice/Items/shared-id'),
        ),
        isEmpty,
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
    'comparison enters actual B detail, returning restores scope, and legacy detail resolves only allowed A',
    (tester) async {
      isolateImageCache();
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.close);
      f.b.items.first.overview = 'B实际来源正文';
      final app = f.app(PresentationEnvironment.desktop);
      await tester.pumpWidget(app);
      await _settle(tester);
      app.router.go('/aggregation');
      await _settle(tester);
      await tester.ensureVisible(find.text('查找同源 · 2'));
      await tester.pump();
      await tester.tap(find.text('查找同源 · 2'));
      await _settle(tester);
      expect(find.textContaining('已确认来源'), findsOneWidget);
      await tester.tap(find.textContaining('已确认来源'));
      await _settle(tester);
      expect(find.text('B实际来源正文'), findsOneWidget);
      final origin = DetailSourceScope.maybeOf(
        tester.element(find.byType(ItemDetailPage)),
      );
      expect(origin!.source.account.configuredServerId, f.bId);
      expect(f.auth.session!.server.id, f.aId);
      app.router.pop();
      await _settle(tester);
      expect(find.text('查找同源 · 2'), findsOneWidget);
      app.router.go('/item/shared-id');
      await _settle(tester);
      expect(
        DetailSourceScope.maybeOf(
          tester.element(find.byType(ItemDetailPage)),
        )!.source.account.configuredServerId,
        f.aId,
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
      app.router.go('/aggregation');
      await _settle(tester);
      await tester.ensureVisible(find.text('查找同源 · 1').first);
      await tester.pump();
      await tester.tap(find.text('查找同源 · 1').first);
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
      app.router.go('/item/episode');
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
      await tester.runAsync(() => f.auth.regionAccess.unlock('1234'));
      await _settle(tester);
      expect(find.textContaining('私密来源名'), findsNothing);
      expect(find.byType(ItemDetailPage), findsNothing);
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
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        '合成',
      );
      await _settle(tester);
      expect(find.text('查找同源 · 1'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, '全部普通来源'));
      await _settle(tester);
      expect(find.text('查找同源 · 2'), findsOneWidget);
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
        isEmpty,
      );
      expect(find.text('查找同源 · 2'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('aggregation-keyword')),
        '合成',
      );
      await _settle(tester);
      expect(find.text('查找同源 · 1'), findsOneWidget);
      await tester.runAsync(() => f.auth.regionAccess.lock());
      await _settle(tester);
      expect(find.text('查找同源 · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    },
    tags: ['integration'],
  );
}
