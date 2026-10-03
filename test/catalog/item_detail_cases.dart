import 'dart:async';
import 'dart:typed_data';

import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_window_host.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
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
    final app = RillightApp(
      auth: auth,
      playerBindings: host == null
          ? const PlayerBindings()
          : PlayerBindings(windowHost: host),
    );
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
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.dark(),
        home: Scaffold(
          body: AuthScope(
            controller: auth,
            child: const ItemDetailPage(itemId: _series),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.byType(ItemDetailPage), findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
  }

  testWidgets(
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
      expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
      expect(
        tester.widget<EpisodeList>(find.byType(EpisodeList)).episodes,
        isEmpty,
      );
      resume.complete();
      episodes.complete();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
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

  testWidgets(
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
      await tester.ensureVisible(find.byKey(CatalogKeys.seasonPicker));
      await tester.tap(find.byKey(CatalogKeys.seasonPicker));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('第 2 季').last);
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

  testWidgets('episode card play and check keep the detail flow intact', (
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
    expect(tester.widget<IconButton>(toggle).tooltip, '标记已看');

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
          .widget<IconButton>(find.byKey(CatalogKeys.episodePlayed(id)))
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
    expect(
      detailRequests.every((request) => request.contains('People')),
      isTrue,
    );
  }, tags: ['integration']);

  testWidgets('switching episodes keeps the cast and album still', (
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
    testWidgets(
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
            playbackPositionTicks: 100000000,
            runTimeTicks: 200000000,
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

  testWidgets(
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

  testWidgets(
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
      expect(_episodeCardIds(tester), hasLength(80));
      expect(_episodeCardIds(tester).first, 'bulk-e1');
      expect(_episodeCardIds(tester).last, 'bulk-e80');
      final more = find.byKey(CatalogKeys.episodesLoadMore);
      expect(more, findsOneWidget);
      expect(tester.widget(more), isA<OutlinedButton>());
      expect(
        find.descendant(of: more, matching: find.text('加载更多')),
        findsOneWidget,
      );

      // 失败路径:已载窗口不被污染,错误留在分集分区内且可重试。
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await settle(tester);

      expect(_episodeCardIds(tester), hasLength(80));
      expect(_episodeCardIds(tester).first, 'bulk-e1');
      expect(_episodeCardIds(tester).last, 'bulk-e80');
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
      expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      // 重试成功:追加下一窗且按 id 去重,分区内错误清空。
      server.failEpisodeWindowsAfterStart = false;
      final retry = find.descendant(of: row, matching: find.text('重试'));
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      await settle(tester);

      final ids = _episodeCardIds(tester);
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
