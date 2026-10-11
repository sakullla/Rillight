import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/resources.dart';
import 'package:rillight/player/cache/next_episode_prefix.dart';

Uri _origin(HttpServer server) => Uri.parse('http://127.0.0.1:${server.port}');
const _signed = 'path=a%20b&part=one&flag&part=two&signature=x%2By%3D';

void main() {
  for (final tokenHeader in ['X-Plex-Token', 'X-Emby-Token', 'Authorization']) {
    test('next prefix reauthorizes $tokenHeader on every redirect', () async {
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sourceUrl = _origin(source);
      final relayUrl = _origin(relay);
      final foreignUrl = _origin(foreign);
      final prefix = NextEpisodePrefix();
      final seen = <(String, HttpRequest)>[];
      final token = tokenHeader == 'Authorization'
          ? 'MediaBrowser DeviceId="playback", Token="source-secret"'
          : 'source-secret';
      addTearDown(() async {
        await prefix.discard();
        await source.close(force: true);
        await relay.close(force: true);
        await foreign.close(force: true);
      });
      source.listen((request) async {
        seen.add(('source', request));
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          request.uri.path == '/start'
              ? '/same?$_signed'
              : '$relayUrl/relay?$_signed&copied=source-secret',
        );
        await request.response.close();
      });
      relay.listen((request) async {
        seen.add(('relay', request));
        request.response.statusCode = 307;
        request.response.headers.set(
          'location',
          '$foreignUrl/final?$_signed&copied=relay-secret&old=source-secret',
        );
        await request.response.close();
      });
      foreign.listen((request) async {
        seen.add(('foreign', request));
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 0-3/4');
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      await prefix.start(
        itemId: 'next',
        url: sourceUrl.resolve('/start?$_signed'),
        headers: {'X-Emby-Token': 'ordinary-session-must-not-be-used'},
        authorization: ResourceAuthorization(
          headersByOrigin: {
            sourceUrl.origin: {tokenHeader: token},
            relayUrl.origin: {'X-Plex-Token': 'relay-secret'},
          },
          publicHeaders: {'User-Agent': 'prefix-test'},
        ),
        yieldToForeground: () => false,
      );
      expect(prefix.bytes, [1, 2, 3, 4]);
      expect(seen.map((entry) => entry.$1), [
        'source',
        'source',
        'relay',
        'foreign',
      ]);
      for (final (owner, request) in seen) {
        expect(request.uri.query, _signed);
        expect(request.headers.value('range'), 'bytes=0-4194303');
        expect(request.headers.value('user-agent'), 'prefix-test');
        for (final name in ['x-plex-token', 'x-emby-token', 'authorization']) {
          final expected =
              owner == 'source' && name == tokenHeader.toLowerCase()
              ? token
              : owner == 'relay' && name == 'x-plex-token'
              ? 'relay-secret'
              : null;
          expect(request.headers.value(name), expected, reason: '$owner $name');
        }
      }
    });
  }

  test('legacy initial headers cannot cross a prefix redirect', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpRequest? received;
    addTearDown(() async {
      await source.close(force: true);
      await foreign.close(force: true);
    });
    source.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set(
        'location',
        '${_origin(foreign)}/next?$_signed&token=secret',
      );
      await request.response.close();
    });
    foreign.listen((request) async {
      received = request;
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-3/4');
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final slice = await fetchNextPrefixSlice(
      url: _origin(source).resolve('/next'),
      headers: {'X-Plex-Token': 'secret'},
      start: 0,
      endInclusive: 3,
    );
    expect(slice!.bytes, [1, 2, 3, 4]);
    expect(received!.headers.value('x-plex-token'), isNull);
    expect(received!.uri.query, _signed);
  });

  for (final lateRedirect in [false, true]) {
    test(
      'discard aborts pending prefix and ignores late redirect=$lateRedirect',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final prefix = NextEpisodePrefix();
        final accepted = Completer<void>();
        final release = Completer<void>();
        var requests = 0;
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await prefix.discard();
          await server.close(force: true);
        });
        server.listen((request) async {
          requests++;
          if (!accepted.isCompleted) accepted.complete();
          await release.future;
          try {
            if (lateRedirect) {
              request.response.statusCode = 302;
              request.response.headers.set('location', '/late');
            } else {
              request.response.statusCode = 206;
              request.response.headers.set('content-range', 'bytes 0-3/4');
              request.response.add([1, 2, 3, 4]);
            }
            await request.response.close();
          } on IOException {
            // Prefix cancellation closes the upstream socket.
          }
        });
        final loading = prefix.start(
          itemId: 'private-next',
          url: _origin(server).resolve('/first'),
          yieldToForeground: () => false,
        );
        await accepted.future.timeout(const Duration(seconds: 3));
        await prefix.discard();
        await loading.timeout(const Duration(seconds: 2));
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(prefix.bytes, isNull);
        expect(prefix.itemId, isNull);
        expect(requests, 1);
      },
    );
  }

  test('invalid or ignored ranges never populate the next prefix', () async {
    for (final mode in ['ignored', 'wrong-offset', 'oversized']) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = mode == 'ignored' ? 200 : 206;
        request.response.headers.set(
          'content-range',
          mode == 'wrong-offset' ? 'bytes 1-3/4' : 'bytes 0-3/4',
        );
        request.response.add([1, 2, 3, 4, if (mode == 'oversized') 5]);
        await request.response.close();
      });
      try {
        final result = await fetchNextPrefixSlice(
          url: _origin(server).resolve('/next'),
          headers: const {},
          start: 0,
          endInclusive: 3,
        );
        expect(result!.rangeSupported, isFalse, reason: mode);
        expect(result.bytes, isEmpty);
      } finally {
        await server.close(force: true);
      }
    }
  });
}
