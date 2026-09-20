import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';

void main() {
  late Directory root;
  final caches = <SessionByteCache>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rillight-byte-cache-test-');
  });
  tearDown(() async {
    for (final cache in caches) {
      await cache.close();
    }
    caches.clear();
    // A terminated Windows process may briefly retain filesystem handles.
    for (var attempt = 0; root.existsSync(); attempt++) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        if (attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<SessionByteCache> open({
    int memory = 16,
    int disk = 4096,
    int pending = 2048,
    int entries = 4096,
    Directory? directory,
  }) async {
    final cache = await SessionByteCache.open(
      root: directory ?? root,
      memoryLimitBytes: memory,
      diskLimitBytes: disk,
      pendingLimitBytes: pending,
      maxEntries: entries,
    );
    caches.add(cache);
    return cache;
  }

  Future<void> put(
    SessionByteCache cache,
    int offset,
    List<int> data, {
    int generation = 1,
  }) async {
    expect(
      await cache.put(
        resource: 'secret-url-not-on-disk',
        generation: generation,
        offset: offset,
        bytes: Uint8List.fromList(data),
      ),
      isTrue,
    );
  }

  Future<CacheRead?> read(
    SessionByteCache cache,
    int offset, {
    int generation = 1,
    int length = 1024,
  }) => cache.read(
    resource: 'secret-url-not-on-disk',
    generation: generation,
    offset: offset,
    maxLength: length,
  );

  test(
    'timeline availability drops evicted files without counting metadata as hits',
    () async {
      final cache = await open(memory: 0);
      await put(cache, 0, [1, 2, 3, 4]);
      var ranges = await cache.availableRanges(
        resource: 'secret-url-not-on-disk',
        generation: 1,
      );
      expect(ranges!.map((r) => (r.start, r.end)), [(0, 4)]);
      expect(
        (await cache.read(
          resource: 'secret-url-not-on-disk',
          generation: 1,
          offset: 0,
          countHit: false,
        ))!.bytes,
        [1, 2, 3, 4],
      );
      expect(cache.diagnostics['diskHitBytes'], 0);
      final block = root
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.block'));
      await block.delete();
      ranges = await cache.availableRanges(
        resource: 'secret-url-not-on-disk',
        generation: 1,
      );
      expect(ranges, isEmpty);
    },
  );

  test('CRC32 remains compatible with the standard known vector', () async {
    final cache = await open(memory: 0);
    await put(cache, 0, utf8.encode('123456789'));
    final block = root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.block'));
    expect(block.path, endsWith('-9-cbf43926.block'));
    expect((await read(cache, 0))!.bytes, utf8.encode('123456789'));
  });

  test(
    'budget downgrade preserves protected reads and converges on release',
    () async {
      final cache = await open(memory: 16, disk: 4096);
      await put(cache, 0, List.filled(16, 7));
      final lease = await cache.protectRange(
        resource: 'secret-url-not-on-disk',
        generation: 1,
        offset: 0,
        length: 16,
      );
      expect(lease, isNotNull);
      await cache.resize(memoryBytes: 4, pendingBytes: 2048, diskBytes: 256);
      expect(cache.diagnostics['memoryResizePending'], isTrue);
      expect((await lease!.read(0))!.bytes, List.filled(16, 7));
      await lease.close();
      expect(cache.diagnostics['memoryResizePending'], isFalse);
      expect(cache.diagnostics['memoryBytes'], lessThanOrEqualTo(4));
      await cache.resize(memoryBytes: 32, pendingBytes: 2048, diskBytes: 4096);
      await put(cache, 16, List.filled(32, 8));
      expect((await read(cache, 16))!.bytes, List.filled(32, 8));
      expect(cache.diagnostics['memoryBytes'], 32);
    },
  );

  test(
    'disk downgrade preserves pinned blocks until release then evicts',
    () async {
      final cache = await open(memory: 0, disk: 4096);
      await put(cache, 0, List.filled(600, 7));
      final lease = await cache.protectRange(
        resource: 'secret-url-not-on-disk',
        generation: 1,
        offset: 0,
        length: 600,
      );
      expect(lease, isNotNull);
      await cache.resize(memoryBytes: 0, pendingBytes: 2048, diskBytes: 128);
      expect(cache.diagnostics['diskResizePending'], isTrue);
      expect((await lease!.read(0))!.bytes, List.filled(600, 7));
      await lease.close();
      expect(cache.diagnostics['diskResizePending'], isFalse);
      expect(_actualBytes(root), lessThanOrEqualTo(128));
    },
  );

  test(
    'range lease keeps memory bytes within budget during competing writes',
    () async {
      final cache = await open(memory: 768, disk: 0);
      await put(cache, 0, List.filled(256, 1));
      await put(cache, 256, List.filled(256, 2));
      await put(cache, 512, List.filled(256, 3));
      final lease = await cache.protectRange(
        resource: 'secret-url-not-on-disk',
        generation: 1,
        offset: 0,
        length: 512,
      );
      expect(lease, isNotNull);
      await put(cache, 1024, List.filled(512, 4));
      expect((await lease!.read(0))!.bytes, List.filled(256, 1));
      expect((await lease.read(256))!.bytes, List.filled(256, 2));
      expect(cache.diagnostics['memoryBytes'], lessThanOrEqualTo(768));
      await lease.close();
      await put(cache, 2048, List.filled(768, 5));
      expect((await read(cache, 2048))!.bytes, List.filled(768, 5));
    },
  );

  test(
    'range acquisition detects an already missing disk block without pin leaks',
    () async {
      final cache = await open(memory: 0);
      await put(cache, 0, [1, 2, 3, 4]);
      await put(cache, 4, [5, 6, 7, 8]);
      final block = root
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.block'));
      await block.delete();
      expect(
        await cache.protectRange(
          resource: 'secret-url-not-on-disk',
          generation: 1,
          offset: 0,
          length: 8,
        ),
        isNull,
      );
      expect(cache.diagnostics['protectedRanges'], 0);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.pin')),
        isEmpty,
      );
    },
  );

  test(
    'partial memory and disk hits preserve bytes and generation isolation',
    () async {
      final cache = await open(memory: 4);
      await put(cache, 0, [1, 2, 3, 4]);
      expect((await read(cache, 1, length: 2))?.bytes, [2, 3]);
      await put(cache, 4, [5, 6, 7, 8]);
      final disk = await read(cache, 0);
      expect(disk?.source, CacheReadSource.disk);
      expect(disk?.bytes, [1, 2, 3, 4]);
      expect(await read(cache, 0, generation: 2), isNull);
      expect(
        cache.nextOffset(
          resource: 'secret-url-not-on-disk',
          generation: 1,
          after: 0,
        ),
        4,
      );
      cache.invalidate('secret-url-not-on-disk', generation: 1);
      expect(await read(cache, 0), isNull);
      expect(cache.diagnostics['memoryPeakBytes'], lessThanOrEqualTo(4));
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        expect(file.path, isNot(contains('secret-url')));
        if (file.path.endsWith('.lock')) continue;
        expect(
          utf8.decode(file.readAsBytesSync(), allowMalformed: true),
          isNot(contains('secret-url')),
        );
      }
    },
  );

  test(
    'shared quota evicts complete blocks and keeps returned reads stable',
    () async {
      final first = await open(memory: 0, disk: 700);
      final second = await open(memory: 0, disk: 700);
      await put(first, 0, List.filled(300, 1));
      final retained = await read(first, 0);
      await put(second, 0, List.filled(300, 2));
      expect(retained?.bytes, List.filled(300, 1));
      expect(await read(first, 0), isNull);
      expect((await read(second, 0))?.bytes, List.filled(300, 2));
      expect(_actualBytes(root), lessThanOrEqualTo(700));
      await second.close();
      expect((await read(first, 0)), isNull);
    },
  );

  test(
    'smaller snapshot reclaims before joining and never raises active limit',
    () async {
      final first = await open(memory: 0, disk: 4096);
      await put(first, 0, List.filled(1000, 3));
      final small = await open(memory: 0, disk: 500);
      expect(_actualBytes(root), lessThanOrEqualTo(500));
      await put(first, 1000, List.filled(600, 4));
      expect(await read(first, 1000), isNull);
      await small.close();
      await put(first, 1000, List.filled(600, 4));
      expect((await read(first, 1000))?.bytes.length, 600);
    },
  );

  test('corrupt and truncated blocks cannot be returned', () async {
    final cache = await open(memory: 0);
    await put(cache, 0, [1, 2, 3, 4]);
    var block = root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.block'));
    block.writeAsBytesSync([9, 2, 3, 4]);
    expect(await read(cache, 0), isNull);
    await put(cache, 0, [1, 2, 3, 4]);
    block = root
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.block'));
    block.writeAsBytesSync([1]);
    expect(await read(cache, 0), isNull);
  });

  test(
    'disk failure, queued byte and index limits preserve bounded memory',
    () async {
      final obstruction = File('${root.path}/file')..writeAsStringSync('keep');
      final cache = await open(
        directory: Directory(obstruction.path),
        memory: 4,
        pending: 4,
        entries: 2,
      );
      expect(cache.diagnostics['degradation'], isNotNull);
      for (var i = 0; i < 20; i++) {
        await put(cache, i * 4, [1, 2, 3, 4]);
      }
      expect(cache.diagnostics['indexEntries'], 2);
      expect(cache.diagnostics['memoryPeakBytes'], 4);
      expect(
        await cache.put(
          resource: 'x',
          generation: 1,
          offset: 0,
          bytes: Uint8List(SessionByteCache.maxBlockBytes + 1),
        ),
        isFalse,
      );
      expect((await read(cache, 76))?.bytes, [1, 2, 3, 4]);
      expect(obstruction.readAsStringSync(), 'keep');
    },
  );

  test(
    'close removes only owned session data and isolates other sessions',
    () async {
      final unrelated = File('${root.path}/unrelated')
        ..writeAsStringSync('preserve');
      final first = await open(memory: 0);
      final second = await open(memory: 0);
      await put(first, 0, [1, 2]);
      await put(second, 0, [3, 4]);
      await first.close();
      expect((await read(second, 0))?.bytes, [3, 4]);
      await second.close();
      expect(root.listSync().whereType<Directory>(), isEmpty);
      expect(unrelated.readAsStringSync(), 'preserve');
    },
  );

  test(
    'damaged ownership records are preserved and do not poison valid sessions',
    () async {
      final cache = await open(memory: 0, disk: 4096);
      for (final entry in {
        'a': '',
        'b': '{',
        'c': '{"format":false}',
      }.entries) {
        final directory = Directory('${root.path}/${entry.key * 32}')
          ..createSync();
        File('${directory.path}/owner.json').writeAsStringSync(entry.value);
        File(
          '${directory.path}/preserve.bin',
        ).writeAsBytesSync(List.filled(100, 9));
      }
      final second = await open(memory: 0, disk: 4096);
      expect(second.diagnostics['degradation'], isNull);
      await put(cache, 0, [1, 2, 3]);
      expect((await read(cache, 0))?.bytes, [1, 2, 3]);
      expect(cache.diagnostics['diskBytes'], _actualBytes(root));
      await cache.close();
      await second.close();
      expect(cache.diagnostics['cleanup'], 'complete');
      expect(second.diagnostics['cleanup'], 'complete');
      expect(root.listSync().whereType<Directory>().length, 3);
      expect(
        File('${root.path}/${'b' * 32}/owner.json').readAsStringSync(),
        '{',
      );
    },
  );
}

int _actualBytes(Directory root) => root
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .fold(0, (sum, file) => sum + file.lengthSync());
