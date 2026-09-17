@Tags(['integration'])
library;

import 'dart:typed_data';

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

  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (itemDelay > Duration.zero && options.uri.path.contains('/Items/')) {
      await Future<void>.delayed(itemDelay);
    }
    return super.handle(options, requestStream);
  }
}

class _SilentPlayerHost extends OverlayPlayerWindowHost {
  @override
  bool get embedsPlayerInCaller => false;
}

void main() {
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
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    return app;
  }

  Future<void> openItem(
    WidgetTester tester,
    RillightApp app,
    String itemId,
  ) async {
    app.router.push(AppRoutes.item(itemId));
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailPage), findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsOneWidget);
  }

  testWidgets('episode card play button starts playback', (tester) async {
    final host = _SilentPlayerHost();
    final app = await pumpApp(tester, host: host);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final play = find.byKey(CatalogKeys.episodePlay(id));
    await tester.ensureVisible(play);
    await tester.pump();
    await tester.tap(play);
    await tester.pumpAndSettle();

    expect(app.router.state.uri.path, AppRoutes.item(_series));
    expect(host.current?.itemId, id);
  });

  testWidgets('episode card check marks the episode played', (tester) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final toggle = find.byKey(CatalogKeys.episodePlayed(id));
    await tester.ensureVisible(toggle);
    await tester.pump();
    expect(tester.widget<IconButton>(toggle).tooltip, '标记已看');

    await tester.tap(toggle);
    await tester.pumpAndSettle();

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
  });

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
    await tester.pumpAndSettle();

    ids = _episodeCardIds(tester);
    expect(ids.length, 100);
    expect(ids.toSet().length, 100);
    expect(ids.last, 'bulk-e100');
    expect(find.byKey(CatalogKeys.episodesLoadMore), findsNothing);
  });

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
    await tester.pumpAndSettle();

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
  });

  testWidgets('episode detail request asks for the People field', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    server.requests.clear();
    await openItem(tester, app, 'episode-friends-s1e2');

    // fake server 对 People 无条件序列化,必须钉住请求侧的 Fields,
    // 防止详情链路退回不带 People 的请求而测试假绿。
    final detailRequests = server.requests
        .where((request) => request.contains('/Items/episode-friends-s1e2?'))
        .toList();
    expect(detailRequests, isNotEmpty);
    expect(
      detailRequests.every((request) => request.contains('People')),
      isTrue,
    );
  });
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
