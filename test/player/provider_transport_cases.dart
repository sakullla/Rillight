import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/resources.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_transport_session.dart';
import 'package:rillight/plex/plex_client.dart';

const _device = ClientDeviceInfo(
  clientName: 'transport-test',
  deviceName: 'synthetic',
  deviceId: 'transport-test-device',
  version: '1',
);
const _signedQuery = 'file=a%20b&part=one&flag&part=two&signature=x%2By%3D';
Uri _origin(HttpServer server) => Uri.parse('http://127.0.0.1:${server.port}');

Future<String> _get(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  return response.transform(utf8.decoder).join();
}

void main() {
  test(
    'authorization strips only foreign secrets and freezes public headers',
    () {
      final public = {'User-Agent': 'original-agent'};
      final auth = ResourceAuthorization(
        headersByOrigin: {
          'https://jellyfin.test': {
            'Authorization':
                'MediaBrowser DeviceId="device", Token="jf-secret"',
          },
          'https://plex.test': {
            'X-Plex-Token': 'plex-secret',
            'X-Plex-Version': 'one',
          },
          'https://bearer.test': {'Authorization': 'Bearer bearer-secret'},
        },
        publicHeaders: public,
      );
      public['User-Agent'] = 'mutated';
      final target = Uri.parse(
        'https://plex.test/file?$_signedQuery'
        '&a=jf-secret&b=bearer-secret&X-Plex-Token=plex-secret&nested=token%3Djf-secret',
      );
      expect(
        auth.sanitizeUri(target).query,
        '$_signedQuery&X-Plex-Token=plex-secret',
      );
      expect(auth.headersFor(target), {
        'User-Agent': 'original-agent',
        'X-Plex-Token': 'plex-secret',
        'X-Plex-Version': 'one',
      });
    },
  );

  test(
    'transport isolate applies authorization on every HLS and subtitle hop',
    () async {
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sourceUrl = _origin(source);
      final relayUrl = _origin(relay);
      final foreignUrl = _origin(foreign);
      final sourceRequests = <HttpRequest>[];
      final relayRequests = <HttpRequest>[];
      final foreignRequests = <HttpRequest>[];
      final client = HttpClient();
      final transport = await PlaybackTransportSession.start(
        // Explicit resource authorization must replace ordinary session headers.
        origin: sourceUrl,
        headers: {'Authorization': 'ordinary-session-must-not-be-used'},
        authorization: ResourceAuthorization(
          headersByOrigin: {
            sourceUrl.origin: {
              'Authorization':
                  'MediaBrowser DeviceId="playback-device", Token="jf-secret"',
            },
            relayUrl.origin: {'X-Plex-Token': 'relay-secret'},
          },
          publicHeaders: {'User-Agent': 'Synthetic player'},
        ),
        readAheadBytes: 0,
      );
      addTearDown(() async {
        client.close(force: true);
        await transport.close();
        await source.close(force: true);
        await relay.close(force: true);
        await foreign.close(force: true);
      });
      source.listen((request) async {
        sourceRequests.add(request);
        if (request.uri.path == '/master.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="$foreignUrl/key?$_signedQuery&token=jf-secret"\n'
            '#EXTINF:1,\n$relayUrl/segment?$_signedQuery&token=jf-secret\n'
            '#EXT-X-ENDLIST\n',
          );
        } else {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            '$relayUrl${request.uri.path}?$_signedQuery&token=jf-secret',
          );
        }
        await request.response.close();
      });
      relay.listen((request) async {
        relayRequests.add(request);
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          '$foreignUrl${request.uri.path}?$_signedQuery&token=relay-secret&old=jf-secret',
        );
        await request.response.close();
      });
      foreign.listen((request) async {
        foreignRequests.add(request);
        request.response.write('resource');
        await request.response.close();
      });
      final playlist = await _get(
        client,
        await transport.register(sourceUrl.resolve('/master.m3u8')),
      );
      expect(playlist, isNot(contains('jf-secret')));
      final key = RegExp('URI="([^"]+)"').firstMatch(playlist)![1]!;
      expect(await _get(client, Uri.parse(key)), 'resource');
      for (final line
          in playlist.split('\n').where((line) => line.startsWith('http'))) {
        expect(await _get(client, Uri.parse(line)), 'resource');
      }
      expect(
        await _get(
          client,
          await transport.register(
            sourceUrl.resolve('/subtitle.srt'),
            role: PlaybackResourceRole.subtitle,
          ),
        ),
        'resource',
      );
      for (final request in sourceRequests) {
        expect(
          request.headers.value('authorization'),
          contains('playback-device'),
        );
        expect(request.headers.value('x-plex-token'), isNull);
      }
      expect(relayRequests, hasLength(2));
      for (final request in relayRequests) {
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('x-plex-token'), 'relay-secret');
        expect(request.uri.query, _signedQuery);
      }
      expect(foreignRequests, hasLength(3));
      for (final request in foreignRequests) {
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('x-plex-token'), isNull);
        expect(request.headers.value('user-agent'), 'Synthetic player');
        expect(request.uri.query, _signedQuery);
      }
    },
  );

  for (final provider in ['emby', 'jellyfin', 'plex']) {
    test(
      '$provider rejects late image bytes after same-user session replacement',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final accepted = Completer<void>();
        final release = Completer<void>();
        final MediaServerClient adapter = switch (provider) {
          'emby' => EmbyClient(device: _device),
          'jellyfin' => JellyfinClient(device: _device),
          _ => PlexClient(device: _device),
        };
        void attach() => adapter.attachSession(
          baseUrl: _origin(server),
          accessToken: 'same-token',
          userId: 'same-user',
        );
        attach();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          adapter.clearSession();
          await server.close(force: true);
        });
        server.listen((request) async {
          request.response.bufferOutput = false;
          request.response.add([1]);
          await request.response.flush();
          accepted.complete();
          await release.future;
          try {
            request.response.add([2, 3]);
            await request.response.close();
          } on IOException {
            // The obsolete reader may close its socket first.
          }
        });
        final result = adapter.getItemImage('item', tag: '/image');
        final assertion = expectLater(
          result,
          throwsA(
            isA<MediaServerException>().having(
              (error) => error.kind,
              'kind',
              MediaServerFailureKind.cancelled,
            ),
          ),
        );
        await accepted.future.timeout(const Duration(seconds: 3));
        adapter.clearSession();
        attach();
        release.complete();
        await assertion;
      },
    );

    test(
      '$provider image redirect preserves signed bytes without session credentials',
      () async {
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final foreignRequests = <HttpRequest>[];
        final MediaServerClient adapter = switch (provider) {
          'emby' => EmbyClient(device: _device),
          'jellyfin' => JellyfinClient(device: _device),
          _ => PlexClient(device: _device),
        };
        adapter.attachSession(
          baseUrl: _origin(source),
          accessToken: 'provider-secret',
          userId: 'user',
        );
        addTearDown(() async {
          adapter.clearSession();
          await source.close(force: true);
          await foreign.close(force: true);
        });
        source.listen((request) async {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            '${_origin(foreign)}/image?$_signedQuery&api_key=provider-secret',
          );
          await request.response.close();
        });
        foreign.listen((request) async {
          foreignRequests.add(request);
          request.response.add([1, 2, 3]);
          await request.response.close();
        });
        expect(await adapter.getItemImage('item', tag: '/image'), [1, 2, 3]);
        expect(foreignRequests, hasLength(1));
        final request = foreignRequests.single;
        expect(request.uri.query, _signedQuery);
        for (final name in [
          'authorization',
          'x-emby-token',
          'x-emby-authorization',
          'x-plex-token',
        ]) {
          expect(
            request.headers.value(name),
            isNull,
            reason: '$provider $name',
          );
        }
      },
    );
  }

  test(
    'revoked transport cannot publish late bytes or reuse a sealed route',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        accepted.complete();
        await release.future;
        try {
          request.response.write('private late bytes');
          await request.response.close();
        } on IOException {
          // Revocation retires the pending connection.
        }
      });
      final first = await PlaybackTransportSession.start();
      final second = await PlaybackTransportSession.start();
      final client = HttpClient();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        client.close(force: true);
        await first.close();
        await second.close();
        await server.close(force: true);
      });
      final route = await first.register(_origin(server).resolve('/private'));
      final result = _get(client, route).catchError((Object _) => 'cancelled');
      await accepted.future.timeout(const Duration(seconds: 3));
      await first.close();
      release.complete();
      expect(await result, isNot(contains('private late bytes')));
      final secondRoute = await second.register(
        _origin(server).resolve('/private'),
      );
      final wrongSession = secondRoute.replace(path: route.path);
      final response = await (await client.getUrl(wrongSession)).close();
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    },
  );
}
