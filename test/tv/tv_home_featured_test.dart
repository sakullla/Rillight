import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(isolateImageCache);
  Future<RillightApp> start(WidgetTester tester, FakeEmbyServer server) async {
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
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
      playerBindings: PlayerBindings(
        createBackend: () => FakeVideoBackend(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
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
    return app;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
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

  String featuredIndicator(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>()
      .firstWhere((data) => RegExp(r'^\d+ / \d+$').hasMatch(data));

  testWidgets(
    'featured switches manually with focus pinned to controls and never auto-advances',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      expect(find.byKey(TvHomeKeys.featured), findsOneWidget);
      final initial = featuredIndicator(tester);
      expect(initial, startsWith('1 / '));
      final count = int.parse(initial.substring(4));
      expect(count, greaterThan(1));

      final next = find.byKey(TvHomeKeys.featuredNext);
      expect(next, findsOneWidget);
      // Activate once; activation refocuses the control.
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(featuredIndicator(tester), '2 / $count');
      expect(
        find.descendant(of: next, matching: focusedAction()),
        findsOneWidget,
      );

      // Rapid consecutive confirmations outpace the crossfade; focus must stay
      // on the same control and the index must still advance deterministically.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(featuredIndicator(tester), '4 / $count');
      expect(
        find.descendant(of: next, matching: focusedAction()),
        findsOneWidget,
        reason: 'Rapid switching must not drop or move focus',
      );

      // No automatic rotation while idling.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(featuredIndicator(tester), '4 / $count');
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'focused TV action scales within 1.05-1.1 and shows a high-contrast ring of at least 4px',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);

      await tester.tap(find.byKey(TvHomeKeys.featuredNext));
      await tester.pumpAndSettle();

      final focusedScale = tester.widget<AnimatedScale>(
        find.descendant(
          of: focusedAction(),
          matching: find.byType(AnimatedScale),
        ),
      );
      expect(focusedScale.scale, inInclusiveRange(1.05, 1.1));
      final focusedContainer = tester.widget<AnimatedContainer>(
        find.descendant(
          of: focusedAction(),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final border =
          (focusedContainer.decoration as BoxDecoration).border! as Border;
      expect(border.top.width, greaterThanOrEqualTo(4));
      expect(border.top.color, Colors.white);

      // Unfocused action stays at rest scale.
      final navScale = tester.widget<AnimatedScale>(
        find.descendant(
          of: find.byKey(const Key('tv-nav-0')),
          matching: find.byType(AnimatedScale),
        ),
      );
      expect(navScale.scale, 1.0);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('poster row restores focus to the last focused item', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    await start(tester, server);
    await login(tester, server);

    final row = find.byKey(const ValueKey('tv-row-最近更新的电影'));
    await key(tester, LogicalKeyboardKey.arrowRight);
    // D-pad down until focus enters the latest-movies row's posters; the outer
    // ListView builds the row lazily as focus scrolls it into view.
    for (
      var i = 0;
      i < 10 &&
          find
              .descendant(of: row, matching: focusedAction())
              .evaluate()
              .isEmpty;
      i++
    ) {
      await key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(find.descendant(of: row, matching: focusedAction()), findsOneWidget);

    // Move to the next poster; the row remembers it.
    await key(tester, LogicalKeyboardKey.arrowRight);
    final remembered = FocusManager.instance.primaryFocus;
    final rememberedLabel = focusedLabel(tester);
    expect(rememberedLabel, isNotEmpty);

    // Leave the row, then come back: focus lands on the remembered item, not
    // the directionally nearest one.
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(find.descendant(of: row, matching: focusedAction()), findsNothing);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(find.descendant(of: row, matching: focusedAction()), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, same(remembered));
    expect(focusedLabel(tester), rememberedLabel);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('featured section hides entirely without candidates', (
    tester,
  ) async {
    final server = FakeEmbyServer(items: []);
    await start(tester, server);
    await login(tester, server);
    expect(find.byKey(TvHomeKeys.featured), findsNothing);
    expect(find.byKey(TvHomeKeys.featuredNext), findsNothing);
    expect(find.text('暂无内容'), findsOneWidget);
    // The page stays navigable: the refresh action is a D-pad target.
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedAction(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'remote reaches featured controls, rows and refresh by D-pad only',
    (tester) async {
      final server = FakeEmbyServer();
      await start(tester, server);
      await login(tester, server);
      expect(focusedLabel(tester), '首页');

      final featured = find.byKey(TvHomeKeys.featured);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(
        find.descendant(of: featured, matching: focusedAction()),
        findsOneWidget,
        reason: 'First pane entry lands inside the featured section',
      );

      // Every vertical step keeps a live focus target down to the page bottom.
      for (var i = 0; i < 40 && focusedLabel(tester) != '刷新'; i++) {
        await key(tester, LogicalKeyboardKey.arrowDown);
        expect(focusedAction(), findsOneWidget);
      }
      expect(focusedLabel(tester), '刷新');

      // And back up into the featured section.
      for (
        var i = 0;
        i < 40 &&
            find
                .descendant(of: featured, matching: focusedAction())
                .evaluate()
                .isEmpty;
        i++
      ) {
        await key(tester, LogicalKeyboardKey.arrowUp);
        expect(focusedAction(), findsOneWidget);
      }
      expect(
        find.descendant(of: featured, matching: focusedAction()),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
