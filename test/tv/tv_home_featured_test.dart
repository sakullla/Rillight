import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/home/tv_section_prefs.dart';
import 'package:rillight/home/tv_shelf_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(() {
    isolateImageCache();
    TvSectionController.debugResetApp();
    debugResetTvSectionStore();
    PhoneHomeSectionController.debugResetApp();
  });
  Future<(RillightApp, Future<void> Function())> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    Size size = const Size(960, 540),
  }) async {
    tester.view.physicalSize = size;
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
    var disposed = false;
    Future<void> shutdown() async {
      if (disposed) {
        return;
      }
      disposed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      auth.dispose();
    }

    addTearDown(shutdown);
    return (app, shutdown);
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
    // User-Agent 与提交之间隔了外观三态行,多按一次向下才到提交。
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
      // 焦点环取主题前景色:深色主题是暖白,浅色主题是深色,均高对比。
      expect(
        border.top.color,
        Theme.of(tester.element(focusedAction())).colorScheme.onSurface,
      );

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

  testWidgets('featured hero bleeds edge to edge behind the top nav', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    await start(tester, server);
    await login(tester, server);
    final rect = tester.getRect(find.byKey(TvHomeKeys.featured));
    expect(rect.top, 0);
    expect(rect.left, 0);
    expect(rect.width, 960);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('poster row restores focus to the last focused item', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    // Two continue-watching posters, so the row has somewhere to move inside.
    // Next-up episodes now share this row; keep them out so focus stays on
    // these two posters.
    for (final item in server.items) {
      item.nextUp = false;
    }
    server.items
            .firstWhere((item) => item.id == 'movie-up')
            .playbackPositionTicks =
        1000;
    await start(tester, server);
    await login(tester, server);

    final row = find.byKey(const ValueKey('tv-row-继续观看'));
    await key(tester, LogicalKeyboardKey.arrowDown);
    // D-pad down until focus enters the continue-watching posters.
    // The first down-arrow enters beside the featured controls, so the
    // landing poster is the right-hand one.
    for (
      var i = 0;
      i < 24 &&
          find
              .descendant(of: row, matching: focusedAction())
              .evaluate()
              .isEmpty;
      i++
    ) {
      await key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedLabel(tester), '飞屋环游记');

    // Step to the other poster in this row. The shelf title is full width, so
    // a further right-arrow leaves the row instead of finding another poster.
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.descendant(of: row, matching: focusedAction()), findsOneWidget);
    expect(focusedLabel(tester), 'Inception');
    final remembered = FocusManager.instance.primaryFocus;
    final rememberedLabel = focusedLabel(tester);

    // Leave the row, then come back. Directional search prefers the poster
    // nearest the title's center; the row must restore the one we left.
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
    final server = FakeEmbyServer(items: [], views: []);
    await start(tester, server);
    await login(tester, server);
    expect(find.byKey(TvHomeKeys.featured), findsNothing);
    expect(find.byKey(TvHomeKeys.featuredNext), findsNothing);
    expect(find.text('暂无内容'), findsOneWidget);
    // The page stays navigable: the refresh action is a D-pad target.
    await key(tester, LogicalKeyboardKey.arrowDown);
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
      await key(tester, LogicalKeyboardKey.arrowDown);
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

  testWidgets(
    'tv section file is per server and does not change the phone file',
    (tester) async {
      await tester.runAsync(() async {
        final root = Directory.systemTemp.createTempSync(
          'rillight_tv_sections_',
        );
        addTearDown(() {
          if (root.existsSync()) {
            root.deleteSync(recursive: true);
          }
        });
        final phoneFile = File('${root.path}/phone_home_sections.json');
        const phoneJson =
            '{"server-a":{"order":["banner","resume"],"hidden":["nextUp"]}}';
        await phoneFile.writeAsString(phoneJson);
        final tvFile = File('${root.path}/tv_home_sections.json');
        const libraries = [
          EmbyItem(id: 'view-movies', name: '电影', type: 'CollectionFolder'),
          EmbyItem(id: 'view-tv', name: '剧集', type: 'CollectionFolder'),
        ];
        final first = TvSectionController(store: FileTvSectionStore(tvFile));
        addTearDown(first.dispose);
        await first.load('server-b');
        await first.setVisible(PhoneHomeSectionId.resume, false);
        await first.move(PhoneHomeSectionId.libraries, -3, libraries);
        final editing = TvSectionController(store: FileTvSectionStore(tvFile));
        addTearDown(editing.dispose);
        await editing.load('server-a');
        expect(editing.isHidden(PhoneHomeSectionId.banner), isFalse);
        expect(editing.orderedIds(libraries), [
          PhoneHomeSectionId.banner,
          PhoneHomeSectionId.resume,
          PhoneHomeSectionId.nextUp,
          PhoneHomeSectionId.libraries,
          PhoneHomeSectionId.libraryLatest('view-movies'),
          PhoneHomeSectionId.libraryLatest('view-tv'),
        ]);
        await editing.move(PhoneHomeSectionId.resume, 1, libraries);
        await editing.setVisible(PhoneHomeSectionId.banner, false);
        expect(editing.visibleIds(libraries).first, PhoneHomeSectionId.nextUp);
        expect(
          editing.visibleIds(libraries),
          isNot(contains(PhoneHomeSectionId.banner)),
        );
        expect(phoneFile.readAsStringSync(), phoneJson);

        final restarted = TvSectionController(
          store: FileTvSectionStore(tvFile),
        );
        addTearDown(restarted.dispose);
        await restarted.load('server-a');
        expect(restarted.isHidden(PhoneHomeSectionId.banner), isTrue);
        expect(restarted.visibleIds(libraries).take(2), [
          PhoneHomeSectionId.nextUp,
          PhoneHomeSectionId.resume,
        ]);
        await restarted.load('server-b');
        expect(restarted.isHidden(PhoneHomeSectionId.resume), isTrue);
        expect(restarted.isHidden(PhoneHomeSectionId.banner), isFalse);
        expect(
          restarted.orderedIds(libraries).first,
          PhoneHomeSectionId.libraries,
        );
        await restarted.load('server-a');
        expect(restarted.isHidden(PhoneHomeSectionId.banner), isTrue);
        expect(restarted.isHidden(PhoneHomeSectionId.resume), isFalse);

        final phone = PhoneHomeSectionController(
          store: FilePhoneHomeSectionStore(phoneFile),
        );
        addTearDown(phone.dispose);
        await phone.load('server-a');
        expect(phone.prefs.order, ['banner', 'resume']);
        expect(phone.isHidden(PhoneHomeSectionId.nextUp), isTrue);
        expect(phone.isHidden(PhoneHomeSectionId.banner), isFalse);
        expect(phoneFile.readAsStringSync(), phoneJson);
        final saved = jsonDecode(tvFile.readAsStringSync());
        expect(saved, isA<Map<String, dynamic>>());
        expect((saved as Map).keys, containsAll(['server-a', 'server-b']));
        expect(tvFile.path, endsWith('tv_home_sections.json'));
        expect(tvFile.path, isNot(endsWith('phone_home_sections.json')));
      });
    },
  );

  testWidgets(
    'moving sections keeps saved library ids when libraries are missing',
    (tester) async {
      await tester.runAsync(() async {
        final root = Directory.systemTemp.createTempSync(
          'rillight_tv_sections_missing_',
        );
        addTearDown(() {
          if (root.existsSync()) {
            root.deleteSync(recursive: true);
          }
        });
        final phoneFile = File('${root.path}/phone_home_sections.json');
        const phoneJson =
            '{"server-a":{"order":["banner","resume"],"hidden":["nextUp"]}}';
        await phoneFile.writeAsString(phoneJson);
        final tvFile = File('${root.path}/tv_home_sections.json');
        final movies = PhoneHomeSectionId.libraryLatest('view-movies');
        final shows = PhoneHomeSectionId.libraryLatest('view-tv');
        final savedOrder = [
          PhoneHomeSectionId.banner,
          movies,
          PhoneHomeSectionId.resume,
          shows,
          PhoneHomeSectionId.nextUp,
          PhoneHomeSectionId.libraries,
        ];
        await tvFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'server-a': {'order': savedOrder, 'hidden': <String>[]},
            'server-b': {
              'order': [
                PhoneHomeSectionId.libraries,
                PhoneHomeSectionId.banner,
              ],
              'hidden': [PhoneHomeSectionId.nextUp],
            },
          }),
        );
        final editing = TvSectionController(store: FileTvSectionStore(tvFile));
        addTearDown(editing.dispose);
        await editing.load('server-a');
        await editing.move(PhoneHomeSectionId.resume, 1, const <EmbyItem>[]);
        await editing.setVisible(PhoneHomeSectionId.banner, false);

        final stored = jsonDecode(tvFile.readAsStringSync());
        expect(stored, isA<Map<String, dynamic>>());
        final servers = stored as Map<String, dynamic>;
        expect(servers['server-a'], {
          'order': [
            PhoneHomeSectionId.banner,
            movies,
            PhoneHomeSectionId.nextUp,
            shows,
            PhoneHomeSectionId.resume,
            PhoneHomeSectionId.libraries,
          ],
          'hidden': [PhoneHomeSectionId.banner],
        });
        expect(servers['server-b'], {
          'order': [PhoneHomeSectionId.libraries, PhoneHomeSectionId.banner],
          'hidden': [PhoneHomeSectionId.nextUp],
        });
        expect(phoneFile.readAsStringSync(), phoneJson);

        final restarted = TvSectionController(
          store: FileTvSectionStore(tvFile),
        );
        addTearDown(restarted.dispose);
        await restarted.load('server-a');
        const libraries = [
          EmbyItem(id: 'view-movies', name: '电影', type: 'CollectionFolder'),
          EmbyItem(id: 'view-tv', name: '剧集', type: 'CollectionFolder'),
        ];
        expect(restarted.orderedIds(libraries), [
          PhoneHomeSectionId.banner,
          movies,
          PhoneHomeSectionId.nextUp,
          shows,
          PhoneHomeSectionId.resume,
          PhoneHomeSectionId.libraries,
        ]);
        expect(restarted.isHidden(PhoneHomeSectionId.banner), isTrue);
        await restarted.load('server-b');
        expect(restarted.prefs.order, [
          PhoneHomeSectionId.libraries,
          PhoneHomeSectionId.banner,
        ]);
        expect(restarted.isHidden(PhoneHomeSectionId.nextUp), isTrue);
        expect(restarted.prefs.order, isNot(contains(movies)));

        final phone = PhoneHomeSectionController(
          store: FilePhoneHomeSectionStore(phoneFile),
        );
        addTearDown(phone.dispose);
        await phone.load('server-a');
        expect(phone.prefs.order, ['banner', 'resume']);
        expect(phone.isHidden(PhoneHomeSectionId.nextUp), isTrue);
        expect(phoneFile.readAsStringSync(), phoneJson);
      });
    },
  );

  testWidgets(
    'remote moves sections up and down without changing the phone home',
    (tester) async {
      final server = FakeEmbyServer();
      _showContinueAndNext(server);
      final phone = PhoneHomeSectionController.app();
      await tester.runAsync(() => phone.load('server-id-1'));
      final (_, stop) = await start(
        tester,
        server,
        size: const Size(960, 1600),
      );
      await login(tester, server);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('tv-row-继续观看'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('tv-row-即将播放'))).dy,
        ),
      );

      await _openSectionEditor(tester);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      await _focusEditorAction(
        tester,
        TvSectionEditor.moveDownKey(PhoneHomeSectionId.resume),
      );
      await key(tester, LogicalKeyboardKey.select);
      expect(
        tester
            .getTopLeft(
              find.byKey(TvSectionEditor.tileKey(PhoneHomeSectionId.nextUp)),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(TvSectionEditor.tileKey(PhoneHomeSectionId.resume)),
              )
              .dy,
        ),
      );
      final bannerSwitch = find.byKey(
        TvSectionEditor.visibleKey(PhoneHomeSectionId.banner),
      );
      await tester.ensureVisible(bannerSwitch);
      await tester.pumpAndSettle();
      await tester.tap(bannerSwitch);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TvSectionEditor.closeKey));
      await tester.pumpAndSettle();
      final homeScroll = find
          .descendant(
            of: find.byKey(const PageStorageKey('tv-home')),
            matching: find.byType(Scrollable),
          )
          .first;
      tester.state<ScrollableState>(homeScroll).position.jumpTo(0);
      await tester.pumpAndSettle();

      expect(find.byKey(TvHomeKeys.featured), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('tv-row-即将播放'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('tv-row-继续观看'))).dy,
        ),
      );
      expect(phone.prefs.order, PhoneHomeSectionId.fixed);
      expect(phone.prefs.hidden, isEmpty);
      expect(
        TvSectionController.app().isHidden(PhoneHomeSectionId.banner),
        isTrue,
      );
      expect(phone.isHidden(PhoneHomeSectionId.banner), isFalse);

      await stop();
      TvSectionController.debugResetApp();
      final restarted = FakeEmbyServer();
      _showContinueAndNext(restarted);
      await start(tester, restarted, size: const Size(960, 1600));
      await login(tester, restarted);
      expect(find.byKey(TvHomeKeys.featured), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('tv-row-即将播放'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('tv-row-继续观看'))).dy,
        ),
      );
      expect(phone.prefs.order, PhoneHomeSectionId.fixed);
      expect(phone.prefs.hidden, isEmpty);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'a failed library row keeps the other rows operable and retryable',
    (tester) async {
      final server = FakeEmbyServer()..itemsStatus = 503;
      final (app, _) = await start(tester, server);
      await login(tester, server);
      expect(find.byKey(const ValueKey('tv-row-继续观看')), findsOneWidget);
      final moviesRetry = find.descendant(
        of: find.byKey(const Key('tv-library-view-movies')),
        matching: find.text('重试'),
      );
      final seriesRetry = find.descendant(
        of: find.byKey(const Key('tv-library-view-tv')),
        matching: find.text('重试'),
      );
      await tester.tap(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfResume)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TvShelfPage), findsOneWidget);
      app.router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(TvShelfPage), findsNothing);

      final homeScroll = find
          .descendant(
            of: find.byKey(const PageStorageKey('tv-home')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(moviesRetry, 400, scrollable: homeScroll);
      await tester.pumpAndSettle();
      expect(moviesRetry, findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('tv-library-view-tv')),
        400,
        scrollable: homeScroll,
      );
      await tester.pumpAndSettle();
      expect(seriesRetry, findsOneWidget);
      await tester.scrollUntilVisible(
        moviesRetry,
        -400,
        scrollable: homeScroll,
      );
      server.itemsStatus = null;
      // 顶部导航叠在内容之上:把目标滚到视口中央再点,避免落在导航热区。
      Scrollable.ensureVisible(tester.element(moviesRetry), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(moviesRetry);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('tv-library-view-movies')),
          matching: find.byKey(const ValueKey('tv-row-电影')),
        ),
        findsOneWidget,
      );
      expect(moviesRetry, findsNothing);
      await tester.scrollUntilVisible(seriesRetry, 400, scrollable: homeScroll);
      expect(seriesRetry, findsOneWidget);
      tester.state<ScrollableState>(homeScroll).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-row-继续观看')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}

void _showContinueAndNext(FakeEmbyServer server) {
  final current = server.items.firstWhere(
    (item) => item.id == 'episode-friends-s1e1',
  );
  current.played = false;
  current.playedPercentage = 40;
  current.playbackPositionTicks = 1000;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey logicalKey) async {
  await tester.sendKeyEvent(logicalKey);
  await tester.pumpAndSettle();
}

Future<void> _openSectionEditor(WidgetTester tester) async {
  await _press(tester, LogicalKeyboardKey.arrowDown);
  for (var i = 0; i < 48 && _focusedLabel(tester) != '编辑首页'; i++) {
    await _press(tester, LogicalKeyboardKey.arrowDown);
  }
  expect(_focusedLabel(tester), '编辑首页');
  await _press(tester, LogicalKeyboardKey.select);
  expect(find.byKey(TvSectionEditor.editorKey), findsOneWidget);
  await tester.pump();
  expect(
    find.descendant(
      of: find.byKey(TvSectionEditor.editorKey),
      matching: _focusedAction(),
    ),
    findsOneWidget,
  );
}

Future<void> _focusEditorAction(WidgetTester tester, Key keyId) async {
  final matched = find.descendant(
    of: find.byKey(keyId),
    matching: _focusedAction(),
  );
  for (var i = 0; i < 24 && matched.evaluate().isEmpty; i++) {
    await _press(tester, LogicalKeyboardKey.arrowDown);
  }
  expect(matched, findsOneWidget);
}

Finder _focusedAction() => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.focused == true &&
      widget.properties.button == true,
);

String _focusedLabel(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: _focusedAction(), matching: find.byType(Text)),
    )
    .map((text) => text.data)
    .join(' ');
