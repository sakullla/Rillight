import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';

void main() {
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
  Duration delay = Duration.zero;
  int requests = 0;
  final ranges = <String?>[];
  final methods = <String>[];

  static Future<_CacheFixture> open({
    int memoryBytes = 1024 * 1024,
    bool disk = false,
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
    if (!ignoreRange && range != null && (ifRange == null || ifRange == etag)) {
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
