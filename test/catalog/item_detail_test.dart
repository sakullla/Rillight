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

  testWidgets('movie header renders poster, title and actions', (tester) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'movie-inception');

    expectHeaderShape(tester, posterSize: const Size(200, 300));
    expect(
      tester.widget<SelectableText>(_headerTitle()).data,
      contains('Inception'),
    );
    expect(find.byKey(PlayerKeys.resumeFromStart), findsOneWidget);
    expect(find.byKey(CatalogKeys.detailSubtitle), findsOneWidget);
    expect(
      tester.widget(find.byKey(CatalogKeys.detailSubtitle)),
      isA<ScrimIconButton>(),
    );
    expect(find.byKey(CatalogKeys.seriesLink), findsNothing);
    expect(find.byKey(CatalogKeys.episodesRow), findsNothing);
    expect(find.byKey(CatalogKeys.overview), findsOneWidget);
    expect(find.text('简介'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(ItemDetailPage.posterKey),
        matching: find.text(
          'A thief who steals corporate secrets through dream-sharing.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
    expect(
      find.byKey(CatalogKeys.shelfScrollRight(CatalogKeys.shelfChapters)),
      findsNothing,
    );
  });

  testWidgets('series header renders poster and a full-width episode list', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    expectHeaderShape(tester, posterSize: const Size(200, 300));
    expect(tester.widget<SelectableText>(_headerTitle()).data, contains('老友记'));
    expect(find.byKey(CatalogKeys.viewEpisode), findsNothing);
    expect(find.byKey(CatalogKeys.playTarget), findsOneWidget);
    expect(find.text('播放 S1E1'), findsOneWidget);
    expect(find.byKey(CatalogKeys.seriesLink), findsNothing);
    expect(find.byKey(CatalogKeys.overview), findsOneWidget);
    expect(find.text('简介'), findsNothing);
    expect(find.text('Six friends living in New York.'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(ItemDetailPage.posterKey),
        matching: find.text('Six friends living in New York.'),
      ),
      findsNothing,
    );
    final row = find.byKey(CatalogKeys.episodesRow);
    // 行内承载「N. 标题」与本集简介(纵向列表,ADR-3 修订)。
    expect(
      find.descendant(of: row, matching: find.text('1. The Pilot')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.text('Monica gets a new apartment.'),
      ),
      findsOneWidget,
    );
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('集')), findsOneWidget);
    expect(
      find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfEpisodes)),
      findsOneWidget,
    );
    expect(_episodeCardIds(tester), [
      'episode-friends-s1e1',
      'episode-friends-s1e2',
    ]);
    // 纵向行列表:两行纵向排布,行内容自适应伸展铺满内容宽,
    // 不再有 1080px 上限;每行缩略图左、文本中、操作右。
    final first = tester.getRect(
      find.byKey(CatalogKeys.episode('episode-friends-s1e1')),
    );
    final second = tester.getRect(
      find.byKey(CatalogKeys.episode('episode-friends-s1e2')),
    );
    const contentWidth = 1200 - AppSpacing.page * 2;
    expect(first.width, moreOrLessEquals(contentWidth));
    expect(second.top, greaterThanOrEqualTo(first.bottom));
    expect(second.left, first.left);
    expect(_cardSelected(tester, 'episode-friends-s1e1'), isTrue);
    expect(_cardSelected(tester, 'episode-friends-s1e2'), isFalse);
    // 操作控件保留在树中(键盘/测试可达),平时隐藏、选中时可见。
    for (final id in _episodeCardIds(tester)) {
      expect(find.byKey(CatalogKeys.episodePlay(id)), findsOneWidget);
      expect(find.byKey(CatalogKeys.episodePlayed(id)), findsOneWidget);
    }
  });

  testWidgets('episode list rows keep synopsis and meta', (tester) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    final row = find.byKey(CatalogKeys.episodesRow);
    // 行内承载「N. 标题」、时长与简介(ADR-3 修订:恢复纵向列表)。
    expect(
      find.descendant(of: row, matching: find.text('1. The Pilot')),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.text('22分钟')), findsWidgets);
    expect(
      find.descendant(
        of: row,
        matching: find.text('Monica gets a new apartment.'),
      ),
      findsOneWidget,
    );
    // 未悬停时操作控件隐藏。
    final play = find.byKey(CatalogKeys.episodePlay('episode-friends-s1e2'));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(of: play, matching: find.byType(AnimatedOpacity)),
          )
          .opacity,
      0,
    );
  });

  testWidgets(
    'episode list rows fill the window width below the compact breakpoint',
    (tester) async {
      final app = await pumpApp(tester, viewSize: const Size(900, 800));
      await openItem(tester, app, _series);

      final first = tester.getRect(
        find.byKey(CatalogKeys.episode('episode-friends-s1e1')),
      );
      final second = tester.getRect(
        find.byKey(CatalogKeys.episode('episode-friends-s1e2')),
      );
      expect(second.top, greaterThanOrEqualTo(first.bottom));
      expect(second.left, first.left);
      expect(first.width, 900 - AppSpacing.page * 2);
    },
  );

  testWidgets('episode card tap opens details instead of playing', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final row = find.byKey(CatalogKeys.episode(id));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(app.router.state.uri.path, AppRoutes.item(id));
    expect(app.windowHost.current, isNull);
    expect(find.textContaining('The One with the Sonogram'), findsWidgets);
    expect(find.byKey(CatalogKeys.viewSeries), findsOneWidget);
  });

  testWidgets('episode card play button starts playback', (tester) async {
    final host = _SilentPlayerHost();
    final app = await pumpApp(tester, host: host);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final play = find.byKey(CatalogKeys.episodePlay(id));
    await tester.ensureVisible(play);
    await tester.pumpAndSettle();
    await tester.tap(play);
    await tester.pumpAndSettle();

    expect(app.router.state.uri.path, AppRoutes.item(_series));
    expect(host.current?.itemId, id);
  });

  testWidgets('episode header omits the duplicate poster thumb', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s1e2');

    // 单集 hero 不重复显示与 backdrop 同源的小缩略图,信息区铺满底部。
    expect(find.byKey(ItemDetailPage.posterKey), findsNothing);
    final header = find.byKey(ItemDetailPage.headerKey);
    final rect = tester.getRect(header);
    expect(rect.width, 1200);
    expect(
      tester.getRect(_headerTitle()).left,
      greaterThanOrEqualTo(AppSpacing.page),
    );
    expect(
      tester.widget<SelectableText>(_headerTitle()).data,
      contains('The One with the Sonogram'),
    );
    expect(find.byKey(CatalogKeys.seriesLink), findsOneWidget);
    expect(find.byKey(CatalogKeys.viewSeries), findsOneWidget);
    expect(find.byKey(CatalogKeys.locateEpisode), findsOneWidget);
    // 单集简介由概览分区承载(可展开收起),海报不再叠简介带。
    expect(find.byKey(CatalogKeys.overview), findsNothing);
    expect(find.text('简介'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(ItemDetailPage.posterKey),
        matching: find.text('Six friends living in New York.'),
      ),
      findsNothing,
    );
    expect(
      tester.widget<Text>(find.byKey(EpisodeOverviewSection.textKey)).data,
      'Six friends living in New York.',
    );
    expect(find.byKey(CatalogKeys.episodesRow), findsNothing);

    expect(find.byKey(PlayerKeys.open), findsOneWidget);
  });

  testWidgets('resumable episode shows continue play', (tester) async {
    const ticksPerMinute = 10000000 * 60;
    server.setEpisodes(_series, const [
      FakeEpisode(
        id: 'resume-e9',
        name: '第 9 集',
        seasonId: _season1,
        indexNumber: 9,
        runTimeTicks: ticksPerMinute * 24,
        playbackPositionTicks: ticksPerMinute * 10,
        playedPercentage: 42,
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, 'resume-e9');

    expect(find.byKey(PlayerKeys.open), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(PlayerKeys.open),
        matching: find.text('继续播放'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(CatalogKeys.episodesRow), findsNothing);
  });

  testWidgets('closing the player refreshes detail playback progress', (
    tester,
  ) async {
    const ticksPerMinute = 10000000 * 60;
    server.setEpisodes(_series, const [
      FakeEpisode(
        id: 'resume-e9',
        name: '第 9 集',
        seasonId: _season1,
        indexNumber: 9,
        runTimeTicks: ticksPerMinute * 24,
        playbackPositionTicks: ticksPerMinute * 10,
        playedPercentage: 42,
      ),
    ]);
    final host = _SilentPlayerHost();
    final app = await pumpApp(tester, host: host);
    await openItem(tester, app, 'resume-e9');
    expect(find.text('已看 42%'), findsWidgets);

    final item = server.items.firstWhere((entry) => entry.id == 'resume-e9');
    item.playbackPositionTicks = ticksPerMinute * 20;
    item.playedPercentage = 80;

    await host.open(const PlayerOpenRequest(itemId: 'resume-e9'));
    await tester.pump();
    await host.close();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('已看 80%'), findsWidgets);
    expect(find.text('已看 42%'), findsNothing);
  });

  testWidgets('episode card check marks the episode played', (tester) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final toggle = find.byKey(CatalogKeys.episodePlayed(id));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
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

  testWidgets('episode card check can clear played', (tester) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e1';
    final toggle = find.byKey(CatalogKeys.episodePlayed(id));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(toggle).tooltip, '标记未看');

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(
      server.requests.any(
        (request) =>
            request.contains('DELETE ') && request.contains('/PlayedItems/$id'),
      ),
      isTrue,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(CatalogKeys.episodePlayed(id)))
          .tooltip,
      '标记已看',
    );
  });

  testWidgets('episode card context menu can mark played', (tester) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    const id = 'episode-friends-s1e2';
    final row = find.byKey(CatalogKeys.episode(id));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('标记已看'), findsOneWidget);
    await tester.tap(find.text('标记已看'));
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

  testWidgets('skeleton header matches the loaded header height', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    server.itemDelay = const Duration(seconds: 1);

    app.router.push(AppRoutes.item('movie-inception'));
    await tester.pump();
    await tester.pump();
    final skeleton = find.byKey(ItemDetailPage.skeletonHeaderKey);
    expect(skeleton, findsOneWidget);
    expect(find.byKey(ItemDetailPage.headerKey), findsNothing);
    final skeletonSize = tester.getSize(skeleton);

    await tester.pumpAndSettle();
    final header = find.byKey(ItemDetailPage.headerKey);
    expect(header, findsOneWidget);
    expect(find.byKey(ItemDetailPage.skeletonHeaderKey), findsNothing);
    final headerSize = tester.getSize(header);
    expect(headerSize.width, skeletonSize.width);
    expect(headerSize.height, skeletonSize.height);
    expect(
      headerSize.height,
      greaterThanOrEqualTo(ItemDetailPage.headerHeightFor(1200, 800)),
    );
  });

  testWidgets('episodes sharing an index number stay as distinct cards', (
    tester,
  ) async {
    server.setEpisodes(_series, const [
      FakeEpisode(
        id: 'dup-e1',
        name: 'Pilot',
        seasonId: _season1,
        indexNumber: 1,
      ),
      FakeEpisode(
        id: 'dup-e2-web',
        name: 'Second (WEB)',
        seasonId: _season1,
        indexNumber: 2,
      ),
      FakeEpisode(
        id: 'dup-e2-bd',
        name: 'Second (BD)',
        seasonId: _season1,
        indexNumber: 2,
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    final ids = _episodeCardIds(tester);
    expect(ids, ['dup-e1', 'dup-e2-web', 'dup-e2-bd']);
    expect(ids.toSet().length, ids.length);
    expect(_cardSelected(tester, 'dup-e1'), isTrue);
    expect(_cardSelected(tester, 'dup-e2-web'), isFalse);
    expect(_cardSelected(tester, 'dup-e2-bd'), isFalse);
  });

  testWidgets('episode whose season is missing still lists by its seasonId', (
    tester,
  ) async {
    server.setSeasons(_series, const [
      FakeSeason(id: _season1, name: '第 1 季', indexNumber: 1),
    ]);
    server.setEpisodes(_series, const [
      FakeEpisode(
        id: 'ghost-e1',
        name: 'Lost One',
        seasonId: 'season-ghost',
        indexNumber: 1,
        parentIndexNumber: 1,
      ),
      FakeEpisode(
        id: 'ghost-e2',
        name: 'Lost Two',
        seasonId: 'season-ghost',
        indexNumber: 2,
        parentIndexNumber: 1,
      ),
    ]);
    final app = await pumpApp(tester);
    server.requests.clear();
    await openItem(tester, app, 'ghost-e1');

    final episodeQueries = server.requests
        .where(
          (request) =>
              request.contains('/Items?') &&
              request.contains('IncludeItemTypes=Episode'),
        )
        .toList();
    expect(
      episodeQueries.where((r) => r.contains('ParentId=season-ghost')),
      isNotEmpty,
    );
    expect(
      episodeQueries.where((r) => r.contains('ParentId=$_season1')),
      isEmpty,
    );
    expect(find.byKey(CatalogKeys.episodesRow), findsNothing);
    expect(find.byKey(CatalogKeys.nextEpisode), findsOneWidget);
    expect(find.byKey(CatalogKeys.viewSeries), findsOneWidget);
  });

  testWidgets('season switch failure shows an inline error that retries', (
    tester,
  ) async {
    server.setSeasons(_series, const [
      FakeSeason(id: _season1, name: '第 1 季', indexNumber: 1),
      FakeSeason(id: 'season-friends-2', name: '第 2 季', indexNumber: 2),
    ]);
    server.setEpisodes(_series, const [
      FakeEpisode(id: 's1e1', name: 'One', seasonId: _season1, indexNumber: 1),
      FakeEpisode(
        id: 's2e1',
        name: 'Two',
        seasonId: 'season-friends-2',
        indexNumber: 1,
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);
    expect(_episodeCardIds(tester), ['s1e1']);

    server.itemsStatus = 500;
    final picker = find.byKey(CatalogKeys.seasonPicker);
    await ensureVisibleBelowTopBar(tester, picker);
    await tapBelowTopBar(tester, picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 2 季').last);
    await tester.pumpAndSettle();

    final row = find.byKey(CatalogKeys.episodesRow);
    expect(row, findsOneWidget);
    final error = find.descendant(of: row, matching: find.byType(AppErrorView));
    expect(error, findsOneWidget);
    expect(_episodeCardIds(tester), isEmpty);

    server.itemsStatus = null;
    final retry = find.descendant(
      of: error,
      matching: find.byType(FilledButton),
    );
    expect(retry, findsOneWidget);
    await ensureVisibleBelowTopBar(tester, retry);
    await tapBelowTopBar(tester, retry);
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsNothing);
    expect(_episodeCardIds(tester), ['s2e1']);
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

  testWidgets('jumping to an off-screen episode scrolls it into view', (
    tester,
  ) async {
    server.setEpisodes(_series, [
      for (var i = 1; i <= 40; i++)
        FakeEpisode(
          id: 'bulk-e$i',
          name: 'Episode $i',
          seasonId: _season1,
          indexNumber: i,
        ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);
    expect(_cardSelected(tester, 'bulk-e1'), isTrue);

    final locate = find.byKey(CatalogKeys.locateEpisode);
    await ensureVisibleBelowTopBar(tester, locate);
    await tapBelowTopBar(tester, locate);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '40');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    expect(_cardSelected(tester, 'bulk-e40'), isTrue);
    final barBottom = tester.getRect(find.byKey(AppShell.topBarKey)).bottom;
    final rect = tester.getRect(find.byKey(CatalogKeys.episode('bulk-e40')));
    expect(rect.bottom, greaterThan(barBottom));
    expect(rect.top, lessThan(800));
  });

  testWidgets('empty season still shows the season picker', (tester) async {
    server.setSeasons(_series, const [
      FakeSeason(id: _season1, name: '第 1 季', indexNumber: 1),
      FakeSeason(id: 'season-friends-2', name: '第 2 季', indexNumber: 2),
    ]);
    server.setEpisodes(_series, const [
      FakeEpisode(id: 's1e1', name: 'One', seasonId: _season1, indexNumber: 1),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);
    expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);

    final picker = find.byKey(CatalogKeys.seasonPicker);
    await ensureVisibleBelowTopBar(tester, picker);
    await tapBelowTopBar(tester, picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 2 季').last);
    await tester.pumpAndSettle();

    expect(find.byKey(CatalogKeys.episodesRow), findsOneWidget);
    expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
    expect(_episodeCardIds(tester), isEmpty);

    await ensureVisibleBelowTopBar(
      tester,
      find.byKey(CatalogKeys.seasonPicker),
    );
    await tapBelowTopBar(tester, find.byKey(CatalogKeys.seasonPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1 季').last);
    await tester.pumpAndSettle();
    expect(_episodeCardIds(tester), ['s1e1']);
  });

  testWidgets('episode meta row shows premiere date and metadata section', (
    tester,
  ) async {
    server.setEpisodes(_series, [
      FakeEpisode(
        id: 'dated-e1',
        name: 'Dated One',
        seasonId: _season1,
        indexNumber: 1,
        premiereDate: DateTime.utc(2024, 11, 4),
        dateCreated: DateTime.utc(2025, 1, 15),
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, 'dated-e1');

    // 元信息行播出日期胶囊(yyyy-MM-dd)。
    expect(find.text('首播 2024-11-04'), findsOneWidget);
    // 元数据分区:入库日期。
    expect(find.byKey(EpisodeMetadataSection.sectionKey), findsOneWidget);
    expect(find.text('入库日期'), findsOneWidget);
    expect(find.text('2025-01-15'), findsOneWidget);
  });

  testWidgets('episode meta row omits the premiere date when missing', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s1e2');

    // 无播出日期时省略该胶囊,不留占位文案。
    expect(find.textContaining('首播'), findsNothing);
    // 有入库日期,元数据分区仍渲染。
    expect(find.byKey(EpisodeMetadataSection.sectionKey), findsOneWidget);
  });

  testWidgets('episode overview expands and collapses', (tester) async {
    final longOverview = List.filled(
      60,
      'Monica gets a new apartment and the gang adjusts to the change.',
    ).join(' ');
    server.setEpisodes(_series, [
      FakeEpisode(
        id: 'long-e1',
        name: 'Long One',
        seasonId: _season1,
        indexNumber: 1,
        overview: longOverview,
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, 'long-e1');

    final text = find.byKey(EpisodeOverviewSection.textKey);
    expect(text, findsOneWidget);
    expect(tester.widget<Text>(text).maxLines, 3);
    final toggle = find.byKey(EpisodeOverviewSection.toggleKey);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: toggle, matching: find.text('展开')),
      findsOneWidget,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(text).maxLines, isNull);
    expect(
      find.descendant(of: toggle, matching: find.text('收起')),
      findsOneWidget,
    );

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(text).maxLines, 3);
    expect(
      find.descendant(of: toggle, matching: find.text('展开')),
      findsOneWidget,
    );
  });

  testWidgets('episode people section renders grouped cast with fallback', (
    tester,
  ) async {
    server.setEpisodes(_series, const [
      FakeEpisode(
        id: 'cast-e1',
        name: 'Cast One',
        seasonId: _season1,
        indexNumber: 1,
      ),
    ]);
    server.items.firstWhere((item) => item.id == 'cast-e1').people = const [
      FakePerson(name: 'Courteney Cox', type: 'Actor', role: 'Monica Geller'),
      FakePerson(name: 'James Burrows', type: 'Director'),
      FakePerson(name: 'David Crane', type: 'Writer'),
    ];
    final app = await pumpApp(tester);
    await openItem(tester, app, 'cast-e1');

    final section = find.byKey(EpisodePeopleSection.sectionKey);
    expect(section, findsOneWidget);
    expect(find.text('演职员'), findsOneWidget);
    expect(find.text('演员'), findsOneWidget);
    expect(find.text('导演'), findsOneWidget);
    expect(find.text('编剧'), findsOneWidget);
    expect(find.text('Courteney Cox'), findsOneWidget);
    expect(find.text('Monica Geller'), findsOneWidget);
    expect(find.text('James Burrows'), findsOneWidget);
    // 无图条目以名字首字圆形兜底。
    expect(find.text('D'), findsOneWidget);
  });

  testWidgets('episode people section is hidden without people', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s1e2');

    expect(find.byKey(EpisodePeopleSection.sectionKey), findsNothing);
    expect(find.text('演职员'), findsNothing);
  });

  testWidgets('episode media streams section renders grouped tracks', (
    tester,
  ) async {
    server.setEpisodes(_series, const [
      FakeEpisode(
        id: 'media-e1',
        name: 'Media One',
        seasonId: _season1,
        indexNumber: 1,
        mediaStreams: [
          FakeMediaStream(
            index: 0,
            type: 'Video',
            codec: 'h264',
            displayTitle: '1080p',
          ),
          FakeMediaStream(
            index: 1,
            type: 'Audio',
            codec: 'ac3',
            language: 'eng',
            displayTitle: 'English',
            isDefault: true,
            channels: 6,
          ),
          FakeMediaStream(
            index: 2,
            type: 'Subtitle',
            codec: 'subrip',
            language: 'chi',
            displayTitle: '中文',
            isTextSubtitleStream: true,
          ),
        ],
      ),
    ]);
    final app = await pumpApp(tester);
    await openItem(tester, app, 'media-e1');

    expect(find.byKey(EpisodeMediaStreamsSection.sectionKey), findsOneWidget);
    expect(find.text('媒体信息'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('音轨'), findsOneWidget);
    expect(find.text('字幕'), findsOneWidget);
    expect(find.textContaining('H264'), findsOneWidget);
    expect(find.textContaining('AC3'), findsOneWidget);
    expect(find.textContaining('6 声道'), findsOneWidget);
    expect(find.textContaining('SUBRIP'), findsOneWidget);
  });

  testWidgets('episode media section is hidden without streams', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s1e2');

    expect(find.byKey(EpisodeMediaStreamsSection.sectionKey), findsNothing);
    expect(find.text('媒体信息'), findsNothing);
  });

  testWidgets('next episode card opens the next episode detail', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s1e1');

    final card = find.byKey(NextEpisodeCard.cardKey);
    expect(card, findsOneWidget);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(app.router.state.uri.path, AppRoutes.item('episode-friends-s1e2'));
    expect(find.textContaining('The One with the Sonogram'), findsWidgets);
  });

  testWidgets('next episode card is hidden on the season finale', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s1e2');

    expect(find.byKey(NextEpisodeCard.sectionKey), findsNothing);
    expect(find.byKey(NextEpisodeCard.cardKey), findsNothing);
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
