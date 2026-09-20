import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/cache/session_read_ahead.dart';

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
        expect(cache.diagnostics['memoryBytes'], lessThanOrEqualTo(256 * 1024));
        expect(cache.diagnostics['diskBytes'], greaterThan(1024 * 1024));
        await reader.cancel();
        final before = downloads;
        final bytes = await ahead.read(0, 31).expand((chunk) => chunk).toList();
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
      fetch: (_, _) async => ReadAheadTransfer(Stream.value([1, 2, 3]), () {}),
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
}
