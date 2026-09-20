// Manual filesystem/process pressure checks. Run via tool/player_cache_stress.ps1,
// never as part of flutter test's automatic discovery or alongside a player.
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

  test(
    'late successful write recovers disk and publishes its original block',
    () async {
      await open(disk: 4 * 1024 * 1024);
      final cache = await SessionByteCache.open(
        root: root,
        memoryLimitBytes: 256 * 1024,
        pendingLimitBytes: 2 * 1024 * 1024,
        diskLimitBytes: 4 * 1024 * 1024,
        diskTimeout: const Duration(milliseconds: 40),
      );
      caches.add(cache);
      final locker = await _Locker.start(root);
      try {
        await put(cache, 0, List.filled(64 * 1024, 7));
        expect(cache.diagnostics['degradation'], 'disk-timeout');
        expect(cache.diagnostics['pendingBytes'], greaterThan(0));
      } finally {
        await locker.stop();
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((cache.diagnostics['degradation'] != null ||
              cache.diagnostics['pendingBytes'] != 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.diagnostics['degradation'], null);
      expect(cache.diagnostics['diskRecoveries'], greaterThanOrEqualTo(1));
      await cache.resize(
        memoryBytes: 0,
        pendingBytes: 2 * 1024 * 1024,
        diskBytes: 4 * 1024 * 1024,
      );
      final result = await read(cache, 0);
      expect(result?.source, CacheReadSource.disk);
      expect(result?.bytes, List.filled(1024, 7));
    },
  );

  test(
    'optional timeline query under foreign lock does not disable disk',
    () async {
      final cache = await open(memory: 0);
      await put(cache, 0, [1, 2, 3, 4]);
      final locker = await _Locker.start(root);
      try {
        expect(
          await cache.availableRanges(
            resource: 'secret-url-not-on-disk',
            generation: 1,
          ),
          null,
        );
        expect(cache.diagnostics['degradation'], null);
      } finally {
        await locker.stop();
      }
      expect((await read(cache, 0))?.bytes, [1, 2, 3, 4]);
    },
  );

  test('foreign quota lock times out and leaves memory usable', () async {
    final locker = await Process.start(_dart, [
      'tool/player_cache_process_fixture.dart',
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
      'tool/player_cache_process_fixture.dart',
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
      'tool/player_cache_process_fixture.dart',
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
