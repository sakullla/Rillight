import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_libraries_tab.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/media_image/media_image.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-library',
  version: '1',
);

void main() {
  setUp(isolateImageCache);

  test(
    'year, genre and premiere sort stay optional for television calls',
    () async {
      final server = FakeEmbyServer();
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _device,
          dio: dioForFakeEmby(FakeEmbyAdapter([server])),
        ),
      );
      addTearDown(auth.dispose);
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final cache = CatalogCache()
        ..debugSetDiskStore(null)
        ..attachSession(serverId: server.serverId, userId: auth.client.userId!);
      final browse = BrowseController(
        auth: auth,
        cache: cache,
        parentId: 'view-movies',
      );
      addTearDown(browse.dispose);
      await browse.load();
      await browse.filter(type: 'Movie', sortBy: 'SortName');
      final plain = _lastItemsQuery(server);
      expect(plain, contains('SortBy=SortName'));
      expect(plain, contains('SortOrder=Ascending'));
      expect(plain, isNot(contains('Years=')));
      expect(plain, isNot(contains('Genres=')));
      expect(plain, isNot(contains('Random')));

      await browse.filter(
        watch: 'IsUnplayed',
        sortBy: CatalogSort.dateCreated.sortBy,
        year: 2010,
        genre: 'SciFi',
      );
      final narrowed = _lastItemsQuery(server);
      expect(narrowed, contains('SortBy=DateCreated'));
      expect(narrowed, contains('SortOrder=Descending'));
      expect(narrowed, contains('Filters=IsUnplayed'));
      expect(narrowed, contains('Years=2010'));
      expect(narrowed, contains('Genres=SciFi'));
      expect(browse.year, 2010);
      expect(browse.genre, 'SciFi');

      await browse.filter(sortBy: CatalogSort.premiereDate.sortBy);
      final premiere = _lastItemsQuery(server);
      expect(premiere, contains('SortBy=PremiereDate'));
      expect(premiere, contains('SortOrder=Descending'));
      expect(browse.year, isNull);
      expect(browse.genre, isNull);
      expect(premiere, isNot(contains('Years=')));
      expect(premiere, isNot(contains('Genres=')));

      await browse.filter(sortBy: CatalogSort.communityRating.sortBy);
      expect(_lastItemsQuery(server), contains('SortBy=CommunityRating'));
      expect(_lastItemsQuery(server), contains('SortOrder=Descending'));

      server.items = [
        for (var i = 0; i < 65; i++)
          FakeEmbyItem(
            id: 'movie-$i',
            name: 'Film ${i.toString().padLeft(2, '0')}',
            type: 'Movie',
            parentId: 'view-movies',
          ),
      ];
      await browse.load();
      expect(browse.items, hasLength(50));
      server.itemsStatus = 503;
      await browse.load(more: true);
      expect(browse.items, hasLength(50));
      expect(browse.error, isNotNull);
      expect(browse.hasMore, isTrue);
    },
  );

  testWidgets('library blocks use artwork or a full name placeholder', (
    tester,
  ) async {
    await _start(tester);
    expect(find.byIcon(Icons.video_library), findsNothing);
    expect(find.byIcon(Icons.video_library_outlined), findsNothing);
    expect(find.byType(MediaImage), findsNothing);
    expect(
      find.byKey(const Key('phone-library-placeholder-view-movies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('phone-library-placeholder-view-tv')),
      findsOneWidget,
    );
    expect(find.text('电影'), findsOneWidget);
    final block = tester.getSize(
      find.byKey(const Key('phone-library-block-view-movies')),
    );
    expect(block.width, greaterThan(200));
    expect(block.height, greaterThan(100));
    expect(block.height / block.width, closeTo(9 / 16, 0.02));
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('a library with artwork keeps the library name on the block', (
    tester,
  ) async {
    await _start(
      tester,
      prepare: (server) {
        server.views = [
          FakeEmbyItem(
            id: 'view-movies',
            name: '电影',
            type: 'CollectionFolder',
            collectionType: 'movies',
            primaryImageTag: 'view-movies-art',
          ),
        ];
      },
    );
    expect(
      find.byKey(const Key('phone-library-image-view-movies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('phone-library-placeholder-view-movies')),
      findsNothing,
    );
    expect(find.text('电影'), findsOneWidget);
    expect(find.byIcon(Icons.video_library), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'library title, poster grid, filters and four sorts follow the library',
    (tester) async {
      final harness = await _start(tester);
      await _openMovies(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('phone-library-title'))).data,
        '电影',
      );
      final arts = tester
          .renderObjectList<RenderBox>(
            find.byWidgetPredicate((widget) {
              final key = widget.key;
              return key is ValueKey<String> &&
                  key.value.startsWith('phone-library-art-');
            }),
          )
          .toList();
      expect(arts.length, greaterThanOrEqualTo(2));
      final width = arts.first.size.width;
      expect(width, closeTo((360 - 32) / 2, 1));
      expect(arts.every((box) => (box.size.width - width).abs() < 0.5), isTrue);
      expect(
        arts.every((box) => (box.size.height - width * 1.5).abs() < 0.5),
        isTrue,
      );
      final columns = arts
          .map((box) => box.localToGlobal(Offset.zero).dx.round())
          .toSet();
      expect(columns.length, 2);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('phone-library-progress-movie-inception')),
      );
      expect(progress.value, closeTo(0.4, 0.001));
      expect(
        find.byKey(const ValueKey('phone-library-progress-movie-up')),
        findsNothing,
      );

      await _openFilters(tester);
      expect(find.text('最近添加'), findsOneWidget);
      expect(find.text('名称'), findsWidgets);
      expect(find.text('IMDb评分'), findsOneWidget);
      expect(find.text('首映日期'), findsOneWidget);
      expect(find.text('随机'), findsNothing);
      expect(find.text('出品年份'), findsNothing);
      expect(
        find.byKey(const Key('phone-library-year-section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('phone-library-genre-section')),
        findsNothing,
      );
      expect(find.text('流派'), findsNothing);

      await _tap(tester, const Key('phone-library-watch-IsUnplayed'));
      await _tap(tester, const Key('phone-library-sort-DateCreated'));
      await _tap(tester, const Key('phone-library-year-2010'));
      await _tap(tester, const Key('phone-library-apply'));
      expect(find.text('最近添加'), findsOneWidget);
      expect(find.text('未看'), findsOneWidget);
      expect(find.text('2010'), findsOneWidget);
      final recent = _lastItemsQuery(harness.server);
      expect(recent, contains('SortBy=DateCreated'));
      expect(recent, contains('SortOrder=Descending'));
      expect(recent, contains('Filters=IsUnplayed'));
      expect(recent, contains('Years=2010'));
      expect(recent, isNot(contains('Random')));

      await _openFilters(tester);
      await _tap(tester, const Key('phone-library-sort-PremiereDate'));
      await _tap(tester, const Key('phone-library-sort-CommunityRating'));
      await _tap(tester, const Key('phone-library-apply'));
      expect(find.text('IMDb评分'), findsOneWidget);
      expect(
        _lastItemsQuery(harness.server),
        contains('SortBy=CommunityRating'),
      );

      await _openFilters(tester);
      await _tap(tester, const Key('phone-library-sort-PremiereDate'));
      await _tap(tester, const Key('phone-library-apply'));
      expect(find.text('首映日期'), findsOneWidget);
      final premiere = _lastItemsQuery(harness.server);
      expect(premiere, contains('SortBy=PremiereDate'));
      expect(premiere, contains('SortOrder=Descending'));
      expect(premiere, contains('Years=2010'));

      await _tap(tester, const Key('phone-library-reset'));
      expect(find.text('名称'), findsOneWidget);
      expect(find.text('首映日期'), findsNothing);
      expect(find.text('未看'), findsNothing);
      expect(find.text('2010'), findsNothing);
      final cleared = _lastItemsQuery(harness.server);
      expect(cleared, contains('SortBy=SortName'));
      expect(cleared, contains('SortOrder=Ascending'));
      expect(cleared, contains('IncludeItemTypes=Movie,Series'));
      expect(cleared, isNot(contains('Years=')));
      expect(cleared, isNot(contains('Filters=')));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('genre filter appears only when the server has genres', (
    tester,
  ) async {
    final harness = await _start(tester);
    harness.dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          final data = response.data;
          if (data is Map) {
            final items = data['Items'];
            if (items is List) {
              for (final raw in items) {
                if (raw is Map && raw['Type'] == 'Movie') {
                  raw['Genres'] = <String>['SciFi'];
                }
              }
            }
          }
          handler.next(response);
        },
      ),
    );
    await _openMovies(tester);
    await _openFilters(tester);
    expect(
      find.byKey(const Key('phone-library-genre-section')),
      findsOneWidget,
    );
    expect(find.text('流派'), findsOneWidget);
    await _tap(tester, const Key('phone-library-genre-SciFi'));
    await _tap(tester, const Key('phone-library-apply'));
    expect(find.text('SciFi'), findsOneWidget);
    expect(_lastItemsQuery(harness.server), contains('Genres=SciFi'));
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('year and genre sections stay hidden without server options', (
    tester,
  ) async {
    final harness = await _start(tester);
    harness.server.items = [
      FakeEmbyItem(
        id: 'movie-plain',
        name: 'Plain',
        type: 'Movie',
        parentId: 'view-movies',
      ),
    ];
    await _openMovies(tester);
    await _openFilters(tester);
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('观看状态'), findsOneWidget);
    expect(find.text('排序'), findsOneWidget);
    expect(find.text('年份'), findsNothing);
    expect(find.text('流派'), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('an empty filter result is not a load failure', (tester) async {
    final harness = await _start(tester);
    await _openMovies(tester);
    await _openFilters(tester);
    await _tap(tester, const Key('phone-library-type-Series'));
    await _tap(tester, const Key('phone-library-apply'));
    expect(find.byType(MobileEmptyState), findsOneWidget);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('清除筛选'), findsOneWidget);
    expect(find.byType(MobileFailureState), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(find.text('Inception'), findsNothing);
    expect(
      _lastItemsQuery(harness.server),
      contains('IncludeItemTypes=Series'),
    );

    await tester.tap(find.byKey(MobileEmptyState.actionKey));
    await tester.pumpAndSettle();
    expect(find.text('Inception'), findsOneWidget);
    expect(find.byType(MobileEmptyState), findsNothing);
    final cleared = _lastItemsQuery(harness.server);
    expect(cleared, contains('IncludeItemTypes=Movie,Series'));
    expect(cleared, contains('SortBy=SortName'));
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('an empty library and a failed load are different screens', (
    tester,
  ) async {
    final harness = await _start(tester);
    harness.server.items = [];
    await _openMovies(tester);
    expect(find.byType(MobileEmptyState), findsOneWidget);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(find.byType(MobileFailureState), findsNothing);
    expect(find.text('重试'), findsNothing);

    harness.server.itemsStatus = 503;
    await tester.tap(find.byKey(MobileEmptyState.actionKey));
    await tester.pumpAndSettle();
    expect(find.byType(MobileFailureState), findsOneWidget);
    expect(find.textContaining('503'), findsOneWidget);
    expect(find.byType(MobileEmptyState), findsNothing);
    expect(find.text('暂无内容'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('the next page failure keeps posters already on screen', (
    tester,
  ) async {
    final harness = await _start(tester);
    harness.server.items = [
      for (var i = 0; i < 65; i++)
        FakeEmbyItem(
          id: 'movie-$i',
          name: 'Film ${i.toString().padLeft(2, '0')}',
          type: 'Movie',
          parentId: 'view-movies',
        ),
    ];
    await _openMovies(tester);
    expect(
      find.byKey(const ValueKey('phone-library-poster-movie-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('phone-library-poster-movie-50')),
      findsNothing,
    );
    harness.server.itemsStatus = 503;
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    scrollable.position.jumpTo(0);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('phone-library-poster-movie-0')),
      findsOneWidget,
    );
    expect(find.text('Film 00'), findsWidgets);
    expect(
      find.byKey(const ValueKey('phone-library-poster-movie-50')),
      findsNothing,
    );
    expect(find.byType(MobileFailureState), findsOneWidget);
    expect(find.byType(MobileEmptyState), findsNothing);
    expect(find.text('暂无内容'), findsNothing);
    expect(find.textContaining('503'), findsOneWidget);

    harness.server.itemsStatus = null;
    await tester.tap(find.byKey(MobileFailureState.retryKey));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('phone-library-poster-movie-50')),
      findsOneWidget,
    );
    expect(find.byType(MobileFailureState), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}

String _lastItemsQuery(FakeEmbyServer server) {
  return Uri.decodeQueryComponent(
    server.requests.lastWhere((line) => line.contains('/Items?')),
  );
}

Future<void> _openMovies(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('phone-library-block-view-movies')));
  await tester.pumpAndSettle();
}

Future<void> _openFilters(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('phone-library-filter')));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Harness {
  const _Harness({required this.server, required this.dio});

  final FakeEmbyServer server;
  final Dio dio;
}

Future<_Harness> _start(
  WidgetTester tester, {
  void Function(FakeEmbyServer server)? prepare,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final server = FakeEmbyServer();
  server.failingImageIds.clear();
  prepare?.call(server);
  final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
  final auth = AuthController.memory(
    client: EmbyClient(device: _device, dio: dio),
  );
  final catalog = CatalogController(
    auth: auth,
    cache: CatalogCache()..debugSetDiskStore(null),
  );
  // 假异步不会自己推进连接计时器，先在真实异步里完成登录和目录。
  await tester.runAsync(() async {
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await catalog.reload();
  });
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const PhoneLibrariesTab(),
      ),
      GoRoute(
        path: '/library/:viewId',
        builder: (context, state) =>
            MobileLibraryPage(viewId: state.pathParameters['viewId']!),
      ),
    ],
  );
  addTearDown(auth.dispose);
  addTearDown(catalog.dispose);
  addTearDown(router.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.dark(),
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) {
        return AuthScope(
          controller: auth,
          child: CatalogScope(
            controller: catalog,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(server: server, dio: dio);
}
