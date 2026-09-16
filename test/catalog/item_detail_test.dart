@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';
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

  void expectHeaderShape(WidgetTester tester, {required Size posterSize}) {
    final header = find.byKey(ItemDetailPage.headerKey);
    final rect = tester.getRect(header);
    expect(rect.left, 0);
    expect(rect.width, 1200);

    final poster = find.byKey(ItemDetailPage.posterKey);
    expect(poster, findsOneWidget);
    expect(tester.getSize(poster), posterSize);
    final posterImages = find.descendant(
      of: poster,
      matching: find.byType(MediaImage),
    );
    expect(posterImages, findsOneWidget);
    expect(tester.widget<MediaImage>(posterImages).preferBackdrop, isFalse);

    final backdrops = find.descendant(
      of: header,
      matching: find.byWidgetPredicate(
        (widget) => widget is MediaImage && widget.preferBackdrop,
      ),
    );
    expect(backdrops, findsOneWidget);

    final title = _headerTitle();
    expect(title, findsOneWidget);
    final open = find.byKey(PlayerKeys.open);
    expect(open, findsOneWidget);
    expect(
      tester.getTopLeft(open).dy,
      greaterThan(tester.getBottomLeft(title).dy),
    );
    expect(tester.getRect(open).overlaps(rect), isTrue);
    expect(
      tester.getTopLeft(open).dx,
      greaterThan(tester.getRect(poster).right),
    );

    expect(
      find.descendant(
        of: header,
        matching: find.byKey(CatalogKeys.playedToggle),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget(find.byKey(CatalogKeys.playedToggle)),
      isA<ScrimIconButton>(),
    );
    expect(find.byType(LiquidGlass), findsNothing);
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

Finder _headerTitle() {
  return find
      .descendant(
        of: find.byKey(ItemDetailPage.headerKey),
        matching: find.byType(SelectableText),
      )
      .first;
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

/// 当前集卡片以 surfaceContainerHigh 底色标示;其余卡片透明。
bool _cardSelected(WidgetTester tester, String id) {
  final well = find.byKey(CatalogKeys.episode(id));
  final material = find.ancestor(of: well, matching: find.byType(Material));
  final color = tester.widget<Material>(material.first).color;
  final scheme = Theme.of(tester.element(well)).colorScheme;
  if (color == scheme.surfaceContainerHigh) {
    return true;
  }
  expect(color, Colors.transparent);
  return false;
}
