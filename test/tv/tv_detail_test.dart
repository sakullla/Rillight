import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/home/catalog_keys.dart';

import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

Future<void> _back(WidgetTester tester) async {
  var finished = false;
  await tester.runAsync(() async {
    unawaited(tester.binding.handlePopRoute().then((_) => finished = true));
  });
  for (var frame = 0; frame < 60 && !finished; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(finished, isTrue, reason: 'TV back dispatch exceeded six seconds');
}

void main() {
  setUp(isolateImageCache);
  Future<RillightApp> start(WidgetTester tester, FakeEmbyServer server) async {
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
      libraryIds: {'view-movies', 'view-tv', 'view-photos', 'view-untyped'},
    );
    final runtime = (await tester.runAsync(auth.runtime))!;
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
      playerBindings: PlayerBindings(
        runtime: runtime,
        createBackend: () => FakeVideoBackend(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    await tester.pumpWidget(app);
    await _settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      // History operations queued during playback belong to the fake-async
      // zone. Awaiting close inside runAsync strands those continuations.
      // Drain both fake frames and real adapter IO with a bounded budget.
      var historyClosed = false;
      unawaited(runtime.history.close().then((_) => historyClosed = true));
      for (var frame = 0; frame < 60 && !historyClosed; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(
        historyClosed,
        isTrue,
        reason: 'History teardown exceeded six seconds',
      );
      auth.dispose();
    });
    return app;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await _settle(tester);
  }

  Future<void> edit(WidgetTester tester, String text) async {
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('tv-input-editor')), findsOneWidget);
    // Text input represents the platform IME; all application navigation is D-pad.
    await tester.enterText(find.byKey(const Key('tv-input-editor')), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
  }

  Future<void> login(WidgetTester tester, FakeEmbyServer server) async {
    await edit(tester, server.baseUrl.toString());
    await key(tester, LogicalKeyboardKey.arrowDown);
    await edit(tester, 'alice');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await edit(tester, 'correct-horse');
    await key(tester, LogicalKeyboardKey.arrowDown);
    // 表单卡里 User-Agent 下面就是连接按钮;外观选项在左栏。
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byType(TvShell), findsOneWidget);
  }

  Future<void> openItem(WidgetTester tester, RillightApp app, String id) async {
    unawaited(app.router.push(AppRoutes.item(id)));
    await _settle(tester);
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

  int detailRequests(FakeEmbyServer server, String itemId) => server.requests
      .where((r) => r.startsWith('GET') && r.contains('/Items/$itemId'))
      .length;

  bool overlapsRow(WidgetTester tester, Finder tile) {
    final row = find
        .ancestor(of: tile, matching: find.byType(Scrollable))
        .first;
    return tester.getRect(tile).overlaps(tester.getRect(row));
  }

  testWidgets(
    'remote opens the current season through the episode title link',
    (tester) async {
      final server = FakeEmbyServer();
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'episode-friends-s1e1');
      expect(find.byKey(CatalogKeys.viewSeries), findsNothing);
      expect(find.byKey(CatalogKeys.seriesLink), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(
        find.descendant(
          of: focusedAction(),
          matching: find.textContaining('老友记'),
        ),
        findsOneWidget,
      );
      await key(tester, LogicalKeyboardKey.select);
      expect(app.router.state.uri.path, AppRoutes.item('series-friends'));
      expect(
        app.router.state.uri.queryParameters['season'],
        'season-friends-1',
      );
      expect(
        app.router.state.uri.queryParameters['episode'],
        'episode-friends-s1e1',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('series link from a later episode lands on that episode', (
    tester,
  ) async {
    const minute = 10000000 * 60;
    final server = FakeEmbyServer();
    server.setEpisodes('series-friends', [
      for (var index = 1; index <= 20; index++)
        FakeEpisode(
          id: 'episode-friends-s1e$index',
          name: 'Episode $index',
          seasonId: 'season-friends-1',
          indexNumber: index,
          parentIndexNumber: 1,
          playbackPositionTicks: index == 12 ? minute * 5 : 0,
          playedPercentage: index == 12 ? 20 : null,
          runTimeTicks: minute * 22,
        ),
    ]);
    final app = await start(tester, server);
    await login(tester, server);
    await openItem(tester, app, 'episode-friends-s1e12');
    expect(find.byKey(CatalogKeys.seriesLink), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowUp);
    await key(tester, LogicalKeyboardKey.select);
    expect(
      app.router.state.uri.queryParameters['episode'],
      'episode-friends-s1e12',
    );
    expect(app.router.state.uri.queryParameters['season'], 'season-friends-1');
    final target = find.byKey(const ValueKey('episode-friends-s1e12'));
    expect(target, findsOneWidget);
    expect(overlapsRow(tester, target), isTrue);
    expect(find.byKey(const ValueKey('episode-friends-s1e1')), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'season chip scrolls the episode row to that season resume episode',
    (tester) async {
      const minute = 10000000 * 60;
      final server = FakeEmbyServer();
      server.setSeasons('series-friends', const [
        FakeSeason(id: 'season-friends-1', name: '第 1 季', indexNumber: 1),
        FakeSeason(id: 'season-friends-2', name: '第 2 季', indexNumber: 2),
      ]);
      server.setEpisodes('series-friends', [
        const FakeEpisode(
          id: 'episode-friends-s1e1',
          name: 'The Pilot',
          seasonId: 'season-friends-1',
          indexNumber: 1,
          parentIndexNumber: 1,
          played: true,
          runTimeTicks: minute * 22,
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e2',
          name: 'The One with the Resume',
          seasonId: 'season-friends-1',
          indexNumber: 2,
          parentIndexNumber: 1,
          playbackPositionTicks: minute * 5,
          playedPercentage: 20,
          runTimeTicks: minute * 22,
        ),
        for (var index = 1; index <= 16; index++)
          FakeEpisode(
            id: 'episode-friends-s2e$index',
            name: 'Season Two $index',
            seasonId: 'season-friends-2',
            indexNumber: index,
            parentIndexNumber: 2,
            playbackPositionTicks: index == 12 ? minute * 4 : 0,
            playedPercentage: index == 12 ? 25 : null,
            runTimeTicks: minute * 22,
          ),
      ]);
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');
      expect(find.byKey(const ValueKey('season-friends-2')), findsOneWidget);

      // 先把详情页纵向滚开。这条偏移曾被分集横条当成自己的位置。
      final vertical = find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      );
      expect(vertical, findsOneWidget);
      final page = tester.state<ScrollableState>(vertical).position;
      expect(page.maxScrollExtent, greaterThan(120));
      page.jumpTo(160);
      await tester.pump();
      final chip = find.byKey(const ValueKey('season-friends-2'));
      await tester.ensureVisible(chip);
      await tester.pump();
      expect(page.pixels, greaterThan(40));
      await tester.tap(chip);
      await _settle(tester);

      final target = find.byKey(const ValueKey('episode-friends-s2e12'));
      expect(target, findsOneWidget);
      final row = find
          .ancestor(of: target, matching: find.byType(Scrollable))
          .first;
      final rowPixels = tester.state<ScrollableState>(row).position.pixels;
      expect(rowPixels, greaterThan(page.pixels + 400));
      expect(overlapsRow(tester, target), isTrue);
      expect(
        find.descendant(
          of: target,
          matching: find.byKey(const Key('tv-episode-current')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('episode-friends-s2e1')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'series detail shows immersive header, episode states and refreshes after remote play',
    (tester) async {
      const minute = 10000000 * 60;
      final server = FakeEmbyServer();
      server.setEpisodes('series-friends', [
        const FakeEpisode(
          id: 'episode-friends-s1e1',
          name: 'The Pilot',
          seasonId: 'season-friends-1',
          indexNumber: 1,
          parentIndexNumber: 1,
          played: true,
          runTimeTicks: minute * 22,
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e2',
          name: 'The One with the Resume',
          seasonId: 'season-friends-1',
          indexNumber: 2,
          parentIndexNumber: 1,
          playbackPositionTicks: minute * 5,
          playedPercentage: 20,
          runTimeTicks: minute * 22,
          primaryImageTag: 'tag-e2',
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e3',
          name: 'The Next One',
          seasonId: 'season-friends-1',
          indexNumber: 3,
          parentIndexNumber: 1,
          runTimeTicks: minute * 22,
        ),
        for (var index = 4; index <= 40; index++)
          FakeEpisode(
            id: 'episode-friends-s1e$index',
            name: 'Episode $index',
            seasonId: 'season-friends-1',
            indexNumber: index,
            parentIndexNumber: 1,
            runTimeTicks: minute * 22,
          ),
      ]);
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');

      expect(find.byType(TvDetailPage), findsOneWidget);
      expect(find.byKey(const Key('tv-detail-backdrop')), findsOneWidget);
      expect(find.byKey(const Key('tv-detail-episodes')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('episode-friends-s1e40')),
        findsNothing,
        reason: 'Offscreen episodes must not mount every image in the season',
      );

      // 续播集是主操作,自动聚焦在播放上。
      expect(focusedLabel(tester), '继续播放');

      // 当前集(续播目标)有可识别标识,行内带进度条;已看集有已看标记。
      final currentTile = find.byKey(const ValueKey('episode-friends-s1e2'));
      await tester.scrollUntilVisible(
        currentTile,
        200,
        scrollable: find
            .descendant(
              of: find.byType(TvDetailPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: currentTile,
          matching: find.byKey(const Key('tv-episode-current')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: currentTile,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );
      // 分集是横向一行:在分集行里往回滑到第一集。
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('episode-friends-s1e1')),
        -150,
        scrollable: find
            .ancestor(of: currentTile, matching: find.byType(Scrollable))
            .first,
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('episode-friends-s1e1')),
          matching: find.byType(EpisodeWatchedBadge),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('episode-friends-s1e1')),
          matching: find.text('已看'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('episode-friends-s1e3')),
          matching: find.byType(EpisodeWatchedBadge),
        ),
        findsNothing,
      );

      // 遥控器确认开播;返回后详情重新加载,分集进度/已看状态随刷新更新。
      // 播放器会拦截返回键(先收控制层/结束页),逐级弹出直到回到详情。
      final before = detailRequests(server, 'series-friends');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvPlayerPage), findsOneWidget);
      for (
        var i = 0;
        i < 4 && find.byType(TvDetailPage).evaluate().isEmpty;
        i++
      ) {
        await _back(tester);
        await _settle(tester);
        await tester.pump(const Duration(seconds: 4));
        await _settle(tester);
      }
      expect(find.byType(TvDetailPage), findsOneWidget);
      expect(
        detailRequests(server, 'series-friends'),
        greaterThan(before),
        reason: '播放返回后详情必须重新拉取,分集进度与已看状态才刷新',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'remote selects an episode from the list and returns to the series',
    (tester) async {
      final server = FakeEmbyServer();
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');

      // 焦点从播放出发,纯方向键下移到分集行。
      expect(focusedLabel(tester), '播放');
      for (
        var i = 0;
        i < 15 && !focusedLabel(tester).contains('The Pilot');
        i++
      ) {
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), contains('The Pilot'));
      final episodeFocus = FocusManager.instance.primaryFocus;
      final episodeLabel = focusedLabel(tester);
      await key(tester, LogicalKeyboardKey.select);

      // 单集详情:头部为集名(标题栏与头部各一处),且单集提供标记已看操作。
      expect(find.text('The Pilot'), findsWidgets);
      expect(find.byKey(const Key('tv-detail-played-toggle')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('tv-detail-played-toggle')),
          matching: find.text('标记未看'),
        ),
        findsOneWidget,
      );

      await _back(tester);
      await _settle(tester);
      expect(find.byKey(const Key('tv-detail-episodes')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(episodeFocus));
      expect(focusedLabel(tester), episodeLabel);
      expect(focusedAction(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'movie detail toggles played state optimistically and hides episode section',
    (tester) async {
      final server = FakeEmbyServer();
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'movie-inception');

      expect(find.byKey(const Key('tv-detail-backdrop')), findsOneWidget);
      // 无分集数据(电影)时分集区隐藏。
      expect(find.byKey(const Key('tv-detail-episodes')), findsNothing);
      expect(find.byKey(const ValueKey('season-friends-1')), findsNothing);

      final toggle = find.byKey(const Key('tv-detail-played-toggle'));
      expect(
        find.descendant(of: toggle, matching: find.text('标记已看')),
        findsOneWidget,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        server.items.firstWhere((item) => item.id == 'movie-inception').played,
        isTrue,
      );
      expect(
        find.descendant(of: toggle, matching: find.text('标记未看')),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);

      await tester.tap(toggle);
      await _settle(tester);
      expect(
        server.items.firstWhere((item) => item.id == 'movie-inception').played,
        isFalse,
      );
      expect(
        find.descendant(of: toggle, matching: find.text('标记已看')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
