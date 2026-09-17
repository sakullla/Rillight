import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_resolver.dart';

void main() {
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
