import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_window_host.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/top_bar_hit.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-item-detail',
  version: '0.1.0',
);

const _series = 'series-friends';
const _season1 = 'season-friends-1';

/// 可为 `/Items/{id}` 一类请求注入延迟的假服务端,用来抓住骨架屏帧。
class _DelayedEmbyServer extends FakeEmbyServer {
  Duration itemDelay = Duration.zero;
  final hiddenEpisodeIds = <String>{};

  /// StartIndex 大于 0 的分集窗口返回 500,用来验收继续加载失败。
  bool failEpisodeWindowsAfterStart = false;

  /// 非空时,失败的后续分集窗口先停在这里,便于切季后再放行。
  Completer<void>? episodeWindowGate;

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (itemDelay > Duration.zero && options.uri.path.contains('/Items/')) {
      await Future<void>.delayed(itemDelay);
    }
    if (failEpisodeWindowsAfterStart &&
        options.uri.path.endsWith('/Items') &&
        options.uri.queryParameters['IncludeItemTypes'] == 'Episode') {
      final start =
          int.tryParse(options.uri.queryParameters['StartIndex'] ?? '') ?? 0;
      if (start > 0) {
        final gate = episodeWindowGate;
        if (gate != null) {
          await gate.future;
        }
        return ResponseBody.fromString(
          'episode-window-failed',
          500,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        );
      }
    }
    final response = await super.handle(options, requestStream);
    if (hiddenEpisodeIds.isNotEmpty &&
        options.uri.path.endsWith('/Items') &&
        options.uri.queryParameters['IncludeItemTypes'] == 'Episode') {
      final text = await response.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join();
      final json = jsonDecode(text) as Map<String, dynamic>;
      final items = json['Items'] as List;
      final filtered = items
          .where((item) => !hiddenEpisodeIds.contains(item['Id']))
          .toList();
      json['Items'] = filtered;
      json['TotalRecordCount'] =
          (json['TotalRecordCount'] as int) - (items.length - filtered.length);
      return ResponseBody.fromString(
        jsonEncode(json),
        response.statusCode,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return response;
  }
}

class _SilentPlayerHost extends OverlayPlayerWindowHost {
  @override
  bool get embedsPlayerInCaller => false;
}

void main() {
  setUp(isolateImageCache);
  late _DelayedEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = _DelayedEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    HomeHero.autoAdvanceEnabled = false;
  });

  tearDown(() {
    HomeHero.autoAdvanceEnabled = true;
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

  testWidgets('reentering episode detail replaces its alternate catalog id', (
    tester,
  ) async {
    server.setEpisodes(_series, [
      const FakeEpisode(
        id: 'catalog-e8',
        name: '第 8 集',
        seasonId: _season1,
        indexNumber: 8,
      ),
      const FakeEpisode(
        id: 'current-e8',
        name: '第 8 集',
        seasonId: _season1,
        indexNumber: 8,
      ),
      const FakeEpisode(
        id: 'episode-e9',
        name: '第 9 集',
        seasonId: _season1,
        indexNumber: 9,
      ),
    ]);
    server.hiddenEpisodeIds.add('current-e8');
    final app = await pumpApp(tester);
    for (var attempt = 0; attempt < 2; attempt++) {
      await openItem(tester, app, 'current-e8');
      final cards = tester
          .widgetList<EpisodeThumbCard>(find.byType(EpisodeThumbCard))
          .toList();
      expect(cards.where((card) => card.item.indexNumber == 8), hasLength(1));
      expect(cards.where((card) => card.selected).map((card) => card.item.id), [
        'current-e8',
      ]);
      expect(cards.map((card) => card.item.id), contains('episode-e9'));
      await openItem(tester, app, 'movie-up');
    }
  }, tags: ['integration']);

  testWidgets('actual distinct episode versions are not all highlighted', (
    tester,
  ) async {
    server.setEpisodes(_series, [
      const FakeEpisode(
        id: 'version-a',
        name: '第 8 集',
        seasonId: _season1,
        indexNumber: 8,
      ),
      const FakeEpisode(
        id: 'version-b',
        name: '第 8 集',
        seasonId: _season1,
        indexNumber: 8,
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, 'version-b');
    final cards = tester
        .widgetList<EpisodeThumbCard>(find.byType(EpisodeThumbCard))
        .toList();
    expect(
      cards.map((card) => card.item.id),
      containsAll(['version-a', 'version-b']),
    );
    expect(cards.where((card) => card.selected).map((card) => card.item.id), [
      'version-b',
    ]);
  }, tags: ['integration']);

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

  testWidgets('load more appends the next episode window without duplicates', (
    tester,
  ) async {
    server.setEpisodes(_series, [
      for (var i = 1; i <= 100; i++)
        FakeEpisode(
          id: 'bulk-e$i',
          name: 'Episode $i',
          seasonId: _season1,
          indexNumber: i,
        ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    var ids = _episodeCardIds(tester);
    expect(ids.length, 80);
    expect(ids.first, 'bulk-e1');
    expect(ids.last, 'bulk-e80');
    final more = find.byKey(CatalogKeys.episodesLoadMore);
    expect(more, findsOneWidget);
    expect(tester.widget(more), isA<OutlinedButton>());
    expect(
      find.descendant(of: more, matching: find.text('加载更多')),
      findsOneWidget,
    );

    await ensureVisibleBelowTopBar(tester, more);
    await tapBelowTopBar(tester, more);
    await settle(tester);

    ids = _episodeCardIds(tester);
    expect(ids.length, 100);
    expect(ids.toSet().length, 100);
    expect(ids.last, 'bulk-e100');
    expect(find.byKey(CatalogKeys.episodesLoadMore), findsNothing);
  }, tags: ['integration']);

  testWidgets('view series from an episode opens that season', (tester) async {
    server.setSeasons('series-friends', [
      const FakeSeason(id: 'season-friends-1', name: '第 1 季', indexNumber: 1),
      const FakeSeason(id: 'season-friends-2', name: '第 4 季', indexNumber: 4),
    ]);
    server.setEpisodes('series-friends', [
      const FakeEpisode(
        id: 'episode-friends-s1e1',
        name: 'The Pilot',
        seasonId: 'season-friends-1',
        indexNumber: 1,
        parentIndexNumber: 1,
      ),
      const FakeEpisode(
        id: 'episode-friends-s1e2',
        name: 'The One with the Sonogram',
        seasonId: 'season-friends-1',
        indexNumber: 2,
        parentIndexNumber: 1,
      ),
      const FakeEpisode(
        id: 'episode-friends-s4e17',
        name: 'S4E17',
        seasonId: 'season-friends-2',
        indexNumber: 17,
        parentIndexNumber: 4,
        overview: 'later season',
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s4e17');
    await ensureVisibleBelowTopBar(tester, find.byKey(CatalogKeys.viewSeries));
    await tapBelowTopBar(tester, find.byKey(CatalogKeys.viewSeries));
    await settle(tester);

    expect(app.router.state.uri.path, AppRoutes.item(_series));
    expect(app.router.state.uri.queryParameters['season'], 'season-friends-2');
    expect(
      find.descendant(
        of: find.byKey(CatalogKeys.seasonPicker),
        matching: find.text('第 4 季'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(CatalogKeys.episode('episode-friends-s4e17')),
      findsOneWidget,
    );
    expect(
      find.byKey(CatalogKeys.episode('episode-friends-s1e1')),
      findsNothing,
    );
  }, tags: ['integration']);

  testWidgets(
    'movie detail resumes from catalog progress when the item payload omits ticks',
    (tester) async {
      server.stripDetailPlaybackProgress = true;
      final app = await pumpApp(tester);
      await tester.pumpWidget(app);
      await settle(tester);
      await openItem(tester, app, 'movie-inception');

      expect(find.text('继续播放'), findsOneWidget);
      expect(find.byKey(CatalogKeys.resumeProgress), findsOneWidget);
      expect(find.text('已看 40%'), findsOneWidget);
    },
    tags: ['integration'],
  );

  testWidgets('reduced motion pages the chapter strip without sliding', (
    tester,
  ) async {
    server.items.firstWhere((item) => item.id == 'movie-inception').chapters = [
      for (var i = 0; i < 24; i++)
        FakeChapter(name: 'Chapter $i', startPositionTicks: i * 600000000),
    ];
    final app = await pumpApp(tester);
    await openItem(tester, app, 'movie-inception');
    final right = find.byKey(
      CatalogKeys.shelfScrollRight(CatalogKeys.shelfChapters),
    );
    expect(right, findsOneWidget);
    await ensureVisibleBelowTopBar(tester, right);

    final position = _chapterPosition(tester);
    final start = position.pixels;
    await tapBelowTopBar(tester, right);
    expect(position.activity, isA<DrivenScrollActivity>());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = position.pixels;
    await tester.pump(const Duration(milliseconds: 200));
    expect(mid, greaterThan(start));
    expect(position.pixels, greaterThan(mid));
    expect(position.activity, isA<IdleScrollActivity>());

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    final before = position.pixels;
    await tapBelowTopBar(tester, right);
    final jumped = position.pixels;
    expect(jumped, greaterThan(before));
    expect(position.activity, isA<IdleScrollActivity>());
    await tester.pump(const Duration(milliseconds: 200));
    expect(position.pixels, jumped);
    expect(position.activity, isA<IdleScrollActivity>());
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('detail header axis follows 960 and module order stays', (
    tester,
  ) async {
    final app = await pumpApp(tester, viewSize: const Size(960, 800));
    await openItem(tester, app, 'movie-inception');
    expect(_headerDirection(tester), Axis.horizontal);
    _expectPosterBesideTitle(tester);
    _expectTopToBottom(tester, [
      find.byKey(ItemDetailPage.headerKey),
      find.text('章节'),
      find.byKey(CatalogKeys.similarRow),
    ]);

    tester.view.physicalSize = const Size(959, 800);
    await tester.pump();
    await settle(tester);
    expect(_headerDirection(tester), Axis.vertical);
    _expectPosterAboveTitle(tester);
    _expectTopToBottom(tester, [
      find.byKey(ItemDetailPage.headerKey),
      find.text('章节'),
      find.byKey(CatalogKeys.similarRow),
    ]);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    await openItem(tester, app, _series);
    _expectTopToBottom(tester, [
      find.byKey(ItemDetailPage.headerKey),
      find.byKey(CatalogKeys.episodesRow),
    ]);
    expect(find.text('章节'), findsNothing);

    await openItem(tester, app, 'episode-friends-s1e1');
    _expectTopToBottom(tester, [
      find.byKey(ItemDetailPage.headerKey),
      find.text('本季分集'),
    ]);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('episode load-more failure stays inside the episode section', (
    tester,
  ) async {
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
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    final more = find.byKey(CatalogKeys.episodesLoadMore);
    await ensureVisibleBelowTopBar(tester, more);
    await tapBelowTopBar(tester, more);
    await settle(tester);

    final row = find.byKey(CatalogKeys.episodesRow);
    final ids = _episodeCardIds(tester);
    expect(ids, hasLength(80));
    expect(ids.first, 'bulk-e1');
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('episode-window-failed'),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.text('重试')), findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    server.failEpisodeWindowsAfterStart = false;
    final retry = find.descendant(of: row, matching: find.text('重试'));
    await ensureVisibleBelowTopBar(tester, retry);
    await tapBelowTopBar(tester, retry);
    await settle(tester);

    expect(_episodeCardIds(tester), hasLength(100));
    expect(
      find.descendant(
        of: find.byKey(CatalogKeys.episodesRow),
        matching: find.textContaining('episode-window-failed'),
      ),
      findsNothing,
    );
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('stale episode load-more failure does not mark the new season', (
    tester,
  ) async {
    final gate = Completer<void>();
    server.episodeWindowGate = gate;
    server.failEpisodeWindowsAfterStart = true;
    server.setSeasons(_series, const [
      FakeSeason(id: _season1, name: '第 1 季', indexNumber: 1),
      FakeSeason(id: 'season-friends-2', name: '第 2 季', indexNumber: 2),
    ]);
    server.setEpisodes(_series, [
      for (var i = 1; i <= 100; i++)
        FakeEpisode(
          id: 'bulk-e$i',
          name: 'Episode $i',
          seasonId: _season1,
          indexNumber: i,
        ),
      const FakeEpisode(
        id: 'season-two-e1',
        name: 'Second Season Pilot',
        seasonId: 'season-friends-2',
        indexNumber: 1,
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    final more = find.byKey(CatalogKeys.episodesLoadMore);
    await ensureVisibleBelowTopBar(tester, more);
    await tapBelowTopBar(tester, more);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      find.descendant(
        of: more,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    final picker = find.byKey(CatalogKeys.seasonPicker);
    await Scrollable.ensureVisible(
      tester.element(picker),
      alignment: 0.3,
      duration: Duration.zero,
    );
    await tester.pump();
    await tapBelowTopBar(tester, picker);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '第 2 季'));

    final seasonTwo = find.byKey(CatalogKeys.episode('season-two-e1'));
    for (var i = 0; i < 30 && seasonTwo.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(seasonTwo, findsOneWidget);
    expect(_episodeCardIds(tester), ['season-two-e1']);

    gate.complete();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    await settle(tester);

    expect(_episodeCardIds(tester), ['season-two-e1']);
    expect(
      find.descendant(
        of: find.byKey(CatalogKeys.episodesRow),
        matching: find.textContaining('episode-window-failed'),
      ),
      findsNothing,
    );
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('failed episode jump keeps the loaded window under the notice', (
    tester,
  ) async {
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
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);
    expect(_episodeCardIds(tester), hasLength(80));

    final locate = find.byKey(CatalogKeys.locateEpisode);
    await ensureVisibleBelowTopBar(tester, locate);
    await tapBelowTopBar(tester, locate);
    await settle(tester);
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      '90',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);

    final row = find.byKey(CatalogKeys.episodesRow);
    final notice = find.descendant(
      of: row,
      matching: find.textContaining('episode-window-failed'),
    );
    final first = find.byKey(CatalogKeys.episode('bulk-e1'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(_episodeCardIds(tester), hasLength(80));
    expect(_episodeCardIds(tester).first, 'bulk-e1');
    expect(find.byKey(CatalogKeys.episode('bulk-e90')), findsNothing);
    expect(notice, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('重试')),
      findsOneWidget,
    );
    expect(tester.getRect(notice).bottom, lessThanOrEqualTo(tester.getRect(first).top));
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    server.failEpisodeWindowsAfterStart = false;
    final retry = find.descendant(of: row, matching: find.text('重试'));
    await ensureVisibleBelowTopBar(tester, retry);
    await tapBelowTopBar(tester, retry);
    await settle(tester);

    final ids = _episodeCardIds(tester);
    expect(ids.first, 'bulk-e86');
    expect(ids, contains('bulk-e90'));
    expect(ids, isNot(contains('bulk-e1')));
    expect(
      find.descendant(
        of: find.byKey(CatalogKeys.episodesRow),
        matching: find.textContaining('episode-window-failed'),
      ),
      findsNothing,
    );
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}

Axis _headerDirection(WidgetTester tester) {
  return tester
      .widget<Flex>(
        find
            .ancestor(
              of: find.byKey(ItemDetailPage.posterKey),
              matching: find.byType(Flex),
            )
            .first,
      )
      .direction;
}

void _expectPosterBesideTitle(WidgetTester tester) {
  final poster = tester.getRect(find.byKey(ItemDetailPage.posterKey));
  final title = tester.getRect(find.text('Inception (2010)'));
  expect(poster.right, lessThanOrEqualTo(title.left));
  expect(poster.top, lessThan(title.bottom));
  expect(title.top, lessThan(poster.bottom));
}

void _expectPosterAboveTitle(WidgetTester tester) {
  final poster = tester.getRect(find.byKey(ItemDetailPage.posterKey));
  final title = tester.getRect(find.text('Inception (2010)'));
  expect(title.top, greaterThanOrEqualTo(poster.bottom - 1));
}

void _expectTopToBottom(WidgetTester tester, List<Finder> finders) {
  var previous = double.negativeInfinity;
  for (final finder in finders) {
    expect(finder, findsOneWidget);
    final top = tester.getRect(finder).top;
    expect(top, greaterThan(previous));
    previous = top;
  }
}

ScrollPosition _chapterPosition(WidgetTester tester) {
  final tile = tester.allElements.firstWhere(
    (element) => element.widget.key == CatalogKeys.chapter(0),
  );
  ScrollableState? scrollable;
  tile.visitAncestorElements((ancestor) {
    final state = ancestor is StatefulElement ? ancestor.state : null;
    if (state is ScrollableState && state.position.axis == Axis.horizontal) {
      scrollable = state;
      return false;
    }
    return true;
  });
  return scrollable!.position;
}

const _episodeKeyPrefix = 'catalog-episode-';

/// 分集分区内各卡片的条目 id,按渲染顺序。
List<String> _episodeCardIds(WidgetTester tester) {
  final row = find.byKey(CatalogKeys.episodesRow);
  if (row.evaluate().isEmpty) {
    return const [];
  }
  final wells = find.descendant(of: row, matching: find.byType(InkWell));
  return [
    for (final element in wells.evaluate())
      if (element.widget.key case ValueKey<String>(value: final value)
          when value.startsWith(_episodeKeyPrefix) &&
              !value.startsWith('catalog-episode-play-') &&
              !value.startsWith('catalog-episode-played-'))
        value.substring(_episodeKeyPrefix.length),
  ];
}
