import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';

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
    final auth = SyntheticSourceAuth(
      adapter: FakeEmbyAdapter([server]),
      device: const EmbyDeviceInfo(
        clientName: 'test',
        deviceName: 'tv',
        deviceId: 'tv-widget',
        version: '1',
      ),
      libraryIds: {
        'view-movies',
        'view-tv',
        'view-mixed',
        'view-untyped',
        'view-music',
        'view-photos',
      },
    );
    final runtime = (await tester.runAsync(auth.runtime))!;
    final backend = FakeVideoBackend();
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
      playerBindings: PlayerBindings(
        runtime: runtime,
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
      var closed = false;
      unawaited(runtime.history.close().then((_) => closed = true));
      for (var frame = 0; frame < 60 && !closed; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue, reason: 'History teardown exceeded six seconds');
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
    // User-Agent 与提交之间隔了外观三态行,多按一次向下才到提交。
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byType(TvShell), findsOneWidget);
  }

  Finder focusedAction() {
    final explicit = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.focused == true &&
          w.properties.button == true,
    );
    if (explicit.evaluate().isNotEmpty) return explicit;
    // Aggregation's Material controls own real FocusNodes without exporting
    // TvAction's explicit Semantics widget. Inspect the actual focused subtree.
    final context = FocusManager.instance.primaryFocus?.context;
    return context == null ? explicit : find.byWidget(context.widget);
  }

  String focusedLabel(WidgetTester tester) {
    final focused = FocusManager.instance.primaryFocus?.context;
    Element? button;
    focused?.visitAncestorElements((element) {
      if (element.widget is TextButton) {
        button = element;
        return false;
      }
      return true;
    });
    return tester
        .widgetList<Text>(
          find.descendant(
            of: button == null
                ? focusedAction()
                : find.byWidget(button!.widget),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .join(' ');
  }

  bool focusedWithin(Finder target) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final targets = target.evaluate().toSet();
    var found = targets.contains(focused);
    focused.visitAncestorElements((element) {
      if (targets.contains(element)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  Future<void> focusTarget(
    WidgetTester tester,
    Finder target,
    String title,
  ) async {
    for (var frame = 0; frame < 40 && !focusedWithin(target); frame++) {
      var direction = LogicalKeyboardKey.arrowDown;
      final focus = FocusManager.instance.primaryFocus;
      if (target.evaluate().isNotEmpty && focus?.context != null) {
        final destination = tester.getRect(target).center;
        final current = focus!.rect.center;
        final delta = destination - current;
        direction = delta.dy.abs() > delta.dx.abs()
            ? (delta.dy > 0
                  ? LogicalKeyboardKey.arrowDown
                  : LogicalKeyboardKey.arrowUp)
            : (delta.dx > 0
                  ? LogicalKeyboardKey.arrowRight
                  : LogicalKeyboardKey.arrowLeft);
      }
      await key(tester, direction);
    }
    expect(
      focusedWithin(target),
      isTrue,
      reason: 'Focused ${focusedLabel(tester)}, not concrete title $title',
    );
  }

  Future<void> focusTitle(WidgetTester tester, String title) =>
      focusTarget(tester, find.widgetWithText(TextButton, title), title);

  testWidgets('snapshot recovery retry is reachable from navigation', (
    tester,
  ) async {
    final server = FakeEmbyServer(), store = _FailingRecoveryStore();
    await start(tester, server, snapshotStore: store);
    await login(tester, server);
    expect(find.text('上次播放进度同步失败，请重试。'), findsOneWidget);
    expect(focusedLabel(tester), '重试');
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedLabel(tester), isNot('重试'));
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), '重试');
    store.fail = false;
    await key(tester, LogicalKeyboardKey.select);
    expect(store.reads, 2);
    expect(find.text('上次播放进度同步失败，请重试。'), findsNothing);
    expect(focusedAction(), findsOneWidget);
    expect(focusedLabel(tester), isNotEmpty);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'remote login browse play seek tracks back restores exact source card',
    (tester) async {
      final server = FakeEmbyServer();
      final (_, backend) = await start(tester, server);
      await login(tester, server);
      expect(focusedLabel(tester), '首页');
      await key(tester, LogicalKeyboardKey.arrowDown);
      // Pane entry now directly focuses its first registered remote action.
      // 横幅主操作行是「播放」在前、「详情」在后;向右一步到详情。
      expect(
        find.descendant(
          of: find.byKey(TvHomeKeys.featuredPlay),
          matching: focusedAction(),
        ),
        findsOneWidget,
      );
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(
        find.descendant(
          of: find.byKey(TvHomeKeys.featuredOpen),
          matching: focusedAction(),
        ),
        findsOneWidget,
      );
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
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const Key('tv-player-panel')), findsOneWidget);
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

  testWidgets(
    'remote search retains query and returns to home from destination',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowDown);
      // Down enters the registered keyword editor; Select on nav only selects.
      await edit(tester, 'Inception');
      expect(find.textContaining('Inception'), findsWidgets);
      await focusTitle(tester, 'Inception');
      expect(focusedLabel(tester), contains('Inception'));
      final resultLabel = focusedLabel(tester);
      final resultFocus = FocusManager.instance.primaryFocus;
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvDetailPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.textContaining('Inception'), findsWidgets);
      expect(FocusManager.instance.primaryFocus, same(resultFocus));
      expect(focusedLabel(tester), resultLabel);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focusedLabel(tester), '首页');
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'catalog removes focused card and remote recovers a visible target',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      await key(tester, LogicalKeyboardKey.arrowDown);
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
    'remote aggregation type popup keeps focus during catalog refresh and pagination restores a target',
    (tester) async {
      final server = FakeEmbyServer(
        items: [
          for (var i = 0; i < 61; i++)
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
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(AggregationPage), findsOneWidget);
      // Down enters the registered year field; its type dropdown is above.
      await key(tester, LogicalKeyboardKey.arrowDown);
      final types = find.widgetWithText(DropdownButton<String>, '全部类型');
      for (var step = 0; step < 8 && !focusedWithin(types); step++) {
        await key(tester, LogicalKeyboardKey.arrowLeft);
      }
      expect(focusedWithin(types), isTrue);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('电影'), findsWidgets);
      expect(focusedAction(), findsOneWidget);
      final dialogFocus = FocusManager.instance.primaryFocus;
      unawaited(catalog.reload(showCachedFirst: false));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(dialogFocus));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AggregationPage), findsOneWidget);
      final more = find.widgetWithText(TextButton, '加载此来源更多');
      // Catalogue/source reload also performs real asynchronous history IO.
      for (var frame = 0; frame < 60 && more.evaluate().isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(more, findsOneWidget);
      await focusTarget(tester, more, '加载此来源更多');
      expect(focusedLabel(tester), '加载此来源更多');
      await key(tester, LogicalKeyboardKey.select);
      for (var frame = 0; frame < 60 && more.evaluate().isNotEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.textContaining('已加载作品: 61'), findsOneWidget);
      expect(more, findsNothing);
      expect(focusedAction(), findsOneWidget);
      expect(focusedLabel(tester), isNot('加载此来源更多'));
      // Sliver cards are lazy; remote traversal must bring the new final row
      // into view, rather than asserting an off-screen card was built eagerly.
      for (
        var step = 0;
        step < 80 && find.textContaining('Catalog 60').evaluate().isEmpty;
        step++
      ) {
        await key(tester, LogicalKeyboardKey.arrowDown);
        // New lazy cards validate their complete source through real async IO.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('Catalog 60'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('remote library poster focus returns to the opened item', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    await start(tester, server);
    await login(tester, server);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byType(AggregationPage), findsOneWidget);
    await focusTitle(tester, 'Inception');
    expect(focusedLabel(tester), contains('Inception'));
    final card = FocusManager.instance.primaryFocus;
    final label = focusedLabel(tester);
    expect(label, isNotEmpty);
    expect(label, isNot('筛选'));
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byType(TvDetailPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AggregationPage), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, same(card));
    expect(focusedLabel(tester), label);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
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
