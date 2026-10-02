import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/http_cache_policy.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

import 'mp4_fixture.dart';

void main() {
  test(
    'busy integrity refresh retains recent coverage then expires and recovers',
    () async {
      final bytes = progressiveMp4Fixture();
      final root = await Directory.systemTemp.createTemp(
        'rillight-timeline-retry-',
      );
      final cache = await SessionByteCache.open(
        root: root,
        memoryLimitBytes: 0,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = bytes.length;
        request.response.headers.set('etag', '"immutable"');
        request.response.add(bytes);
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create(
        cache: cache,
        sessionBuffering: true,
      );
      final client = HttpClient();
      try {
        final route = proxy.register(
          Uri.parse('http://127.0.0.1:${server.port}/movie.mp4'),
        );
        await (await (await client.getUrl(route)).close()).drain<void>();
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while ((cache.diagnostics['diskBytes'] as int? ?? 0) < bytes.length &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await proxy.refreshTimeline(const Duration(seconds: 4));
        final expected = [
          {'startMs': 0, 'endMs': 4000},
        ];
        expect(proxy.diagnostics['cachedTimeRanges'], expected);
        await cache.resize(
          memoryBytes: 0,
          pendingBytes: 0,
          diskBytes: 2048 * 1024 * 1024,
        );
        await proxy.refreshTimeline(
          const Duration(seconds: 4, milliseconds: 1),
        );
        expect(proxy.diagnostics['cachedTimeRanges'], expected);
        await Future<void>.delayed(const Duration(milliseconds: 5100));
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedTimeRanges'], isEmpty);
        await cache.resize(
          memoryBytes: 0,
          pendingBytes: 8 * 1024 * 1024,
          diskBytes: 2048 * 1024 * 1024,
        );
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedTimeRanges'], expected);
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'busy byte verification retains recent coverage then expires and recovers',
    () async {
      final bytes = Uint8List(1024);
      final root = await Directory.systemTemp.createTemp(
        'rillight-timeline-retry-',
      );
      final cache = await SessionByteCache.open(
        root: root,
        memoryLimitBytes: 0,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = bytes.length;
        request.response.headers.set('etag', '"immutable"');
        request.response.add(bytes);
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create(
        cache: cache,
        sessionBuffering: true,
      );
      final client = HttpClient();
      try {
        final route = proxy.register(
          Uri.parse('http://127.0.0.1:${server.port}/movie.mp4'),
        );
        await (await (await client.getUrl(route)).close()).drain<void>();
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while ((cache.diagnostics['diskBytes'] as int? ?? 0) < bytes.length &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await proxy.refreshTimeline(const Duration(seconds: 4));
        final expected = [
          {'start': 0, 'end': 1024},
        ];
        expect(proxy.diagnostics['cachedByteRanges'], expected);
        await cache.resize(
          memoryBytes: 0,
          pendingBytes: 0,
          diskBytes: 2048 * 1024 * 1024,
        );
        await proxy.refreshTimeline(
          const Duration(seconds: 4, milliseconds: 1),
        );
        expect(proxy.diagnostics['cachedByteRanges'], expected);
        await Future<void>.delayed(const Duration(milliseconds: 5100));
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedByteRanges'], isEmpty);
        await cache.resize(
          memoryBytes: 0,
          pendingBytes: 8 * 1024 * 1024,
          diskBytes: 2048 * 1024 * 1024,
        );
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedByteRanges'], expected);
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test('unknown timeline exposes only current verified byte islands', () async {
    final bytes = Uint8List.fromList(List<int>.generate(1024, (i) => i % 251));
    var etag = '"first"';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = MediaByteRange.resolve(
        request.headers.value('range'),
        bytes.length,
      )!;
      request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = range.length;
      request.response.headers
        ..set('etag', etag)
        ..set('cache-control', 'max-age=3600')
        ..set(
          'content-range',
          'bytes ${range.start}-${range.end}/${bytes.length}',
        );
      request.response.add(bytes.sublist(range.start, range.end + 1));
      await request.response.close();
    });
    final cache = await SessionByteCache.open(memoryLimitBytes: 1024);
    final proxy = await PlaybackHttpProxy.create(
      cache: cache,
      sessionBuffering: true,
    );
    final client = HttpClient();
    final route = proxy.register(
      Uri.parse('http://127.0.0.1:${server.port}/opaque.bin'),
    );
    Future<void> read(int first, int last) async {
      final request = await client.getUrl(route);
      request.headers.set('range', 'bytes=$first-$last');
      await (await request.close()).drain<void>();
    }

    try {
      await read(0, 99);
      await read(500, 599);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      final first = proxy.diagnostics;
      expect(first['cachedTimeRanges'], isEmpty);
      expect(first['timelineUnknownReason'], isNotNull);
      expect(first['cachedByteTotal'], 1024);
      expect(first['cachedByteRanges'], [
        {'start': 0, 'end': 100},
        {'start': 500, 'end': 600},
      ]);

      // Appending bytes does not invalidate a time-index snapshot. This opaque
      // container remains unmappable; the next scan includes the new island.
      final identity = first['timelineIdentity'] as String;
      final separator = identity.lastIndexOf(':');
      expect(separator, greaterThan(0));
      final resource = identity.substring(0, separator);
      final generation = int.parse(identity.substring(separator + 1));
      await cache.put(
        resource: 'unrelated',
        generation: 1,
        offset: 0,
        bytes: Uint8List(600),
      );
      await cache.read(
        resource: resource,
        generation: generation,
        offset: 0,
        maxLength: 100,
      );
      await cache.read(
        resource: resource,
        generation: generation,
        offset: 500,
        maxLength: 100,
      );
      await cache.put(
        resource: 'other',
        generation: 1,
        offset: 0,
        bytes: Uint8List(600),
      );
      // Evicting unrelated, unadvertised RAM must not blink verified islands.
      expect(proxy.diagnostics['cachedByteRanges'], first['cachedByteRanges']);

      proxy.selectContainerTracks(videoTrackId: 1, audioTrackId: 2);
      final refreshing = proxy.refreshTimeline(const Duration(seconds: 4));
      final write = cache.put(
        resource: identity.substring(0, separator),
        generation: int.parse(identity.substring(separator + 1)),
        offset: 900,
        bytes: Uint8List.fromList(bytes.sublist(900, 950)),
      );
      await write;
      await refreshing;
      final concurrent = proxy.diagnostics;
      expect(
        concurrent['timelineUnknownReason'],
        'containerTrackOrTimingUnknown',
      );
      expect(concurrent['cachedTimeRanges'], isEmpty);
      expect(concurrent['cachedByteRanges'], [
        {'start': 0, 'end': 100},
        {'start': 500, 'end': 600},
      ]);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(proxy.diagnostics['cachedByteRanges'], [
        {'start': 0, 'end': 100},
        {'start': 500, 'end': 600},
        {'start': 900, 'end': 950},
      ]);

      etag = '"second"';
      await read(700, 799);
      final invalidated = proxy.diagnostics;
      expect(invalidated['cachedByteRanges'], isEmpty);
      await proxy.refreshTimeline(const Duration(seconds: 4));
      expect(proxy.diagnostics['cachedByteRanges'], [
        {'start': 700, 'end': 800},
      ]);
    } finally {
      client.close(force: true);
      await proxy.close();
      await server.close(force: true);
    }
  });

  test(
    'full byte response does not fabricate playable time for unknown media',
    () async {
      final bytes = Uint8List.fromList(List<int>.filled(1024, 0x6b));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers
          ..set('etag', '"unknown"')
          ..set('cache-control', 'max-age=3600');
        request.response
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      });
      final cache = await SessionByteCache.open();
      final proxy = await PlaybackHttpProxy.create(
        cache: cache,
        sessionBuffering: true,
      );
      final client = HttpClient();
      try {
        final route = proxy.register(
          Uri.parse('http://127.0.0.1:${server.port}/unknown.bin'),
        );
        final response = await (await client.getUrl(route)).close();
        await response.drain<void>();
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedTimeRanges'], isEmpty);
        expect(proxy.diagnostics['timelineUnknownReason'], isNotNull);
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'track selection retracts old ranges until selected audio is readable',
    () async {
      final bytes = progressiveMp4Fixture(secondAudio: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = MediaByteRange.resolve(
          request.headers.value('range'),
          bytes.length,
        )!;
        request.response
          ..statusCode = 206
          ..contentLength = range.length;
        request.response.headers
          ..set('etag', '"two-audio"')
          ..set('cache-control', 'max-age=3600')
          ..set(
            'content-range',
            'bytes ${range.start}-${range.end}/${bytes.length}',
          );
        request.response.add(bytes.sublist(range.start, range.end + 1));
        await request.response.close();
      });
      final cache = await SessionByteCache.open();
      final proxy = await PlaybackHttpProxy.create(
        cache: cache,
        sessionBuffering: true,
      );
      final client = HttpClient();
      final route = proxy.register(
        Uri.parse('http://127.0.0.1:${server.port}/two-audio.mp4'),
      );
      Future<void> read(int start, int end) async {
        final request = await client.getUrl(route);
        request.headers.set('range', 'bytes=$start-$end');
        await (await request.close()).drain<void>();
      }

      try {
        await read(0, 27);
        await read(52, bytes.length - 1);
        await read(28, 43);
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedTimeRanges'], isEmpty);
        expect(proxy.diagnostics['timelineUnknownReason'], isNotNull);
        proxy.selectContainerTracks(videoTrackId: 1, audioTrackId: 2);
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedTimeRanges'], [
          {'startMs': 0, 'endMs': 4000},
        ]);
        proxy.selectContainerTracks(videoTrackId: 1, audioTrackId: 3);
        expect(proxy.diagnostics['cachedTimeRanges'], isEmpty);
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedTimeRanges'], isEmpty);
        await read(44, 51);
        await proxy.refreshTimeline(const Duration(seconds: 4));
        expect(proxy.diagnostics['cachedTimeRanges'], [
          {'startMs': 0, 'endMs': 4000},
        ]);
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );

  for (final tagged in [true, false]) {
    test(
      'cancelled metadata probe ${tagged ? 'retains validated' : 'rejects unvalidated'} prefix',
      () async {
        final movie = progressiveMp4Fixture();
        const padding = 4 * 1024 * 1024;
        final header = ByteData(8)
          ..setUint32(0, padding)
          ..setUint32(4, 0x66726565);
        final prefix = [
          ...movie,
          ...header.buffer.asUint8List(),
          ...List<int>.filled(16 * 1024, 0),
        ];
        final release = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (tagged) request.response.headers.set('etag', '"movie"');
          request.response.headers.set('cache-control', 'max-age=3600');
          request.response.contentLength = movie.length + padding;
          try {
            request.response.add(prefix);
            await request.response.flush();
            await release.future;
            await request.response.close();
          } catch (_) {
            /* The demuxer cancelled this probe. */
          }
        });
        final cache = await SessionByteCache.open();
        final proxy = await PlaybackHttpProxy.create(
          cache: cache,
          sessionBuffering: true,
        );
        final client = HttpClient();
        try {
          final route = proxy.register(
            Uri.parse('http://127.0.0.1:${server.port}/probe.mp4'),
          );
          final response = await (await client.getUrl(route)).close();
          final arrived = Completer<void>();
          response.listen((_) {
            if (!arrived.isCompleted) arrived.complete();
          }, onError: (Object _) {});
          await arrived.future;
          proxy.cancelPendingReads();
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (proxy.diagnostics['activeRequests'] != 0 &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(proxy.diagnostics['activeRequests'], 0);
          await proxy.refreshTimeline(const Duration(seconds: 4));
          expect(
            proxy.diagnostics['cachedTimeRanges'],
            tagged
                ? [
                    {'startMs': 0, 'endMs': 4000},
                  ]
                : isEmpty,
          );
          if (!tagged) {
            expect(proxy.diagnostics['cachedByteTotal'], isNull);
            expect(proxy.diagnostics['cachedByteRanges'], isEmpty);
          }
        } finally {
          release.complete();
          client.close(force: true);
          await proxy.close();
          await server.close(force: true);
        }
      },
    );
  }

  for (final complete in [false, true]) {
    test(
      'verified ${complete ? '200 body' : 'partial MP4 groups'} maps without a read-ahead worker',
      () async {
        final bytes = progressiveMp4Fixture();
        var etag = '"one"';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final header = request.headers.value('range');
          final range = MediaByteRange.resolve(header, bytes.length)!;
          request.response.headers.set('etag', etag);
          request.response.headers.set('cache-control', 'max-age=3600');
          if (header != null) {
            request.response.statusCode = 206;
            request.response.headers.set(
              'content-range',
              'bytes ${range.start}-${range.end}/${bytes.length}',
            );
          }
          request.response.contentLength = range.length;
          request.response.add(bytes.sublist(range.start, range.end + 1));
          await request.response.close();
        });
        final cache = await SessionByteCache.open();
        final proxy = await PlaybackHttpProxy.create(
          cache: cache,
          sessionBuffering: true,
        );
        final client = HttpClient();
        final route = proxy.register(
          Uri.parse('http://127.0.0.1:${server.port}/movie.mp4'),
        );
        Future<void> read([String? range]) async {
          final request = await client.getUrl(route);
          if (range != null) request.headers.set('range', range);
          await (await request.close()).drain<void>();
        }

        try {
          if (complete) {
            await read();
          } else {
            await read('bytes=0-27');
            await read('bytes=44-${bytes.length - 1}');
            await read('bytes=28-31');
            await read('bytes=36-39');
          }
          await proxy.refreshTimeline(const Duration(seconds: 4));
          expect(proxy.diagnostics['readAheadActive'], isNull);
          expect(proxy.diagnostics['timelineUnknownReason'], isNull);
          expect(proxy.diagnostics['cachedTimeRanges'], [
            {'startMs': 0, 'endMs': complete ? 4000 : 2000},
          ]);
          if (!complete) {
            // Downloading the second video group cannot bridge missing audio.
            await read('bytes=32-35');
            await proxy.refreshTimeline(const Duration(seconds: 4));
            expect(proxy.diagnostics['cachedTimeRanges'], [
              {'startMs': 0, 'endMs': 2000},
            ]);
            etag = '"two"';
            await read('bytes=40-43');
            await proxy.refreshTimeline(const Duration(seconds: 4));
            expect(proxy.diagnostics['cachedTimeRanges'], isEmpty);
            expect(proxy.diagnostics['timelineUnknownReason'], isNotNull);
          }
        } finally {
          client.close(force: true);
          await proxy.close();
          await server.close(force: true);
        }
      },
    );
  }
}
