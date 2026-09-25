import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_transport_session.dart';

void main() {
  test(
    'isolated transport serves sealed media and keeps credentials upstream',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final received = <String?>[];
      server.listen((request) async {
        received.add(request.headers.value('x-emby-token'));
        request.response.headers.set('etag', '"one"');
        request.response.headers.set('cache-control', 'max-age=120');
        request.response.write('media');
        await request.response.close();
      });
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final session = await PlaybackTransportSession.start(
        origin: origin,
        headers: {'X-Emby-Token': 'private-token'},
        diskLimitBytes: 0,
      );
      try {
        final media = await session.register(origin.resolve('/video'));
        expect(media.toString(), isNot(contains('private-token')));
        final response = await (await client.getUrl(media)).close();
        expect(await response.transform(utf8.decoder).join(), 'media');
        expect(received, ['private-token']);
        expect((await session.diagnostics)['upstreamBytes'], 5);
        await session.seek();
        await session.resizeCache(
          memoryBytes: 1024 * 1024,
          pendingBytes: 1024 * 1024,
          diskBytes: 0,
        );
        final subtitle = await session.register(
          origin.resolve('/caption'),
          role: PlaybackResourceRole.subtitle,
        );
        expect(subtitle.host, '127.0.0.1');
      } finally {
        client.close(force: true);
        await session.close();
        await server.close(force: true);
      }
      await expectLater(
        session.register(origin.resolve('/late')),
        throwsStateError,
      );
    },
  );

  test('authentication failure does not retry or reuse an old route', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    final first = await PlaybackTransportSession.start(diskLimitBytes: 0);
    final oldRoute = await first.register(origin.resolve('/video'));
    try {
      final response = await (await client.getUrl(oldRoute)).close();
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();
      expect(requests, 1);
      expect((await first.diagnostics)['recoveryAttempts'], 0);
    } finally {
      await first.close();
    }
    final second = await PlaybackTransportSession.start(diskLimitBytes: 0);
    try {
      final current = await second.register(origin.resolve('/video'));
      expect(current.path, isNot(oldRoute.path));
      if (current.port == oldRoute.port) {
        final stale = await (await client.getUrl(oldRoute)).close();
        expect(stale.statusCode, HttpStatus.notFound);
        await stale.drain<void>();
      }
    } finally {
      client.close(force: true);
      await second.close();
      await server.close(force: true);
    }
  });
}
