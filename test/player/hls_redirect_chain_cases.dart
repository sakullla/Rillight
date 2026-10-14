import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_transport_session.dart';

const _signature = 'name=a%20b&part=one&flag&part=two&sig=x%2By%3D';

void main() {
  for (final redirect in [301, 302, 303, 307, 308]) {
    test(
      'HLS $redirect resolves children from the final URL and preserves seek ranges',
      () async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originUrl = Uri.parse('http://127.0.0.1:${origin.port}');
        final cdnUrl = Uri.parse('http://127.0.0.1:${cdn.port}');
        final seen = <(String, String?, String?)>[];
        origin.listen((request) async {
          expect(request.headers.value('x-emby-token'), 'synthetic-secret');
          request.response.statusCode = redirect;
          request.response.headers.set(
            'location',
            '$cdnUrl/root/master?$_signature&api_key=synthetic-secret',
          );
          await request.response.close();
        });
        cdn.listen((request) async {
          seen.add((
            request.uri.path,
            request.headers.value('range'),
            request.headers.value('x-emby-token'),
          ));
          expect(request.headers.value('authorization'), isNull);
          expect(request.headers.value('user-agent'), 'Synthetic HLS');
          expect(request.uri.query, _signature);
          final response = request.response;
          switch (request.uri.path) {
            case '/root/master':
              response.headers.contentType = ContentType(
                'application',
                'vnd.apple.mpegurl',
              );
              response.write(
                '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nquality/variant?$_signature\n',
              );
            case '/root/quality/variant':
              response.headers.contentType = ContentType(
                'application',
                'vnd.apple.mpegurl',
              );
              response.write(
                '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
                '#EXT-X-MEDIA-SEQUENCE:0\n'
                '#EXT-X-KEY:METHOD=AES-128,URI="../key?$_signature"\n'
                '#EXT-X-MAP:URI="../init?$_signature"\n'
                '#EXTINF:4,\nchunk?$_signature\n#EXT-X-ENDLIST\n',
              );
            case '/root/quality/chunk':
              response.statusCode = redirect;
              response.headers.set('location', '../../cdn/chunk?$_signature');
            case '/cdn/chunk':
              final range = RegExp(r'^bytes=(\d+)-(\d+)$')
                  .firstMatch(request.headers.value('range') ?? '');
              final start = range == null ? 0 : int.parse(range[1]!);
              final end = range == null ? 15 : int.parse(range[2]!);
              response.statusCode = range == null ? 200 : 206;
              if (range != null) {
                response.headers.set('content-range', 'bytes $start-$end/16');
              }
              response.contentLength = end - start + 1;
              response.add(
                List.generate(end - start + 1, (index) => start + index),
              );
            case '/root/key':
            case '/root/init':
              response.contentLength = 16;
              response.add(List.filled(16, 7));
            default:
              response.statusCode = 404;
          }
          await response.close();
        });
        final transport = await PlaybackTransportSession.start(
          origin: originUrl,
          headers: {
            'X-Emby-Token': 'synthetic-secret',
            'User-Agent': 'Synthetic HLS',
          },
          readAheadBytes: 0,
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await transport.close();
          await origin.close(force: true);
          await cdn.close(force: true);
        });
        Future<List<int>> get(Uri url, {String? range}) async {
          final request = await client.getUrl(url);
          if (range != null) request.headers.set('range', range);
          final response = await request.close();
          expect(response.statusCode, range == null ? 200 : 206);
          return response.fold<List<int>>(
            [],
            (bytes, chunk) => bytes..addAll(chunk),
          );
        }

        Uri child(String playlist) => Uri.parse(
          playlist.split('\n').firstWhere((line) => line.startsWith('http')),
        );
        final master = utf8.decode(
          await get(await transport.register(originUrl.resolve('/download'))),
        );
        final playlist = utf8.decode(await get(child(master)));
        expect(playlist, isNot(contains('synthetic-secret')));
        for (final match in RegExp(r'URI="([^"]+)"').allMatches(playlist)) {
          expect(await get(Uri.parse(match[1]!)), List.filled(16, 7));
        }
        final segment = child(playlist);
        // Forward seek, rewind, then resume from a later byte offset.
        for (final start in [8, 0, 4]) {
          expect(
            await get(segment, range: 'bytes=$start-${start + 3}'),
            List.generate(4, (index) => start + index),
          );
        }
        expect(seen.where((r) => r.$1 == '/cdn/chunk').map((r) => r.$2), [
          'bytes=8-11',
          'bytes=0-3',
          'bytes=4-7',
        ]);
        expect(seen.every((r) => r.$3 == null), isTrue);
      },
    );
  }
}
