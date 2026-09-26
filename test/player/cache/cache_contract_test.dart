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
  });
}

int _actualBytes(Directory root) => root
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .fold(0, (sum, file) => sum + file.lengthSync());
