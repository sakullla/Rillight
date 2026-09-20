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

  static Future<_Child> start(Directory root, int limit) async {
    final process = await Process.start(_dart, [
      'test/player/cache/cache_process_fixture.dart',
      root.path,
      '$limit',
    ]);
    final output = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    process.stderr.drain<void>();
    if (!await output.moveNext().timeout(const Duration(seconds: 15))) {
      throw StateError('Child failed to start');
    }
    final diagnostics = jsonDecode(output.current) as Map;
    expect(diagnostics['degradation'], isNull);
    return _Child(process, output);
  }

  Future<Map> command(Map<String, Object?> command) async {
    process.stdin.writeln(jsonEncode(command));
    await process.stdin.flush();
    if (!await output.moveNext().timeout(const Duration(seconds: 5))) {
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
