import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/matroska_cache_index.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/cache/session_read_ahead.dart';

List<int> uint(int value, [int? width]) {
  var count = width ?? 1;
  while (width == null && value >= (1 << (count * 8))) {
    count++;
  }
  return [for (var i = count - 1; i >= 0; i--) (value >> (i * 8)) & 255];
}

List<int> element(int id, List<int> body) {
  var width = 1;
  while (body.length >= (1 << (width * 7)) - 1) {
    width++;
  }
  return [
    ...uint(id),
    ...uint((1 << (width * 7)) | body.length, width),
    ...body,
  ];
}

(Uint8List, List<int>, int) fixture({
  int scale = 1000000,
  bool videoKeyframe = true,
  bool includeAudio = true,
}) {
  final info = element(0x1549a966, element(0x2ad7b1, uint(scale)));
  final tracks = element(0x1654ae6b, [
    ...element(0xae, [
      ...element(0xd7, [1]),
      ...element(0x83, [1]),
    ]),
    ...element(0xae, [
      ...element(0xd7, [2]),
      ...element(0x83, [2]),
      ...element(0x86, 'A_AAC'.codeUnits),
    ]),
  ]);
  final payload = [...info, ...tracks];
  final positions = <int>[];
  var clusterNumber = 0;
  for (final size in [100, 500, 80]) {
    positions.add(payload.length);
    payload.addAll(
      element(0x1f43b675, [
        ...element(0xe7, uint(clusterNumber++ * 10000)),
        ...element(0xa3, [0x81, 0, 0, videoKeyframe ? 0x80 : 0, 1]),
        if (includeAudio) ...element(0xa3, [0x82, 0, 0, 0, 2]),
        ...element(0xec, List.filled(size, 0)),
      ]),
    );
  }
  final cuesPosition = payload.length;
  payload.addAll(
    element(0x1c53bb6b, [
      for (var i = 0; i < positions.length; i++)
        ...element(0xbb, [
          ...element(0xb3, uint(i * 10000)),
          ...element(0xb7, [
            ...element(0xf7, [1]),
            ...element(0xf1, uint(positions[i])),
          ]),
        ]),
    ]),
  );
  final segment = element(0x18538067, payload);
  final ebml = element(0x1a45dfa3, []);
  final base = ebml.length + segment.length - payload.length;
  return (
    Uint8List.fromList([...ebml, ...segment]),
    [for (final p in positions) base + p],
    base + cuesPosition,
  );
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    condition(),
    true,
    reason: 'read-ahead did not reach the expected state',
  );
}

void main() {
  group('matroska_cache_index_test.dart', () {
    test('follows an EOF SeekHead to locate cues outside the prefix', () async {
      List<int> head(int target, int offset) => element(
        0x114d9b74,
        element(0x4dbb, [
          ...element(0x53ab, uint(target)),
          ...element(0x53ac, uint(offset, 8)),
        ]),
      );
      final first = head(0x114d9b74, 0);
      final prefix = [
        ...first,
        ...element(0x1549a966, element(0x2ad7b1, uint(1000000))),
        ...element(
          0x1654ae6b,
          element(0xae, [
            ...element(0xd7, [1]),
            ...element(0x83, [1]),
          ]),
        ),
        ...element(0xec, List.filled(70000, 0)),
      ];
      final cues = element(0x1c53bb6b, [
        for (var i = 0; i < 2; i++)
          ...element(0xbb, [
            ...element(0xb3, uint(i * 10000)),
            ...element(0xb7, [
              ...element(0xf7, [1]),
              ...element(0xf1, uint(1000 + i * 1000)),
            ]),
          ]),
      ]);
      final payload = [
        ...head(0x114d9b74, prefix.length + cues.length),
        ...prefix.skip(first.length),
        ...cues,
        ...head(0x1c53bb6b, prefix.length),
      ];
      final bytes = Uint8List.fromList([
        ...element(0x1a45dfa3, []),
        ...element(0x18538067, payload),
      ]);
      final offsets = <int>[];
      final index = await MatroskaCacheIndex.load(
        total: bytes.length,
        read: (offset, length) async {
          offsets.add(offset);
          return Uint8List.sublistView(bytes, offset, offset + length);
        },
      );
      expect(index?.points.length, 2);
      expect(offsets.any((offset) => offset > 64 * 1024), true);
    });

    test(
      'variable bitrate clusters map via cues, not file percentage',
      () async {
        final (bytes, positions, cuesPosition) = fixture();
        final index = await MatroskaCacheIndex.load(
          total: bytes.length,
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        );
        expect(index, isNotNull);
        final metadata = [
          CachedByteRange(0, positions.first),
          CachedByteRange(cuesPosition, bytes.length),
        ];
        final partial = await index!.ranges(
          [...metadata, CachedByteRange(positions[1], positions[2] + 5)],
          const Duration(seconds: 30),
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        );
        expect(partial.map((r) => (r.start.inSeconds, r.end.inSeconds)), [
          (10, 20),
        ]);
        final tail = await index.ranges(
          [...metadata, CachedByteRange(positions[1], bytes.length)],
          const Duration(seconds: 30),
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        );
        expect(tail.map((r) => (r.start.inSeconds, r.end.inSeconds)), [
          (10, 30),
        ]);
        final holes = await index.ranges(
          [
            ...metadata,
            CachedByteRange(positions[0], positions[1]),
            CachedByteRange(positions[2], bytes.length),
          ],
          const Duration(seconds: 30),
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        );
        expect(holes.map((r) => (r.start.inSeconds, r.end.inSeconds)), [
          (0, 10),
          (20, 30),
        ]);
      },
    );

    test(
      'index deadline retains verified later clusters and retracts missing bytes',
      () async {
        final (bytes, positions, cuesPosition) = fixture();
        Future<Uint8List?> read(int offset, int length) async =>
            Uint8List.sublistView(bytes, offset, offset + length);
        final index = (await MatroskaCacheIndex.load(
          total: bytes.length,
          read: read,
        ))!;
        final metadata = [
          CachedByteRange(0, positions.first),
          CachedByteRange(cuesPosition, bytes.length),
        ];
        final prior = await index.ranges(
          [...metadata, CachedByteRange(positions[1], positions[2])],
          const Duration(seconds: 30),
          read: read,
        );
        expect(prior.map((r) => (r.start.inSeconds, r.end.inSeconds)), [
          (10, 20),
        ]);
        final timedOut = await index.ranges(
          [CachedByteRange(0, bytes.length)],
          const Duration(seconds: 30),
          read: (_, _) async => throw TimeoutException('optional index budget'),
        );
        expect(timedOut.map((r) => (r.start.inSeconds, r.end.inSeconds)), [
          (10, 20),
        ]);
        final removed = await index.ranges(
          [...metadata, CachedByteRange(positions[0], positions[1])],
          const Duration(seconds: 30),
          read: (_, _) async => throw TimeoutException('optional index budget'),
        );
        expect(removed, isEmpty);
      },
    );

    test(
      'evicted metadata clears previously verified cluster coverage',
      () async {
        final (bytes, positions, cuesPosition) = fixture();
        final index = (await MatroskaCacheIndex.load(
          total: bytes.length,
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        ))!;
        Future<List<CachedTimeRange>> map(List<CachedByteRange> ranges) =>
            index.ranges(
              ranges,
              const Duration(seconds: 30),
              read: (offset, length) async =>
                  Uint8List.sublistView(bytes, offset, offset + length),
            );
        final all = [CachedByteRange(0, bytes.length)];
        expect(await map(all), isNotEmpty);
        expect(
          await map([CachedByteRange(positions.first, bytes.length)]),
          isEmpty,
        );
        expect(await map([CachedByteRange(0, cuesPosition)]), isEmpty);
      },
    );

    test('cue alone cannot prove keyframe or selected audio', () async {
      for (final data in [
        fixture(videoKeyframe: false),
        fixture(includeAudio: false),
      ]) {
        final (bytes, _, _) = data;
        final index = (await MatroskaCacheIndex.load(
          total: bytes.length,
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        ))!;
        expect(
          await index.ranges(
            [CachedByteRange(0, bytes.length)],
            const Duration(seconds: 30),
            read: (offset, length) async =>
                Uint8List.sublistView(bytes, offset, offset + length),
          ),
          isEmpty,
        );
      }
    });

    test(
      'timestamp scale is honored and unavailable metadata is not guessed',
      () async {
        final (bytes, positions, cuesPosition) = fixture(scale: 2000000);
        final index = await MatroskaCacheIndex.load(
          total: bytes.length,
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        );
        expect(
          (await index!.ranges(
            [
              CachedByteRange(0, positions.first),
              CachedByteRange(cuesPosition, bytes.length),
              CachedByteRange(positions[1], bytes.length),
            ],
            const Duration(seconds: 60),
            read: (offset, length) async =>
                Uint8List.sublistView(bytes, offset, offset + length),
          )).single.start,
          const Duration(seconds: 20),
        );
        expect(
          await MatroskaCacheIndex.load(
            total: bytes.length,
            read: (_, _) async => null,
          ),
          null,
        );
        expect(
          await MatroskaCacheIndex.load(
            total: 16,
            read: (_, length) async => Uint8List(length),
          ),
          null,
        );
      },
    );
  });

  group('session_byte_cache_test.dart', () {
    test(
      'coverage survives append but detects eviction and replacement',
      () async {
        final cache = await SessionByteCache.open(memoryLimitBytes: 16);
        addTearDown(cache.close);
        Future<bool> put(int offset) => cache.put(
          resource: 'media',
          generation: 0,
          offset: offset,
          bytes: Uint8List(8),
        );
        await put(0);
        final first = cache.coverageRevision;
        await put(8);
        expect(cache.coverageRevision, first);
        expect(
          (await cache.availableRanges(
            resource: 'media',
            generation: 0,
          ))!.single.end,
          16,
        );
        await put(16);
        expect(cache.coverageRevision, greaterThan(first));
        final evicted = cache.coverageRevision;
        await put(16);
        expect(cache.coverageRevision, greaterThan(evicted));
        final replaced = cache.coverageRevision;
        cache.invalidate('media');
        expect(cache.coverageRevision, greaterThan(replaced));
        expect(
          await cache.availableRanges(resource: 'media', generation: 0),
          isEmpty,
        );
      },
    );
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

    test(
      'published disk blocks and reads retain continuous verified coverage',
      () async {
        const blockSize = 1024 * 1024;
        final cache = await open(
          memory: 0,
          disk: 10 * blockSize,
          pending: 8 * blockSize,
        );
        for (var i = 0; i < 6; i++) {
          await put(cache, i * blockSize, Uint8List(blockSize));
        }
        Future<void> check() async {
          final ranges = await cache.availableRanges(
            resource: 'secret-url-not-on-disk',
            generation: 1,
            verifyChecksum: true,
          );
          expect(ranges!.map((r) => (r.start, r.end)), [(0, 6 * blockSize)]);
        }

        await check();
        // Reading must not mutate the immutable files while the verifier can
        // be inspecting the same blocks on its own isolate.
        final before = {
          for (final file in root.listSync(recursive: true).whereType<File>())
            if (file.path.endsWith('.block'))
              file.path: file.statSync().modified,
        };
        await read(cache, 2 * blockSize);
        for (final entry in before.entries) {
          expect(File(entry.key).statSync().modified, entry.value);
        }
        await check();
        final removed = root
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((f) => f.path.endsWith('.block'));
        await removed.delete();
        final ranges = await cache.availableRanges(
          resource: 'secret-url-not-on-disk',
          generation: 1,
          verifyChecksum: true,
        );
        expect(
          ranges!.fold<int>(0, (sum, r) => sum + r.end - r.start),
          5 * blockSize,
        );
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
        expect(cache.diagnostics['appliedMemoryLimitBytes'], 16);
        expect((await lease!.read(0))!.bytes, List.filled(16, 7));
        await lease.close();
        expect(cache.diagnostics['memoryResizePending'], isFalse);
        expect(cache.diagnostics['appliedMemoryLimitBytes'], 4);
        expect(cache.diagnostics['memoryBytes'], lessThanOrEqualTo(4));
        await cache.resize(
          memoryBytes: 32,
          pendingBytes: 2048,
          diskBytes: 4096,
        );
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
        expect(cache.diagnostics['appliedDiskSessionLimitBytes'], 4096);
        expect((await lease!.read(0))!.bytes, List.filled(600, 7));
        await lease.close();
        expect(cache.diagnostics['diskResizePending'], isFalse);
        expect(cache.diagnostics['appliedDiskSessionLimitBytes'], 128);
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

    test('foreground reads survive a blocked quota writer', () async {
      // Windows byte-range locks also exclude another handle in this process.
      // POSIX record locks are process-owned, so this contention fixture is
      // intentionally Windows-only; immutable-read coverage above is portable.
      if (!Platform.isWindows) return;
      final cache = await open(memory: 0);
      await put(cache, 0, [1, 2, 3, 4]);
      final lock = File(
        '${root.path}/quota.lock',
      ).openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      try {
        await put(cache, 4, [5, 6, 7, 8]);
        expect(cache.diagnostics['degradation'], 'disk-lock-timeout');
        expect((await read(cache, 0))?.bytes, [1, 2, 3, 4]);
        final verified = await cache.availableRanges(
          resource: 'secret-url-not-on-disk',
          generation: 1,
          verifyChecksum: true,
        );
        expect(verified, isNotNull);
        expect(
          verified!.any((range) => range.start == 0 && range.end >= 4),
          true,
        );
      } finally {
        lock.unlockSync();
        lock.closeSync();
      }
    });

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
        final obstruction = File('${root.path}/file')
          ..writeAsStringSync('keep');
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
  });

  group('session_read_ahead_test.dart', () {
    test('slow recovery can supply first bytes after 26 seconds', () async {
      final cache = await SessionByteCache.open(memoryLimitBytes: 1024 * 1024);
      var requests = 0;
      final ahead = SessionReadAhead(
        cache: cache,
        resource: 'slow-recovery',
        generation: 1,
        total: 4,
        aheadBytes: 4,
        continuousTransfers: true,
        fetch: (start, end) async {
          requests++;
          return ReadAheadTransfer(
            (() async* {
              await Future<void>.delayed(const Duration(seconds: 26));
              yield [1, 2, 3, 4];
            })(),
            () {},
          );
        },
      );
      try {
        expect(await ahead.read(0, 3).expand((b) => b).toList(), [1, 2, 3, 4]);
        expect(requests, 1);
      } finally {
        await ahead.close();
        await cache.close();
      }
    });

    test(
      'continuous response pauses at quota and yields to foreground',
      () async {
        const mib = 1024 * 1024;
        const total = 48 * mib;
        final root = await Directory.systemTemp.createTemp(
          'rillight-continuous-',
        );
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 8 * mib,
          diskLimitBytes: 64 * mib,
        );
        final ranges = <(int, int)>[];
        var cancelled = 0;
        var received = 0;
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'continuous',
          generation: 1,
          total: total,
          aheadBytes: 8 * mib,
          continuousTransfers: true,
          fetch: (start, end) async {
            ranges.add((start, end));
            var stopped = false;
            return ReadAheadTransfer(
              (() async* {
                // Deliberately cross window boundaries with a nonaligned chunk.
                for (var offset = start; offset <= end && !stopped;) {
                  final size = (end - offset + 1).clamp(0, 71 * 1024);
                  received += size;
                  yield Uint8List.fromList(
                    List.generate(size, (i) => (offset + i) % 251),
                  );
                  offset += size;
                }
              })(),
              () {
                stopped = true;
                cancelled++;
              },
            );
          },
        );
        try {
          await ahead.read(0, 31).drain<void>();
          await until(
            () => ahead.diagnostics['readAheadWorkerActive'] == false,
          );
          expect(ranges, [(0, total - 1)]);
          expect(cancelled, 0);
          expect(received, lessThan(9 * mib));
          final hit = await ahead
              .read(4 * mib, 4 * mib + 31)
              .expand((b) => b)
              .toList();
          expect(hit, List.generate(32, (i) => (4 * mib + i) % 251));
          await until(
            () => ahead.diagnostics['readAheadWorkerActive'] == false,
          );
          expect(ranges, hasLength(1));
          expect(received, lessThan(13 * mib));
          final resume = await ahead.yieldToForeground();
          expect(cancelled, 1);
          resume();
          ahead.stop();
          final later = await ahead
              .read(32 * mib, 32 * mib + 31)
              .expand((b) => b)
              .toList();
          expect(later, List.generate(32, (i) => (32 * mib + i) % 251));
          expect(ranges.last, (32 * mib, total - 1));
          await ahead.close();
          expect(cancelled, ranges.length);
        } finally {
          await ahead.close();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );

    for (final concurrency in [2, 4]) {
      test(
        '$concurrency parallel ranges publish past a stalled lane within bounded workspace',
        () async {
          const mib = 1024 * 1024;
          final chunk = concurrency == 2 ? 8 * mib : 6 * mib;
          final root = await Directory.systemTemp.createTemp(
            'rillight-parallel-',
          );
          final cache = await SessionByteCache.open(
            root: root,
            memoryLimitBytes: 8 * mib,
            diskLimitBytes: 64 * mib,
          );
          final release = Completer<void>();
          final ranges = <(int, int)>[];
          var reservations = 0;
          var peak = 0;
          final ahead = SessionReadAhead(
            cache: cache,
            resource: 'parallel',
            generation: 1,
            total: 24 * mib,
            aheadBytes: 24 * mib,
            maxConcurrentTransfers: concurrency,
            reserveWorkspace: () {
              reservations++;
              if (reservations > peak) peak = reservations;
              return true;
            },
            releaseWorkspace: () => reservations--,
            fetch: (start, end) async {
              ranges.add((start, end));
              return ReadAheadTransfer(
                (() async* {
                  for (var offset = start; offset <= end; offset += 64 * 1024) {
                    final length = (end - offset + 1).clamp(0, 64 * 1024);
                    yield Uint8List(length)
                      ..fillRange(0, length, offset ~/ mib);
                    if (offset == 0) await release.future;
                  }
                })(),
                () {
                  if (start == 0 && !release.isCompleted) release.complete();
                },
              );
            },
          );
          final reader = StreamIterator(ahead.read(0, 24 * mib - 1));
          try {
            expect(await reader.moveNext(), true);
            await until(
              () =>
                  ahead.diagnostics['readAheadPublishedBytes'] ==
                  24 * mib - chunk,
            );
            expect(release.isCompleted, false);
            final later = await ahead
                .read(chunk, chunk + 31)
                .expand((bytes) => bytes)
                .toList();
            expect(later, List.filled(32, chunk ~/ mib));
            expect(ranges, [
              for (var start = 0; start < 24 * mib; start += chunk)
                (start, start + chunk - 1),
            ]);
            expect(peak, concurrency);
            expect(
              cache.diagnostics['pendingPeakBytes'],
              lessThanOrEqualTo(cache.pendingLimitBytes),
            );
            ahead.stop();
            await reader.cancel();
            await ahead.close();
            expect(reservations, 0);
            expect(ahead.failed, false);
          } finally {
            if (!release.isCompleted) release.complete();
            await reader.cancel();
            await ahead.close();
            await cache.close();
            await root.delete(recursive: true);
          }
        },
      );
    }

    test(
      'consumed reclamation preserves initialization upcoming bytes and active leases',
      () async {
        const block = 64 * 1024;
        final root = await Directory.systemTemp.createTemp(
          'rillight-consumed-',
        );
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 0,
          diskLimitBytes: 8 * block,
        );
        CacheRangeLease? lease;
        try {
          for (var i = 0; i < 5; i++) {
            await cache.put(
              resource: 'movie',
              generation: 1,
              offset: i * block,
              bytes: Uint8List(block)..fillRange(0, block, i),
            );
          }
          lease = await cache.protectRange(
            resource: 'movie',
            generation: 1,
            offset: block,
            length: block,
          );
          expect(lease, isNotNull);
          await cache.discardBefore(
            resource: 'movie',
            generation: 1,
            offset: 3 * block,
            keepPrefixBytes: block,
          );
          for (final i in [0, 1, 3, 4]) {
            expect(
              await cache.read(
                resource: 'movie',
                generation: 1,
                offset: i * block,
              ),
              isNotNull,
            );
          }
          expect(
            await cache.read(
              resource: 'movie',
              generation: 1,
              offset: 2 * block,
            ),
            isNull,
          );
          await lease!.close();
          await cache.discardBefore(
            resource: 'movie',
            generation: 1,
            offset: 3 * block,
            keepPrefixBytes: block,
          );
          expect(
            await cache.read(resource: 'movie', generation: 1, offset: block),
            isNull,
          );
        } finally {
          await lease?.close();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );
    test(
      'overlapping demux readers share prefetch without cancelling each other',
      () async {
        const block = 64 * 1024;
        final cache = await SessionByteCache.open(
          memoryLimitBytes: 2 * 1024 * 1024,
        );
        final release = Completer<void>();
        var requests = 0;
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'tracks',
          generation: 1,
          total: 1024 * 1024,
          aheadBytes: 1024 * 1024,
          fetch: (start, end) async {
            requests++;
            return ReadAheadTransfer(
              (() async* {
                for (var offset = start; offset <= end; offset += block) {
                  yield Uint8List(block)..fillRange(0, block, offset ~/ block);
                  if (offset == 0) await release.future;
                }
              })(),
              () {
                if (!release.isCompleted) release.complete();
              },
            );
          },
        );
        final video = StreamIterator(ahead.read(0, 1024 * 1024 - 1));
        final audio = StreamIterator(ahead.read(2 * block, 1024 * 1024 - 1));
        try {
          expect(
            await video.moveNext().timeout(const Duration(seconds: 2)),
            isTrue,
          );
          final pendingAudio = audio.moveNext();
          await Future<void>.delayed(const Duration(milliseconds: 10));
          release.complete();
          expect(
            await pendingAudio.timeout(const Duration(seconds: 2)),
            isTrue,
          );
          expect(audio.current.every((byte) => byte == 2), isTrue);
          expect(
            await video.moveNext().timeout(const Duration(seconds: 2)),
            isTrue,
          );
          expect(video.current.every((byte) => byte == 1), isTrue);
          expect(requests, 1);
          expect(ahead.failed, isFalse);
        } finally {
          ahead.stop();
          await video.cancel();
          await audio.cancel();
          await ahead.close();
          await cache.close();
        }
      },
    );
    test(
      'bounded track reads keep an active transfer covering a distant track',
      () async {
        const mib = 1024 * 1024;
        const block = 64 * 1024;
        final cache = await SessionByteCache.open(memoryLimitBytes: 64 * mib);
        final release = Completer<void>();
        final starts = <int>[];
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'distant-tracks',
          generation: 1,
          total: 32 * mib,
          aheadBytes: 32 * mib,
          fetch: (start, end) async {
            starts.add(start);
            return ReadAheadTransfer(
              (() async* {
                for (var offset = start; offset <= end; offset += block) {
                  yield Uint8List(block)
                    ..fillRange(0, block, (offset ~/ block) % 251);
                  if (offset == 0) await release.future;
                }
              })(),
              () {
                if (!release.isCompleted) release.complete();
              },
            );
          },
        );
        try {
          await ahead.read(0, block - 1).drain<void>();
          final audio = ahead
              .read(24 * mib, 24 * mib + block - 1)
              .fold<List<int>>([], (all, part) => all..addAll(part));
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (!release.isCompleted) release.complete();
          expect(
            (await audio.timeout(
              const Duration(seconds: 5),
            )).every((byte) => byte == (24 * mib ~/ block) % 251),
            isTrue,
          );
          expect(starts, [0]);
        } finally {
          if (!release.isCompleted) release.complete();
          await ahead.close();
          await cache.close();
        }
      },
    );
    for (final targetMiB in [8, 40]) {
      test('seek to $targetMiB MiB preempts a stalled old download', () async {
        const mib = 1024 * 1024;
        final cache = await SessionByteCache.open(memoryLimitBytes: 8 * mib);
        final releases = <Completer<void>>[];
        final starts = <int>[];
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'seek',
          generation: 1,
          total: 192 * mib,
          aheadBytes: 64 * mib,
          fetch: (start, end) async {
            starts.add(start);
            final release = Completer<void>();
            releases.add(release);
            return ReadAheadTransfer(
              (() async* {
                yield Uint8List(64 * 1024)
                  ..fillRange(0, 64 * 1024, start == 0 ? 1 : 7);
                await release.future;
              })(),
              () {
                if (!release.isCompleted) release.complete();
              },
            );
          },
        );
        final old = StreamIterator(ahead.read(0, 192 * mib - 1));
        final seek = StreamIterator(
          ahead.read(targetMiB * mib, targetMiB * mib + 64 * 1024 - 1),
        );
        Future<void>? oldPending;
        try {
          expect(await old.moveNext(), true);
          // The old downstream can still be awaiting bytes when native seek
          // opens its replacement. It must not steal the producer position.
          oldPending = old.moveNext().then<void>(
            (_) {},
            onError: (Object _) {},
          );
          await Future<void>.delayed(Duration.zero);
          expect(
            await seek.moveNext().timeout(const Duration(seconds: 2)),
            true,
          );
          expect(seek.current.every((byte) => byte == 7), true);
          expect(starts.take(2), [0, targetMiB * mib]);
          expect(await seek.moveNext(), false);
          await oldPending.timeout(const Duration(seconds: 2));
          expect(old.current.every((byte) => byte == 7), true);
          expect(starts.take(3), [0, targetMiB * mib, 64 * 1024]);
        } finally {
          ahead.stop();
          for (final release in releases) {
            if (!release.isCompleted) release.complete();
          }
          await oldPending;
          await old.cancel();
          await seek.cancel();
          await ahead.close();
          await cache.close();
        }
      });
    }
    test(
      'a cancelled track read retains its validated partial block',
      () async {
        const size = 64 * 1024;
        final cache = await SessionByteCache.open(memoryLimitBytes: 4 * size);
        final release = Completer<void>();
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'interleaved',
          generation: 1,
          total: 1024 * 1024,
          aheadBytes: 1024 * 1024,
          fetch: (start, end) async => ReadAheadTransfer(
            (() async* {
              yield Uint8List(size)..fillRange(0, size, 7);
              await release.future;
            })(),
            () {
              if (!release.isCompleted) release.complete();
            },
          ),
        );
        final reader = StreamIterator(ahead.read(0, 1024 * 1024 - 1));
        try {
          expect(
            await reader.moveNext().timeout(const Duration(seconds: 2)),
            isTrue,
          );
          ahead.stop();
          await reader.cancel();
          await until(
            () => ahead.diagnostics['readAheadWorkerActive'] == false,
          );
          final retained = await cache.read(
            resource: 'interleaved',
            generation: 1,
            offset: 0,
            maxLength: size,
          );
          expect(retained?.bytes, hasLength(size));
          expect(retained!.bytes.every((byte) => byte == 7), isTrue);
          expect(ahead.failed, isFalse);
        } finally {
          await ahead.close();
          await cache.close();
        }
      },
    );
    test(
      'transient exhaustion resumes automatically and retains its prefix',
      () async {
        const size = 64 * 1024;
        final cache = await SessionByteCache.open(memoryLimitBytes: 4 * size);
        var attempts = 0;
        final starts = <int>[];
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'retry',
          generation: 1,
          total: 2 * size,
          aheadBytes: 2 * size,
          fetch: (start, end) async {
            starts.add(start);
            final attempt = ++attempts;
            return ReadAheadTransfer(
              (() async* {
                if (attempt == 1) {
                  yield Uint8List(size)..fillRange(0, size, 7);
                  throw const ReadAheadRetryLater();
                }
                yield Uint8List(end - start + 1)
                  ..fillRange(0, end - start + 1, 7);
              })(),
              () {},
            );
          },
        );
        try {
          final bytes = await ahead
              .read(0, 2 * size - 1)
              .expand((bytes) => bytes)
              .toList()
              .timeout(const Duration(seconds: 5));
          expect(bytes, List.filled(2 * size, 7));
          expect(starts, [0, size]);
          expect(ahead.failed, false);
          expect(ahead.diagnostics['readAheadTemporaryFailures'], 1);
          expect(cache.diagnostics['invalidations'], 0);
        } finally {
          await ahead.close();
          await cache.close();
        }
      },
    );
    test('a full disk window keeps rolling beyond its quota', () async {
      const mib = 1024 * 1024;
      const total = 48 * mib;
      final root = await Directory.systemTemp.createTemp(
        'rillight-rolling-window-',
      );
      final cache = await SessionByteCache.open(
        root: root,
        memoryLimitBytes: 4 * mib,
        diskLimitBytes: 16 * mib,
      );
      final starts = <int>[];
      final ahead = SessionReadAhead(
        cache: cache,
        resource: 'rolling',
        generation: 1,
        total: total,
        aheadBytes: 16 * mib,
        fetch: (start, end) async {
          starts.add(start);
          return ReadAheadTransfer(
            (() async* {
              for (var offset = start; offset <= end; offset += 64 * 1024) {
                final bytes = Uint8List((end - offset + 1).clamp(0, 64 * 1024));
                bytes.fillRange(0, bytes.length, (offset ~/ (64 * 1024)) % 251);
                yield bytes;
              }
            })(),
            () {},
          );
        },
      );
      try {
        var received = 0;
        await for (final chunk
            in ahead.read(0, total - 1).timeout(const Duration(seconds: 10))) {
          expect(chunk.first, (received ~/ (64 * 1024)) % 251);
          received += chunk.length;
        }
        expect(received, total);
        expect(starts.any((start) => start >= 32 * mib), isTrue);
        expect(
          cache.diagnostics['diskBytes'] as int,
          lessThanOrEqualTo(16 * mib),
        );
      } finally {
        await ahead.close();
        await cache.close();
        await root.delete(recursive: true);
      }
    });

    test(
      'large cache windows use bounded requests and expose the first 64 KiB',
      () async {
        const mib = 1024 * 1024;
        const total = 80 * mib;
        final root = await Directory.systemTemp.createTemp(
          'rillight-bounded-range-',
        );
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 8 * mib,
          diskLimitBytes: 128 * mib,
          pendingLimitBytes: 64 * mib,
        );
        final requests = <(int, int)>[];
        final release = Completer<void>();
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'bounded',
          generation: 1,
          total: total,
          aheadBytes: 2048 * mib,
          fetch: (start, end) async {
            requests.add((start, end));
            if (end - start + 1 > 32 * mib) {
              throw const HttpException('Range rejected by server');
            }
            return ReadAheadTransfer(
              (() async* {
                for (var offset = start; offset <= end; offset += 64 * 1024) {
                  yield Uint8List((end - offset + 1).clamp(0, 64 * 1024));
                  if (offset == 0) await release.future;
                }
              })(),
              () {
                if (!release.isCompleted) release.complete();
              },
            );
          },
        );
        final reader = StreamIterator(ahead.read(0, total - 1));
        try {
          expect(
            await reader.moveNext().timeout(const Duration(seconds: 3)),
            isTrue,
          );
          expect(reader.current, hasLength(64 * 1024));
          release.complete();
          await until(
            () =>
                ahead.diagnostics['readAheadWorkerActive'] == false &&
                ahead.diagnostics['readAheadPublishedBytes'] == total,
          );
          expect(requests, [
            (0, 32 * mib - 1),
            (32 * mib, 64 * mib - 1),
            (64 * mib, total - 1),
          ]);
          expect(ahead.failed, isFalse);
        } finally {
          if (!release.isCompleted) release.complete();
          await reader.cancel();
          await ahead.close();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );

    test(
      'large blocks reduce file count without delaying first delivery',
      () async {
        const mib = 1024 * 1024;
        const total = 16 * mib;
        final root = await Directory.systemTemp.createTemp('rillight-density-');
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 8 * mib,
          diskLimitBytes: 32 * mib,
        );
        var downloaded = 0;
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'density',
          generation: 1,
          total: total,
          aheadBytes: total,
          fetch: (start, end) async {
            Stream<List<int>> chunks() async* {
              for (var offset = start; offset <= end; offset += 64 * 1024) {
                final length = (end - offset + 1).clamp(0, 64 * 1024);
                downloaded += length;
                yield Uint8List(length)..fillRange(0, length, 7);
                await Future<void>.delayed(Duration.zero);
              }
            }

            return ReadAheadTransfer(chunks(), () {});
          },
        );
        final reader = StreamIterator(ahead.read(0, total - 1));
        try {
          expect(await reader.moveNext(), true);
          expect(downloaded, lessThan(4 * mib));
          await until(
            () =>
                downloaded == total &&
                ahead.diagnostics['readAheadWorkerActive'] == false,
          );
          final files = root
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => file.path.endsWith('.block'))
              .toList();
          expect(files, hasLength(5));
          expect(
            files.fold<int>(0, (sum, file) => sum + file.lengthSync()),
            total,
          );
          expect(
            cache.diagnostics['pendingPeakBytes'],
            lessThanOrEqualTo(24 * mib),
          );
          final ranges = await cache.availableRanges(
            resource: 'density',
            generation: 1,
            verifyChecksum: true,
          );
          expect(ranges?.map((range) => (range.start, range.end)).toList(), [
            (0, total),
          ]);
          final hit = await cache.read(
            resource: 'density',
            generation: 1,
            offset: 0,
            maxLength: 32,
          );
          expect(hit?.bytes, List.filled(32, 7));
        } finally {
          await reader.cancel();
          await ahead.close();
          await cache.close();
          expect(
            root
                .listSync(recursive: true)
                .whereType<File>()
                .where((file) => file.path.endsWith('.block')),
            isEmpty,
          );
          await root.delete(recursive: true);
        }
      },
    );

    test(
      'indexed disk hit resumes when pending read capacity returns',
      () async {
        final root = await Directory.systemTemp.createTemp('rillight-budget-');
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 0,
          pendingLimitBytes: 2 * 1024 * 1024,
          diskLimitBytes: 8 * 1024 * 1024,
        );
        final bytes = Uint8List(1024 * 1024)..fillRange(0, 32, 7);
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'cached',
          generation: 1,
          total: bytes.length,
          aheadBytes: bytes.length,
          fetch: (_, _) async =>
              throw StateError('Indexed block was refetched'),
        );
        final reader = StreamIterator(ahead.read(0, 31));
        try {
          expect(
            await cache.put(
              resource: 'cached',
              generation: 1,
              offset: 0,
              bytes: bytes,
            ),
            true,
          );
          expect(cache.diagnostics['diskBytes'], greaterThan(0));
          await cache.resize(
            memoryBytes: 0,
            pendingBytes: 0,
            diskBytes: 8 * 1024 * 1024,
          );
          final first = reader.moveNext();
          await until(
            () => ahead.diagnostics['readAheadReaderWaiting'] == true,
          );
          expect(ahead.diagnostics['readAheadWorkerActive'], false);
          await cache.resize(
            memoryBytes: 0,
            pendingBytes: 2 * 1024 * 1024,
            diskBytes: 8 * 1024 * 1024,
          );
          expect(await first.timeout(const Duration(seconds: 3)), true);
          expect(reader.current, List.filled(32, 7));
        } finally {
          await reader.cancel();
          await ahead.close();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );

    test(
      'explicit pause stops surplus transfer and resume serves demand',
      () async {
        final root = await Directory.systemTemp.createTemp('rillight-paused-');
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 4 * 1024 * 1024,
          diskLimitBytes: 8 * 1024 * 1024,
        );
        var fetches = 0;
        var downloaded = 0;
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'pause',
          generation: 1,
          total: 8 * 1024 * 1024,
          aheadBytes: 4 * 1024 * 1024,
          fetch: (start, end) async {
            fetches++;
            Stream<List<int>> chunks() async* {
              for (var offset = start; offset <= end; offset += 64 * 1024) {
                await Future<void>.delayed(const Duration(milliseconds: 1));
                final length = (end - offset + 1).clamp(0, 64 * 1024);
                downloaded += length;
                yield Uint8List(length);
              }
            }

            return ReadAheadTransfer(chunks(), () {});
          },
        );
        final reader = StreamIterator(ahead.read(0, 8 * 1024 * 1024 - 1));
        try {
          expect(await reader.moveNext(), true);
          ahead.setPrefetchAllowed(false);
          await until(
            () => ahead.diagnostics['readAheadWorkerActive'] == false,
          );
          expect(fetches, 1);
          expect(downloaded, lessThan(4 * 1024 * 1024));
          await reader.cancel();
          ahead.setPrefetchAllowed(true);
          final resumed = await ahead
              .read(4 * 1024 * 1024, 4 * 1024 * 1024 + 31)
              .expand((chunk) => chunk)
              .toList();
          expect(resumed, hasLength(32));
          expect(fetches, 2);
        } finally {
          await reader.cancel();
          await ahead.close();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );

    test(
      'paused consumer still prefetches bounded disk window and reads it back',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'rillight-read-ahead-',
        );
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 256 * 1024,
          diskLimitBytes: 8 * 1024 * 1024,
        );
        var downloads = 0;
        var active = 0;
        var peak = 0;
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'media',
          generation: 1,
          total: 16 * 1024 * 1024,
          aheadBytes: 2 * 1024 * 1024,
          fetch: (start, end) async {
            var cancelled = false;
            Stream<List<int>> body() async* {
              active++;
              if (active > peak) peak = active;
              try {
                for (var p = start; p <= end && !cancelled; p += 64 * 1024) {
                  final n = (end - p + 1).clamp(0, 64 * 1024);
                  downloads += n;
                  yield Uint8List.fromList(
                    List.generate(n, (i) => (p + i) % 251),
                  );
                }
              } finally {
                active--;
              }
            }

            return ReadAheadTransfer(body(), () => cancelled = true);
          },
        );
        final reader = StreamIterator(ahead.read(0, 16 * 1024 * 1024 - 1));
        try {
          expect(await reader.moveNext(), true);
          expect(reader.current.first, 0);
          // Do not pull the next event: this models mpv stopping after its small
          // packet buffer fills, while the disk producer continues independently.
          await until(
            () =>
                (ahead.diagnostics['readAheadPublishedBytes'] as int) >=
                2 * 1024 * 1024,
          );
          expect(downloads, 2 * 1024 * 1024);
          expect(
            cache.diagnostics['memoryBytes'],
            lessThanOrEqualTo(256 * 1024),
          );
          expect(cache.diagnostics['diskBytes'], greaterThan(1024 * 1024));
          await reader.cancel();
          final before = downloads;
          final bytes = await ahead
              .read(0, 31)
              .expand((chunk) => chunk)
              .toList();
          expect(bytes, List.generate(32, (i) => i));
          expect(downloads, before);
          expect(cache.diagnostics['diskHitBytes'], greaterThanOrEqualTo(32));
          expect(peak, 1);
          await ahead.close();
          await cache.close();
          expect(cache.diagnostics['diskBytes'], 0);
          expect(root.listSync().whereType<Directory>(), isEmpty);
        } finally {
          await reader.cancel();
          await ahead.close();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );

    test(
      'continuous prefetch reuses one request with bounded block publications',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'rillight-pipeline-',
        );
        final cache = await SessionByteCache.open(
          root: root,
          memoryLimitBytes: 2 * 1024 * 1024,
          pendingLimitBytes: 64 * 1024 * 1024,
          diskLimitBytes: 64 * 1024 * 1024,
        );
        final requestLengths = <int>[];
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'pipeline',
          generation: 1,
          total: 24 * 1024 * 1024,
          aheadBytes: 24 * 1024 * 1024,
          fetch: (start, end) async {
            requestLengths.add(end - start + 1);
            return ReadAheadTransfer(
              (() async* {
                for (var offset = start; offset <= end; offset += 64 * 1024) {
                  yield Uint8List((end - offset + 1).clamp(0, 64 * 1024));
                }
              })(),
              () {},
            );
          },
        );
        final reader = StreamIterator(ahead.read(0, 24 * 1024 * 1024 - 1));
        try {
          expect(await reader.moveNext(), true);
          await until(
            () =>
                (ahead.diagnostics['readAheadPublishedBytes'] as int) >=
                24 * 1024 * 1024,
          );
          expect(requestLengths, [24 * 1024 * 1024]);
          expect(ahead.diagnostics['readAheadRequestBytes'], 24 * 1024 * 1024);
          expect(
            ahead.diagnostics['readAheadPublicationPeak'],
            inInclusiveRange(2, 4),
          );
          expect(
            cache.diagnostics['pendingPeakBytes'],
            lessThanOrEqualTo(64 * 1024 * 1024),
          );
          expect(cache.diagnostics['pendingPublicationPeak'], greaterThan(1));
        } finally {
          await reader.cancel();
          await ahead.close();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );

    test('truncated producer wakes a waiting reader with failure', () async {
      final cache = await SessionByteCache.open();
      final ahead = SessionReadAhead(
        cache: cache,
        resource: 'bad',
        generation: 0,
        total: 1024 * 1024,
        aheadBytes: 1024 * 1024,
        fetch: (_, _) async =>
            ReadAheadTransfer(Stream.value([1, 2, 3]), () {}),
      );
      try {
        await expectLater(
          ahead.read(0, 100).drain<void>(),
          throwsA(isA<HttpException>()),
        );
        expect(ahead.failed, true);
      } finally {
        await ahead.close();
        await cache.close();
      }
    });

    test(
      'rejected cache publication stops the producer and wakes playback',
      () async {
        final cache = await SessionByteCache.open();
        await cache.close();
        var fetches = 0;
        final ahead = SessionReadAhead(
          cache: cache,
          resource: 'closed',
          generation: 0,
          total: SessionReadAhead.blockBytes,
          aheadBytes: SessionReadAhead.blockBytes,
          fetch: (_, _) async {
            fetches++;
            return ReadAheadTransfer(
              Stream.value(Uint8List(SessionReadAhead.blockBytes)),
              () {},
            );
          },
        );
        try {
          await expectLater(
            ahead
                .read(0, 100)
                .drain<void>()
                .timeout(const Duration(seconds: 2)),
            throwsA(isA<HttpException>()),
          );
          expect(ahead.failed, true);
          expect(fetches, 1);
        } finally {
          await ahead.close();
        }
      },
    );
  });
}

int _actualBytes(Directory root) => root
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .fold(0, (sum, file) => sum + file.lengthSync());
