import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/http_cache_policy.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

import 'mp4_fixture.dart';

void main() {
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
