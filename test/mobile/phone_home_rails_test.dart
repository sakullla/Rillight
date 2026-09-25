import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-home-rails',
  version: '1',
);

const _filteredShelfPage =
    '{"Items":[{"Id":"series-filtered","Name":"仅新筛选","Type":"Series"}],"TotalRecordCount":1}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(isolateImageCache);

  tearDown(PhoneHomeSectionController.debugResetApp);

  for (final width in [360.0, 412.0]) {
    testWidgets(
      'shelf skeleton matches the poster grid at ${width.toInt()}dp',
      (tester) async {
        final harness = await _pumpShelf(
          tester,
          width: width,
          source: 'latest-series',
          items: [
            for (var i = 0; i < 6; i++)
              FakeEmbyItem(id: 'series-$i', name: '剧集 $i', type: 'Series'),
          ],
        );
        await _expectPosterGrid(tester, width);
        expect(
          tester
              .widgetList<SkeletonBlock>(find.byType(SkeletonBlock))
              .every((block) => !block.animated),
          isTrue,
        );
        expect(tester.binding.transientCallbackCount, 0);

        harness.hold.release();
        await tester.pumpAndSettle();
        final posters = find.byType(MobilePoster);
        expect(posters, findsAtLeastNWidgets(3));
        final first = tester.getRect(posters.at(0));
        final second = tester.getRect(posters.at(1));
        final third = tester.getRect(posters.at(2));
        expect(first.top, closeTo(second.top, 1));
        expect(second.top, closeTo(third.top, 1));
        expect(first.left, closeTo(16, 1));
        expect(third.right, closeTo(width - 16, 1));
        expect(second.left - first.right, closeTo(AppSpacing.sm, 1));
        expect(tester.takeException(), isNull);

        harness.hold.holdLists = true;
        await tester.tap(find.byKey(const Key('phone-shelf-filter')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('catalog-filter-watch-unplayed')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('剧集 0'), findsOneWidget);
        expect(find.text('剧集 1'), findsOneWidget);
        expect(find.text('剧集 2'), findsOneWidget);
        harness.hold.release();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets(
      'continue shelf uses the same poster grid at ${width.toInt()}dp',
      (tester) async {
        final harness = await _pumpShelf(
          tester,
          width: width,
          source: 'resume',
        );
        await _expectPosterGrid(tester, width);
        harness.hold.release();
        await tester.pumpAndSettle();
        final posters = find.byType(MobilePoster);
        expect(posters, findsAtLeastNWidgets(1));
        expect(tester.getRect(posters.at(0)).left, closeTo(16, 1));
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  testWidgets('kept shelf filter failure retries page zero', (tester) async {
    final harness = await _pumpShelf(
      tester,
      width: 360,
      height: 1200,
      source: 'latest-series',
      items: _series(6),
    );
    harness.hold.release();
    await tester.pumpAndSettle();
    expect(find.text('剧集 0'), findsOneWidget);
    harness.hold.failFilteredRemaining = 1;
    harness.hold.filteredBody = _filteredShelfPage;
    await _tapUnplayed(tester);
    await tester.pumpAndSettle();
    expect(find.text('剧集 0'), findsOneWidget);
    expect(find.byKey(MobileFailureState.retryKey), findsOneWidget);
    expect(find.byKey(PhoneShelfPage.loadMoreKey), findsNothing);

    await tester.tap(find.byKey(MobileFailureState.retryKey));
    await tester.pumpAndSettle();
    expect(find.text('仅新筛选'), findsOneWidget);
    expect(find.text('剧集 0'), findsNothing);
    expect(find.text('老友记'), findsNothing);
    _expectUnplayedFirstPage(harness.hold.itemRequests);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'in-flight shelf filter blocks load more and retry replaces the page',
    (tester) async {
      final harness = await _pumpShelf(
        tester,
        width: 360,
        height: 5200,
        source: 'latest-series',
        items: _series(60),
      );
      harness.hold.release();
      await tester.pumpAndSettle();
      expect(find.text('老友记'), findsOneWidget);
      expect(find.byKey(PhoneShelfPage.loadMoreKey), findsOneWidget);
      final loaded = harness.hold.itemRequests.length;

      harness.hold.holdLists = true;
      harness.hold.failFilteredRemaining = 1;
      harness.hold.filteredBody = _filteredShelfPage;
      await _tapUnplayed(tester);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('老友记'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(PhoneShelfPage.loadMoreKey))
            .onPressed,
        isNull,
      );

      harness.hold.release();
      await tester.pumpAndSettle();
      expect(find.text('老友记'), findsOneWidget);
      expect(find.byKey(MobileFailureState.retryKey), findsOneWidget);
      expect(find.byKey(PhoneShelfPage.loadMoreKey), findsNothing);

      await tester.ensureVisible(find.byKey(MobileFailureState.retryKey));
      await tester.tap(find.byKey(MobileFailureState.retryKey));
      await tester.pumpAndSettle();
      expect(find.text('仅新筛选'), findsOneWidget);
      expect(find.text('老友记'), findsNothing);
      expect(find.text('剧集 0'), findsNothing);
      _expectUnplayedFirstPage(harness.hold.itemRequests.skip(loaded));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('home row placeholders follow wide and poster cards', (
    tester,
  ) async {
    await _pumpSurface(tester, width: 360, height: 800);
    final auth = AuthController.memory();
    final catalog = CatalogController(auth: auth);
    addTearDown(catalog.dispose);
    addTearDown(auth.dispose);
    catalog
      ..resume = const CatalogRowState(loading: true)
      ..nextUp = const CatalogRowState(loading: true)
      ..latestMovies = const CatalogRowState(loading: true)
      ..latestSeries = const CatalogRowState(loading: true)
      ..librariesLoading = false;
    await tester.pumpWidget(_homeApp(catalog));
    await tester.pump();
    final blocks = tester
        .widgetList<SkeletonBlock>(find.byType(SkeletonBlock))
        .where((block) => (block.height ?? 0) > 20)
        .toList();
    expect(
      blocks.where((block) => _isRatio(block, 9 / 16)).length,
      greaterThanOrEqualTo(2),
    );
    expect(
      blocks.where((block) => _isRatio(block, 1.5)).length,
      greaterThanOrEqualTo(3),
    );
    expect(
      blocks
          .where(
            (block) =>
                ((block.width ?? 0) - phoneHomeWideCardWidth(360)).abs() < 0.5,
          )
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(
      blocks
          .where(
            (block) =>
                ((block.width ?? 0) - phoneHomePosterCardWidth(360)).abs() <
                0.5,
          )
          .length,
      greaterThanOrEqualTo(3),
    );

    catalog
      ..resume = const CatalogRowState(loading: true)
      ..nextUp = const CatalogRowState(hidden: true)
      ..latestMovies = CatalogRowState(items: [_movie('movie-a', '甲')])
      ..latestSeries = const CatalogRowState(loading: true);
    catalog.notifyListeners();
    await tester.pump();
    _expectRowShape(
      tester,
      find.byKey(CatalogKeys.resumeRow),
      wide: true,
      screen: 360,
    );
    _expectRowShape(
      tester,
      find.byKey(CatalogKeys.latestSeriesRow),
      wide: false,
      screen: 360,
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  for (final width in [360.0, 412.0]) {
    testWidgets(
      'home rails peek one card and clear the nav at ${width.toInt()}dp',
      (tester) async {
        await _pumpRails(tester, width: width, height: 800);
        _expectPeek(tester, width);
        final navTop = tester.getTopLeft(find.byType(PhoneBottomNav)).dy;
        final title = tester.getRect(find.text('继续观看'));
        final picture = tester.getRect(
          find.descendant(
            of: find.byKey(CatalogKeys.item('ep-1')),
            matching: find.byType(AspectRatio),
          ),
        );
        expect(title.bottom, lessThanOrEqualTo(navTop + 0.5));
        expect(picture.bottom, lessThanOrEqualTo(navTop + 0.5));
        final badges = tester.getRect(find.byKey(phoneHomeBadgesKey('ep-1')));
        expect(badges.top, greaterThanOrEqualTo(picture.bottom - 0.5));
        final remove = tester.getRect(
          find.byKey(CatalogKeys.removeFromResume('ep-1')),
        );
        expect(remove.width, greaterThanOrEqualTo(48));
        expect(remove.height, greaterThanOrEqualTo(48));
        final overlap = remove.intersect(picture);
        expect(
          overlap.width * overlap.height,
          lessThan(picture.width * picture.height * 0.5),
        );
        expect(
          tester.getTopLeft(find.text('最近更新的电影')).dy -
              tester.getRect(find.byKey(CatalogKeys.item('ep-1'))).bottom,
          greaterThanOrEqualTo(16),
        );

        await tester.fling(
          find.byKey(CatalogKeys.resumeRow),
          const Offset(-180, 0),
          800,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );
  }

  testWidgets('a short viewport only compresses the banner extension', (
    tester,
  ) async {
    await _pumpRails(tester, width: 360, height: 560);
    final navTop = tester.getTopLeft(find.byType(PhoneBottomNav)).dy;
    final picture = tester.getRect(
      find.descendant(
        of: find.byKey(CatalogKeys.item('ep-1')),
        matching: find.byType(AspectRatio),
      ),
    );
    final natural = tester.getSize(find.byKey(PhoneHero.bannerKey)).height;
    final clips = find.ancestor(
      of: find.byKey(PhoneHero.bannerKey),
      matching: find.byType(ClipRect),
    );
    var fitted = natural;
    for (var i = 0; i < clips.evaluate().length; i++) {
      final height = tester.getSize(clips.at(i)).height;
      if (height < fitted) {
        fitted = height;
      }
    }
    expect(picture.bottom, lessThanOrEqualTo(navTop + 1));
    expect(fitted, lessThan(natural - 1));
    expect(fitted, greaterThanOrEqualTo(360 * 9 / 16 - 1));
    expect(tester.getTopLeft(find.text('继续观看')).dy, lessThan(navTop));
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('home keeps its scroll offset across detail and reduced motion', (
    tester,
  ) async {
    await _pumpSurface(tester, width: 360, height: 800);
    final server = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(() async {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    final router = createAppRouter(
      auth: auth,
      environment: PresentationEnvironment.phone,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      ),
    );
    await _settle(tester);
    final scroll = _homeScroll(tester);
    scroll.jumpTo(220);
    await tester.pump();
    final before = scroll.pixels;
    router.push('/item/movie-inception');
    await _settle(tester);
    expect(find.byType(MobileDetailPage), findsOneWidget);
    router.pop();
    await _settle(tester);
    expect((_homeScroll(tester).pixels - before).abs(), lessThan(24));

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    router.push('/item/movie-inception');
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.byType(MobileDetailPage)))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.animation!.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}

bool _isRatio(SkeletonBlock block, double ratio) {
  final width = block.width ?? 0;
  final height = block.height ?? 0;
  if (width <= 0 || height <= 0) {
    return false;
  }
  return (height / width - ratio).abs() < 0.02;
}

void _expectRowShape(
  WidgetTester tester,
  Finder row, {
  required bool wide,
  required double screen,
}) {
  final blocks = tester
      .widgetList<SkeletonBlock>(
        find.descendant(of: row, matching: find.byType(SkeletonBlock)),
      )
      .where((block) => (block.height ?? 0) > 20)
      .toList();
  final card = wide
      ? phoneHomeWideCardWidth(screen)
      : phoneHomePosterCardWidth(screen);
  expect(blocks, isNotEmpty);
  expect(blocks.first.width, closeTo(card, 0.5));
  expect(
    blocks.first.height! / blocks.first.width!,
    closeTo(wide ? 9 / 16 : 1.5, 0.02),
  );
}

void _expectPeek(WidgetTester tester, double width) {
  final first = tester.getRect(find.byKey(CatalogKeys.item('ep-1')));
  final second = tester.getRect(find.byKey(CatalogKeys.item('ep-2')));
  expect(first.left, closeTo(16, 1));
  expect(first.width, closeTo(phoneHomeWideCardWidth(width), 1));
  expect(first.right, lessThanOrEqualTo(width));
  expect(second.left - first.right, closeTo(AppSpacing.xs, 1));
  expect(second.left, lessThan(width));
  expect(second.right, greaterThan(width));
  final picture = tester.getSize(
    find.descendant(
      of: find.byKey(CatalogKeys.item('ep-1')),
      matching: find.byType(AspectRatio),
    ),
  );
  expect(picture.aspectRatio, closeTo(16 / 9, 0.02));

  final posters = [
    for (var i = 0; i < 4; i++)
      tester.getRect(find.byKey(CatalogKeys.item('movie-$i'))),
  ];
  expect(posters[0].left, closeTo(16, 1));
  expect(posters[0].width, closeTo(phoneHomePosterCardWidth(width), 1));
  for (var i = 0; i < 3; i++) {
    expect(posters[i].right, lessThanOrEqualTo(width));
    if (i > 0) {
      expect(posters[i].left - posters[i - 1].right, closeTo(AppSpacing.xs, 1));
    }
  }
  expect(posters[3].left, lessThan(width));
  expect(posters[3].right, greaterThan(width));
  final poster = tester.getSize(
    find.descendant(
      of: find.byKey(CatalogKeys.item('movie-0')),
      matching: find.byType(AspectRatio),
    ),
  );
  expect(poster.aspectRatio, closeTo(2 / 3, 0.02));
}

Future<void> _expectPosterGrid(WidgetTester tester, double width) async {
  await tester.pump();
  final images = <Rect>[];
  final finder = find.byType(SkeletonBlock);
  final count = finder.evaluate().length;
  for (var i = 0; i < count; i++) {
    final rect = tester.getRect(finder.at(i));
    if (rect.width < 40 || rect.height < 40) {
      continue;
    }
    images.add(rect);
  }
  images.sort((a, b) {
    final byTop = a.top.compareTo(b.top);
    return byTop == 0 ? a.left.compareTo(b.left) : byTop;
  });
  expect(images.length, greaterThanOrEqualTo(3));
  final row = images.where((rect) => (rect.top - images.first.top).abs() < 1);
  expect(row.length, 3);
  final first = images[0];
  final second = images[1];
  final third = images[2];
  expect(first.left, closeTo(16, 1));
  expect(third.right, closeTo(width - 16, 1));
  expect(second.left - first.right, closeTo(AppSpacing.sm, 1));
  expect(first.height / first.width, closeTo(1.5, 0.05));
  expect(tester.takeException(), isNull);
}

Future<void> _pumpSurface(
  WidgetTester tester, {
  required double width,
  required double height,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _ShelfHarness {
  _ShelfHarness(this.hold, this.auth);

  final _HoldAdapter hold;
  final AuthController auth;
}

List<FakeEmbyItem> _series(int count) {
  return [
    for (var i = 0; i < count; i++)
      FakeEmbyItem(id: 'series-$i', name: '剧集 $i', type: 'Series'),
  ];
}

void _expectUnplayedFirstPage(Iterable<Uri> uris) {
  final filtered = uris.where(
    (uri) => uri.queryParameters['Filters'] == 'IsUnplayed',
  );
  expect(filtered, isNotEmpty);
  for (final uri in filtered) {
    expect(uri.queryParameters['StartIndex'], '0');
  }
}

Future<void> _tapUnplayed(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('phone-shelf-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('catalog-filter-watch-unplayed')));
}

Future<_ShelfHarness> _pumpShelf(
  WidgetTester tester, {
  required double width,
  required String source,
  double height = 800,
  List<FakeEmbyItem>? items,
}) async {
  await _pumpSurface(tester, width: width, height: height);
  final server = FakeEmbyServer(
    items: items == null ? null : [...defaultCatalogItems(), ...items],
  );
  final inner = FakeEmbyAdapter([server]);
  final hold = _HoldAdapter(inner);
  final dio = dioForFakeEmby(inner);
  final auth = AuthController.memory(
    client: EmbyClient(device: _device, dio: dio),
  );
  addTearDown(auth.dispose);
  addTearDown(hold.close);
  await tester.runAsync(() async {
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
  });
  dio.httpClientAdapter = hold;
  hold.holdLists = true;
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: PhoneShelfPage(source: source, title: '货架'),
      ),
    ),
  );
  await tester.pump();
  return _ShelfHarness(hold, auth);
}

Future<void> _pumpRails(
  WidgetTester tester, {
  required double width,
  required double height,
}) async {
  await _pumpSurface(tester, width: width, height: height);
  final auth = AuthController.memory();
  final catalog = CatalogController(auth: auth);
  addTearDown(catalog.dispose);
  addTearDown(auth.dispose);
  catalog
    ..resume = CatalogRowState(
      items: [
        for (var i = 1; i <= 2; i++)
          EmbyItem(
            id: 'ep-$i',
            name: '第 $i 集',
            type: 'Episode',
            seriesName: '示例剧',
            parentIndexNumber: 1,
            indexNumber: i,
            userData: const EmbyUserData(
              playbackPositionTicks: 1,
              playedPercentage: 40,
            ),
          ),
      ],
    )
    ..nextUp = const CatalogRowState(hidden: true)
    ..latestMovies = CatalogRowState(
      items: [for (var i = 0; i < 4; i++) _movie('movie-$i', '电影 $i')],
    )
    ..latestSeries = const CatalogRowState(hidden: true)
    ..librariesLoading = false;
  await tester.pumpWidget(_homeApp(catalog, nav: true));
  await tester.pump();
}

EmbyItem _movie(String id, String name) {
  return EmbyItem(id: id, name: name, type: 'Movie', productionYear: 2024);
}

Widget _homeApp(CatalogController catalog, {bool nav = false}) {
  return MaterialApp(
    theme: AppTheme.dark(),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      extendBody: nav,
      extendBodyBehindAppBar: nav,
      appBar: nav ? AppBar(toolbarHeight: 56, title: const Text('首页')) : null,
      body: CatalogScope(controller: catalog, child: const PhoneHome()),
      bottomNavigationBar: nav
          ? PhoneBottomNav(index: 0, floating: true, onSelected: (_) {})
          : null,
    ),
  );
}

ScrollPosition _homeScroll(WidgetTester tester) {
  return tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byKey(const PageStorageKey('mobile-home-scroll')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        ),
      )
      .position;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _HoldAdapter implements HttpClientAdapter {
  _HoldAdapter(this._inner);

  final HttpClientAdapter _inner;
  var holdLists = false;
  var failFilteredRemaining = 0;
  String? filteredBody;
  final itemRequests = <Uri>[];
  final _waiters = <Completer<void>>[];

  void release() {
    holdLists = false;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _waiters.clear();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final itemsList = options.uri.path.endsWith('/Items');
    if (itemsList) {
      itemRequests.add(options.uri);
    }
    if (holdLists) {
      final gate = Completer<void>();
      _waiters.add(gate);
      await gate.future;
    }
    if (itemsList) {
      final filters = options.uri.queryParameters['Filters'];
      if (filters != null && filters.isNotEmpty) {
        if (failFilteredRemaining > 0) {
          failFilteredRemaining--;
          return _scriptedBody('{"error":"items failed"}', 500);
        }
        final body = filteredBody;
        if (body != null) {
          return _scriptedBody(body, 200);
        }
      }
    }
    return _inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    release();
    _inner.close(force: force);
  }
}

ResponseBody _scriptedBody(String raw, int status) {
  return ResponseBody.fromString(
    raw,
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
