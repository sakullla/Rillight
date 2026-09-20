import 'dart:async';
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
    'file slot reservation counts protected blocks pins and temporary files',
    () async {
      final child = await _Child.start(root, 1024 * 1024, diskTimeoutMs: 10000);
      try {
        await child.command({
          'op': 'put',
          'offset': 0,
          'length': 1,
          'value': 7,
        });
        await child.command({
          'op': 'seed-files',
          'entries': 8191,
          'kind': 'block',
        });
        final protected = await child.command({
          'op': 'protect',
          'offset': 0,
          'length': 1,
        });
        expect(protected['protected'], isTrue, reason: '$protected');
        expect(_actualFileCount(root), lessThanOrEqualTo(8192));
        final pin = root
            .listSync(recursive: true)
            .whereType<File>()
            .singleWhere((file) => file.path.endsWith('.pin'));
        final pinnedToken = pin.readAsStringSync();
        expect(
          File('${pin.parent.path}/$pinnedToken').existsSync(),
          isTrue,
          reason: 'protected block missing immediately after pin',
        );
        final after = await child.command({
          'op': 'put',
          'offset': 1,
          'length': 1,
          'value': 8,
        });
        expect(after['degradation'], isNull);
        expect(_actualFileCount(root), lessThanOrEqualTo(8192));
        expect(
          File('${pin.parent.path}/$pinnedToken').existsSync(),
          isTrue,
          reason:
              'protected block evicted by a write; token=$pinnedToken pin=${pin.path}',
        );
        expect(
          (await child.command({'op': 'protected-read', 'offset': 0}))['bytes'],
          [7],
        );
        expect((await child.command({'op': 'read', 'offset': 1}))['bytes'], [
          8,
        ]);
        await child.command({'op': 'unprotect'});
        expect(
          root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.pin')),
          isEmpty,
        );
      } finally {
        await child.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
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
    'full temporary file inventory skips writes without exceeding entry limit',
    () async {
      final child = await _Child.start(root, 1024 * 1024, diskTimeoutMs: 10000);
      try {
        await child.command({
          'op': 'seed-files',
          'entries': 8191,
          'kind': 'partial',
        });
        final result = await child.command({
          'op': 'put',
          'offset': 0,
          'length': 1,
          'value': 7,
        });
        expect(result['degradation'], isNull);
        expect(_actualFileCount(root), 8192);
        expect(
          (await child.command({'op': 'read', 'offset': 0}))['bytes'],
          isNull,
        );
        expect(
          root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.block')),
          isEmpty,
        );
      } finally {
        await child.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'killed oversized owned session is reclaimed without harming an unrelated file',
    () async {
      final child = await _Child.start(root, 1024 * 1024, diskTimeoutMs: 10000);
      addTearDown(child.stop);
      await child.command({'op': 'put', 'offset': 0, 'length': 1, 'value': 7});
      expect(
        (await child.command({
          'op': 'protect',
          'offset': 0,
          'length': 1,
        }))['protected'],
        isTrue,
      );
      // Reproduce the historical count violation, including a live pin, then
      // force process death before normal unprotect/close could reduce it.
      await child.command({
        'op': 'seed-files',
        'entries': 8193,
        'kind': 'partial',
      });
      final deadDirectory = root.listSync().whereType<Directory>().single;
      final unrelated = File('${deadDirectory.path}/user-note.txt')
        ..writeAsStringSync('preserve');
      final peer = await _Child.start(
        root,
        1024 * 1024,
        diskTimeoutMs: 10000,
        expectHealthy: false,
      );
      // The oversized live session cannot be removed while its owner still holds
      // the lifecycle lock. The new peer safely falls back instead.
      await peer.stop();
      expect(unrelated.existsSync(), isTrue);
      expect(deadDirectory.listSync().length, greaterThan(8192));
      child.process.kill(ProcessSignal.sigkill);
      await child.process.exitCode.timeout(const Duration(seconds: 10));
      await child.output.cancel();
      final recovered = await _Child.start(
        root,
        1024 * 1024,
        diskTimeoutMs: 10000,
      );
      try {
        expect(unrelated.readAsStringSync(), 'preserve');
        expect(
          deadDirectory.listSync().whereType<File>().where(
            (f) =>
                f.path.endsWith('.partial') ||
                f.path.endsWith('.block') ||
                f.path.endsWith('.pin'),
          ),
          isEmpty,
        );
        final result = await recovered.command({
          'op': 'put',
          'offset': 0,
          'length': 4,
          'value': 9,
        });
        expect(result['degradation'], isNull);
        expect(
          (await recovered.command({'op': 'read', 'offset': 0}))['bytes'],
          [9, 9, 9, 9],
        );
      } finally {
        await recovered.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
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
    'disk range lease survives a real foreign writer and releases quota protection',
    () async {
      final cache = await open(memory: 0, disk: 4096, pending: 4096);
      for (var i = 0; i < 6; i++) {
        await put(cache, i * 512, List.filled(512, i));
      }
      final child = await _Child.start(root, 4096);
      try {
        final lease = await cache.protectRange(
          resource: 'secret-url-not-on-disk',
          generation: 1,
          offset: 0,
          length: 3072,
        );
        expect(lease, isNotNull);
        final stats = await child.command({
          'op': 'put',
          'offset': 0,
          'length': 2048,
          'value': 9,
        });
        expect(stats['diskBytes'], lessThanOrEqualTo(4096));
        for (var i = 0; i < 6; i++) {
          expect((await lease!.read(i * 512))!.bytes, List.filled(512, i));
        }
        await lease!.close();
        await child.command({
          'op': 'put',
          'offset': 0,
          'length': 2048,
          'value': 9,
        });
        expect(
          (await child.command({'op': 'read', 'offset': 0}))['bytes'],
          List.filled(2048, 9),
        );
        expect(await read(cache, 0), isNull);
        expect(
          root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.pin')),
          isEmpty,
        );
      } finally {
        await child.stop();
      }
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
    'read protection release survives a foreign lock and is retried under the next lock',
    () async {
      final cache = await open(memory: 0);
      await put(cache, 0, [1, 2, 3, 4]);
      final lease = await cache.protectRange(
        resource: 'secret-url-not-on-disk',
        generation: 1,
        offset: 0,
        length: 4,
      );
      expect(lease, isNotNull);
      final locker = await _Locker.start(root);
      try {
        await lease!.close();
        expect(
          root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.pin')),
          hasLength(1),
        );
      } finally {
        await locker.stop();
      }
      await put(cache, 4, [5, 6, 7, 8]);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.pin')),
        isEmpty,
      );
      expect(cache.diagnostics['degradation'], isNull);
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
    'real processes enforce shared quota and reclaim only dead sessions',
    () async {
      final first = await _Child.start(root, 1200);
      final second = await _Child.start(root, 1200);
      try {
        await first.command({
          'op': 'put',
          'offset': 0,
          'length': 600,
          'value': 1,
        });
        await second.command({
          'op': 'put',
          'offset': 0,
          'length': 600,
          'value': 2,
        });
        expect(_actualBytes(root), lessThanOrEqualTo(1200));
        expect(
          (await first.command({'op': 'read', 'offset': 0}))['bytes'],
          isNull,
        );
        expect(
          (await second.command({'op': 'read', 'offset': 0}))['bytes'],
          List.filled(600, 2),
        );
        first.process.kill();
        await first.process.exitCode;
        final cache = await open(memory: 0, disk: 1200);
        expect(root.listSync().whereType<Directory>().length, 2);
        expect(
          (await second.command({'op': 'read', 'offset': 0}))['bytes'],
          List.filled(600, 2),
        );
        await cache.close();
      } finally {
        await first.stop();
        await second.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test('foreign quota lock times out and leaves memory usable', () async {
    final locker = await Process.start(_dart, [
      'test/player/cache/cache_process_fixture.dart',
      'lock',
      root.path,
    ]);
    final output = StreamIterator(
      locker.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      expect(
        await output.moveNext().timeout(const Duration(seconds: 15)),
        isTrue,
      );
      final elapsed = Stopwatch()..start();
      final cache = await open();
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
      expect(cache.diagnostics['degradation'], isNotNull);
      await put(cache, 0, [1, 2]);
      expect((await read(cache, 0))?.source, CacheReadSource.memory);
    } finally {
      locker.kill();
      await locker.exitCode;
      await output.cancel();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
    'closing under a foreign lock releases ownership for later reclamation',
    () async {
      final first = await open(memory: 0, disk: 800);
      final second = await open(memory: 0, disk: 4096);
      await put(first, 0, List.filled(300, 1));
      await put(second, 0, List.filled(300, 2));
      final locker = await _Locker.start(root);
      try {
        await first.close();
        expect(first.diagnostics['cleanup'], 'pending');
      } finally {
        await locker.stop();
      }
      // The surviving coordinator must no longer retain the departed session's
      // lease or its lower snapshot. Its next operation reclaims those bytes.
      await put(second, 300, List.filled(900, 3));
      expect(root.listSync().whereType<Directory>().length, 1);
      expect(
        (await read(second, 300, length: 900))?.bytes,
        List.filled(900, 3),
      );
      expect(second.diagnostics['diskLimitBytes'], 4096);
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

  test(
    'timed-out full disk queue still accepts fresh bounded memory data',
    () async {
      const mib = 1024 * 1024;
      final cache = await SessionByteCache.open(
        root: root,
        memoryLimitBytes: mib,
        diskLimitBytes: 16 * mib,
        pendingLimitBytes: 8 * mib,
        diskTimeout: const Duration(milliseconds: 50),
      );
      caches.add(cache);
      expect(cache.diagnostics['degradation'], isNull);
      final locker = await _Locker.start(root);
      try {
        await Future.wait(
          List.generate(
            4,
            (i) => cache.put(
              resource: 'queue',
              generation: 1,
              offset: i * mib,
              bytes: Uint8List(mib),
            ),
          ),
        );
        expect(cache.diagnostics['degradation'], 'disk-timeout');
        expect(cache.diagnostics['pendingBytes'], 8 * mib);
        expect(
          await cache.put(
            resource: 'latest',
            generation: 1,
            offset: 0,
            bytes: Uint8List.fromList([7, 8, 9]),
          ),
          isTrue,
        );
        final hit = await cache.read(
          resource: 'latest',
          generation: 1,
          offset: 0,
        );
        expect(hit?.bytes, [7, 8, 9]);
        expect(hit?.source, CacheReadSource.memory);
        expect(cache.diagnostics['memoryPeakBytes'], lessThanOrEqualTo(mib));
      } finally {
        await locker.stop();
      }
      await cache.close();
    },
  );

  test('simultaneous real writers stay within shared physical quota', () async {
    final first = await _Child.start(root, 4096);
    final second = await _Child.start(root, 4096);
    try {
      for (var i = 0; i < 12; i++) {
        final results = await Future.wait([
          first.command({
            'op': 'put',
            'offset': i * 512,
            'length': 512,
            'value': 1,
          }),
          second.command({
            'op': 'put',
            'offset': i * 512,
            'length': 512,
            'value': 2,
          }),
        ]);
        expect(_actualBytes(root), lessThanOrEqualTo(4096));
        for (final result in results) {
          expect(result['degradation'], isNull);
          expect(result['diskPeakBytes'], lessThanOrEqualTo(4096));
        }
      }
    } finally {
      await first.stop();
      await second.stop();
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}

int _actualBytes(Directory root) => root
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .fold(0, (sum, file) => sum + file.lengthSync());

int _actualFileCount(Directory root) =>
    root.listSync(recursive: true, followLinks: false).whereType<File>().length;

String get _dart {
  final executable = File(Platform.resolvedExecutable);
  if (!executable.path.contains('flutter_tester')) return executable.path;
  return '${executable.parent.path}/../../../dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
}

class _Locker {
  _Locker(this.process, this.output);
  final Process process;
  final StreamIterator<String> output;

  static Future<_Locker> start(Directory root) async {
    final process = await Process.start(_dart, [
      'test/player/cache/cache_process_fixture.dart',
      'lock',
      root.path,
    ]);
    final output = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    process.stderr.drain<void>();
    if (!await output.moveNext().timeout(const Duration(seconds: 15))) {
      throw StateError('Lock child did not start');
    }
    return _Locker(process, output);
  }

  Future<void> stop() async {
    process.stdin.writeln('release');
    await process.stdin.flush();
    await process.exitCode.timeout(const Duration(seconds: 5));
    await output.cancel();
  }
}

class _Child {
  _Child(this.process, this.output);
  final Process process;
  final StreamIterator<String> output;
  bool _stopped = false;

  static Future<_Child> start(
    Directory root,
    int limit, {
    int diskTimeoutMs = 750,
    bool expectHealthy = true,
  }) async {
    final process = await Process.start(_dart, [
      'test/player/cache/cache_process_fixture.dart',
      root.path,
      '$limit',
      '$diskTimeoutMs',
    ]);
    final output = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    process.stderr.drain<void>();
    if (!await output.moveNext().timeout(const Duration(seconds: 15))) {
      throw StateError('Child failed to start');
    }
    final diagnostics = jsonDecode(output.current) as Map;
    if (expectHealthy) expect(diagnostics['degradation'], isNull);
    return _Child(process, output);
  }

  Future<Map> command(Map<String, Object?> command) async {
    process.stdin.writeln(jsonEncode(command));
    await process.stdin.flush();
    if (!await output.moveNext().timeout(const Duration(seconds: 20))) {
      throw StateError('Missing child response');
    }
    return jsonDecode(output.current) as Map;
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await command({'op': 'close'});
    } catch (_) {
      process.kill();
    }
    await process.exitCode;
    await output.cancel();
  }
}
