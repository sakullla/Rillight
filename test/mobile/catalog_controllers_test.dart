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
  setUp(() async {
    server = FakeEmbyServer();
    auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'mobile-catalog',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
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
      expect(browse.items, hasLength(50));
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
      await detail.load();
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
