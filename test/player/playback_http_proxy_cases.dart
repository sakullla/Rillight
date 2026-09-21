import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';

void main() {
  test(
    'seek cancellation preserves a pending subtitle but close cancels it',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await PlaybackHttpProxy.create();
      final client = HttpClient();
      final pending = <String, HttpRequest>{};
      upstream.listen((request) => pending[request.uri.path] = request);
      Future<String> read(String path, PlaybackResourceRole role) async {
        final url = proxy.register(
          Uri.parse('http://127.0.0.1:${upstream.port}/$path'),
          role: role,
        );
        final response = await (await client.getUrl(url)).close();
        return response.transform(utf8.decoder).join();
      }

      Future<void> waitFor(bool Function() ready) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed < const Duration(seconds: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(ready(), isTrue);
      }

      try {
        final media = read(
          'media',
          PlaybackResourceRole.media,
        ).catchError((Object _) => 'cancelled');
        var subtitleFinished = false;
        final subtitle = read(
          'subtitle',
          PlaybackResourceRole.subtitle,
        ).whenComplete(() => subtitleFinished = true);
        await waitFor(() => pending.length == 2);
        proxy.cancelPendingReads(preserveSubtitles: true);
        await media.timeout(const Duration(seconds: 2));
        expect(subtitleFinished, isFalse);
        pending['/subtitle']!.response.write('subtitle still available');
        await pending['/subtitle']!.response.close();
        expect(await subtitle, 'subtitle still available');
        final abandoned = read(
          'abandoned',
          PlaybackResourceRole.subtitle,
        ).catchError((Object _) => 'cancelled');
        await waitFor(() => pending.containsKey('/abandoned'));
        await proxy.close().timeout(const Duration(seconds: 2));
        await abandoned.timeout(const Duration(seconds: 2));
      } finally {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
      }
    },
  );

  test(
    'busy timeline snapshot does not shrink buffer or degrade disk',
    () async {
      final fixture = await _CacheFixture.open(
        disk: true,
        sessionBuffering: true,
        readAheadBytes: 2 * 1024 * 1024,
      );
      fixture.body = 'x' * (2 * 1024 * 1024);
      await fixture.read('bytes=0-2097151');
      await fixture.settle();
      const duration = Duration(seconds: 30);
      await fixture.proxy.refreshTimeline(duration);
      expect(
        fixture.proxy.bufferedEnd(
          const Duration(seconds: 5),
          const Duration(seconds: 10),
        ),
        duration,
      );
      await fixture.cache.resize(
        memoryBytes: 1024 * 1024,
        pendingBytes: 0,
        diskBytes: 64 * 1024 * 1024,
      );
      await fixture.proxy.refreshTimeline(duration);
      expect(
        fixture.proxy.bufferedEnd(
          const Duration(seconds: 5),
          const Duration(seconds: 10),
        ),
        duration,
      );
      expect(fixture.cache.diagnostics['degradation'], null);
      await fixture.cache.close();
      await fixture.proxy.refreshTimeline(duration);
      expect(
        fixture.proxy.bufferedEnd(
          const Duration(seconds: 5),
          const Duration(seconds: 10),
        ),
        const Duration(seconds: 10),
      );
    },
  );

  test(
    'unsupported conditional ranges fall back before committing output',
    () async {
      final fixture = await _CacheFixture.open(
        disk: true,
        sessionBuffering: true,
        readAheadBytes: 2 * 1024 * 1024,
      );
      fixture.body = 'x' * (2 * 1024 * 1024);
      fixture.ignoreConditionalRange = true;
      expect((await fixture.read('bytes=0-1048575')).$2, 'x' * 1024 * 1024);
      expect(fixture.proxy.diagnostics['readAheadBypassedResources'], 1);
    },
  );

  test('disconnect also cancels the cached-prefix gap producer', () async {
    final fixture = await _CacheFixture.open();
    fixture.body = 'x' * (8 * 1024 * 1024);
    await fixture.read('bytes=0-262143');
    await fixture.settle();
    final before = fixture.proxy.upstreamBytes;
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(fixture.url)).close();
      final first = Completer<void>();
      response.listen((_) {
        if (!first.isCompleted) first.complete();
      }, onError: (Object _) {});
      await first.future.timeout(const Duration(seconds: 3));
      client.close(force: true);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (fixture.proxy.diagnostics['activeRequests'] != 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(fixture.proxy.diagnostics['activeRequests'], 0);
      expect(fixture.proxy.upstreamBytes - before, lessThan(2 * 1024 * 1024));
    } finally {
      client.close(force: true);
    }
  });

  test(
    'rotating signed redirect revalidates bytes instead of discarding disk',
    () async {
      final fixture = await _CacheFixture.open(
        memoryBytes: 4,
        disk: true,
        sessionBuffering: true,
      );
      fixture.control = 'no-store';
      fixture.redirectVersion = 1;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      await fixture.settle();
      fixture.redirectVersion = 2;
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.proxy.upstreamBytes - before, 1);
      expect(fixture.cache.diagnostics['diskHitBytes'], 8);
      expect(fixture.cache.diagnostics['invalidations'], 0);
      fixture.redirectVersion = 3;
      fixture.etag = '"other-content"';
      fixture.body = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      expect((await fixture.read('bytes=0-7')).$2, 'ABCDEFGH');
    },
  );

  test(
    'HEAD failure validates a tiny range without discarding disk cache',
    () async {
      final fixture = await _CacheFixture.open(
        memoryBytes: 4,
        disk: true,
        sessionBuffering: true,
      );
      fixture.control = 'no-store';
      fixture.headStatus = 502;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      await fixture.settle();
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.proxy.upstreamBytes - before, 1);
      expect(fixture.cache.diagnostics['diskHitBytes'], 8);
      expect(fixture.cache.diagnostics['invalidations'], 0);
      expect(fixture.methods, ['GET', 'HEAD', 'GET']);
      expect(fixture.ranges.last, 'bytes=0-0');
      fixture.etag = '"new-version"';
      fixture.body = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      expect((await fixture.read('bytes=0-7')).$2, 'ABCDEFGH');
    },
  );

  test(
    'read-ahead HTTP path serves disk bytes and does not redownload a seek',
    () async {
      final fixture = await _CacheFixture.open(
        memoryBytes: 256 * 1024,
        disk: true,
        sessionBuffering: true,
        readAheadBytes: 2 * 1024 * 1024,
      );
      fixture.body = 'x' * (8 * 1024 * 1024);
      fixture.control = 'no-store';
      expect(
        (await fixture.read('bytes=0-4194303')).$2,
        'x' * (4 * 1024 * 1024),
      );
      await fixture.settle();
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (fixture.proxy.diagnostics['readAheadWorkerActive'] == true &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(fixture.proxy.diagnostics['readAheadWorkerActive'], false);
      expect(
        fixture.cache.diagnostics['diskBytes'],
        greaterThan(4 * 1024 * 1024),
      );
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=0-1048575')).$2, 'x' * 1024 * 1024);
      expect(fixture.cache.diagnostics['diskHitBytes'], greaterThan(0));
      expect(fixture.proxy.upstreamBytes, before);
      final rangeCount = fixture.ranges.length;
      expect(
        (await fixture.read('bytes=2097152-3145727')).$2,
        'x' * 1024 * 1024,
      );
      // The shifted window may prefetch new bytes beyond the original 4 MiB;
      // it must not download the already-cached forward-seek target again.
      for (final range in fixture.ranges.skip(rangeCount).whereType<String>()) {
        expect(
          int.parse(RegExp(r'^bytes=(\d+)-').firstMatch(range)![1]!),
          greaterThanOrEqualTo(4 * 1024 * 1024),
        );
      }
      await fixture.settle();
      final settled = DateTime.now().add(const Duration(seconds: 3));
      while (fixture.proxy.diagnostics['readAheadWorkerActive'] == true &&
          DateTime.now().isBefore(settled)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final beforeBack = fixture.proxy.upstreamBytes;
      expect(
        (await fixture.read('bytes=1048576-2097151')).$2,
        'x' * 1024 * 1024,
      );
      expect(fixture.proxy.upstreamBytes, beforeBack);
    },
  );

  test(
    'read-ahead revalidates changed content and bypasses unavailable disk',
    () async {
      final fixture = await _CacheFixture.open(
        memoryBytes: 256 * 1024,
        disk: true,
        sessionBuffering: true,
        readAheadBytes: 2 * 1024 * 1024,
      );
      fixture.body = 'a' * (4 * 1024 * 1024);
      fixture.control = 'no-store';
      expect((await fixture.read('bytes=0-1048575')).$2, 'a' * 1024 * 1024);
      fixture.etag = '"changed"';
      fixture.body = 'b' * (4 * 1024 * 1024);
      expect((await fixture.read('bytes=0-1048575')).$2, 'b' * 1024 * 1024);
      await fixture.proxy.close();
      expect(fixture.cache.diagnostics['diskBytes'], 0);
      final memoryOnly = await _CacheFixture.open(
        sessionBuffering: true,
        readAheadBytes: 2 * 1024 * 1024,
      );
      memoryOnly.body = 'c' * (2 * 1024 * 1024);
      expect((await memoryOnly.read('bytes=0-1048575')).$2, 'c' * 1024 * 1024);
      expect(memoryOnly.proxy.diagnostics['readAheadActive'], null);
    },
  );

  test(
    'disconnected player stops its upstream body instead of draining it',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await PlaybackHttpProxy.create();
      final client = HttpClient();
      final release = Completer<void>();
      server.listen((request) async {
        request.response.contentLength = 32 * 1024 * 1024;
        try {
          request.response.add(List.filled(64 * 1024, 1));
          await request.response.flush();
          await release.future;
          for (var i = 1; i < 512; i++) {
            request.response.add(List.filled(64 * 1024, 1));
            await request.response.flush();
            await Future<void>.delayed(Duration.zero);
          }
        } catch (_) {
        } finally {
          try {
            await request.response.close();
          } catch (_) {}
        }
      });
      try {
        final response = await (await client.getUrl(
          proxy.register(Uri.parse('http://127.0.0.1:${server.port}/media')),
        )).close();
        final first = Completer<void>();
        response.listen((_) {
          if (!first.isCompleted) first.complete();
        }, onError: (Object _) {});
        await first.future.timeout(const Duration(seconds: 3));
        client.close(force: true);
        release.complete();
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (proxy.diagnostics['activeRequests'] != 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(proxy.diagnostics['activeRequests'], 0);
        expect(
          proxy.upstreamBytes,
          lessThan(8 * 1024 * 1024),
          reason: 'a disconnected probe must not download the remaining movie',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );

  test('cache pressure bypasses caching and transport slots recover', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cache = await SessionByteCache.open(
      memoryLimitBytes: 32 * 1024 * 1024,
    );
    final proxy = await PlaybackHttpProxy.create(cache: cache);
    final client = HttpClient();
    final release = Completer<void>();
    server.listen((request) async {
      final tail = request.uri.path == '/tail';
      request.response.headers.set('etag', '"${request.uri.path}"');
      request.response.headers.set('cache-control', 'max-age=600');
      request.response.contentLength = tail ? 16 : 4 * 1024 * 1024;
      try {
        request.response.add(List.filled(tail ? 16 : 64 * 1024, 7));
        await request.response.flush();
        if (!tail) await release.future;
      } catch (_) {
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    Uri route(String path) =>
        proxy.register(Uri.parse('http://127.0.0.1:${server.port}/$path'));
    try {
      for (var i = 0; i < 8; i++) {
        final response = await (await client.getUrl(
          route('movie$i'),
        )).close().timeout(const Duration(seconds: 2));
        expect(response.statusCode, 200);
        final received = Completer<void>();
        response.listen((bytes) {
          if (!received.isCompleted) received.complete();
        }, onError: (Object _) {});
        await received.future.timeout(const Duration(seconds: 2));
      }
      expect(proxy.diagnostics['cacheWorkspaceBytes'], 3 * 1024 * 1024);
      expect(
        proxy.diagnostics['proxyInFlightPeakBytes'],
        lessThanOrEqualTo(4 * 1024 * 1024),
      );
      final overloaded = await (await client.getUrl(
        route('tail'),
      )).close().timeout(const Duration(seconds: 2));
      expect(overloaded.statusCode, HttpStatus.serviceUnavailable);
      await overloaded.drain<void>();
      proxy.cancelPendingReads();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (proxy.diagnostics['activeRequests'] != 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(proxy.diagnostics['activeRequests'], 0);
      expect(proxy.diagnostics['cacheWorkspaceBytes'], 0);
      final tail = await (await client.getUrl(
        route('tail'),
      )).close().timeout(const Duration(seconds: 2));
      expect(tail.statusCode, 200);
      expect(
        await tail.fold<int>(0, (total, bytes) => total + bytes.length),
        16,
      );
    } finally {
      release.complete();
      client.close(force: true);
      await proxy.close();
      await server.close(force: true);
    }
  });

  test('tail probe is not queued behind two open media responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    final release = Completer<void>();
    final opened = Completer<void>();
    var streams = 0;
    server.listen((request) async {
      final tail = request.headers.value('range') == 'bytes=1048560-';
      final start = tail ? 1048560 : 0;
      request.response.statusCode = 206;
      request.response.headers.set(
        'content-range',
        'bytes $start-1048575/1048576',
      );
      request.response.contentLength = 1048576 - start;
      try {
        request.response.add(List.filled(tail ? 16 : 64 * 1024, 7));
        await request.response.flush();
        if (!tail) {
          if (++streams == 2) opened.complete();
          await release.future;
        }
      } catch (_) {
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${server.port}/movie.mkv'),
      );
      for (var i = 0; i < 2; i++) {
        final request = await client.getUrl(url);
        request.headers.set('range', 'bytes=0-');
        final response = await request.close();
        response.listen((_) {}, onError: (Object _) {});
      }
      await opened.future;
      final request = await client.getUrl(url);
      request.headers.set('range', 'bytes=1048560-');
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      expect(response.statusCode, 206);
      expect(
        await response.fold<int>(0, (count, bytes) => count + bytes.length),
        16,
      );
    } finally {
      release.complete();
      client.close(force: true);
      await proxy.close();
      await server.close(force: true);
    }
  });

  test(
    'a wholly evicted range streams once instead of loading small gaps',
    () async {
      final fixture = await _CacheFixture.open(
        memoryBytes: 256 * 1024,
        disk: true,
      );
      fixture.body = 'x' * (2 * 1024 * 1024);
      await fixture.read('bytes=0-1048575');
      await fixture.settle();
      await fixture.read('bytes=1048576-2097151');
      await fixture.settle();
      // Shrink below a published block, reproducing a real quota eviction while
      // the proxy's range index still contains its old disk tokens.
      await fixture.cache.resize(
        memoryBytes: 0,
        pendingBytes: 4 * 1024 * 1024,
        diskBytes: 128,
      );
      final before = fixture.requests;
      expect((await fixture.read('bytes=0-1048575')).$2, 'x' * 1048576);
      expect(fixture.requests - before, 1);
      expect(fixture.ranges.last, 'bytes=0-1048575');
    },
  );
  test(
    'stable socket fragments aggregate into MiB blocks without delaying output',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final cache = await SessionByteCache.open(
        memoryLimitBytes: 32 * 1024 * 1024,
      );
      final proxy = await PlaybackHttpProxy.create(cache: cache);
      final continueBody = Completer<void>();
      const size = 2 * 1024 * 1024 + 32 * 1024;
      server.listen((request) async {
        request.response.headers.set('cache-control', 'max-age=600');
        request.response.headers.set('etag', '"blocks"');
        request.response.contentLength = size;
        request.response.add(List.filled(64 * 1024, 7));
        await request.response.flush();
        await continueBody.future;
        for (var position = 64 * 1024; position < size; position += 32 * 1024) {
          request.response.add(List.filled(32 * 1024, 7));
          await request.response.flush();
        }
        await request.response.close();
      });
      try {
        final uri = proxy.register(
          Uri.parse('http://127.0.0.1:${server.port}/media'),
        );
        final response = await (await client.getUrl(uri)).close();
        var received = 0;
        await for (final bytes in response) {
          if (received == 0) {
            expect(cache.diagnostics['indexEntries'], 0);
            continueBody.complete();
          }
          received += bytes.length;
        }
        await Future<void>.delayed(Duration.zero);
        expect(received, size);
        expect(cache.diagnostics['indexEntries'], 3);
        expect(cache.diagnostics['memoryBytes'], size);
        expect(
          proxy.diagnostics['proxyInFlightPeakBytes'],
          lessThanOrEqualTo(2 * 1024 * 1024),
        );
        final before = proxy.upstreamBytes;
        await (await (await client.getUrl(uri)).close()).drain<void>();
        expect(proxy.upstreamBytes, before);
      } finally {
        if (!continueBody.isCompleted) continueBody.complete();
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );
  for (final tightened in ['no-cache', 'max-age=0']) {
    test(
      'same ETag gap immediately applies $tightened before its next hit',
      () async {
        final fixture = await _CacheFixture.open();
        await fixture.read('bytes=0-7');
        await fixture.settle();
        fixture.control = tightened;
        expect((await fixture.read('bytes=4-11')).$2, 'efghijkl');
        final before = fixture.proxy.upstreamBytes;
        expect((await fixture.read('bytes=8-11')).$2, 'ijkl');
        expect(fixture.methods, ['GET', 'GET', 'HEAD']);
        expect(fixture.proxy.upstreamBytes, before);
      },
    );
  }

  for (final disk in [false, true]) {
    test(
      'complete 512KiB no-validator response reuses bounded ${disk ? 'disk' : 'memory'} reads',
      () async {
        final fixture = await _CacheFixture.open(
          memoryBytes: disk ? 0 : 1024 * 1024,
          disk: disk,
        );
        fixture.etag = null;
        fixture.body = 'a' * (512 * 1024);
        expect((await fixture.read(null)).$2, fixture.body);
        await fixture.settle();
        final before = fixture.proxy.upstreamBytes;
        expect((await fixture.read(null)).$2, fixture.body);
        expect(fixture.requests, 1);
        expect(fixture.proxy.upstreamBytes, before);
        await fixture.settle();
        expect(
          fixture.proxy.diagnostics['proxyInFlightPeakBytes'],
          lessThanOrEqualTo(2 * 1024 * 1024),
        );
        expect(fixture.cache.diagnostics['protectedRanges'], 0);
      },
    );
  }

  for (final caching in [false, true]) {
    test(
      '4096-entry >512KiB HLS keeps sealed first last and rewind routes with cache=$caching',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = Uri.parse('http://127.0.0.1:${server.port}');
        var requests = 0;
        final manifest =
            '#EXTM3U\n${List.filled(9000, '# ${'x' * 60}\n').join()}${List.generate(4096, (i) => '#EXTINF:2,\nsegment$i.ts?api_key=secret\n').join()}#EXT-X-ENDLIST\n';
        expect(utf8.encode(manifest).length, greaterThan(512 * 1024));
        server.listen((request) async {
          requests++;
          final text = request.uri.path == '/index.m3u8'
              ? manifest
              : request.uri.path;
          final bytes = utf8.encode(text);
          request.response.contentLength = bytes.length;
          request.response.headers.set('cache-control', 'max-age=3600');
          request.response.add(bytes);
          await request.response.close();
        });
        final cache = caching ? await SessionByteCache.open() : null;
        final proxy = await PlaybackHttpProxy.create(
          origin: origin,
          cache: cache,
          headers: {'X-Emby-Token': 'secret'},
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await proxy.close();
          await server.close(force: true);
        });
        Future<(int, String)> get(Uri url) async {
          final response = await (await client.getUrl(url)).close();
          return (
            response.statusCode,
            await response.transform(utf8.decoder).join(),
          );
        }

        final result = await get(proxy.register(origin.resolve('/index.m3u8')));
        expect(result.$1, 200);
        expect(result.$2, isNot(contains('secret')));
        final routes = result.$2
            .split('\n')
            .where((line) => line.startsWith('http'))
            .map(Uri.parse)
            .toList();
        expect(routes, hasLength(4096));
        expect((await get(routes.first)).$2, '/segment0.ts');
        expect((await get(routes.last)).$2, '/segment4095.ts');
        // Distinct admitted resources evict cache metadata, never issued routes.
        for (final route in routes.skip(1).take(260)) {
          expect((await get(route)).$1, 200);
        }
        expect((await get(routes.first)).$2, '/segment0.ts');
        expect(
          proxy.diagnostics['registeredResources'],
          lessThanOrEqualTo(256),
        );
        final before = requests;
        final segments = routes.first.pathSegments.toList();
        final token = segments[1];
        segments[1] = '${token[0] == 'A' ? 'B' : 'A'}${token.substring(1)}';
        expect(
          (await get(routes.first.replace(pathSegments: segments))).$1,
          404,
        );
        expect(requests, before);
        // Registration creates fresh nonces but keeps the canonical cache identity.
        final same = proxy.register(origin.resolve('/index.m3u8'));
        expect((await get(same)).$1, 200);
      },
    );
  }

  test('If-Range change before a gap replaces the entire old range', () async {
    final fixture = await _CacheFixture.open();
    await fixture.read('bytes=0-7');
    await fixture.settle();
    fixture.etag = '"replacement"';
    fixture.body = fixture.body.toUpperCase();
    expect((await fixture.read('bytes=4-11')).$2, 'EFGHIJKL');
    expect(fixture.ranges, ['bytes=0-7', 'bytes=8-11', 'bytes=4-11']);
  });

  test(
    'seek cancels old requests and preserves published validated bytes',
    () async {
      final fixture = await _CacheFixture.open();
      await fixture.read('bytes=0-7');
      await fixture.settle();
      fixture.delay = const Duration(milliseconds: 100);
      final pending = fixture
          .read('bytes=12-19')
          .then<Object?>((r) => r, onError: (Object _) => null);
      while (fixture.requests < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      fixture.proxy.cancelPendingReads();
      await pending;
      fixture.delay = Duration.zero;
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.proxy.upstreamBytes, before);
      expect(fixture.proxy.diagnostics['cancelledReads'], greaterThan(0));
      expect((await fixture.read('bytes=12-19')).$2, 'mnopqrst');
    },
  );

  test(
    'one cancelled consumer does not abort a shared gap for another',
    () async {
      final fixture = await _CacheFixture.open();
      await fixture.read('bytes=0-3');
      await fixture.settle();
      fixture.delay = const Duration(milliseconds: 100);
      final leavingClient = HttpClient();
      final request = await leavingClient.getUrl(fixture.url);
      request.headers.set('range', 'bytes=8-15');
      final leaving = request.close().then<Object?>(
        (r) => r.drain<void>(),
        onError: (Object _) => null,
      );
      final remaining = fixture.read('bytes=8-15');
      while (fixture.requests < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      leavingClient.close(force: true);
      await leaving;
      expect((await remaining).$2, 'ijklmnop');
      expect(fixture.ranges.where((r) => r == 'bytes=8-15'), hasLength(1));
    },
  );

  test(
    'HLS refresh isolates reused URLs by sequence and never caches keys',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      var sequence = 1;
      var keys = 0;
      var manifests = 0;
      server.listen((request) async {
        request.response.headers.set('cache-control', 'max-age=3600');
        request.response.headers.set('etag', '"fixed"');
        final text = request.uri.path == '/index.m3u8'
            ? '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:$sequence\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:2,\nsame.ts\n'
            : request.uri.path == '/key'
            ? 'key${++keys}'
            : 'segment$sequence';
        if (request.uri.path == '/index.m3u8') manifests++;
        final bytes = utf8.encode(text);
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create(
        origin: origin,
        cache: await SessionByteCache.open(),
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      });
      Future<String> get(Uri uri) async => (await (await client.getUrl(
        uri,
      )).close()).transform(utf8.decoder).join();
      final playlistUri = proxy.register(origin.resolve('/index.m3u8'));
      final first = await get(playlistUri);
      final firstSegment = Uri.parse(
        first.split('\n').firstWhere((line) => line.startsWith('http')),
      );
      final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(first)![1]!);
      expect(await get(firstSegment), 'segment1');
      expect(await get(key), 'key1');
      expect(await get(key), 'key2');
      sequence++;
      final second = await get(playlistUri);
      final secondSegment = Uri.parse(
        second.split('\n').firstWhere((line) => line.startsWith('http')),
      );
      expect(secondSegment, isNot(firstSegment));
      expect(await get(secondSegment), 'segment2');
      expect(manifests, 2);
      expect(proxy.stream, PlaybackCacheStream.conservative);
    },
  );

  test('hybrid cache reuses full and overlapping byte ranges', () async {
    final fixture = await _CacheFixture.open();
    expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
    await fixture.settle();
    final firstBytes = fixture.proxy.upstreamBytes;
    expect((await fixture.read('bytes=0-3')).$2, 'abcd');
    expect(fixture.proxy.upstreamBytes, firstBytes);
    expect((await fixture.read('bytes=4-11')).$2, 'efghijkl');
    expect(fixture.ranges, ['bytes=0-7', 'bytes=8-11']);
    expect(fixture.proxy.upstreamBytes, 12);
    expect((await fixture.read('bytes=-4')).$2, 'wxyz');
    expect((await fixture.read('bytes=24-')).$2, 'yz');
    expect((await fixture.read('bytes=90-')).$1, 416);
    expect(fixture.proxy.diagnostics['memoryHitBytes'], greaterThan(0));
    expect(fixture.proxy.upstreamBytesPerSecond, greaterThan(0));
  });

  test(
    'disk hit works after memory eviction and does not count as upstream',
    () async {
      final fixture = await _CacheFixture.open(memoryBytes: 4, disk: true);
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      await fixture.settle();
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.proxy.upstreamBytes, before);
      expect(fixture.proxy.diagnostics['diskHitBytes'], 8);
    },
  );

  test('no-store and unsupported Vary never reuse bodies', () async {
    final fixture = await _CacheFixture.open();
    for (final mode in ['no-store', 'vary']) {
      fixture.control = mode == 'no-store' ? 'no-store' : 'max-age=3600';
      fixture.vary = mode == 'vary' ? '*' : null;
      final before = fixture.requests;
      await fixture.read('bytes=0-7');
      await fixture.settle();
      await fixture.read('bytes=0-7');
      expect(fixture.requests - before, 2);
    }
  });

  test(
    'opt-in no-store session buffer writes disk and validates reuse',
    () async {
      final fixture = await _CacheFixture.open(
        memoryBytes: 4,
        disk: true,
        sessionBuffering: true,
      );
      fixture.control = 'no-store, max-age=3600';
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      await fixture.settle();
      expect(fixture.cache.diagnostics['diskBytes'], greaterThan(8));
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.methods, ['GET', 'HEAD']);
      expect(fixture.cache.diagnostics['diskHitBytes'], 8);
      expect(fixture.proxy.upstreamBytes, before);
      fixture.etag = '"changed"';
      fixture.body = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      expect((await fixture.read('bytes=0-7')).$2, 'ABCDEFGH');
      expect(fixture.proxy.upstreamBytes, before + 8);
      await fixture.proxy.close();
      expect(fixture.cache.diagnostics['closed'], true);
      expect(fixture.cache.diagnostics['diskBytes'], 0);
    },
  );

  test(
    'session buffering still rejects unknown Vary and unvalidated reuse',
    () async {
      final fixture = await _CacheFixture.open(sessionBuffering: true);
      fixture.control = 'no-store, max-age=3600';
      fixture.vary = '*';
      await fixture.read('bytes=0-7');
      await fixture.settle();
      expect(fixture.cache.diagnostics['indexEntries'], 0);
      fixture.vary = null;
      fixture.etag = null;
      await fixture.read('bytes=0-7');
      final before = fixture.proxy.upstreamBytes;
      fixture.body = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      expect((await fixture.read('bytes=0-7')).$2, 'ABCDEFGH');
      expect(fixture.proxy.upstreamBytes, before + 8);
    },
  );

  test(
    'no-cache validates with HEAD 304 and transfers no duplicate body',
    () async {
      final fixture = await _CacheFixture.open();
      fixture.control = 'no-cache';
      await fixture.read('bytes=0-7');
      await fixture.settle();
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.methods, ['GET', 'HEAD']);
      expect(fixture.proxy.upstreamBytes, before);
    },
  );

  test('changed validation never serves the old representation', () async {
    final fixture = await _CacheFixture.open();
    fixture.control = 'no-cache';
    await fixture.read('bytes=0-7');
    await fixture.settle();
    fixture.body = fixture.body.toUpperCase();
    fixture.etag = '"second"';
    expect((await fixture.read('bytes=0-7')).$2, 'ABCDEFGH');
    expect(fixture.methods, ['GET', 'HEAD', 'GET']);
  });

  test(
    'without strong validator only one complete fresh response is reused',
    () async {
      final fixture = await _CacheFixture.open();
      fixture.etag = 'W/"weak"';
      await fixture.read('bytes=0-7');
      await fixture.settle();
      expect((await fixture.read('bytes=2-5')).$2, 'cdef');
      expect(fixture.requests, 1);
      expect((await fixture.read('bytes=4-11')).$2, 'efghijkl');
      expect(fixture.ranges, ['bytes=0-7', 'bytes=4-11']);
      await fixture.settle();
      await fixture.read('bytes=0-3');
      expect(fixture.requests, 3);
    },
  );

  test(
    'weak response eviction falls back before emitting cached bytes',
    () async {
      final fixture = await _CacheFixture.open(memoryBytes: 4);
      fixture.etag = null;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      await fixture.settle();
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.requests, 2);
    },
  );

  test(
    'no validator and no freshness keeps ordinary streaming functional',
    () async {
      final fixture = await _CacheFixture.open();
      fixture.etag = null;
      fixture.control = '';
      expect((await fixture.read(null)).$2, fixture.body);
      await fixture.settle();
      expect((await fixture.read(null)).$2, fixture.body);
      expect(fixture.requests, 2);
    },
  );

  test(
    'ignored ranges preserve 200 and multiple ranges bypass the cache',
    () async {
      final fixture = await _CacheFixture.open();
      fixture.ignoreRange = true;
      final response = await fixture.read('bytes=4-7');
      expect(response, (200, fixture.body));
      await fixture.settle();
      await fixture.read('bytes=0-1,4-5');
      expect(fixture.requests, 2);
      expect(fixture.ranges.last, 'bytes=0-1,4-5');
    },
  );

  test('HEAD uses no body and sessions do not share response data', () async {
    final fixture = await _CacheFixture.open();
    final head = await fixture.client.headUrl(fixture.url);
    final response = await head.close();
    expect(response.contentLength, fixture.body.length);
    await response.drain<void>();
    expect(fixture.proxy.upstreamBytes, 0);
    await fixture.read('bytes=0-7');
    await fixture.settle();
    final other = await PlaybackHttpProxy.create(
      origin: fixture.origin,
      cache: await SessionByteCache.open(),
    );
    addTearDown(other.close);
    final request = await fixture.client.getUrl(
      other.register(fixture.origin.resolve('/video')),
    );
    request.headers.set('range', 'bytes=0-7');
    await (await request.close()).drain<void>();
    expect(fixture.requests, 3);
    expect(other.upstreamBytes, 8);
  });

  test(
    'cached gap downloads are shared between concurrent consumers',
    () async {
      final fixture = await _CacheFixture.open();
      await fixture.read('bytes=0-3');
      await fixture.settle();
      fixture.delay = const Duration(milliseconds: 50);
      final responses = await Future.wait([
        fixture.read('bytes=8-15'),
        fixture.read('bytes=8-15'),
      ]);
      expect(responses.map((r) => r.$2), ['ijklmnop', 'ijklmnop']);
      expect(fixture.ranges.where((r) => r == 'bytes=8-15'), hasLength(1));
    },
  );

  for (final mode in ['complete', 'retry', 'partial-only']) {
    test('HLS 206 $mode never exposes unrewritten resources', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      const manifest = '#EXTM3U\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n';
      var count = 0;
      server.listen((request) async {
        count++;
        final partial =
            mode == 'partial-only' ||
            (mode == 'retry' && request.headers.value('range') != null);
        final bytes = utf8.encode(
          partial ? manifest.substring(0, 8) : manifest,
        );
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-type',
          'application/vnd.apple.mpegurl',
        );
        request.response.headers.set(
          'content-range',
          'bytes 0-${bytes.length - 1}/${manifest.length}',
        );
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create(origin: origin);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      });
      final request = await client.getUrl(
        proxy.register(origin.resolve('/playlist')),
      );
      request.headers.set('range', 'bytes=0-7');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (mode == 'partial-only') {
        expect(response.statusCode, 502);
        expect(text, isNot(contains('segment.ts')));
      } else {
        expect(response.statusCode, 200);
        expect(response.headers.value('content-range'), isNull);
        expect(text, contains('http://127.0.0.1:'));
        expect(text, isNot(contains('${origin.port}')));
      }
      expect(count, mode == 'complete' ? 1 : 2);
    });
  }
  test(
    'gzip media and HLS are decoded even when upstream ignores identity',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        final text = request.uri.path.endsWith('.m3u8')
            ? '#EXTM3U\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n'
            : 'decoded-media';
        final bytes = gzip.encode(utf8.encode(text));
        request.response.headers.set('Content-Encoding', 'gzip');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create(origin: origin);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      });
      Future<String> read(String path) async {
        final request = await client.getUrl(
          proxy.register(origin.resolve(path)),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        expect(response.headers.value('content-encoding'), isNull);
        return response.transform(utf8.decoder).join();
      }

      expect(await read('/video.mp4'), 'decoded-media');
      final manifest = await read('/stream.m3u8');
      expect(manifest, startsWith('#EXTM3U'));
      expect(manifest, contains('/segment.ts'));
      expect(manifest, isNot(contains('${origin.port}')));
    },
  );
  test('external direct and transcode URLs never gain an Emby token', () {
    final external = embyResourceUri(
      Uri.parse('https://emby.test'),
      'https://cdn.test/video?signature=cdn',
      'secret',
    );
    expect(external.queryParameters, {'signature': 'cdn'});
  });

  test(
    'redirects, HLS segments, keys and subtitles authorize each origin',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamUrl = Uri.parse('http://127.0.0.1:${upstream.port}');
      final foreignUrl = Uri.parse('http://127.0.0.1:${foreign.port}');
      final foreignRequests = <HttpRequest>[];
      final authenticated = <String>[];
      foreign.listen((request) async {
        foreignRequests.add(request);
        request.response.write('resource');
        await request.response.close();
      });
      upstream.listen((request) async {
        if (request.headers.value('x-emby-token') == 'secret') {
          authenticated.add(request.uri.path);
        }
        if (request.uri.path == '/redirect') {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            '$foreignUrl/file?api_key=secret',
          );
        } else if (request.uri.path == '/index.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="$foreignUrl/key?api_key=secret"\n#EXTINF:2,\nsegment.ts\n#EXTINF:2,\n$foreignUrl/segment.ts?api_key=secret\n#EXT-X-ENDLIST\n',
          );
        } else {
          request.response.write('resource');
        }
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create(
        origin: upstreamUrl,
        headers: {
          'X-Emby-Token': 'secret',
          'Authorization': 'Emby Token="secret"',
          'User-Agent': 'Custom UA',
        },
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
        await foreign.close(force: true);
      });
      Future<String> get(Uri uri) async => utf8.decode(
        await (await (await client.getUrl(
          uri,
        )).close()).fold<List<int>>([], (a, b) => a..addAll(b)),
      );
      expect(
        await get(proxy.register(upstreamUrl.resolve('/redirect'))),
        'resource',
      );
      final playlist = await get(
        proxy.register(upstreamUrl.resolve('/index.m3u8')),
      );
      expect(playlist, isNot(contains('secret')));
      final key = RegExp('URI="([^"]+)"').firstMatch(playlist)![1]!;
      await get(Uri.parse(key));
      for (final line
          in playlist.split('\n').where((s) => s.startsWith('http'))) {
        await get(Uri.parse(line));
      }
      await get(proxy.register(upstreamUrl.resolve('/subtitle.ass')));
      expect(
        authenticated,
        containsAll([
          '/redirect',
          '/index.m3u8',
          '/segment.ts',
          '/subtitle.ass',
        ]),
      );
      expect(foreignRequests, hasLength(3));
      for (final request in foreignRequests) {
        expect(request.headers.value('x-emby-token'), isNull);
        expect(request.headers.value('authorization'), isNull);
        expect(request.uri.query, isNot(contains('secret')));
        expect(request.headers.value('user-agent'), 'Custom UA');
      }
    },
  );
}

class _CacheFixture {
  _CacheFixture(this.server, this.cache);
  final HttpServer server;
  final SessionByteCache cache;
  late final PlaybackHttpProxy proxy;
  final client = HttpClient();
  Uri get origin => Uri.parse('http://127.0.0.1:${server.port}');
  Uri get url => proxy.register(origin.resolve('/video'));
  String body = 'abcdefghijklmnopqrstuvwxyz';
  String? etag = '"first"';
  String control = 'max-age=3600';
  String? vary;
  bool ignoreRange = false;
  bool ignoreConditionalRange = false;
  int? headStatus;
  int? redirectVersion;
  Duration delay = Duration.zero;
  int requests = 0;
  final ranges = <String?>[];
  final methods = <String>[];

  static Future<_CacheFixture> open({
    int memoryBytes = 1024 * 1024,
    bool disk = false,
    bool sessionBuffering = false,
    int readAheadBytes = 0,
  }) async {
    final root = disk
        ? await Directory.systemTemp.createTemp('rillight-proxy-test-')
        : null;
    final cache = await SessionByteCache.open(
      root: root,
      memoryLimitBytes: memoryBytes,
    );
    final fixture = _CacheFixture(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      cache,
    );
    fixture.server.listen(fixture._serve);
    fixture.proxy = await PlaybackHttpProxy.create(
      origin: fixture.origin,
      cache: cache,
      sessionBuffering: sessionBuffering,
      readAheadBytes: readAheadBytes,
    );
    addTearDown(() async {
      fixture.client.close(force: true);
      await fixture.proxy.close();
      await fixture.server.close(force: true);
      if (root != null) await root.delete(recursive: true);
    });
    return fixture;
  }

  Future<void> settle() async {
    // Network completion precedes final publication by a microtask; disk tests
    // wait for the bounded storage writer rather than assuming synchronous IO.
    for (var tries = 0; tries < 100; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (cache.diagnostics['pendingBytes'] == 0) return;
    }
    fail('Cache writer did not settle');
  }

  Future<(int, String)> read(String? range) async {
    final request = await client.getUrl(url);
    if (range != null) request.headers.set('range', range);
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  }

  Future<void> _serve(HttpRequest request) async {
    requests++;
    methods.add(request.method);
    ranges.add(request.headers.value('range'));
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    final output = request.response;
    if (request.uri.path == '/video' && redirectVersion != null) {
      output.statusCode = 307;
      output.headers.set('location', '/content?version=$redirectVersion');
      await output.close();
      return;
    }
    if (request.method == 'HEAD' && headStatus != null) {
      output.statusCode = headStatus!;
      await output.close();
      return;
    }
    output.headers.set('cache-control', control);
    if (etag != null) output.headers.set('etag', etag!);
    if (vary != null) output.headers.set('vary', vary!);
    if (etag != null && request.headers.value('if-none-match') == etag) {
      output.statusCode = 304;
      await output.close();
      return;
    }
    final range = RegExp(
      r'^bytes=(\d+)-(\d*)$',
    ).firstMatch(request.headers.value('range') ?? '');
    final ifRange = request.headers.value('if-range');
    var bytes = utf8.encode(body);
    if (!ignoreRange &&
        !(ignoreConditionalRange && ifRange != null) &&
        range != null &&
        (ifRange == null || ifRange == etag)) {
      final start = int.parse(range[1]!);
      final end = int.tryParse(range[2]!) ?? bytes.length - 1;
      output.statusCode = 206;
      output.headers.set('content-range', 'bytes $start-$end/${bytes.length}');
      bytes = bytes.sublist(start, end + 1);
    }
    output.contentLength = bytes.length;
    if (request.method != 'HEAD') output.add(bytes);
    try {
      await output.close();
    } catch (_) {}
  }
}
