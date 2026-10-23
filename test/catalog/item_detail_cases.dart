import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/case_shard.dart';

import 'dart:async';
import 'dart:typed_data';

import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import '../helpers/synthetic_source_fixture.dart';
import '../helpers/top_bar_hit.dart';

import 'package:dio/dio.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/episode_range_bar.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window_host.dart';

import '../emby/fake_emby_server.dart';

const _device = ClientDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-item-detail',
  version: '0.1.0',
);

const _series = 'series-friends';
const _season1 = 'season-friends-1';

/// StartIndex 大于 0 的分集窗口返回 500,用来验收继续加载失败。
class _FailingWindowServer extends FakeEmbyServer {
  bool failEpisodeWindowsAfterStart = false;

  /// 该季的分集请求一律返回 500,用来验收切季失败。
  String? failEpisodesOf;
  Completer<void>? holdSeasons, holdEpisodes, holdSimilar, holdResume;
  final episodeHolds = <String, Completer<void>>{};

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final query = options.uri.queryParameters;
    if (query['IncludeItemTypes'] == 'Season') await holdSeasons?.future;
    if (query['IncludeItemTypes'] == 'Episode') {
      if (query['Filters'] == 'IsResumable') {
        await holdResume?.future;
      } else {
        await holdEpisodes?.future;
        await episodeHolds[query['ParentId']]?.future;
      }
    }
    if (options.uri.path.endsWith('/Similar')) await holdSimilar?.future;
    if (failEpisodesOf != null &&
        query['IncludeItemTypes'] == 'Episode' &&
        query['ParentId'] == failEpisodesOf) {
      return ResponseBody.fromString(
        'season-episodes-failed',
        500,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    }
    if (failEpisodeWindowsAfterStart &&
        options.uri.path.endsWith('/Items') &&
        options.uri.queryParameters['IncludeItemTypes'] == 'Episode') {
      final start =
          int.tryParse(options.uri.queryParameters['StartIndex'] ?? '') ?? 0;
      if (start > 0) {
        return ResponseBody.fromString(
          'episode-window-failed',
          500,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        );
      }
    }
    return super.handle(options, requestStream);
  }
}

class _SilentPlayerHost extends OverlayPlayerWindowHost {
  @override
  bool get embedsPlayerInCaller => false;
}

double _detailPageOffset(WidgetTester tester) {
  final people = tester.element(find.byKey(EpisodePeopleSection.sectionKey));
  ScrollableState? page;
  people.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Scrollable &&
        (widget.axisDirection == AxisDirection.down ||
            widget.axisDirection == AxisDirection.up)) {
      page = (element as StatefulElement).state as ScrollableState;
      return false;
    }
    return true;
  });
  final scroll = page;
  expect(scroll, isNotNull);
  return scroll!.position.pixels;
}

void main() {
  setUp(isolateImageCache);
  late _FailingWindowServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = _FailingWindowServer();
    adapter = FakeEmbyAdapter([server]);
  });

  Future<RillightApp> pumpApp(
    WidgetTester tester, {
    PlayerWindowHost? host,
    Size viewSize = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = SyntheticSourceAuth(
      adapter: adapter,
      device: _device,
      libraryIds: {'view-movies', 'view-tv', 'view-mixed', 'view-untyped'},
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    final runtime = await tester.runAsync(() async => auth.runtime());
    final app = RillightApp(
      auth: auth,
      playerBindings: PlayerBindings(runtime: runtime, windowHost: host),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(runtime!.history.close);
      auth.dispose();
    });
    return app;
  }

  Future<void> openItem(
    WidgetTester tester,
    RillightApp app,
    String itemId,
  ) async {
    app.router.go(AppRoutes.item(itemId));
    await tester.pumpWidget(app);
    await settle(tester);
    expect(find.byType(ItemDetailPage), findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
  }

  /// 只泵 ItemDetailPage 本体(不带 app shell/路由),驱动其内联的
  /// 分集窗口化与继续加载。
  Future<void> pumpDetailOnly(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController(
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
      CupertinoTestApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        theme: AppUiTheme.dark(),
        home: CupertinoPageScaffold(
          child: AuthScope(
            controller: auth,
            child: const ItemDetailPage(itemId: _series),
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    await settle(tester);
    expect(find.byType(ItemDetailPage), findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
  }

  cases.testWidgets(
    'resume episode list renders while season and similar requests are held',
    (tester) async {
      final seasons = server.holdSeasons = Completer<void>();
      final similar = server.holdSimilar = Completer<void>();
      addTearDown(() {
        for (final gate in [seasons, similar]) {
          if (!gate.isCompleted) gate.complete();
        }
      });
      final app = await pumpApp(tester);
      app.router.go(AppRoutes.item('episode-friends-s1e2'));
      await tester.pumpWidget(app);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
      expect(
        tester
            .widget<MediaShelf>(
              find.byWidgetPredicate(
                (w) => w is MediaShelf && w.shelfId == 'season-episodes',
              ),
            )
            .items,
        contains(
          isA<MediaItem>().having(
            (item) => item.id,
            'id',
            'episode-friends-s1e1',
          ),
        ),
      );
      expect(seasons.isCompleted, isFalse);
      expect(similar.isCompleted, isFalse);
      seasons.complete();
      similar.complete();
      await settle(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'header, seasons and episodes render before secondary responses',
    (tester) async {
      server.setSeasons(_series, const [
        FakeSeason(id: _season1, name: '第 1 季', indexNumber: 1),
        FakeSeason(id: 'season-extra', name: '第 2 季', indexNumber: 2),
      ]);
      final seasons = server.holdSeasons = Completer<void>();
      final episodes = server.holdEpisodes = Completer<void>();
      final similar = server.holdSimilar = Completer<void>();
      final resume = server.holdResume = Completer<void>();
      addTearDown(() {
        for (final gate in [seasons, episodes, similar, resume]) {
          if (!gate.isCompleted) gate.complete();
        }
      });
      final app = await pumpApp(tester);
      app.router.go(AppRoutes.item(_series));
      await tester.pumpWidget(app);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
      expect(
        tester.widget<EpisodeList>(find.byType(EpisodeList)).episodes,
        isEmpty,
      );
      seasons.complete();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // 两季放得下:直接是两个可点的季标签,不折叠成下拉。
      expect(find.byKey(CatalogKeys.seasonTab(_season1)), findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonTab('season-extra')), findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonPicker), findsNothing);
      expect(
        tester.widget<EpisodeList>(find.byType(EpisodeList)).episodes,
        isEmpty,
      );
      resume.complete();
      episodes.complete();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(CatalogKeys.locateEpisode), findsOneWidget);
      expect(similar.isCompleted, isFalse);
      expect(
        tester.widget<EpisodeList>(find.byType(EpisodeList)).episodes,
        isNotEmpty,
      );
      similar.complete();
      await settle(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'series without resume progress targets the first unwatched episode',
    (tester) async {
      // 固定夹具：S1E1 已看、S1E2 未看，两集都没有续播进度。
      final app = await pumpApp(tester);
      await openItem(tester, app, _series);
      final play = find.byKey(PlayerKeys.open);
      expect(play, findsOneWidget);
      expect(
        find.descendant(of: play, matching: find.text('播放 S1E2')),
        findsOneWidget,
      );
      expect(
        tester.widget<EpisodeList>(find.byType(EpisodeList)).currentId,
        'episode-friends-s1e2',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'a late initial season response cannot replace a newly selected season',
    (tester) async {
      server.setSeasons(_series, const [
        FakeSeason(id: _season1, name: '第 1 季', indexNumber: 1),
        FakeSeason(id: 'season-second', name: '第 2 季', indexNumber: 2),
      ]);
      server.setEpisodes(_series, const [
        FakeEpisode(id: 'first-episode', name: 'First', seasonId: _season1),
        FakeEpisode(
          id: 'second-episode',
          name: 'Second',
          seasonId: 'season-second',
        ),
      ]);
      final gate = server.episodeHolds[_season1] = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final app = await pumpApp(tester);
      app.router.go(AppRoutes.item(_series, seasonId: _season1));
      await tester.pumpWidget(app);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final secondTab = find.byKey(CatalogKeys.seasonTab('season-second'));
      await tester.ensureVisible(secondTab);
      await tester.tap(secondTab);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        tester
            .widget<EpisodeList>(find.byType(EpisodeList))
            .episodes
            .map((e) => e.id),
        ['second-episode'],
      );
      gate.complete();
      await settle(tester);
      expect(
        tester
            .widget<EpisodeList>(find.byType(EpisodeList))
            .episodes
            .map((e) => e.id),
        ['second-episode'],
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'desktop actions are one labelled group with a single primary',
    (tester) async {
      final app = await pumpApp(tester, viewSize: const Size(1440, 900));
      await openItem(tester, app, 'movie-inception');
      final header = find.byKey(ItemDetailPage.headerKey);
      final actionRow = find.byKey(ItemDetailPage.actionRowKey);
      final buttons = tester
          .widgetList<ui.AppActionButton>(
            find.descendant(
              of: actionRow,
              matching: find.byType(ui.AppActionButton),
            ),
          )
          .toList();
      // 只有播放是 primary,且排在第一位;其余都是带字的次级按钮。
      expect(
        buttons.where((b) => b.tier == ui.AppActionTier.primary),
        hasLength(1),
      );
      expect(buttons.first.key, PlayerKeys.open);
      for (final button in buttons.skip(1)) {
        expect(button.tier, ui.AppActionTier.secondary);
        expect(button.label, isNotEmpty);
      }
      expect(
        find.descendant(of: header, matching: find.byType(ScrimIconButton)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.favoriteToggle),
          matching: find.text('收藏'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.playedToggle),
          matching: find.text('标记已看'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ui.AppActionButton>(find.byKey(CatalogKeys.favoriteToggle))
            .active,
        isFalse,
      );

      // 收藏激活后换成「已收藏」并以 active 呈现。
      await ensureVisibleBelowTopBar(
        tester,
        find.byKey(CatalogKeys.favoriteToggle),
      );
      await tapBelowTopBar(tester, find.byKey(CatalogKeys.favoriteToggle));
      await settle(tester);
      expect(
        tester
            .widget<ui.AppActionButton>(find.byKey(CatalogKeys.favoriteToggle))
            .active,
        isTrue,
      );
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.favoriteToggle),
          matching: find.text('已收藏'),
        ),
        findsOneWidget,
      );

      // 字幕在播放设置行可选,媒体信息不再重复列出;单一音轨与视频照常显示。
      expect(
        find.descendant(
          of: find.byKey(ItemDetailPage.optionRowKey),
          matching: find.byKey(CatalogKeys.detailSubtitle),
        ),
        findsOneWidget,
      );
      expect(find.byKey(CatalogKeys.detailAudio), findsNothing);
      final streams = find.byKey(EpisodeMediaStreamsSection.sectionKey);
      await tester.ensureVisible(streams);
      await settle(tester);
      expect(
        find.descendant(of: streams, matching: find.text('中文')),
        findsNothing,
      );
      expect(
        find.descendant(of: streams, matching: find.text('字幕')),
        findsNothing,
      );
      expect(
        find.descendant(of: streams, matching: find.text('音轨')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: streams, matching: find.text('视频')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'narrow desktop wraps the action group in at most two lines',
    (tester) async {
      final app = await pumpApp(tester, viewSize: const Size(1024, 768));
      await openItem(tester, app, 'episode-friends-s1e2');
      final actionRow = find.byKey(ItemDetailPage.actionRowKey);
      final rects = [
        for (final element
            in find
                .descendant(
                  of: actionRow,
                  matching: find.byType(ui.AppActionButton),
                )
                .evaluate())
          tester.getRect(find.byWidget(element.widget)),
      ];
      expect(rects.length, greaterThanOrEqualTo(4));
      final lines = {for (final rect in rects) rect.top.round()};
      expect(lines.length, lessThanOrEqualTo(2));
      final play = tester.getRect(find.byKey(PlayerKeys.open));
      for (final rect in rects) {
        expect(play.top, lessThanOrEqualTo(rect.top + .5));
        if ((rect.top - play.top).abs() < 1) {
          expect(play.left, lessThanOrEqualTo(rect.left + .5));
        }
      }
      // 同一行的次级按钮等高。
      final heights = {for (final rect in rects) rect.height.round()};
      expect(heights.length, 1);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'season episodes shelf pages whole cards and sits close to media info',
    (tester) async {
      server.setEpisodes(_series, [
        for (var i = 1; i <= 14; i++)
          FakeEpisode(
            id: 'shelf-e$i',
            name: '第 $i 集',
            seasonId: _season1,
            indexNumber: i,
            mediaStreams: const [
              FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
              FakeMediaStream(
                index: 1,
                type: 'Audio',
                codec: 'aac',
                displayTitle: '国语',
                isDefault: true,
              ),
            ],
          ),
      ]);
      const width = 1440.0;
      final app = await pumpApp(tester, viewSize: const Size(width, 900));
      await openItem(tester, app, 'shelf-e2');
      final shelf = find.byWidgetPredicate(
        (w) => w is MediaShelf && w.shelfId == 'season-episodes',
      );
      expect(shelf, findsOneWidget);

      void expectWholeCards() {
        var visible = 0;
        for (final element
            in find
                .descendant(of: shelf, matching: find.byType(EpisodeThumbCard))
                .evaluate()) {
          final box = element.renderObject! as RenderBox;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          // 视口收在页边距之内,边距外的卡片被裁掉。
          if (rect.right <= AppSpacing.page ||
              rect.left >= width - AppSpacing.page) {
            continue;
          }
          visible++;
          expect(rect.left, greaterThanOrEqualTo(AppSpacing.page - .5));
          expect(rect.right, lessThanOrEqualTo(width - AppSpacing.page + .5));
        }
        expect(visible, greaterThan(1));
      }

      expectWholeCards();
      final right = find.byKey(CatalogKeys.shelfScrollRight('season-episodes'));
      expect(right, findsOneWidget);
      await tester.tap(right);
      await settle(tester);
      expectWholeCards();

      // 货架与媒体信息之间不留大块空白。
      final cards = find.descendant(
        of: shelf,
        matching: find.byType(EpisodeThumbCard),
      );
      final shelfBottom = tester.getRect(cards.first).bottom;
      final media = find.text('媒体信息');
      await tester.ensureVisible(media);
      await settle(tester);
      final gap =
          tester.getRect(media).top - tester.getRect(cards.first).bottom;
      expect(shelfBottom, isNonZero);
      expect(gap, lessThan(56));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'season detail shows more than six whole episodes in two columns',
    (tester) async {
      server.setEpisodes(_series, [
        for (var i = 1; i <= 26; i++)
          FakeEpisode(
            id: 'grid-e$i',
            name: '第 $i 集',
            seasonId: _season1,
            indexNumber: i,
            overview: '一段足够长的分集简介，用来占满两行文字。' * 3,
            runtime: const Duration(minutes: 24),
          ),
      ]);
      const view = Size(1440, 1000);
      final app = await pumpApp(tester, viewSize: view);
      app.router.go(AppRoutes.item(_series, seasonId: _season1));
      await tester.pumpWidget(app);
      await settle(tester);
      final rows = [
        for (final row in tester.widgetList<EpisodeRow>(
          find.byType(EpisodeRow),
        ))
          tester.getRect(find.byKey(ValueKey('episode-row-${row.item.id}'))),
      ];
      final whole = rows
          .where((rect) => rect.top >= 0 && rect.bottom <= view.height)
          .toList();
      expect(whole.length, greaterThan(6));
      expect({for (final rect in rows) rect.left.round()}, hasLength(2));
      expect({for (final rect in rows) rect.height.round()}, hasLength(1));
      // 剧集标题、统计与季切换器在左侧同一组;选集与更多在右侧。
      final title = tester.getRect(
        find.descendant(
          of: find.byKey(CatalogKeys.episodesRow),
          matching: find.text('剧集'),
        ),
      );
      final summary = tester.getRect(
        find.byKey(const Key('episode-list-summary')),
      );
      final locate = tester.getRect(find.byKey(CatalogKeys.locateEpisode));
      expect(summary.left, greaterThan(title.right));
      expect(locate.left, greaterThan(view.width / 2));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'many seasons fold into a picker; switching keeps the header then retries',
    (tester) async {
      server.setSeasons(_series, [
        for (var i = 1; i <= 8; i++)
          FakeSeason(
            id: i == 1 ? _season1 : 'season-$i',
            name: '第 $i 季 · 很长的季名称用来撑开',
            indexNumber: i,
          ),
      ]);
      server.setEpisodes(_series, [
        FakeEpisode(id: 'first', name: 'First', seasonId: _season1),
        for (var i = 2; i <= 8; i++)
          FakeEpisode(id: 'ep-s$i', name: 'Season $i', seasonId: 'season-$i'),
      ]);
      final app = await pumpApp(tester, viewSize: const Size(1024, 768));
      app.router.go(AppRoutes.item(_series, seasonId: _season1));
      await tester.pumpWidget(app);
      await settle(tester);
      final picker = find.byKey(CatalogKeys.seasonPicker);
      expect(picker, findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonTab(_season1)), findsNothing);

      // 切季加载中:已显示的分集和头部留在屏幕上,不换成整页或分集骨架。
      final gate = server.episodeHolds['season-5'] = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final hero = find.byKey(const ValueKey('detail-hero'));
      final heroId = tester.widget<MediaImage>(hero).item.id;
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await settle(tester);
      await tester.tap(find.byKey(CatalogKeys.seasonOption('season-5')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final row = find.byKey(CatalogKeys.episodesRow);
      final list = tester.widget<EpisodeList>(find.byType(EpisodeList));
      expect(list.loading, isTrue);
      expect(list.error, isNull);
      expect(list.episodes.map((episode) => episode.id), ['first']);
      expect(
        find.descendant(of: row, matching: find.byType(EpisodeListSkeleton)),
        findsNothing,
      );
      expect(find.byKey(ItemDetailPage.titleKey), findsOneWidget);
      expect(find.byKey(ItemDetailPage.actionRowKey), findsOneWidget);
      expect(tester.widget<MediaImage>(hero).item.id, heroId);
      expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
      gate.complete();
      await settle(tester);
      expect(_loadedEpisodeIds(tester), ['ep-s5']);

      // 切季失败:列表区显示错误与重试,头部保留;重试成功后恢复。
      server.failEpisodesOf = 'season-3';
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await settle(tester);
      await tester.tap(find.byKey(CatalogKeys.seasonOption('season-3')));
      await settle(tester);
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('season-episodes-failed'),
        ),
        findsOneWidget,
      );
      final retry = find.descendant(of: row, matching: find.text('重试'));
      expect(retry, findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
      server.failEpisodesOf = null;
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await settle(tester);
      expect(_loadedEpisodeIds(tester), ['ep-s3']);

      // 缓存分集先写入、随后网络失败:错误和重试仍在分集区,头图留在切换前。
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await settle(tester);
      await tester.tap(find.byKey(CatalogKeys.seasonOption('season-5')));
      await settle(tester);
      expect(_loadedEpisodeIds(tester), ['ep-s5']);
      final heroBeforeFailure = tester.widget<MediaImage>(hero).item.id;
      final again = Completer<void>();
      addTearDown(() {
        if (!again.isCompleted) again.complete();
      });
      server.episodeHolds['season-3'] = again;
      server.failEpisodesOf = 'season-3';
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await settle(tester);
      await tester.tap(find.byKey(CatalogKeys.seasonOption('season-3')));
      var sawCachedSeason = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final loading = tester.widget<EpisodeList>(find.byType(EpisodeList));
        final ids = loading.episodes.map((episode) => episode.id).join(',');
        if (loading.loading && loading.error == null && ids == 'ep-s3') {
          sawCachedSeason = true;
          break;
        }
      }
      expect(sawCachedSeason, isTrue);
      again.complete();
      await settle(tester);
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('season-episodes-failed'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('重试')),
        findsOneWidget,
      );
      final failed = tester.widget<EpisodeList>(find.byType(EpisodeList));
      expect(failed.episodes, isEmpty);
      expect(failed.error, isNotNull);
      expect(tester.widget<MediaImage>(hero).item.id, heroBeforeFailure);
      expect(find.byKey(ItemDetailPage.titleKey), findsOneWidget);
      expect(find.byKey(ItemDetailPage.actionRowKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets('episode card play and check keep the detail flow intact', (
    tester,
  ) async {
    final host = _SilentPlayerHost();
    final app = await pumpApp(tester, host: host);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final play = find.byKey(CatalogKeys.episodePlay(id));
    await tester.ensureVisible(play);
    await tester.pump();
    await tester.tap(play);
    await settle(tester);

    expect(app.router.state.uri.path, AppRoutes.item(_series));
    expect(host.current?.itemId, id);

    final toggle = find.byKey(CatalogKeys.episodePlayed(id));
    await tester.ensureVisible(toggle);
    await tester.pump();
    expect(tester.widget<ui.AppIconButton>(toggle).tooltip, '标记已看');

    await tester.tap(toggle);
    await settle(tester);

    expect(
      server.requests.any(
        (request) =>
            request.contains('POST ') && request.contains('/PlayedItems/$id'),
      ),
      isTrue,
    );
    expect(
      tester
          .widget<ui.AppIconButton>(find.byKey(CatalogKeys.episodePlayed(id)))
          .tooltip,
      '标记未看',
    );

    // 分集详情请求必须带 People 字段(fake server 无条件序列化 People,
    // 只有钉住请求侧的 Fields 才能防止详情链路退回不带 People 的请求)。
    server.requests.clear();
    await openItem(tester, app, 'episode-friends-s1e2');
    final detailRequests = server.requests
        .where((request) => request.contains('/Items/episode-friends-s1e2?'))
        .toList();
    expect(detailRequests, isNotEmpty);
    // Registry ancestry/identity probes use canonical metadata fields; only
    // the actual detail-content fetch must include People.
    expect(detailRequests.any((request) => request.contains('People')), isTrue);
    expect(
      detailRequests.every(
        (request) =>
            request.contains('People') ||
            Uri.parse(request.substring(request.indexOf(' ') + 1))
                    .queryParameters['Fields'] ==
                MediaServerClient.itemFields,
      ),
      isTrue,
    );
  }, tags: ['integration']);

  cases.testWidgets('switching episodes keeps the cast and album still', (
    tester,
  ) async {
    const first = 'episode-friends-s1e1';
    const second = 'episode-friends-s1e2';
    final series = server.items.firstWhere((item) => item.id == _series);
    series.backdropImageTag = 'friends-bd';
    for (final item in server.items) {
      if (item.id != first && item.id != second) {
        continue;
      }
      item.genres = ['奇幻冒险'];
      item.parentBackdropItemId = _series;
      item.parentBackdropImageTags = ['still-a', 'still-b'];
    }
    server.items.firstWhere((item) => item.id == first).people = const [
      FakePerson(name: '铃木崚汰', type: 'Actor', role: '勇者'),
    ];
    server.items.firstWhere((item) => item.id == second).people = const [
      FakePerson(name: '铃木崚汰', type: 'Actor', role: '勇者'),
      FakePerson(name: '花泽香菜', type: 'Actor', role: '同伴'),
    ];
    server.omitUnrequestedListFields = true;

    final app = await pumpApp(tester, viewSize: const Size(1440, 900));
    await openItem(tester, app, first);
    expect(find.text('铃木崚汰'), findsOneWidget);
    expect(find.text('花泽香菜'), findsNothing);
    expect(find.text('奇幻冒险'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);

    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
    server.holdItemGet = gate;
    final card = find.byKey(CatalogKeys.episode(second));
    await tester.ensureVisible(card);
    await tester.pump();
    final people = tester.element(find.byKey(EpisodePeopleSection.sectionKey));
    final offset = _detailPageOffset(tester);
    final hero = find.byKey(const ValueKey('detail-hero'));
    final heroElement = tester.element(hero);
    final heroSource = tester.widget<MediaImage>(hero).item;

    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('The One with the Sonogram'), findsWidgets);
    expect(tester.element(hero), same(heroElement));
    expect(tester.widget<MediaImage>(hero).item.id, heroSource.id);
    expect(
      tester.widget<MediaImage>(hero).item.backdropImageTag,
      heroSource.backdropImageTag,
    );
    expect(find.text('铃木崚汰'), findsOneWidget);
    expect(find.text('花泽香菜'), findsNothing);
    expect(find.text('奇幻冒险'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(
      tester.element(find.byKey(EpisodePeopleSection.sectionKey)),
      same(people),
    );
    expect(_detailPageOffset(tester), closeTo(offset, 1));

    gate.complete();
    await settle(tester);
    expect(find.text('铃木崚汰'), findsOneWidget);
    expect(find.text('花泽香菜'), findsOneWidget);
    expect(find.text('奇幻冒险'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  for (final explicit in [false, true]) {
    cases.testWidgets(
      'series opens ${explicit ? 'requested' : 'resuming'} season with specials first',
      (tester) async {
        server.setSeasons(_series, const [
          FakeSeason(id: 'specials', name: '特别篇', indexNumber: 0),
          FakeSeason(id: _season1, name: '第 1 季', indexNumber: 1),
          FakeSeason(id: 'season-3', name: '第 3 季', indexNumber: 3),
        ]);
        server.setEpisodes(_series, const [
          FakeEpisode(
            id: 'special-e1',
            name: '特别篇',
            seasonId: 'specials',
            indexNumber: 1,
          ),
          FakeEpisode(
            id: 'first-e1',
            name: '第一季首集',
            seasonId: _season1,
            indexNumber: 1,
          ),
          FakeEpisode(
            id: 'resume-e13',
            name: '续播第13集',
            seasonId: 'season-3',
            indexNumber: 13,
            parentIndexNumber: 3,
            playbackPosition: Duration(microseconds: (100000000) ~/ 10),
            runtime: Duration(microseconds: (200000000) ~/ 10),
          ),
        ]);
        final app = await pumpApp(tester);
        app.router.go(
          AppRoutes.item(_series, seasonId: explicit ? _season1 : null),
        );
        await tester.pumpWidget(app);
        await settle(tester);
        expect(_episodeCardIds(tester), [explicit ? 'first-e1' : 'resume-e13']);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'episode title link keeps its season without a duplicate action',
    (tester) async {
      server.setSeasons(_series, const [
        FakeSeason(id: 'specials', name: '特别篇', indexNumber: 0),
        FakeSeason(id: 'season-3', name: '第 3 季', indexNumber: 3),
      ]);
      server.setEpisodes(_series, const [
        FakeEpisode(
          id: 'special-e1',
          name: '特别篇',
          seasonId: 'specials',
          indexNumber: 1,
        ),
        FakeEpisode(
          id: 'third-e13',
          name: '第三季第13集',
          seasonId: 'season-3',
          indexNumber: 13,
          parentIndexNumber: 3,
        ),
      ]);
      final app = await pumpApp(tester);
      await openItem(tester, app, 'third-e13');
      expect(find.byKey(CatalogKeys.viewSeries), findsNothing);
      await tester.ensureVisible(find.byKey(CatalogKeys.seriesLink));
      await tester.tap(find.byKey(CatalogKeys.seriesLink));
      await settle(tester);
      expect(app.router.state.uri.queryParameters['season'], 'season-3');
      expect(_episodeCardIds(tester), ['third-e13']);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'long seasons auto-load at the end and ranges scroll without changing the current episode',
    (tester) async {
      server.setEpisodes(_series, [
        for (var i = 1; i <= 130; i++)
          FakeEpisode(
            id: 'range-e$i',
            name: 'Episode $i',
            seasonId: _season1,
            indexNumber: i,
          ),
      ]);
      await pumpDetailOnly(tester);
      final pageScroll = find
          .descendant(
            of: find.byType(ItemDetailPage),
            matching: find.byType(Scrollable),
          )
          .first;
      expect(_loadedEpisodeIds(tester), hasLength(80));
      expect(
        find.byKey(EpisodeRangeBar.barKey, skipOffstage: false),
        findsOneWidget,
      );
      final current = tester.widget<EpisodeList>(find.byType(EpisodeList));
      expect(current.currentId, 'range-e1');

      // 滚到第一窗末尾就续载，不需要点「加载更多」。
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('episode-row-range-e130')),
        800,
        scrollable: pageScroll,
        maxScrolls: 200,
      );
      await settle(tester);
      expect(_loadedEpisodeIds(tester), hasLength(130));

      // 点「51–100」：滚到第 51 集，当前集高亮仍是续播目标。
      final bar = find.byKey(EpisodeRangeBar.barKey, skipOffstage: false);
      await tester.scrollUntilVisible(bar, -800, scrollable: pageScroll);
      await Scrollable.ensureVisible(tester.element(bar), alignment: .5);
      await settle(tester);
      await tester.tap(find.byKey(EpisodeRangeBar.chipKey(51)));
      await settle(tester);
      final target = find.byKey(const ValueKey('episode-row-range-e51'));
      expect(target, findsOneWidget);
      final rect = tester.getRect(target);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(800));
      expect(
        tester.widget<EpisodeList>(find.byType(EpisodeList)).currentId,
        'range-e1',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets('compact desktop windows keep episodes in two columns', (
    tester,
  ) async {
    server.setEpisodes(_series, [
      for (var i = 1; i <= 8; i++)
        FakeEpisode(
          id: 'compact-e$i',
          name: '第 $i 集',
          seasonId: _season1,
          indexNumber: i,
          overview: '简介' * 20,
        ),
    ]);
    const view = Size(1024, 768);
    final app = await pumpApp(tester, viewSize: view);
    app.router.go(AppRoutes.item(_series, seasonId: _season1));
    await tester.pumpWidget(app);
    await settle(tester);
    final rows = [
      for (final row in tester.widgetList<EpisodeRow>(find.byType(EpisodeRow)))
        tester.getRect(find.byKey(ValueKey('episode-row-${row.item.id}'))),
    ];
    expect({for (final rect in rows) rect.left.round()}, hasLength(2));
    // 八集的短季不出现分段条。
    expect(
      find.byKey(EpisodeRangeBar.barKey, skipOffstage: false),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets(
    'episode load-more failure keeps the window and retry appends without duplicates',
    (tester) async {
      server.failEpisodeWindowsAfterStart = true;
      server.setEpisodes(_series, [
        for (var i = 1; i <= 100; i++)
          FakeEpisode(
            id: 'bulk-e$i',
            name: 'Episode $i',
            seasonId: _season1,
            indexNumber: i,
          ),
      ]);
      await pumpDetailOnly(tester);

      final row = find.byKey(CatalogKeys.episodesRow);
      expect(_loadedEpisodeIds(tester), hasLength(80));
      expect(find.byType(EpisodeRow).evaluate().length, lessThan(20));
      expect(_loadedEpisodeIds(tester).first, 'bulk-e1');
      expect(_loadedEpisodeIds(tester).last, 'bulk-e80');
      final more = find.byKey(CatalogKeys.episodesLoadMore);
      final pageScroll = find
          .descendant(
            of: find.byType(ItemDetailPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(more, 600, scrollable: pageScroll);
      expect(more, findsOneWidget);
      expect(tester.widget(more), isA<ui.AppButton>());
      expect(
        find.descendant(of: more, matching: find.text('加载更多')),
        findsOneWidget,
      );

      // 失败路径:已载窗口不被污染,错误留在分集分区内且可重试。
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await settle(tester);

      expect(_loadedEpisodeIds(tester), hasLength(80));
      expect(find.byType(EpisodeRow).evaluate().length, lessThan(20));
      expect(_loadedEpisodeIds(tester).first, 'bulk-e1');
      expect(_loadedEpisodeIds(tester).last, 'bulk-e80');
      await tester.scrollUntilVisible(
        find.textContaining('episode-window-failed'),
        -600,
        scrollable: pageScroll,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('episode-window-failed'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('重试')),
        findsOneWidget,
      );
      expect(find.byType(ItemDetailPage), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_Notice',
        ),
        findsNothing,
      );

      // 重试成功:追加下一窗且按 id 去重,分区内错误清空。
      server.failEpisodeWindowsAfterStart = false;
      final retry = find.descendant(of: row, matching: find.text('重试'));
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      await settle(tester);

      final ids = _loadedEpisodeIds(tester);
      expect(ids, hasLength(100));
      expect(ids.toSet().length, 100);
      expect(ids.first, 'bulk-e1');
      expect(ids.last, 'bulk-e100');
      expect(find.byKey(CatalogKeys.episodesLoadMore), findsNothing);
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('episode-window-failed'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}

/// 分集分区内各卡片的条目 id,按渲染顺序。
List<String> _episodeCardIds(WidgetTester tester) {
  final row = find.byKey(CatalogKeys.episodesRow);
  return [
    for (final card in tester.widgetList<EpisodeRow>(
      find.descendant(of: row, matching: find.byType(EpisodeRow)),
    ))
      card.item.id,
  ];
}

List<String> _loadedEpisodeIds(WidgetTester tester) => tester
    .widget<EpisodeList>(find.byType(EpisodeList))
    .episodes
    .map((episode) => episode.id)
    .toList();

final cases = CaseShard(3);

void mainShard(int part, int expectedParts) =>
    cases.register(part, main, expectedParts: expectedParts);
