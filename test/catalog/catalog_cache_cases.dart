import 'package:rillight/emby/emby_codec.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/library/shelf_grid_page.dart';

import '../emby/fake_emby_server.dart';

const _device = ClientDeviceInfo(
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

class _BlockingDiskStore extends _FakeDiskStore {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> write(String key, String body) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    await super.write(key, body);
  }
}

class _PausedReadDiskStore extends _FakeDiskStore {
  final result = Completer<String?>();
  int reads = 0;
  int removals = 0;

  @override
  Future<String?> read(String key) {
    reads++;
    return result.future;
  }

  @override
  Future<void> remove(String key) async {
    removals++;
    await super.remove(key);
  }
}

class _CountedJson {
  int encodes = 0;
  Map<String, Object> toJson() {
    encodes++;
    return {'value': 1};
  }
}

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late MediaServerClient client;

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

  test('memory-first lookup does not wait for disk initialization', () async {
    final opening = Completer<CatalogDiskStore>();
    final cache = CatalogCache(openDiskStore: () => opening.future)
      ..attachSession(serverId: 'server-a', userId: 'user-alice');
    const request = CatalogRequest('views');
    await cache.write(request, {'items': <Object>[]});
    try {
      final hit = await cache
          .lookupWhenReady(request)
          .timeout(const Duration(seconds: 1));
      expect(hit, isNotNull);
    } finally {
      opening.complete(_FakeDiskStore());
      await cache.flushPendingWrites();
    }
  });

  test('coalescing encodes only the last queued response', () async {
    final disk = _BlockingDiskStore();
    final cache = newCache(disk);
    await cache.write(const CatalogRequest('blocked'), {'value': 0});
    await disk.started.future;
    final payloads = List.generate(20, (_) => _CountedJson());
    for (final payload in payloads) {
      await cache.write(const CatalogRequest('views'), payload);
    }
    expect(payloads.map((value) => value.encodes), everyElement(0));
    disk.release.complete();
    await cache.flushPendingWrites();
    expect(payloads.take(19).map((value) => value.encodes), everyElement(0));
    expect(payloads.last.encodes, 1);
  });

  test(
    'serialization failure preserves memory and drains later writes',
    () async {
      final disk = _FakeDiskStore();
      final cache = newCache(disk);
      final payload = Object();
      await cache.write(const CatalogRequest('bad'), payload);
      await cache.write(const CatalogRequest('good'), {'value': 1});
      await cache.flushPendingWrites();
      expect(cache.diskWriteFailures, 1);
      expect((await cache.lookup(const CatalogRequest('bad')))!.json, payload);
      expect(disk.files, hasLength(1));
    },
  );

  test('disabled persistence does not serialize responses', () async {
    final cache = CatalogCache()
      ..debugSetDiskStore(null)
      ..attachSession(serverId: 'server-a', userId: 'user-alice');
    final payload = _CountedJson();
    await cache.write(const CatalogRequest('views'), payload);
    await cache.flushPendingWrites();
    expect(payload.encodes, 0);
    expect((await cache.lookup(const CatalogRequest('views')))!.json, payload);
  });

  test('concurrent cold lookups share one disk read and decode', () async {
    final disk = _PausedReadDiskStore();
    final cache = newCache(disk);
    final request = catalogResumeRequest(userId: 'user-alice');
    final pending = List.generate(20, (_) => cache.lookup(request));
    expect(disk.reads, 1);
    disk.result.complete(
      jsonEncode({
        'storedAt': DateTime.now().toIso8601String(),
        'data': {'Items': <Object>[]},
      }),
    );
    final hits = await Future.wait(pending);
    expect(hits.first, isNotNull);
    expect(hits.every((hit) => identical(hit, hits.first)), isTrue);
    await cache.lookup(request);
    expect(disk.reads, 1);
  });

  for (final expired in [false, true]) {
    test(
      'late disk read cannot overwrite or remove live data (expired=$expired)',
      () async {
        final disk = _PausedReadDiskStore();
        final cache = newCache(disk);
        final request = catalogResumeRequest(userId: 'user-alice');
        final pending = cache.lookup(request);
        await cache.write(request, {'version': 'live'});
        await cache.flushPendingWrites();
        disk.result.complete(
          jsonEncode({
            'storedAt': (expired ? DateTime(2000) : DateTime.now())
                .toIso8601String(),
            'data': {'version': 'stale'},
          }),
        );
        expect(await pending, isNull);
        expect((await cache.lookup(request))!.json, {'version': 'live'});
        expect(disk.removals, 0);
        expect(jsonDecode(disk.files.values.single)['data'], {
          'version': 'live',
        });
      },
    );
  }

  test('coalesced disk read is retired on account change', () async {
    final disk = _PausedReadDiskStore();
    final cache = newCache(disk);
    final request = catalogResumeRequest(userId: 'user-alice');
    final pending = cache.lookup(request);
    cache.attachSession(serverId: 'server-a', userId: 'user-bob');
    disk.result.complete(
      jsonEncode({
        'storedAt': DateTime.now().toIso8601String(),
        'data': {'owner': 'alice'},
      }),
    );
    expect(await pending, isNull);
  });

  test('disk TTL is checked on receipt after a slow read', () async {
    final disk = _PausedReadDiskStore();
    final cache = newCache(disk);
    final storedAt = DateTime(2026, 1, 1);
    var now = storedAt;
    cache.clock = () => now;
    final pending = cache.lookup(catalogResumeRequest(userId: 'user-alice'));
    now = storedAt.add(CatalogCache.defaultTtl);
    disk.result.complete(
      jsonEncode({
        'storedAt': storedAt.toIso8601String(),
        'data': {'version': 'expired'},
      }),
    );
    expect(await pending, isNull);
    expect(disk.removals, 1);
  });

  test(
    'cache keys include serverId and userId and do not cross sessions',
    () async {
      final disk = _FakeDiskStore();
      final cacheA = newCache(disk);
      final request = catalogResumeRequest(userId: 'user-alice');

      await cacheA.fetch(client, request);
      await cacheA.flushPendingWrites();
      expect(disk.files, hasLength(1));
      expect(
        disk.files.keys.single,
        startsWith('["emby","server-a",null,"user-alice",null,null]|'),
      );

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
      await first.flushPendingWrites();
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
    await cache.flushPendingWrites();
    expect(parseCatalogPage(json).items, isNotEmpty);
    expect(disk.files, isEmpty);
    expect(cache.diskWriteFailures, 1);
    expect(await cache.lookup(request), isNotNull);
  });

  test('network result and memory hit do not wait for disk flush', () async {
    final disk = _BlockingDiskStore();
    final cache = newCache(disk);
    final request = catalogResumeRequest(userId: 'user-alice');

    final json = await cache.fetch(client, request);
    await disk.started.future;
    expect(parseCatalogPage(json).items, isNotEmpty);
    expect(await cache.lookup(request), isNotNull);
    expect(disk.files, isEmpty);

    disk.release.complete();
    await cache.flushPendingWrites();
    expect(disk.files, hasLength(1));
  });

  test('queued old-session writes never land under a new account', () async {
    final disk = _BlockingDiskStore();
    final cache = newCache(disk);
    await cache.fetch(client, catalogResumeRequest(userId: 'user-alice'));
    await disk.started.future;
    await cache.fetch(client, catalogNextUpRequest(userId: 'user-alice'));

    cache.attachSession(serverId: 'server-a', userId: 'user-bob');
    disk.release.complete();
    await cache.flushPendingWrites();
    expect(disk.files.keys, everyElement(contains('user-alice')));
    expect(disk.files.keys.where((key) => key.contains('NextUp')), isEmpty);
  });

  test('slow storage keeps pending writes bounded', () async {
    final disk = _BlockingDiskStore();
    final cache = newCache(disk);
    await cache.write(const CatalogRequest('/blocked'), {'value': 0});
    await disk.started.future;
    for (
      var index = 0;
      index < CatalogCache.maxPendingDiskWrites + 10;
      index++
    ) {
      await cache.write(CatalogRequest('/item/$index'), {'value': index});
    }
    expect(cache.droppedDiskWrites, greaterThan(0));
    disk.release.complete();
    await cache.flushPendingWrites();
    expect(
      disk.files.length,
      lessThanOrEqualTo(CatalogCache.maxPendingDiskWrites + 1),
    );
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

  test('fetch always goes to the network and eventually persists', () async {
    final disk = _FakeDiskStore();
    final cache = newCache(disk);
    final request = catalogResumeRequest(userId: 'user-alice');

    await cache.fetch(client, request);
    await cache.fetch(client, request);
    await cache.fetch(client, request);
    await cache.flushPendingWrites();

    final resumeRequests = server.requests
        .where(
          (entry) =>
              entry.startsWith('GET /emby/Users/user-alice/Items/Resume'),
        )
        .length;
    expect(resumeRequests, 3, reason: '每次 fetch 都走网络,不吃缓存');
    expect(disk.files, hasLength(1));
  });

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
    await cache.flushPendingWrites();

    // 同 parentId 不同筛选各自独立缓存,互不串数据。
    expect(disk.files, hasLength(5));
    expect(disk.files.keys, everyElement(contains('view-movies')));
    expect(
      disk.files.keys.where((key) => key.contains('filters=IsUnplayed')),
      hasLength(1),
    );
    expect(
      disk.files.keys.where(
        (key) => key.contains('years=2025') && key.contains('genres=SciFi'),
      ),
      hasLength(1),
      reason: '组合筛选的 key 同时纳入全部筛选参数',
    );
  });

  test('PersonIds is part of the cache key and the client request', () async {
    final disk = _FakeDiskStore();
    final cache = newCache(disk);
    final ada = catalogItemsRequest(
      userId: 'user-alice',
      personIds: const ['person-ada'],
      includeItemTypes: 'Movie,Series',
      recursive: true,
      limit: 60,
      startIndex: 0,
      sortBy: 'PremiereDate',
      sortOrder: 'Descending',
    );
    final bob = catalogItemsRequest(
      userId: 'user-alice',
      personIds: const ['person-bob'],
      includeItemTypes: 'Movie,Series',
      recursive: true,
      limit: 60,
      startIndex: 0,
      sortBy: 'PremiereDate',
      sortOrder: 'Descending',
    );
    final before = server.requests.length;
    await client.queryItems(
      personIds: const ['person-ada'],
      includeItemTypes: 'Movie,Series',
      recursive: true,
      limit: 60,
      startIndex: 0,
      sortBy: 'PremiereDate',
      sortOrder: 'Descending',
    );
    final viaClient = server.requests[before];
    await cache.fetch(client, ada);
    expect(server.requests[before + 1], viaClient);
    await cache.fetch(client, bob);
    await cache.flushPendingWrites();
    expect(disk.files, hasLength(2));
    expect(
      disk.files.keys.where((key) => key.contains('personIds=person-ada')),
      hasLength(1),
    );
    expect(
      disk.files.keys.where((key) => key.contains('personIds=person-bob')),
      hasLength(1),
    );
    expect(viaClient, isNot(contains('ParentId=')));
  });

  test('mergeItemsById dedupes pagination overlaps by item id', () {
    MediaItem item(String id) =>
        decodeEmbyMediaItem({'Id': id, 'Name': 'Item $id', 'Type': 'Movie'});
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
