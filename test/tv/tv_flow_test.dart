import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(isolateImageCache);
  Future<(RillightApp, FakeVideoBackend)> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    PlaybackSessionSnapshotStore? snapshotStore,
  }) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'tv',
          deviceId: 'tv-widget',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    final backend = FakeVideoBackend();
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
      playerBindings: PlayerBindings(
        createBackend: () => backend,
        snapshotStore: snapshotStore ?? MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      auth.dispose();
    });
    return (app, backend);
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    if (key == LogicalKeyboardKey.goBack) {
      // Android's virtual Back has no physical scan code in the test simulator.
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.browserBack,
          logicalKey: LogicalKeyboardKey.goBack,
          timeStamp: Duration.zero,
        ),
      );
      HardwareKeyboard.instance.handleKeyEvent(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.browserBack,
          logicalKey: LogicalKeyboardKey.goBack,
          timeStamp: Duration.zero,
        ),
      );
    } else {
      await tester.sendKeyEvent(key);
    }
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester, String text) async {
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('tv-input-editor')), findsOneWidget);
    // Text input represents the platform IME; all application navigation is D-pad.
    await tester.enterText(find.byKey(const Key('tv-input-editor')), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<void> login(WidgetTester tester, FakeEmbyServer server) async {
    await edit(tester, server.baseUrl.toString());
    await key(tester, LogicalKeyboardKey.arrowDown);
    await edit(tester, 'alice');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await edit(tester, 'correct-horse');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byType(TvShell), findsOneWidget);
  }

  Finder focusedAction() => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.focused == true &&
        w.properties.button == true,
  );
  String focusedLabel(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(of: focusedAction(), matching: find.byType(Text)),
      )
      .map((t) => t.data)
      .join(' ');

  testWidgets('snapshot recovery retry is reachable from navigation', (
    tester,
  ) async {
    final server = FakeEmbyServer(), store = _FailingRecoveryStore();
    await start(tester, server, snapshotStore: store);
    await login(tester, server);
    expect(find.text('上次播放进度同步失败，请重试。'), findsOneWidget);
    expect(focusedLabel(tester), '重试');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), isNot('重试'));
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), '重试');
    store.fail = false;
    await key(tester, LogicalKeyboardKey.select);
    expect(store.reads, 2);
    expect(find.text('上次播放进度同步失败，请重试。'), findsNothing);
    expect(focusedAction(), findsOneWidget);
    expect(focusedLabel(tester), isNotEmpty);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('snapshot recovery repeated failure allows remote reconnection', (
    tester,
  ) async {
    final server = FakeEmbyServer(), store = _FailingRecoveryStore();
    final (app, _) = await start(tester, server, snapshotStore: store);
    await login(tester, server);
    expect(focusedLabel(tester), '重试');
    await key(tester, LogicalKeyboardKey.select);
    expect(store.reads, 2);
    expect(focusedLabel(tester), '重试');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), '连接');
    await key(tester, LogicalKeyboardKey.select);
    expect(app.auth.isLoggedIn, isFalse);
    expect(find.byKey(const Key('tv-connect-address')), findsOneWidget);
    expect(focusedAction(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'remote login browse play seek tracks back restores exact source card',
    (tester) async {
      final server = FakeEmbyServer();
      final (_, backend) = await start(tester, server);
      await login(tester, server);
      expect(focusedLabel(tester), '首页');
      await key(tester, LogicalKeyboardKey.arrowRight);
      final card = FocusManager.instance.primaryFocus;
      final label = focusedLabel(tester);
      expect(label, isNotEmpty);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvDetailPage), findsOneWidget);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvPlayerPage), findsOneWidget);
      final c = tester
          .state<TvPlayerPageState>(find.byType(TvPlayerPage))
          .controller!;
      expect(c.error, isNull);
      await key(tester, LogicalKeyboardKey.mediaPlayPause);
      expect(backend.isPlaying, isFalse);
      // Playback confirmation key and seek operate without pointer input.
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowUp);
      // Navigate up from the bottom play action to the seek target.
      expect(find.byKey(const Key('tv-player-seek')), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(backend.position, greaterThan(Duration.zero));
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TvPlayerPage), findsOneWidget);
      // Android sends both the key and platform pop for one remote Back.
      await key(tester, LogicalKeyboardKey.goBack);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TvPlayerPage), findsOneWidget);
      expect(c.controlsVisible, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(TvDetailPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(card));
      expect(focusedLabel(tester), label);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('remote Back exits after natural playback completion', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final (_, backend) = await start(tester, server);
    await login(tester, server);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.select);
    final c = tester
        .state<TvPlayerPageState>(find.byType(TvPlayerPage))
        .controller!;
    backend.completePlayback(at: c.duration);
    await tester.pumpAndSettle();
    expect(c.playbackEnded, isTrue);
    expect(c.controlsVisible, isTrue);
    await key(tester, LogicalKeyboardKey.goBack);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(TvDetailPage), findsOneWidget);
    expect(find.byType(TvPlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'remote search retains query and returns to home from destination',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await edit(tester, 'Inception');
      expect(find.text('Inception'), findsWidgets);
      await key(tester, LogicalKeyboardKey.arrowDown); // submit
      await key(tester, LogicalKeyboardKey.arrowDown); // first result
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvDetailPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.textContaining('Inception'), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focusedLabel(tester), '首页');
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'remote offline search retry and empty results retain an escape path',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowRight);
      server.searchStatus = 503;
      await edit(tester, 'Inception');
      expect(find.byType(TvFailure), findsOneWidget);
      server.searchStatus = null;
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvFailure), findsNothing);
      expect(find.text('Inception'), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focusedLabel(tester), '首页');
    },
    tags: ['integration'],
  );

  testWidgets(
    'remote authentication failure retries without retyping credentials',
    (tester) async {
      final server = FakeEmbyServer()..authenticationStatus = 503;
      await start(tester, server);
      await edit(tester, server.baseUrl.toString());
      await key(tester, LogicalKeyboardKey.arrowDown);
      await edit(tester, 'alice');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await edit(tester, 'correct-horse');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvShell), findsNothing);
      server.authenticationStatus = null;
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvShell), findsOneWidget);
    },
    tags: ['integration'],
  );

  testWidgets('remote decoder failure retries and error back exits directly', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final (_, backend) = await start(tester, server);
    await login(tester, server);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.select);
    backend.emitError('network stream interrupted');
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(focusedLabel(tester), '重试');
    final before = backend.openCount;
    await key(tester, LogicalKeyboardKey.select);
    expect(backend.openCount, before + 1);
    backend.emitError('network stream interrupted');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(TvPlayerPage), findsNothing);
    expect(find.byType(TvDetailPage), findsOneWidget);
  }, tags: ['integration']);

  testWidgets(
    'catalog removes focused card and remote recovers a visible target',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      await key(tester, LogicalKeyboardKey.arrowRight);
      final old = FocusManager.instance.primaryFocus;
      final c = CatalogScope.of(tester.element(find.byType(TvShell)));
      server.items = [];
      unawaited(c.reload(showCachedFirst: false));
      await tester.pumpAndSettle();
      expect(
        focusedAction(),
        findsOneWidget,
        reason: 'Removal repairs focus before another key',
      );
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus, isNot(same(old)));
      expect(focusedAction(), findsOneWidget);
      expect(focusedLabel(tester), isNotEmpty);
      await key(tester, LogicalKeyboardKey.select);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'expired authentication returns to remote connection with cleared secret',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, _) = await start(tester, server);
      await login(tester, server);
      server.expireAuthenticatedRequests = true;
      server.authenticationStatus = 401;
      final c = CatalogScope.of(tester.element(find.byType(TvShell)));
      unawaited(c.reload(showCachedFirst: false));
      await tester.pumpAndSettle();
      expect(app.auth.isLoggedIn, isFalse);
      expect(find.byKey(const Key('tv-connect-address')), findsOneWidget);
      expect(find.textContaining('alice'), findsWidgets);
      expect(find.textContaining('•'), findsNothing);
      expect(focusedAction(), findsOneWidget);
    },
    tags: ['integration'],
  );

  testWidgets(
    'covered collection does not steal detail focus and repairs on return',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      final catalog = CatalogScope.of(tester.element(find.byType(TvShell)));
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      final detailFocus = FocusManager.instance.primaryFocus;
      server.items = [];
      unawaited(catalog.reload(showCachedFirst: false));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(detailFocus));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focusedAction(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'credential renewal unwinds TV track dialog and its owned player route',
    (tester) async {
      final server = FakeEmbyServer();
      final (app, _) = await start(tester, server);
      await login(tester, server);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(AlertDialog), findsOneWidget);
      final dialogFocus = FocusManager.instance.primaryFocus;
      final catalog = CatalogScope.of(
        tester.element(find.byType(TvShell, skipOffstage: false)),
      );
      server.items = [];
      unawaited(catalog.reload(showCachedFirst: false));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(dialogFocus));
      server.issuedTokens.clear();
      unawaited(app.auth.client.getUser());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TvPlayerPage), findsNothing);
      expect(find.byType(TvDetailPage), findsOneWidget);
    },
    tags: ['integration'],
  );

  testWidgets(
    'remote library filter modal keeps focus during refresh and pagination restores a target',
    (tester) async {
      final server = FakeEmbyServer(
        items: [
          for (var i = 0; i < 51; i++)
            FakeEmbyItem(
              id: 'catalog-$i',
              name: 'Catalog ${i.toString().padLeft(2, '0')}',
              type: 'Movie',
              parentId: 'view-movies',
            ),
        ],
      );
      await start(tester, server);
      await login(tester, server);
      final catalog = CatalogScope.of(tester.element(find.byType(TvShell)));
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvLibraryPage), findsOneWidget);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(focusedAction(), findsOneWidget);
      final dialogFocus = FocusManager.instance.primaryFocus;
      unawaited(catalog.reload(showCachedFirst: false));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(dialogFocus));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      for (var i = 0; i < 20 && focusedLabel(tester) != '加载更多'; i++) {
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), '加载更多');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('Catalog 50'), findsOneWidget);
      expect(focusedAction(), findsOneWidget);
      expect(focusedLabel(tester), isNot('加载更多'));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}

class _FailingRecoveryStore extends MemoryPlaybackSessionSnapshotStore {
  bool fail = true;
  int reads = 0;

  @override
  Future<PlaybackSessionSnapshot?> read() async {
    reads++;
    // Let the navigation acquire focus before recovery fails, as a delayed
    // snapshot read or interrupted-session report can do in production.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (fail) throw StateError('Synthetic recovery failure');
    return null;
  }
}
