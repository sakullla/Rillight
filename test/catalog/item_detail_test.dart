import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/routes.dart';
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
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_keys.dart';

import '../emby/fake_emby_server.dart';

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

  Future<RillightApp> pumpApp(WidgetTester tester) async {
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
    final app = RillightApp(auth: auth);
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
    expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
    expect(
      find.byKey(CatalogKeys.shelfScrollRight(CatalogKeys.shelfChapters)),
      findsNothing,
    );
  });

  testWidgets('series header renders poster and a vertical episode list', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, _series);

    expectHeaderShape(tester, posterSize: const Size(200, 300));
    expect(tester.widget<SelectableText>(_headerTitle()).data, contains('老友记'));
    expect(find.byKey(CatalogKeys.viewEpisode), findsOneWidget);
    expect(find.byKey(CatalogKeys.seriesLink), findsNothing);

    final row = find.byKey(CatalogKeys.episodesRow);
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('集')), findsOneWidget);
    expect(
      find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfEpisodes)),
      findsOneWidget,
    );
    expect(_episodeRowIds(tester), [
      'episode-friends-s1e1',
      'episode-friends-s1e2',
    ]);
    // 纵向列表:第二行在第一行下方,而不是右侧。
    final first = tester.getRect(
      find.byKey(CatalogKeys.episode('episode-friends-s1e1')),
    );
    final second = tester.getRect(
      find.byKey(CatalogKeys.episode('episode-friends-s1e2')),
    );
    expect(second.top, greaterThanOrEqualTo(first.bottom));
    expect(second.left, first.left);
    for (final id in _episodeRowIds(tester)) {
      expect(_rowSelected(tester, id), isFalse, reason: id);
    }
  });

  testWidgets('episode header uses a 16:9 thumb and marks the current row', (
    tester,
  ) async {
    final app = await pumpApp(tester);
    await openItem(tester, app, 'episode-friends-s1e2');

    expectHeaderShape(tester, posterSize: const Size(320, 180));
    expect(
      tester.widget<SelectableText>(_headerTitle()).data,
      contains('The One with the Sonogram'),
    );
    expect(find.byKey(CatalogKeys.seriesLink), findsOneWidget);
    expect(find.byKey(CatalogKeys.viewSeries), findsNothing);
    expect(find.byKey(CatalogKeys.locateEpisode), findsOneWidget);

    expect(_episodeRowIds(tester), [
      'episode-friends-s1e1',
      'episode-friends-s1e2',
    ]);
    expect(_rowSelected(tester, 'episode-friends-s1e2'), isTrue);
    expect(_rowSelected(tester, 'episode-friends-s1e1'), isFalse);

    final thumb = find.descendant(
      of: find.byKey(CatalogKeys.episode('episode-friends-s1e1')),
      matching: find.byType(MediaImage),
    );
    expect(thumb, findsOneWidget);
    expect(tester.widget<MediaImage>(thumb).preferThumb, isTrue);
    expect(tester.getSize(thumb), const Size(224, 126));
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

  testWidgets('episodes sharing an index number stay as distinct rows', (
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
    await openItem(tester, app, 'dup-e2-web');

    final ids = _episodeRowIds(tester);
    expect(ids, ['dup-e1', 'dup-e2-web', 'dup-e2-bd']);
    expect(ids.toSet().length, ids.length);
    expect(_rowSelected(tester, 'dup-e2-web'), isTrue);
    expect(_rowSelected(tester, 'dup-e2-bd'), isFalse);
    expect(_rowSelected(tester, 'dup-e1'), isFalse);
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
    final ids = _episodeRowIds(tester);
    expect(ids, ['ghost-e1', 'ghost-e2']);
    expect(ids.toSet().length, ids.length);
    expect(_rowSelected(tester, 'ghost-e1'), isTrue);
    expect(find.byKey(CatalogKeys.nextEpisode), findsOneWidget);
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
    expect(_episodeRowIds(tester), ['s1e1']);

    server.itemsStatus = 500;
    final picker = find.byKey(CatalogKeys.seasonPicker);
    await _ensureVisibleBelowTopBar(tester, picker);
    await _tapBelowTopBar(tester, picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 2 季').last);
    await tester.pumpAndSettle();

    final row = find.byKey(CatalogKeys.episodesRow);
    expect(row, findsOneWidget);
    final error = find.descendant(of: row, matching: find.byType(AppErrorView));
    expect(error, findsOneWidget);
    expect(_episodeRowIds(tester), isEmpty);

    server.itemsStatus = null;
    final retry = find.descendant(
      of: error,
      matching: find.byType(FilledButton),
    );
    expect(retry, findsOneWidget);
    await _ensureVisibleBelowTopBar(tester, retry);
    await _tapBelowTopBar(tester, retry);
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsNothing);
    expect(_episodeRowIds(tester), ['s2e1']);
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

    var ids = _episodeRowIds(tester);
    expect(ids.length, 80);
    expect(ids.first, 'bulk-e1');
    expect(ids.last, 'bulk-e80');
    final more = find.byKey(CatalogKeys.episodesLoadMore);
    expect(more, findsOneWidget);
    expect(tester.widget(more), isA<OutlinedButton>());

    await _ensureVisibleBelowTopBar(tester, more);
    await _tapBelowTopBar(tester, more);
    await tester.pumpAndSettle();

    ids = _episodeRowIds(tester);
    expect(ids.length, 100);
    expect(ids.toSet().length, 100);
    expect(ids.last, 'bulk-e100');
    expect(find.byKey(CatalogKeys.episodesLoadMore), findsNothing);
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

/// 分集分区内各行的条目 id,按渲染顺序。
List<String> _episodeRowIds(WidgetTester tester) {
  final row = find.byKey(CatalogKeys.episodesRow);
  if (row.evaluate().isEmpty) {
    return const [];
  }
  final wells = find.descendant(of: row, matching: find.byType(InkWell));
  return [
    for (final element in wells.evaluate())
      if (element.widget.key case ValueKey<String>(
        value: final value,
      ) when value.startsWith(_episodeKeyPrefix))
        value.substring(_episodeKeyPrefix.length),
  ];
}

/// 当前集行以 surfaceContainerHigh 底色标示;其余行透明。
bool _rowSelected(WidgetTester tester, String id) {
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

/// 顶栏叠在内容上时,控件中心可能落在栏内;点到栏下方仍落在同一控件上的位置。
Future<void> _tapBelowTopBar(WidgetTester tester, Finder finder) async {
  final bar = find.byKey(AppShell.topBarKey);
  final rect = tester.getRect(finder);
  var dy = rect.center.dy;
  if (bar.evaluate().isNotEmpty) {
    final barBottom = tester.getRect(bar).bottom;
    if (dy <= barBottom) {
      dy = (barBottom + 1).clamp(rect.top + 1, rect.bottom - 1).toDouble();
    }
  }
  await tester.tapAt(Offset(rect.center.dx, dy));
}

Future<void> _ensureVisibleBelowTopBar(
  WidgetTester tester,
  Finder finder,
) async {
  final context = tester.element(finder);
  final scrollable = Scrollable.maybeOf(context);
  if (scrollable == null) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    return;
  }
  final viewport = scrollable.position.viewportDimension;
  final bar = find.byKey(AppShell.topBarKey);
  final barBottom = bar.evaluate().isEmpty ? 0.0 : tester.getRect(bar).bottom;
  final alignment = viewport <= 0 ? 0.0 : ((barBottom + 8) / viewport);
  await Scrollable.ensureVisible(
    context,
    alignment: alignment.clamp(0.0, 1.0).toDouble(),
    duration: Duration.zero,
  );
  await tester.pumpAndSettle();
}
