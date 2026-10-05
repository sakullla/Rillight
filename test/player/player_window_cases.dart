import '../helpers/image_cache_fixture.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/player/playback_runtime.dart';
import '../helpers/settle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-player-window',
  version: '0.1.0',
);

class _TrackingAuth extends AuthController {
  _TrackingAuth({
    required super.client,
    required super.credentials,
    required super.servers,
    required super.sources,
  });

  var disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _FailingPlayerWindowHost extends PlayerWindowHost {
  _FailingPlayerWindowHost(this.message);

  final String message;

  @override
  PlayerOpenRequest? get current => null;

  @override
  bool get embedsPlayerInCaller => false;

  @override
  Future<void> open(PlayerOpenRequest request) async {
    throw Exception(message);
  }

  @override
  Future<void> close() async {}
}

void main() {
  setUp(isolateImageCache);
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeVideoBackend backend;
  late PlayerWindow window;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    backend = FakeVideoBackend();
    window = PlayerWindow();
  });

  PlayerBindings bindings({
    PlayerWindowHost? windowHost,
    required PlaybackRuntime runtime,
  }) {
    return PlayerBindings(
      runtime: runtime,
      createBackend: () {
        backend = FakeVideoBackend();
        return backend;
      },
      window: window,
      windowHost: windowHost,
      progressInterval: const Duration(days: 1),
      controlsHideAfter: const Duration(days: 1),
      settingsStore: MemoryPlayerSettingsStore(),
      // 不注入时 PlayerController 会以当前 pid 在 %TEMP% 落盘会话快照。
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
    );
  }

  Future<_TrackingAuth> pumpLoggedIn(
    WidgetTester tester, {
    PlayerWindowHost? windowHost,
  }) async {
    final credentials = MemoryCredentialStore();
    final store = MemoryServerListStore();
    EmbyClient client() =>
        EmbyClient(device: _device, dio: dioForFakeEmby(adapter));
    final sources = SourceSessionRegistry(
      access: RegionAccessController(),
      store: store,
      credentials: credentials,
      createClient: client,
    );
    final auth = _TrackingAuth(
      client: client(),
      credentials: credentials,
      servers: store,
      sources: sources,
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    final runtime = await tester.runAsync(() async {
      await sources.configureScope(
        auth.session!.server.id,
        participates: true,
        libraryIds: {'view-movies', 'view-tv'},
      );
      return PlaybackRuntime(
        auth: auth,
        history: await HistoryWriter.open(
          registry: sources,
          store: MemoryHistoryStore(),
        ),
      );
    });
    await tester.pumpWidget(
      RillightApp(
        auth: auth,
        playerBindings: bindings(windowHost: windowHost, runtime: runtime!),
      ),
    );
    await settle(tester);
    return auth;
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isNotEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('never found $finder');
  }

  Future<void> waitForGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('still found $finder');
  }

  Future<void> disposeApp(
    WidgetTester tester,
    RillightApp app,
    _TrackingAuth auth,
  ) async {
    await tester.runAsync(
      () => app.windowHost.close().timeout(const Duration(seconds: 5)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    app.router.dispose();
    await tester.pump();
    await tester.runAsync(
      () => app.playerBindings.runtime!.history.close().timeout(
        const Duration(seconds: 5),
      ),
    );
    auth.dispose();
  }

  Future<void> openPlayable(WidgetTester tester, String itemId) async {
    final homeTitle = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('灯川 Rillight'),
    );
    if (homeTitle.evaluate().isNotEmpty) {
      await tester.tap(homeTitle);
      await settle(tester);
    }
    await tester.tap(find.byKey(const Key('app-shell-aggregation')));
    await settle(tester);
    final title = server.items.firstWhere((item) => item.id == itemId).name;
    final gridScroll = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text(title),
      240,
      scrollable: gridScroll,
    );
    final item = find.text(title).first;
    await tester.ensureVisible(item);
    await settle(tester);
    await tester.tap(item);
    await settle(tester);
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
  }

  testWidgets(
    'closing the player window keeps AuthController and the browse app',
    (tester) async {
      final auth = await pumpLoggedIn(tester);
      final app = tester.widget<RillightApp>(find.byType(RillightApp));
      await openPlayable(tester, 'movie-up');
      await waitFor(tester, find.byType(PlayerPage));
      await waitFor(tester, find.byKey(PlayerKeys.playPause));

      final controller = tester
          .state<PlayerPageState>(find.byType(PlayerPage))
          .controller!;
      final original = controller.resolved!;
      final originalSubtitle = controller.subtitleStreamIndex;
      controller.subtitleStreamIndex = null;
      for (final subtitles in [false, true]) {
        controller.resolved = ResolvedPlayback(
          playMethod: original.playMethod,
          streamUrl: original.streamUrl,
          playSessionId: original.playSessionId,
          mediaSource: PlaybackMediaSource(
            id: original.mediaSource.id,
            mediaStreams: [
              if (subtitles)
                const MediaStreamInfo(index: 2, type: 'Subtitle', codec: 'srt'),
            ],
          ),
          itemId: original.itemId,
        );
        controller.onUserActivity();
        await tester.pump();
        expect(
          find.byKey(PlayerKeys.subtitle),
          subtitles ? findsOneWidget : findsNothing,
        );
      }
      controller.resolved = original;
      controller.subtitleStreamIndex = originalSubtitle;

      final resumeBefore = server.requests
          .where((request) => request.contains('Items/Resume'))
          .length;
      await tester.runAsync(() async {
        await app.windowHost.close();
        for (var i = 0; i < 250; i++) {
          if (server.requests
                  .where((request) => request.contains('Items/Resume'))
                  .length >
              resumeBefore) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pump();
      await waitForGone(tester, find.byType(PlayerPage));
      await settle(tester);
      expect(
        server.requests
            .where((request) => request.contains('Items/Resume'))
            .length,
        greaterThan(resumeBefore),
      );

      expect(auth.disposed, isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(() => auth.notifyListeners(), returnsNormally);
      expect(app.router.state.uri.path, '/item/movie-up');
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(find.text('飞屋环游记 (2009)'), findsOneWidget);

      final back = find.byKey(CatalogKeys.back);
      expect(back, findsOneWidget);
      final bar = tester.getRect(find.byKey(AppShell.topBarKey));
      final backCenter = tester.getCenter(back);
      expect(backCenter.dy, greaterThan(bar.top));
      expect(backCenter.dy, lessThan(bar.bottom));
      await tester.tap(back);
      await settle(tester);
      final inception = find.text('Inception');
      await tester.ensureVisible(inception.first);
      await settle(tester);
      await tester.tap(inception.first);
      await settle(tester);
      await tester.tap(find.byKey(PlayerKeys.open));
      await tester.pump();
      await waitFor(tester, find.byType(PlayerPage));
      await waitFor(tester, find.byKey(PlayerKeys.playPause));

      expect(auth.disposed, isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(app.router.state.uri.path, '/item/movie-inception');
      expect(app.router.state.uri.path.contains('/play'), isFalse);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      await disposeApp(tester, app, auth);
    },
    tags: ['integration'],
  );

  testWidgets(
    'player window create failure shows the original error and does not play',
    (tester) async {
      const message = 'CreateWindow failed: access denied';
      final auth = await pumpLoggedIn(
        tester,
        windowHost: _FailingPlayerWindowHost(message),
      );
      final app = tester.widget<RillightApp>(find.byType(RillightApp));
      await openPlayable(tester, 'movie-up');
      await tester.pump();
      await waitFor(tester, find.byKey(PlayerKeys.windowError));

      expect(find.textContaining(message), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      await disposeApp(tester, app, auth);
    },
    tags: ['integration'],
  );
}
