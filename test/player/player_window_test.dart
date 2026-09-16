@Tags(['integration'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/window_geometry.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:window_manager/window_manager.dart';

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

  PlayerBindings bindings({PlayerWindowHost? windowHost}) {
    return PlayerBindings(
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
    final auth = _TrackingAuth(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    await tester.pumpWidget(
      RillightApp(
        auth: auth,
        playerBindings: bindings(windowHost: windowHost),
      ),
    );
    await tester.pumpAndSettle();
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

  Future<void> openPlayable(WidgetTester tester, String itemId) async {
    final homeTitle = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('灯川 Rillight'),
    );
    if (homeTitle.evaluate().isNotEmpty) {
      await tester.tap(homeTitle);
      await tester.pumpAndSettle();
    }
    final movies = find.byKey(CatalogKeys.library('view-movies'));
    await tester.ensureVisible(movies);
    await tester.tap(movies);
    await tester.pumpAndSettle();
    final item = find.byKey(CatalogKeys.item(itemId)).first;
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
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
      await tester.pump();
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
      await tester.pumpAndSettle();
      final inception = find.byKey(CatalogKeys.item('movie-inception'));
      await tester.ensureVisible(inception.first);
      await tester.tap(inception.first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PlayerKeys.open));
      await tester.pump();
      await waitFor(tester, find.byType(PlayerPage));
      await waitFor(tester, find.byKey(PlayerKeys.playPause));

      expect(auth.disposed, isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(app.router.state.uri.path, '/item/movie-inception');
      expect(app.router.state.uri.path.contains('/play'), isFalse);
      expect(find.byType(ItemDetailPage), findsOneWidget);
    },
  );

  test(
    'player window options hide the title bar without embedding playback',
    () {
      expect(kPlayerWindowOptions.titleBarStyle, TitleBarStyle.hidden);
      expect(kPlayerWindowOptions.size, isNull);
      expect(kPlayerWindowOptions.minimumSize, kMinPlayerWindowSize);
      final auth = AuthController(
        client: EmbyClient(device: _device),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
      final host = DesktopPlayerWindowHost(auth: auth);
      expect(host.embedsPlayerInCaller, isFalse);
      host.dispose();
      auth.dispose();
    },
  );

  testWidgets(
    'player window create failure shows the original error and does not play',
    (tester) async {
      const message = 'CreateWindow failed: access denied';
      await pumpLoggedIn(tester, windowHost: _FailingPlayerWindowHost(message));
      await openPlayable(tester, 'movie-up');
      await tester.pump();
      await waitFor(tester, find.byKey(PlayerKeys.windowError));

      expect(find.textContaining(message), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.byType(ItemDetailPage), findsOneWidget);
    },
  );
}
