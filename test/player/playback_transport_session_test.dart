import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_transport_session.dart';

void main() {
  test(
    'truncated unvalidated media fails its read without killing the worker',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/healthy') {
          request.response.write('healthy');
          await request.response.close();
          return;
        }
        // Without a validator a broken body must fail, rather than resume with
        // bytes from an unknown representation. That failure belongs to this
        // response; subsequent seek/subtitle/control commands must still work.
        request.response.contentLength = 4 * 1024 * 1024;
        final socket = await request.response.detachSocket(writeHeaders: true);
        socket.add(List<int>.filled(128 * 1024, 7));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        socket.destroy();
      });
      final session = await PlaybackTransportSession.start(diskLimitBytes: 0);
      final client = HttpClient();
      try {
        final route = await session.register(
          Uri.parse('http://127.0.0.1:${server.port}/broken'),
        );
        Object? failure;
        try {
          final response = await (await client.getUrl(route)).close();
          await response.drain<void>().timeout(const Duration(seconds: 3));
        } on HttpException catch (error) {
          failure = error;
        }
        expect(failure, isNotNull);
        await session.setPlaybackActive(false);
        await session.seek();
        expect(session.localDiagnostics['transportWorkerExited'], isFalse);
        expect(session.localDiagnostics['transportWorkerFailureKind'], isNull);
        final healthy = await session.register(
          Uri.parse('http://127.0.0.1:${server.port}/healthy'),
        );
        final response = await (await client.getUrl(healthy)).close();
        expect(await response.transform(utf8.decoder).join(), 'healthy');
      } finally {
        client.close(force: true);
        await session.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'cancelled 200 probe recovery keeps the isolate alive for a tail seek',
    () async {
      const total = 4 * 1024 * 1024;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.set('etag', '"movie"');
        final range = request.headers.value('range');
        if (range == null) {
          request.response.contentLength = total;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          socket.add(List<int>.filled(32 * 1024, 7));
          await socket.flush();
          socket.destroy();
        } else {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'content-range',
            'bytes ${total - 16}-${total - 1}/$total',
          );
          request.response.contentLength = 16;
          request.response.add(List<int>.filled(16, 9));
          await request.response.close();
        }
      });
      final session = await PlaybackTransportSession.start(diskLimitBytes: 0);
      final probe = HttpClient();
      final seekClient = HttpClient();
      try {
        final route = await session.register(
          Uri.parse('http://127.0.0.1:${server.port}/movie.mp4'),
        );
        final response = await (await probe.getUrl(route)).close();
        final prefix = Completer<void>();
        response.listen((bytes) {
          if (!prefix.isCompleted) prefix.complete();
        }, onError: (Object _) {});
        await prefix.future;
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while ((await session.diagnostics)['recoveryAttempts'] == 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect((await session.diagnostics)['recoveryAttempts'], greaterThan(0));
        probe.close(force: true);
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(session.localDiagnostics['transportWorkerFailureKind'], isNull);
        expect((await session.diagnostics)['activeRequests'], 0);
        final tail = await seekClient.getUrl(route);
        tail.headers.set('range', 'bytes=${total - 16}-${total - 1}');
        final data = await (await tail.close()).fold<List<int>>(
          [],
          (all, bytes) => all..addAll(bytes),
        );
        expect(data, List<int>.filled(16, 9));
      } finally {
        probe.close(force: true);
        seekClient.close(force: true);
        await session.close();
        await server.close(force: true);
      }
    },
  );

  test('worker failure keeps code locations and drops URL credentials', () {
    final failure = TransportWorkerFailure.fromMessage([
      'Bad state: https://private.example/media?token=secret',
      '#0 _serve (package:rillight/player/playback_http_proxy.dart:12:7)\n'
          '#1 callback (dart:async/future_impl.dart:100:8)\n'
          '#2 https://private.example/media?token=secret',
    ]);
    expect(failure.kind, 'StateError');
    expect(failure.frames, [
      'package:rillight/player/playback_http_proxy.dart:12:7',
      'dart:async/future_impl.dart:100:8',
    ]);
    expect(jsonEncode(failure.frames), isNot(contains('secret')));
    expect(jsonEncode(failure.frames), isNot(contains('private.example')));
  });

  test(
    'closing while headers stall cancels the old session promptly',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final entered = Completer<void>();
      server.listen((request) {
        entered.complete();
        // Keep response headers pending until the session cancels this socket.
      });
      final session = await PlaybackTransportSession.start(diskLimitBytes: 0);
      try {
        final route = await session.register(
          Uri.parse('http://127.0.0.1:${server.port}/stalled'),
        );
        final response = (await client.getUrl(route)).close();
        final settled = response.then<void>(
          (value) => value.drain<void>(),
          onError: (Object _) {},
        );
        await entered.future;
        expect(
          (await session.diagnostics)['upstreamAwaitingHeadersRequests'],
          1,
        );
        await session.close().timeout(const Duration(seconds: 3));
        await settled.timeout(const Duration(seconds: 3));
        await expectLater(session.diagnostics, throwsStateError);
      } finally {
        client.close(force: true);
        await session.close();
        await server.close(force: true);
      }
    },
  );

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
