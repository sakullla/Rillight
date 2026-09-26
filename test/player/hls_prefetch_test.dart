import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

void main() {
  test(
    'foreground reuses a next segment that finishes during bounded handoff',
    () async {
      final fixture = await _SlowHls.open(holdNext: true);
      try {
        final segments = await fixture.playlist();
        final first = await fixture.start(segments[0]);
        await fixture.nextEntered.future.timeout(const Duration(seconds: 1));
        final demand = fixture.read(segments[1]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        fixture.nextReleased.complete();
        expect(await demand.timeout(const Duration(seconds: 1)), 16 * 1024);
        expect(fixture.counts['/b.ts'], 1);
        fixture.currentReleased.complete();
        expect(await first.done, 64 * 1024);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'foreground replaces a stalled matching prefetch after a bounded wait',
    () async {
      final fixture = await _SlowHls.open(holdNext: true);
      try {
        final segments = await fixture.playlist();
        final first = await fixture.start(segments[0]);
        await fixture.nextEntered.future.timeout(const Duration(seconds: 1));
        expect(
          await fixture.read(segments[1]).timeout(const Duration(seconds: 1)),
          16 * 1024,
        );
        expect(fixture.nextReleased.isCompleted, isFalse);
        expect(fixture.counts['/b.ts'], 2);
        fixture.currentReleased.complete();
        await first.done;
        await fixture.waitPrefetch();
        expect(fixture.counts['/b.ts'], 2);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'a stalled prefetch does not stop the current foreground body',
    () async {
      final fixture = await _SlowHls.open(holdNext: true);
      try {
        final segments = await fixture.playlist();
        final first = await fixture.start(segments[0]);
        await fixture.nextEntered.future.timeout(const Duration(seconds: 1));
        fixture.currentReleased.complete();
        expect(await first.done.timeout(const Duration(seconds: 1)), 64 * 1024);
        expect(fixture.nextReleased.isCompleted, isFalse);
        expect(fixture.counts['/b.ts'], 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'next VOD segment overlaps the current slow body and is reused once',
    () async {
      final fixture = await _SlowHls.open();
      try {
        final segments = await fixture.playlist();
        final first = await fixture.start(segments[0]);
        await fixture.nextEntered.future.timeout(const Duration(seconds: 1));
        await fixture.waitPrefetch();
        expect(fixture.currentReleased.isCompleted, isFalse);
        expect(fixture.counts['/b.ts'], 1);
        expect(fixture.counts['/c.ts'], isNull);
        fixture.currentReleased.complete();
        expect(await first.done, 64 * 1024);
        expect(await fixture.read(segments[1]), 16 * 1024);
        expect(fixture.counts['/b.ts'], 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'seek preempts a stalled next segment without waiting for its body',
    () async {
      final fixture = await _SlowHls.open(holdNext: true);
      try {
        final segments = await fixture.playlist();
        final first = await fixture.start(segments[0]);
        await fixture.nextEntered.future.timeout(const Duration(seconds: 1));
        fixture.proxy.cancelPendingReads(preserveSubtitles: true);
        expect(
          await fixture.read(segments[2]).timeout(const Duration(seconds: 1)),
          16 * 1024,
        );
        await first.done;
        expect(fixture.counts['/c.ts'], 1);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'a transient next-segment failure recovers before foreground consumption',
    () async {
      final fixture = await _SlowHls.open(nextFailures: 1);
      try {
        final segments = await fixture.playlist();
        final first = await fixture.start(segments[0]);
        await fixture.nextEntered.future.timeout(const Duration(seconds: 1));
        await fixture.waitPrefetch();
        expect(fixture.counts['/b.ts'], 2);
        expect(
          fixture.proxy.diagnostics['recoveries'],
          greaterThanOrEqualTo(1),
        );
        fixture.currentReleased.complete();
        await first.done;
        expect(await fixture.read(segments[1]), 16 * 1024);
        expect(fixture.counts['/b.ts'], 2);
      } finally {
        await fixture.close();
      }
    },
  );
}

class _SlowHls {
  _SlowHls(this.server, this.proxy, this.holdNext, this.nextFailures);
  final HttpServer server;
  final PlaybackHttpProxy proxy;
  final client = HttpClient();
  final bool holdNext;
  int nextFailures;
  final counts = <String, int>{};
  final currentReleased = Completer<void>();
  final nextReleased = Completer<void>();
  final nextEntered = Completer<void>();

  static Future<_SlowHls> open({
    bool holdNext = false,
    int nextFailures = 0,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cache = await SessionByteCache.open(
      memoryLimitBytes: 2 * 1024 * 1024,
    );
    final proxy = await PlaybackHttpProxy.create(cache: cache);
    final fixture = _SlowHls(server, proxy, holdNext, nextFailures);
    server.listen(fixture.serve);
    return fixture;
  }

  Future<void> serve(HttpRequest request) async {
    final path = request.uri.path;
    counts[path] = (counts[path] ?? 0) + 1;
    try {
      if (path.endsWith('.m3u8')) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts\n#EXTINF:2,\nc.ts\n#EXT-X-ENDLIST\n',
        );
      } else {
        if (path == '/b.ts') {
          if (!nextEntered.isCompleted) nextEntered.complete();
          if (nextFailures-- > 0) {
            request.response.statusCode = 503;
            await request.response.close();
            return;
          }
          if (holdNext && counts[path] == 1) await nextReleased.future;
        }
        request.response.headers.set('etag', '"$path"');
        request.response.headers.set('cache-control', 'max-age=120');
        final length = path == '/a.ts' ? 64 * 1024 : 16 * 1024;
        request.response.contentLength = length;
        if (request.headers.value('range') != null) {
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes 0-${length - 1}/$length',
          );
        }
        if (path == '/a.ts') {
          request.response.add(List<int>.filled(length ~/ 2, 7));
          await request.response.flush();
          await currentReleased.future;
          request.response.add(List<int>.filled(length ~/ 2, 7));
        } else {
          request.response.add(List<int>.filled(length, 9));
        }
      }
      await request.response.close();
    } catch (_) {
      /* The player or seek may close a held response. */
    }
  }

  Future<List<Uri>> playlist() async {
    final origin = Uri.parse('http://127.0.0.1:${server.port}/index.m3u8');
    final response = await (await client.getUrl(
      proxy.register(origin),
    )).close();
    final text = await response.transform(utf8.decoder).join();
    return text
        .split('\n')
        .where((line) => line.startsWith('http://'))
        .map(Uri.parse)
        .toList();
  }

  Future<int> read(Uri url) async => (await (await client.getUrl(
    url,
  )).close()).fold<int>(0, (count, bytes) => count + bytes.length);

  // Return the completion separately so a partially received foreground stream
  // stays open while the test observes the background request order.
  Future<Future<int> Function()> unused() async => throw UnimplementedError();
  Future<({Future<int> done})> start(Uri url) async {
    final response = await (await client.getUrl(url)).close();
    final received = Completer<void>();
    final finished = Completer<int>();
    var count = 0;
    response.listen(
      (bytes) {
        count += bytes.length;
        if (!received.isCompleted) received.complete();
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete(count);
      },
      onError: (Object _) {
        if (!finished.isCompleted) finished.complete(count);
      },
    );
    await received.future;
    return (done: finished.future);
  }

  Future<void> waitPrefetch() async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (proxy.diagnostics['segmentPrefetchActive'] == true &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(proxy.diagnostics['segmentPrefetchActive'], isFalse);
  }

  Future<void> close() async {
    if (!currentReleased.isCompleted) currentReleased.complete();
    if (!nextReleased.isCompleted) nextReleased.complete();
    client.close(force: true);
    await proxy.close();
    await server.close(force: true);
  }
}
