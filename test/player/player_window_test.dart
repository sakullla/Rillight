import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';
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
      createBackend: () => backend,
      window: window,
      windowHost: windowHost,
      progressInterval: const Duration(days: 1),
      controlsHideAfter: const Duration(days: 1),
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
    'play opens a second window host without replacing browse with /play',
    (tester) async {
      final auth = await pumpLoggedIn(tester);
      final app = tester.widget<RillightApp>(find.byType(RillightApp));
      await openPlayable(tester, 'movie-up');
      await waitFor(tester, find.byType(PlayerPage));
      await waitFor(tester, find.byKey(PlayerKeys.playMethod));

      expect(app.router.state.uri.path, '/item/movie-up');
      expect(app.router.state.uri.path.contains('/play'), isFalse);
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(auth.disposed, isFalse);
      expect(auth.isLoggedIn, isTrue);
    },
  );

  testWidgets(
    'closing the player window keeps AuthController and the browse app',
    (tester) async {
      final auth = await pumpLoggedIn(tester);
      final app = tester.widget<RillightApp>(find.byType(RillightApp));
      await openPlayable(tester, 'movie-up');
      await waitFor(tester, find.byType(PlayerPage));
      await waitFor(tester, find.byKey(PlayerKeys.playMethod));

      final resumeBefore = server.requests
          .where((request) => request.contains('Items/Resume'))
          .length;
      await tester.runAsync(() async {
        await app.windowHost.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));
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

      await tester.tap(find.byKey(CatalogKeys.back));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(CatalogKeys.item('movie-inception')),
      );
      await tester.tap(find.byKey(CatalogKeys.item('movie-inception')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PlayerKeys.open));
      await tester.pump();
      await waitFor(tester, find.byType(PlayerPage));
      await waitFor(tester, find.byKey(PlayerKeys.resumeContinue));

      expect(auth.disposed, isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(app.router.state.uri.path, '/item/movie-inception');
      expect(app.router.state.uri.path.contains('/play'), isFalse);
      expect(find.byType(ItemDetailPage), findsOneWidget);
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
