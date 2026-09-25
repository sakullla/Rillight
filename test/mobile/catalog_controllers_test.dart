import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/search/search_controller.dart';
import '../emby/fake_emby_server.dart';

void main() {
  late FakeEmbyServer server;
  late AuthController auth;
  late CatalogCache cache;
  late Dio dio;
  late FakeEmbyServer alternate;
  setUp(() async {
    server = FakeEmbyServer(
      users: const [
        FakeEmbyUser(
          username: 'alice',
          password: 'correct-horse',
          userId: 'user-alice',
        ),
        FakeEmbyUser(
          username: 'bob',
          password: 'bob-password',
          userId: 'user-bob',
        ),
      ],
    );
    alternate = FakeEmbyServer(
      baseUrl: Uri.parse('http://alternate.test:8096'),
    );
    dio = dioForFakeEmby(FakeEmbyAdapter([server, alternate]));
    auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'mobile-catalog',
          version: '1',
        ),
        dio: dio,
      ),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    cache = CatalogCache()
      ..attachSession(serverId: server.serverId, userId: auth.client.userId!);
  });
  tearDown(() {
    auth.dispose();
  });
  Future<void> loadDetailReady(DetailController detail) async {
    await detail.load();
    bool ready() =>
        !detail.seasonsLoading &&
        !detail.episodesLoading &&
        (detail.seasonId != null || detail.seasonError != null);
    if (ready()) return;
    final completed = Completer<void>();
    void onChange() {
      if (ready() && !completed.isCompleted) completed.complete();
    }

    detail.addListener(onChange);
    try {
      await completed.future.timeout(const Duration(seconds: 5));
    } finally {
      detail.removeListener(onChange);
    }
  }

  test('browse accepts same-user automatic token renewal', () async {
    final browse = BrowseController(
      auth: auth,
      cache: cache,
      parentId: 'view-movies',
    );
    addTearDown(browse.dispose);
    final token = auth.client.accessToken;
    server.issuedTokens.clear();
    await browse.load();
    expect(auth.client.accessToken, isNot(token));
    expect(browse.loading, isFalse);
    expect(browse.items, isNotEmpty);
    expect(browse.error, isNull);
  });
  test('detail and season accept same-user automatic token renewal', () async {
    final detail = DetailController(
      auth: auth,
      cache: cache,
      itemId: 'series-friends',
    );
    addTearDown(detail.dispose);
    server.issuedTokens.clear();
    await loadDetailReady(detail);
    expect(detail.loading, isFalse);
    expect(detail.item?.id, 'series-friends');
    expect(detail.episodes, isNotEmpty);
    server.issuedTokens.clear();
    await detail.selectSeason(detail.seasonId!);
    expect(detail.episodesLoading, isFalse);
    expect(detail.episodeError, isNull);
    expect(detail.episodes, isNotEmpty);
  });
  test('search accepts same-user automatic token renewal', () async {
    final search = SearchController(auth: auth, cache: cache);
    addTearDown(search.dispose);
    server.issuedTokens.clear();
    await search.submit('Inception');
    expect(search.searched, isTrue);
    expect(search.loading, isFalse);
    expect(search.items.map((i) => i.name), contains('Inception'));
    expect(search.error, isNull);
  });
  test('late search response cannot replace a newer query', () async {
    final search = SearchController(auth: auth, cache: cache);
    addTearDown(search.dispose);
    final entered = Completer<void>();
    final release = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) async {
          if (response.requestOptions.uri.queryParameters['SearchTerm'] ==
              'Inception') {
            entered.complete();
            await release.future;
          }
          handler.next(response);
        },
      ),
    );
    final older = search.submit('Inception');
    await entered.future;
    await search.submit('老友记');
    release.complete();
    await older;
    expect(search.term, '老友记');
    expect(search.items, isNotEmpty);
    expect(search.items.every((item) => item.name.contains('老友记')), isTrue);
    expect(search.fetched, greaterThan(0));
  });
  test('cached search page cannot paginate before live page settles', () async {
    server.items = [
      for (var i = 0; i < 65; i++)
        FakeEmbyItem(id: 'cached-$i', name: 'Film $i', type: 'Movie'),
    ];
    final request = catalogSearchRequest(
      userId: auth.client.userId!,
      searchTerm: 'Film',
      startIndex: 0,
    );
    await cache.fetch(auth.client, request);
    server.items = [
      for (var i = 0; i < 65; i++)
        FakeEmbyItem(id: 'live-$i', name: 'Film $i', type: 'Movie'),
    ];
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) async {
          final query = response.requestOptions.uri.queryParameters;
          if (query['SearchTerm'] == 'Film' && query['StartIndex'] == '0') {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
          handler.next(response);
        },
      ),
    );
    final search = SearchController(auth: auth, cache: cache);
    addTearDown(search.dispose);
    final first = search.submit('Film');
    await entered.future.timeout(const Duration(seconds: 5));
    final cachedReady = Completer<void>();
    void checkCached() {
      if (search.items.isNotEmpty && !cachedReady.isCompleted) {
        cachedReady.complete();
      }
    }

    search.addListener(checkCached);
    checkCached();
    await cachedReady.future.timeout(const Duration(seconds: 5));
    search.removeListener(checkCached);
    expect(search.items.first.id, startsWith('cached-'));
    expect(search.hasMore, isTrue);
    expect(search.liveFirstPageReady, isFalse);
    await search.loadMore();
    expect(
      server.requests.where((entry) => entry.contains('StartIndex=50')),
      isEmpty,
    );
    release.complete();
    await first;
    expect(search.liveFirstPageReady, isTrue);
    expect(search.items, hasLength(50));
    expect(search.items.every((item) => item.id.startsWith('live-')), isTrue);
    await search.loadMore();
    expect(search.items, hasLength(65));
    expect(search.items.every((item) => item.id.startsWith('live-')), isTrue);
  });
  test('search filter clears old-condition results while loading', () async {
    final search = SearchController(auth: auth, cache: cache);
    addTearDown(search.dispose);
    await search.submit('Inception');
    expect(search.items, isNotEmpty);
    final entered = Completer<void>();
    final release = Completer<void>();
    final done = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) async {
          if (response.requestOptions.uri.queryParameters['Filters'] ==
              'IsPlayed') {
            entered.complete();
            await release.future;
          }
          handler.next(response);
        },
      ),
    );
    search.addListener(() {
      if (search.watch == 'IsPlayed' && !search.loading && !done.isCompleted) {
        done.complete();
      }
    });
    search.setWatch('IsPlayed');
    await entered.future;
    expect(search.items, isEmpty);
    expect(search.loading, isTrue);
    release.complete();
    await done.future;
    expect(search.items, isNotEmpty);
  });
  test('season request completes after its own token renewal', () async {
    final detail = DetailController(
      auth: auth,
      cache: cache,
      itemId: 'series-friends',
    );
    addTearDown(detail.dispose);
    await loadDetailReady(detail);
    final token = auth.client.accessToken;
    server.issuedTokens.clear();
    await detail.selectSeason(detail.seasonId!);
    expect(auth.client.accessToken, isNot(token));
    expect(detail.episodesLoading, isFalse);
    expect(detail.episodes, isNotEmpty);
    expect(detail.episodeError, isNull);
  });
  for (final operation in ['browse', 'detail', 'season', 'search']) {
    for (final change in ['logout', 'user', 'line']) {
      test(
        '$operation rejects delayed data after $change and ends loading',
        () async {
          final browse = BrowseController(
            auth: auth,
            cache: cache,
            parentId: 'view-movies',
          );
          final detail = DetailController(
            auth: auth,
            cache: cache,
            itemId: 'series-friends',
          );
          final search = SearchController(auth: auth, cache: cache);
          addTearDown(browse.dispose);
          addTearDown(detail.dispose);
          addTearDown(search.dispose);
          await loadDetailReady(detail);
          final entered = Completer<void>(), release = Completer<void>();
          dio.interceptors.add(
            InterceptorsWrapper(
              onResponse: (response, handler) async {
                if (!entered.isCompleted &&
                    response.requestOptions.path.contains('/Items')) {
                  entered.complete();
                  await release.future;
                }
                handler.next(response);
              },
            ),
          );
          final pending = switch (operation) {
            'browse' => browse.load(),
            'detail' => detail.load(),
            'season' => detail.selectSeason(detail.seasonId!),
            _ => search.submit('Inception'),
          };
          await entered.future;
          if (change == 'logout') {
            await auth.logout();
          } else {
            await auth.connect(
              address: (change == 'line' ? alternate : server).baseUrl
                  .toString(),
              username: change == 'user' ? 'bob' : 'alice',
              password: change == 'user' ? 'bob-password' : 'correct-horse',
            );
          }
          release.complete();
          await pending;
          expect(browse.items, isEmpty);
          expect(browse.loading, isFalse);
          expect(browse.error, isNull);
          expect(detail.item, isNull);
          expect(detail.episodes, isEmpty);
          expect(detail.loading, isFalse);
          expect(detail.episodesLoading, isFalse);
          expect(detail.error, isNull);
          expect(search.items, isEmpty);
          expect(search.loading, isFalse);
          expect(search.error, isNull);
        },
      );
    }
  }
  test('failed new library query cannot use previous paging offset', () async {
    server.items = [
      for (var i = 0; i < 65; i++)
        FakeEmbyItem(
          id: 'movie-$i',
          name: 'Film $i',
          type: 'Movie',
          parentId: 'view-movies',
        ),
    ];
    final browse = BrowseController(
      auth: auth,
      cache: cache,
      parentId: 'view-movies',
    );
    addTearDown(browse.dispose);
    await browse.load();
    expect(browse.hasMore, isTrue);
    server.itemsStatus = 503;
    await browse.filter(watch: 'IsPlayed', sortBy: 'SortName');
    expect(browse.error, isNotNull);
    expect(browse.hasMore, isFalse);
    server.itemsStatus = null;
    final count = server.requests.length;
    await browse.load(more: true);
    expect(server.requests, hasLength(count));
    await browse.load();
    expect(server.requests.last, contains('StartIndex=0'));
    expect(browse.items, hasLength(BrowseController.pageSize));
  });
  test('failed new season cannot use previous paging offset', () async {
    server.setEpisodes('series-friends', [
      for (var s = 1; s <= 2; s++)
        for (var i = 0; i < 65; i++)
          FakeEpisode(
            id: 's$s-e$i',
            name: 'Episode $i',
            seasonId: 'season-friends-$s',
            indexNumber: i + 1,
          ),
    ]);
    final detail = DetailController(
      auth: auth,
      cache: cache,
      itemId: 'series-friends',
    );
    addTearDown(detail.dispose);
    await loadDetailReady(detail);
    expect(detail.hasMore, isTrue);
    server.itemsStatus = 503;
    await detail.selectSeason('season-friends-2');
    expect(detail.episodeError, isNotNull);
    expect(detail.hasMore, isFalse);
    server.itemsStatus = null;
    final count = server.requests.length;
    await detail.selectSeason('season-friends-2', more: true);
    expect(server.requests, hasLength(count));
    await detail.selectSeason('season-friends-2');
    expect(server.requests.last, contains('StartIndex=0'));
    expect(detail.episodes, hasLength(50));
    expect(detail.episodes.every((e) => e.id.startsWith('s2-')), isTrue);
  });
  test(
    'search pagination retains first page on failure and clears across logout',
    () async {
      server.items = [
        for (var i = 0; i < 65; i++)
          FakeEmbyItem(
            id: 'movie-$i',
            name: 'Film ${i.toString().padLeft(2, '0')}',
            type: 'Movie',
            parentId: 'view-movies',
          ),
      ];
      final search = SearchController(auth: auth, cache: cache);
      addTearDown(search.dispose);
      await search.submit('Film');
      expect(search.items, hasLength(50));
      server.searchStatus = 503;
      await search.loadMore();
      expect(search.items, hasLength(50));
      expect(search.pageError, isNotNull);
      server.searchStatus = null;
      await search.loadMore();
      expect(search.items, hasLength(65));
      expect(search.hasMore, isFalse);
      await auth.logout();
      expect(search.items, isEmpty);
      expect(search.hasMore, isFalse);
    },
  );
  test(
    'library paging and filters have explicit empty and retry state',
    () async {
      server.items = [
        for (var i = 0; i < 65; i++)
          FakeEmbyItem(
            id: 'movie-$i',
            name: 'Film $i',
            type: 'Movie',
            parentId: 'view-movies',
            played: i == 0,
          ),
      ];
      final browse = BrowseController(
        auth: auth,
        cache: cache,
        parentId: 'view-movies',
      );
      addTearDown(browse.dispose);
      await browse.load();
      expect(browse.items, hasLength(BrowseController.pageSize));
      await browse.load(more: true);
      expect(browse.items, hasLength(65));
      expect(browse.hasMore, isFalse);
      server.itemsStatus = 503;
      await browse.load();
      expect(browse.items, hasLength(65));
      expect(browse.error, isNotNull);
      server.itemsStatus = null;
      await browse.filter(watch: 'IsPlayed', sortBy: 'SortName');
      // The common fake does not interpret Filters; verify the server contract.
      expect(server.requests.last, contains('Filters=IsPlayed'));
      expect(browse.watch, 'IsPlayed');
      await browse.filter(type: 'Series', sortBy: 'SortName');
      expect(browse.items, isEmpty);
      expect(browse.error, isNull);
    },
  );
  test(
    'detail seasons and episode pagination retain loaded episodes on failure',
    () async {
      server.setEpisodes('series-friends', [
        for (var i = 0; i < 65; i++)
          FakeEpisode(
            id: 'episode-$i',
            name: 'Episode $i',
            seasonId: 'season-friends-1',
            indexNumber: i + 1,
          ),
      ]);
      final detail = DetailController(
        auth: auth,
        cache: cache,
        itemId: 'series-friends',
      );
      addTearDown(detail.dispose);
      await loadDetailReady(detail);
      expect(detail.item?.isSeries, isTrue);
      expect(detail.episodes, hasLength(50));
      server.itemsStatus = 503;
      await detail.selectSeason(detail.seasonId!, more: true);
      expect(detail.episodes, hasLength(50));
      expect(detail.episodeError, isNotNull);
      server.itemsStatus = null;
      await detail.selectSeason(detail.seasonId!, more: true);
      expect(detail.episodes, hasLength(65));
      expect(detail.hasMore, isFalse);
    },
  );
  test(
    'library refresh failure keeps cached navigation with a notice',
    () async {
      final catalog = CatalogController(auth: auth, cache: cache);
      addTearDown(catalog.dispose);
      await catalog.reload();
      final count = catalog.libraries.length;
      server.viewsStatus = 503;
      await catalog.reload();
      expect(catalog.libraries, hasLength(count));
      expect(catalog.librariesNotice, isNotNull);
      expect(catalog.librariesLoading, isFalse);
      server.viewsStatus = null;
      await catalog.reload();
      expect(catalog.librariesNotice, isNull);
    },
  );
}
