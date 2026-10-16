import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/catalog_cache.dart';

void main() {
  late Directory directory;
  late FileCatalogDiskStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rillight-catalog-');
    store = FileCatalogDiskStore(directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> legacy(String key, String body) async {
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    await File('${directory.path}/$name.json').writeAsString(body);
  }

  test('catalog response is available after a cache restart', () async {
    CatalogCache openCache() =>
        CatalogCache(openDiskStore: () async => store)
          ..attachSession(serverId: 'server-a', userId: 'user-alice');
    final request = catalogItemsRequest(
      userId: 'user-alice',
      searchTerm: List.filled(100, '电影').join(),
      limit: 24,
    );
    final first = openCache();
    await first.write(request, {
      'items': ['movie-1'],
    });
    await first.flushPendingWrites();
    expect(first.diskWriteFailures, 0);
    final second = openCache();
    expect((await second.lookupWhenReady(request))!.json, {
      'items': ['movie-1'],
    });
    await second.invalidateSession();
    expect(await openCache().lookupWhenReady(request), isNull);
  });

  test('long Unicode request survives reopening the disk cache', () async {
    final key = 'server/user/items?search=${List.filled(300, '影片').join()}';
    const body = '{"items":["movie-1"]}';
    await store.write(key, body);
    final files = await directory.list().toList();
    expect(files, hasLength(1));
    expect(files.single.uri.pathSegments.last.length, 72);
    expect(await FileCatalogDiskStore(directory).read(key), body);
    await store.remove(key);
    expect(await store.read(key), isNull);
  });

  test(
    'prefix invalidation isolates sessions across old and new files',
    () async {
      await legacy('alice/legacy', 'old');
      await legacy('bob/legacy', 'keep-old');
      await store.write('alice/new', 'new');
      await store.write('bob/new', 'keep-new');
      await store.removePrefix('alice/');
      expect(await store.read('alice/legacy'), isNull);
      expect(await store.read('alice/new'), isNull);
      expect(await store.read('bob/legacy'), 'keep-old');
      expect(await store.read('bob/new'), 'keep-new');
    },
  );

  test(
    'replacement prefers new data and remove clears legacy fallback',
    () async {
      await legacy('key', 'old');
      expect(await store.read('key'), 'old');
      await store.write('key', 'new');
      expect(await store.read('key'), 'new');
      expect(await directory.list().toList(), hasLength(1));
      await store.remove('key');
      expect(await store.read('key'), isNull);
    },
  );

  test(
    'mismatched stored identity cannot return another account data',
    () async {
      await store.write('alice', 'private');
      final file = (await directory.list().toList()).single as File;
      await file.writeAsString(
        jsonEncode({'cacheKey': 'bob', 'cacheBody': 'other account'}),
      );
      expect(await store.read('alice'), isNull);
    },
  );

  test('disk byte limit includes the key envelope', () async {
    store = FileCatalogDiskStore(directory, limitBytes: 100);
    await store.write('large', List.filled(200, 'x').join());
    expect(await store.read('large'), isNull);
    expect(await directory.list().toList(), isEmpty);
  });
}
