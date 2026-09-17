import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/shelf_grid_page.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-catalog-cache',
  version: '0.1.0',
);

class _FakeDiskStore implements CatalogDiskStore {
  final Map<String, String> files = {};
  bool failWrites = false;
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) {
      throw const FileSystemException('disk read failed');
    }
    return files[key];
  }

  @override
  Future<void> write(String key, String body) async {
    if (failWrites) {
      throw const FileSystemException('disk write failed');
    }
    files[key] = body;
  }

  @override
  Future<void> remove(String key) async {
    files.remove(key);
  }

  @override
  Future<void> clear() async {
    files.clear();
  }
}

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late EmbyClient client;

  setUp(() async {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    client = EmbyClient(device: _device, dio: dioForFakeEmby(adapter));
    final auth = await client.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    client.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
    );
  });

  CatalogCache newCache(_FakeDiskStore disk) {
    final cache = CatalogCache();
    cache.debugSetDiskStore(disk);
    cache.attachSession(serverId: 'server-a', userId: 'user-alice');
    return cache;
  }

  test(
    'cache keys include serverId and userId and do not cross sessions',
    () async {
      final disk = _FakeDiskStore();
      final cacheA = newCache(disk);
      final request = catalogResumeRequest(userId: 'user-alice');

      await cacheA.fetch(client, request);
      expect(disk.files, hasLength(1));
      expect(disk.files.keys.single, contains('server-a|user-alice|'));

      // 同 serverId 不同用户:key 不同,读不到对方数据。
      final cacheB = CatalogCache()
        ..debugSetDiskStore(disk)
        ..attachSession(serverId: 'server-a', userId: 'user-bob');
      expect(await cacheB.lookup(request), isNull);

      // 不同服务器同用户:同样隔离。
      final cacheC = CatalogCache()
        ..debugSetDiskStore(disk)
        ..attachSession(serverId: 'server-b', userId: 'user-alice');
      expect(await cacheC.lookup(request), isNull);

      // 原会话仍然命中。
      expect(await cacheA.lookup(request), isNotNull);
    },
  );

  test('lookup hits memory within TTL and expires afterwards', () async {
    var now = DateTime(2026, 1, 1, 12, 0, 0);
    final cache = newCache(_FakeDiskStore())..clock = () => now;
    final request = catalogNextUpRequest(userId: 'user-alice');

    await cache.fetch(client, request);
    expect(await cache.lookup(request), isNotNull);

    now = now.add(const Duration(minutes: 9, seconds: 59));
    expect(await cache.lookup(request), isNotNull);

    now = now.add(const Duration(seconds: 2));
    expect(await cache.lookup(request), isNull);
  });

  test(
    'disk entry is hit after memory loss, simulating an app restart',
    () async {
      final disk = _FakeDiskStore();
      final first = newCache(disk);
      final request = catalogItemsRequest(
        userId: 'user-alice',
        parentId: 'view-movies',
        limit: 24,
      );

      await first.fetch(client, request);
      // 重启:内存层随进程消失,磁盘层保留。
      final second = newCache(disk);
      final hit = await second.lookup(request);
      expect(hit, isNotNull);
      final page = parseCatalogPage(hit!.json);
      expect(page.items.map((item) => item.id), contains('movie-inception'));
    },
  );

  test('disk write failure degrades to memory-only caching', () async {
    final disk = _FakeDiskStore()..failWrites = true;
    final cache = newCache(disk);
    final request = catalogResumeRequest(userId: 'user-alice');

    final json = await cache.fetch(client, request);
    expect(parseCatalogPage(json).items, isNotEmpty);
    expect(disk.files, isEmpty);
    expect(await cache.lookup(request), isNotNull);
  });

  test('disk read failure falls back to a miss without throwing', () async {
    final disk = _FakeDiskStore()..failReads = true;
    final cache = newCache(disk);
    final request = catalogViewsRequest(userId: 'user-alice');

    await cache.fetch(client, request);
    // 内存层可直接命中;换一个内存为空的实例模拟重启后磁盘读失败。
    final restarted = newCache(disk);
    expect(await restarted.lookup(request), isNull);
    disk.failReads = false;
    expect(await restarted.lookup(request), isNotNull);
  });

  test(
    'fetch always goes to the network and writes through both layers',
    () async {
      final disk = _FakeDiskStore();
      final cache = newCache(disk);
      final request = catalogResumeRequest(userId: 'user-alice');

      await cache.fetch(client, request);
      await cache.fetch(client, request);
      await cache.fetch(client, request);

      final resumeRequests = server.requests
          .where(
            (entry) => entry.startsWith('GET /Users/user-alice/Items/Resume'),
          )
          .length;
      expect(resumeRequests, 3, reason: '每次 fetch 都走网络,不吃缓存');
      expect(disk.files, hasLength(1));
    },
  );

  test(
    'request parity: cache fetch matches the equivalent client request',
    () async {
      final cache = newCache(_FakeDiskStore());

      final before = server.requests.length;
      await client.queryResumeItems(
        limit: 60,
        startIndex: 60,
        sortBy: 'DatePlayed',
        sortOrder: 'Descending',
      );
      final viaClient = server.requests[before];

      await cache.fetch(
        client,
        catalogResumeRequest(
          userId: 'user-alice',
          limit: 60,
          startIndex: 60,
          sortBy: 'DatePlayed',
          sortOrder: 'Descending',
        ),
      );
      final viaCache = server.requests[before + 1];

      expect(viaCache, viaClient);

      final itemsBefore = server.requests.length;
      await client.queryItems(
        parentId: 'view-movies',
        recursive: true,
        limit: 60,
        startIndex: 0,
        sortBy: 'SortName',
        sortOrder: 'Ascending',
      );
      final itemsViaClient = server.requests[itemsBefore];
      await cache.fetch(
        client,
        catalogItemsRequest(
          userId: 'user-alice',
          parentId: 'view-movies',
          recursive: true,
          limit: 60,
          startIndex: 0,
          sortBy: 'SortName',
          sortOrder: 'Ascending',
        ),
      );
      expect(server.requests[itemsBefore + 1], itemsViaClient);

      final searchBefore = server.requests.length;
      await client.searchByName('Inception', startIndex: 0);
      final searchViaClient = server.requests[searchBefore];
      await cache.fetch(
        client,
        catalogSearchRequest(
          userId: 'user-alice',
          searchTerm: 'Inception',
          startIndex: 0,
        ),
      );
      expect(server.requests[searchBefore + 1], searchViaClient);

      final filterBefore = server.requests.length;
      await client.queryItems(
        parentId: 'view-movies',
        recursive: true,
        limit: 60,
        startIndex: 0,
        sortBy: 'SortName',
        sortOrder: 'Ascending',
        filters: ['IsUnplayed'],
        genres: ['SciFi'],
        years: [2025, 2024],
      );
      final filterViaClient = server.requests[filterBefore];
      await cache.fetch(
        client,
        catalogItemsRequest(
          userId: 'user-alice',
          parentId: 'view-movies',
          recursive: true,
          limit: 60,
          startIndex: 0,
          sortBy: 'SortName',
          sortOrder: 'Ascending',
          filters: ['IsUnplayed'],
          genres: ['SciFi'],
          years: [2025, 2024],
        ),
      );
      expect(server.requests[filterBefore + 1], filterViaClient);
      expect(filterViaClient, contains('Filters=IsUnplayed'));
      expect(filterViaClient, contains('Genres=SciFi'));
      expect(filterViaClient, contains('Years=2025%2C2024'));
    },
  );

  test('filter parameters participate in the cache key', () async {
    final disk = _FakeDiskStore();
    final cache = newCache(disk);

    final plain = catalogItemsRequest(
      userId: 'user-alice',
      parentId: 'view-movies',
      limit: 24,
    );
    final unplayed = catalogItemsRequest(
      userId: 'user-alice',
      parentId: 'view-movies',
      limit: 24,
      filters: ['IsUnplayed'],
    );
    final byYear = catalogItemsRequest(
      userId: 'user-alice',
      parentId: 'view-movies',
      limit: 24,
      years: [2025],
    );
    final byGenre = catalogItemsRequest(
      userId: 'user-alice',
      parentId: 'view-movies',
      limit: 24,
      genres: ['SciFi'],
    );
    final combined = catalogItemsRequest(
      userId: 'user-alice',
      parentId: 'view-movies',
      limit: 24,
      filters: ['IsPlayed'],
      years: [2025],
      genres: ['SciFi'],
    );

    await cache.fetch(client, plain);
    await cache.fetch(client, unplayed);
    await cache.fetch(client, byYear);
    await cache.fetch(client, byGenre);
    await cache.fetch(client, combined);

    // 同 parentId 不同筛选各自独立缓存,互不串数据。
    expect(disk.files, hasLength(5));
    expect(disk.files.keys, everyElement(contains('view-movies')));
    expect(
      disk.files.keys.where((key) => key.contains('Filters=IsUnplayed')),
      hasLength(1),
    );
    expect(
      disk.files.keys.where(
        (key) => key.contains('Years=2025') && key.contains('Genres=SciFi'),
      ),
      hasLength(1),
      reason: '组合筛选的 key 同时纳入全部筛选参数',
    );
  });

  test('mergeItemsById dedupes pagination overlaps by item id', () {
    EmbyItem item(String id) =>
        EmbyItem.fromJson({'Id': id, 'Name': 'Item $id', 'Type': 'Movie'});
    final items = [item('item-0'), item('item-1'), item('item-2')];
    final next = [item('item-2'), item('item-3')];
    final merged = ShelfGridPage.mergeItemsById(items, next);
    expect(merged.map((entry) => entry.id), [
      'item-0',
      'item-1',
      'item-2',
      'item-3',
    ]);
  });
}
