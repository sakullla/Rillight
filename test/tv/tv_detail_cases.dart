import '../helpers/case_shard.dart';
import '../helpers/settle.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/home/catalog_keys.dart';

import 'package:rillight/media_server/device.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump(const Duration(milliseconds: 240), EnginePhase.paint);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump(Duration.zero, EnginePhase.sendSemanticsUpdate);
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
  Future<RillightApp> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    FakeEmbyServer? alternate,
  }) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = SyntheticSourceAuth(
      adapter: FakeEmbyAdapter([server, ?alternate]),
      device: const ClientDeviceInfo(
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

  cases.testWidgets(
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

  cases.testWidgets('series link from a later episode lands on that episode', (
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
          playbackPosition: Duration(
            microseconds: (index == 12 ? minute * 5 : 0) ~/ 10,
          ),
          playedPercentage: index == 12 ? 20 : null,
          runtime: Duration(microseconds: (minute * 22) ~/ 10),
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

  cases.testWidgets(
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
          runtime: Duration(microseconds: (minute * 22) ~/ 10),
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e2',
          name: 'The One with the Resume',
          seasonId: 'season-friends-1',
          indexNumber: 2,
          parentIndexNumber: 1,
          playbackPosition: Duration(microseconds: (minute * 5) ~/ 10),
          playedPercentage: 20,
          runtime: Duration(microseconds: (minute * 22) ~/ 10),
        ),
        for (var index = 1; index <= 16; index++)
          FakeEpisode(
            id: 'episode-friends-s2e$index',
            name: 'Season Two $index',
            seasonId: 'season-friends-2',
            indexNumber: index,
            parentIndexNumber: 2,
            playbackPosition: Duration(
              microseconds: (index == 12 ? minute * 4 : 0) ~/ 10,
            ),
            playedPercentage: index == 12 ? 25 : null,
            runtime: Duration(microseconds: (minute * 22) ~/ 10),
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

  cases.testWidgets(
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
          runtime: Duration(microseconds: (minute * 22) ~/ 10),
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e2',
          name: 'The One with the Resume',
          seasonId: 'season-friends-1',
          indexNumber: 2,
          parentIndexNumber: 1,
          playbackPosition: Duration(microseconds: (minute * 5) ~/ 10),
          playedPercentage: 20,
          runtime: Duration(microseconds: (minute * 22) ~/ 10),
          primaryImageTag: 'tag-e2',
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e3',
          name: 'The Next One',
          seasonId: 'season-friends-1',
          indexNumber: 3,
          parentIndexNumber: 1,
          runtime: Duration(microseconds: (minute * 22) ~/ 10),
        ),
        for (var index = 4; index <= 40; index++)
          FakeEpisode(
            id: 'episode-friends-s1e$index',
            name: 'Episode $index',
            seasonId: 'season-friends-1',
            indexNumber: index,
            parentIndexNumber: 1,
            runtime: Duration(microseconds: (minute * 22) ~/ 10),
          ),
      ]);
      final alternate = FakeEmbyServer(
        serverId: server.serverId,
        baseUrl: Uri.parse('http://tv-alternate.test:8096'),
        items: server.items,
      );
      final app = await start(tester, server, alternate: alternate);
      await login(tester, server);
      alternate.issuedTokens.addAll(server.issuedTokens);
      final serverId = app.auth.session!.server.id;
      await tester.runAsync(
        () => app.auth.sources.setLineAddress(
          serverId,
          alternate.baseUrl.toString(),
        ),
      );
      final alternateLine = app.auth.sources.server(serverId).lines.last.id;
      await openItem(tester, app, 'series-friends');

      expect(find.byType(TvDetailPage), findsOneWidget);
      expect(find.byKey(const Key('tv-detail-backdrop')), findsOneWidget);
      expect(find.byKey(const Key('tv-detail-episodes')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('episode-friends-s1e40')),
        findsNothing,
        reason: 'Offscreen episodes must not mount every image in the season',
      );

      // 续播集是主操作,自动聚焦在播放上;按钮写明要续播哪一集。
      expect(focusedLabel(tester), '继续播放 S1E2');

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
      final currentIcon = tester.widget<Icon>(
        find.byKey(const Key('tv-episode-current')),
      );
      expect(currentIcon.color, const Color(0xffffffff));
      final disc = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.byKey(const Key('tv-episode-current')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final plate = disc.decoration as BoxDecoration;
      expect(plate.shape, BoxShape.circle);
      expect(plate.color!.a, greaterThan(0.7));
      // 分集卡标题是「N. 集名」，不再叠 S1E2 前缀。
      final title = find.text('2. The One with the Resume');
      expect(find.textContaining('S1E2 The One'), findsNothing);
      expect(
        tester.widget<Text>(title).style?.color,
        AppUiTheme.of(tester.element(title)).colorScheme.primary,
      );
      expect(
        find.descendant(of: currentTile, matching: find.byType(AppLoadingBar)),
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
      for (var playback = 0; playback < 2; playback++) {
        final before =
            detailRequests(server, 'series-friends') +
            detailRequests(alternate, 'series-friends');
        await key(tester, LogicalKeyboardKey.select);
        expect(find.byType(TvPlayerPage), findsOneWidget);
        if (playback == 1) {
          final player = tester
              .state<TvPlayerPageState>(find.byType(TvPlayerPage))
              .controller!;
          var switched = false;
          final change = player.selectPlaybackLine(
            LineSelection.fixed(alternateLine),
          );
          unawaited(change.then((_) => switched = true));
          for (var frame = 0; frame < 60 && !switched; frame++) {
            await _settle(tester);
          }
          expect(switched, isTrue);
          await change;
          expect(player.origin!.client.baseUrl, alternate.baseUrl);
          expect(app.auth.session!.server.activeLineId, alternateLine);
        }
        app.auth.publishPlaybackConnection(
          app.auth.session!.server.id,
          app.auth.client,
        );
        await _settle(tester);
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
          detailRequests(server, 'series-friends') +
              detailRequests(alternate, 'series-friends'),
          greaterThan(before),
          reason: '播放返回后详情必须重新拉取,分集进度与已看状态才刷新',
        );
        expect(
          tester
              .widget<TvAction>(find.byKey(const Key('tv-detail-play')))
              .onPressed,
          isNotNull,
        );
      }
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'remote selects an episode from the list and returns to the series',
    (tester) async {
      final server = FakeEmbyServer();
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');

      // 焦点从播放出发,纯方向键下移到分集行。按钮写明要播哪一集。
      expect(focusedLabel(tester), '播放 S1E2');
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
          matching: find.text('已看'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TvAction>(find.byKey(const Key('tv-detail-played-toggle')))
            .active,
        isTrue,
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

  cases.testWidgets(
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
      expect(tester.widget<TvAction>(toggle).active, isFalse);
      await tester.tap(toggle);
      await settle(tester);
      expect(
        server.items.firstWhere((item) => item.id == 'movie-inception').played,
        isTrue,
      );
      // 已看是开关：激活时标签写状态，按钮为 active 实底。
      expect(
        find.descendant(of: toggle, matching: find.text('已看')),
        findsOneWidget,
      );
      expect(tester.widget<TvAction>(toggle).active, isTrue);
      expect(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_Notice',
        ),
        findsOneWidget,
      );
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

  cases.testWidgets(
    'down from the action row lands on the season tabs then the episodes',
    (tester) async {
      final server = FakeEmbyServer();
      server.setSeasons('series-friends', const [
        FakeSeason(id: 'season-friends-1', name: '第 1 季', indexNumber: 1),
        FakeSeason(id: 'season-friends-2', name: '第 2 季', indexNumber: 2),
      ]);
      server.setEpisodes('series-friends', [
        for (var index = 1; index <= 12; index++)
          FakeEpisode(
            id: 'episode-friends-s1e$index',
            name: '第 $index 集 · 小小奇遇',
            seasonId: 'season-friends-1',
            indexNumber: index,
            parentIndexNumber: 1,
          ),
        const FakeEpisode(
          id: 'episode-friends-s2e1',
          name: 'Season Two',
          seasonId: 'season-friends-2',
          indexNumber: 1,
          parentIndexNumber: 2,
        ),
      ]);
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');

      // 两季放得下：直接是两个焦点标签，没有折叠入口。
      expect(find.byKey(const ValueKey('season-friends-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('season-friends-2')), findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonPicker), findsNothing);
      expect(focusedLabel(tester), startsWith('播放'));

      // 按一次「下」就到季标签，不跳过这一行。
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), '第 1 季');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), contains('小小奇遇'));

      // 分集卡标题不再重复 S1E1 与「第 N 集」。
      expect(find.textContaining('S1E1 第'), findsNothing);
      expect(find.text('第 1 集 · 小小奇遇'), findsOneWidget);

      // 分集行横向移动，焦点一直留在分集上。
      for (var step = 0; step < 6; step++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
        expect(focusedLabel(tester), contains('小小奇遇'), reason: 'step $step');
      }
      expect(focusedLabel(tester), contains('第 7 集'));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'many seasons fold into one focusable picker that opens a season list',
    (tester) async {
      final server = FakeEmbyServer();
      server.setSeasons('series-friends', [
        for (var index = 1; index <= 12; index++)
          FakeSeason(
            id: 'season-friends-$index',
            name: '第 $index 季 · 很长很长的季名',
            indexNumber: index,
          ),
      ]);
      server.setEpisodes('series-friends', [
        for (var index = 1; index <= 12; index++)
          FakeEpisode(
            id: 'episode-friends-s${index}e1',
            name: 'Season $index opener',
            seasonId: 'season-friends-$index',
            indexNumber: 1,
            parentIndexNumber: index,
          ),
      ]);
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');

      expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
      expect(find.byKey(const ValueKey('season-friends-1')), findsNothing);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), contains('第 1 季'));
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const Key('season-switcher-tv-list')), findsOneWidget);
      // 列表里当前季自动聚焦，往下一项即第 2 季。
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const Key('season-switcher-tv-list')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.seasonPicker),
          matching: find.textContaining('第 2 季'),
        ),
        findsOneWidget,
      );
      expect(find.text('1. Season 2 opener'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets('favorite button shows its active state', (tester) async {
    final server = FakeEmbyServer();
    final app = await start(tester, server);
    await login(tester, server);
    await openItem(tester, app, 'movie-inception');

    final favorite = find.byKey(const Key('tv-detail-favorite'));
    expect(favorite, findsOneWidget);
    expect(tester.widget<TvAction>(favorite).active, isFalse);
    expect(
      find.descendant(of: favorite, matching: find.text('收藏')),
      findsOneWidget,
    );
    await tester.tap(favorite);
    await _settle(tester);
    expect(
      server.items.firstWhere((item) => item.id == 'movie-inception').favorite,
      isTrue,
    );
    expect(tester.widget<TvAction>(favorite).active, isTrue);
    expect(
      find.descendant(of: favorite, matching: find.text('已收藏')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets(
    'season change keeps the drawn backdrop until the next frame is ready',
    (tester) async {
      final server = _HeldImageServer();
      server.setSeasons('series-friends', const [
        FakeSeason(
          id: 'season-friends-1',
          name: '第 1 季',
          indexNumber: 1,
          backdropImageTag: 'bd-s1',
        ),
        FakeSeason(
          id: 'season-friends-2',
          name: '第 2 季',
          indexNumber: 2,
          backdropImageTag: 'bd-s2',
        ),
      ]);
      server.setEpisodes('series-friends', const [
        FakeEpisode(
          id: 'episode-s1',
          name: '第一季开头',
          seasonId: 'season-friends-1',
          indexNumber: 1,
          parentIndexNumber: 1,
        ),
        FakeEpisode(
          id: 'episode-s2',
          name: '第二季开头',
          seasonId: 'season-friends-2',
          indexNumber: 1,
          parentIndexNumber: 2,
        ),
      ]);
      final hold = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');
      final backdrop = find.byKey(const Key('tv-detail-backdrop'));
      await _waitForBackdrop(tester, backdrop, 'season-friends-1');

      server.imageHolds['season-friends-2'] = hold;
      final next = find.byKey(const ValueKey('season-friends-2'));
      await tester.ensureVisible(next);
      await tester.tap(next);
      await _settle(tester);
      expect(_backdropItem(tester, backdrop).id, 'season-friends-1');
      expect(
        find.descendant(of: backdrop, matching: find.byType(SkeletonBlock)),
        findsNothing,
      );
      expect(
        find.text('1. 第二季开头', skipOffstage: false),
        findsOneWidget,
      );
      hold.complete();
      await _waitForBackdrop(tester, backdrop, 'season-friends-2');
      expect(
        find.descendant(of: backdrop, matching: find.byType(SkeletonBlock)),
        findsNothing,
      );

      server.failEpisodesOf = 'season-friends-1';
      final back = find.byKey(const ValueKey('season-friends-1'));
      await tester.ensureVisible(back);
      await tester.tap(back);
      await _settle(tester);
      expect(_backdropItem(tester, backdrop).id, 'season-friends-2');
      expect(find.byType(TvFailure), findsWidgets);
      expect(find.text('重试'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}

MediaItem _backdropItem(WidgetTester tester, Finder backdrop) {
  return tester
      .widget<MediaImage>(
        find.descendant(of: backdrop, matching: find.byType(MediaImage)),
      )
      .item;
}

Future<void> _waitForBackdrop(
  WidgetTester tester,
  Finder backdrop,
  String id,
) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    final drawn = tester
        .widgetList<RawImage>(
          find.descendant(of: backdrop, matching: find.byType(RawImage)),
        )
        .any((raw) => raw.image != null);
    if (drawn && _backdropItem(tester, backdrop).id == id) return;
  }
  fail('backdrop did not draw $id');
}

class _HeldImageServer extends FakeEmbyServer {
  String? failEpisodesOf;
  final imageHolds = <String, Completer<void>>{};

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final segments = options.uri.pathSegments;
    final images = segments.indexOf('Images');
    if (images > 0) {
      final hold = imageHolds[segments[images - 1]];
      if (hold != null) await hold.future;
    }
    final query = options.uri.queryParameters;
    if (failEpisodesOf != null &&
        query['IncludeItemTypes'] == 'Episode' &&
        query['ParentId'] == failEpisodesOf &&
        query['Filters'] != 'IsResumable') {
      return ResponseBody.fromString(
        'season-episodes-failed',
        500,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    }
    return super.handle(options, requestStream);
  }
}

final cases = CaseShard(2);

void mainShard(int part, int expectedParts) =>
    cases.register(part, main, expectedParts: expectedParts);
