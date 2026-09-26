import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';

void main() {
  for (final role in [
    PlaybackResourceRole.media,
    PlaybackResourceRole.segment,
  ]) {
    test('zero-byte $role body resumes from a validated range', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await PlaybackHttpProxy.create();
      final client = HttpClient();
      final ranges = <String?>[];
      upstream.listen((request) async {
        request.response.headers.set('etag', '"stable"');
        if (request.method == 'HEAD') {
          request.response.contentLength = 12;
          await request.response.close();
          return;
        }
        ranges.add(request.headers.value('range'));
        if (ranges.length == 1) {
          request.response.contentLength = 12;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          await socket.flush();
          socket.destroy();
        } else {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('content-range', 'bytes 0-11/12');
          request.response.contentLength = 12;
          request.response.write('abcdefghijkl');
          await request.response.close();
        }
      });
      try {
        final url = proxy.register(
          Uri.parse('http://127.0.0.1:${upstream.port}/body.ts'),
          role: role,
        );
        final response = await (await client.getUrl(url)).close();
        expect(await response.transform(utf8.decoder).join(), 'abcdefghijkl');
        expect(ranges, [null, 'bytes=0-11']);
        expect(proxy.diagnostics['recoveryAttempts'], 1);
        expect(proxy.diagnostics['recoveries'], 1);
      } finally {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
      }
    });

    test('interrupted $role body resumes only the validated suffix', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await PlaybackHttpProxy.create();
      final client = HttpClient();
      final ranges = <String?>[];
      upstream.listen((request) async {
        request.response.headers.set('etag', '"stable"');
        if (request.method == 'HEAD') {
          request.response.contentLength = 12;
          await request.response.close();
          return;
        }
        ranges.add(request.headers.value('range'));
        if (ranges.length == 1) {
          request.response.contentLength = 12;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          socket.add(utf8.encode('abc'));
          await socket.flush();
          socket.destroy();
        } else {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('content-range', 'bytes 3-11/12');
          request.response.contentLength = 9;
          request.response.write('defghijkl');
          await request.response.close();
        }
      });
      try {
        final url = proxy.register(
          Uri.parse('http://127.0.0.1:${upstream.port}/body.ts'),
          role: role,
        );
        final response = await (await client.getUrl(url)).close();
        expect(await response.transform(utf8.decoder).join(), 'abcdefghijkl');
        expect(ranges, [null, 'bytes=3-11']);
        expect(proxy.diagnostics['recoveryAttempts'], 1);
        expect(proxy.diagnostics['recoveries'], 1);
      } finally {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
      }
    });
  }

  test('zero-byte body stall resumes after the body deadline', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    final stalled = <Socket>[];
    var requests = 0;
    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.headers.set('etag', '"stable"');
        request.response.contentLength = 12;
        await request.response.close();
        return;
      }
      requests++;
      request.response.headers.set('etag', '"stable"');
      request.response.contentLength = 12;
      if (requests == 1) {
        final socket = await request.response.detachSocket(writeHeaders: true);
        stalled.add(socket);
        await socket.flush();
      } else {
        expect(request.headers.value('range'), 'bytes=0-11');
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('content-range', 'bytes 0-11/12');
        request.response.write('abcdefghijkl');
        await request.response.close();
      }
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${upstream.port}/video'),
      );
      final watch = Stopwatch()..start();
      final response = await (await client.getUrl(url)).close();
      expect(await response.transform(utf8.decoder).join(), 'abcdefghijkl');
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 15)));
      expect(requests, 2);
      expect(proxy.diagnostics['recoveries'], 1);
    } finally {
      client.close(force: true);
      await proxy.close();
      for (final socket in stalled) {
        socket.destroy();
      }
      await upstream.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('zero-byte untagged body restarts before forwarding bytes', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    final ranges = <String?>[];
    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.contentLength = 12;
        await request.response.close();
        return;
      }
      ranges.add(request.headers.value('range'));
      if (ranges.length == 1) {
        request.response.contentLength = 12;
        final socket = await request.response.detachSocket(writeHeaders: true);
        await socket.flush();
        socket.destroy();
      } else {
        request.response.contentLength = 11;
        request.response.write('new-content');
        await request.response.close();
      }
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${upstream.port}/video'),
      );
      final response = await (await client.getUrl(url)).close();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.contentLength, 11);
      expect(await response.transform(utf8.decoder).join(), 'new-content');
      expect(ranges, [null, null]);
      expect(proxy.diagnostics['recoveryAttempts'], 1);
      expect(proxy.diagnostics['recoveries'], 1);
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
    }
  });

  test('seek cancels zero-byte recovery without another upstream read', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    final stalled = <Socket>[];
    var requests = 0;
    upstream.listen((request) async {
      requests++;
      request.response.headers.set('etag', '"stable"');
      request.response.contentLength = 12;
      final socket = await request.response.detachSocket(writeHeaders: true);
      stalled.add(socket);
      await socket.flush();
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${upstream.port}/video'),
      );
      final responseFuture = (await client.getUrl(url)).close();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (requests == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests, 1);
      proxy.cancelPendingReads(preserveSubtitles: true);
      try {
        final response = await responseFuture.timeout(
          const Duration(seconds: 2),
        );
        expect(response.statusCode, HttpStatus.badGateway);
        await response.drain<void>();
      } on Exception catch (error) {
        if (error is TimeoutException) rethrow;
        // A cancelled socket may close before the local 502 reaches the client.
      }
      expect(requests, 1);
      expect(proxy.diagnostics['recoveryAttempts'], 0);
    } finally {
      client.close(force: true);
      await proxy.close();
      for (final socket in stalled) {
        socket.destroy();
      }
      await upstream.close(force: true);
    }
  });

  test('zero-byte recovery rejects an ignored Range', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    var requests = 0;
    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.headers.set('etag', '"stable"');
        request.response.contentLength = 12;
        await request.response.close();
        return;
      }
      requests++;
      request.response.headers.set('etag', '"stable"');
      request.response.contentLength = 12;
      if (requests == 1) {
        final socket = await request.response.detachSocket(writeHeaders: true);
        await socket.flush();
        socket.destroy();
      } else {
        // The upstream ignored Range and sent a 200 replacement body.
        request.response.write('abcdefghijkl');
        await request.response.close();
      }
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${upstream.port}/video'),
      );
      final response = await (await client.getUrl(url)).close();
      expect(response.statusCode, HttpStatus.badGateway);
      await response.drain<void>();
      expect(requests, 2);
      expect(
        proxy.diagnostics['lastValidationFailure'],
        'foreground-resume-mismatch',
      );
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
    }
  });

  test('zero-byte recovery exhausts six transient attempts', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    var requests = 0;
    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.headers.set('etag', '"stable"');
        request.response.contentLength = 12;
        await request.response.close();
        return;
      }
      requests++;
      if (requests == 1) {
        request.response.headers.set('etag', '"stable"');
        request.response.contentLength = 12;
        final socket = await request.response.detachSocket(writeHeaders: true);
        await socket.flush();
        socket.destroy();
      } else {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      }
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${upstream.port}/video'),
      );
      final response = await (await client.getUrl(url)).close();
      expect(response.statusCode, HttpStatus.badGateway);
      await response.drain<void>();
      expect(requests, 7);
      expect(proxy.diagnostics['recoveryAttempts'], 6);
      expect(proxy.diagnostics['recoveryFailures'], 1);
      expect(
        proxy.diagnostics['lastValidationFailure'],
        'foreground-resume-exhausted',
      );
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 50)));

  test('interrupted body rejects a changed validator', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    var requests = 0;
    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.headers.set('etag', '"old"');
        request.response.contentLength = 12;
        await request.response.close();
        return;
      }
      requests++;
      request.response.headers.set('etag', requests == 1 ? '"old"' : '"new"');
      if (requests == 1) {
        request.response.contentLength = 12;
        final socket = await request.response.detachSocket(writeHeaders: true);
        socket.add(utf8.encode('abc'));
        await socket.flush();
        socket.destroy();
      } else {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('content-range', 'bytes 3-11/12');
        request.response.contentLength = 9;
        request.response.write('defghijkl');
        await request.response.close();
      }
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${upstream.port}/video'),
      );
      final response = await (await client.getUrl(url)).close();
      await expectLater(response.drain<void>(), throwsA(isA<Exception>()));
      expect(requests, 2);
      expect(
        proxy.diagnostics['lastValidationFailure'],
        'foreground-resume-mismatch',
      );
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
    }
  });

  test('interrupted body exhausts bounded transient recovery', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await PlaybackHttpProxy.create();
    final client = HttpClient();
    var requests = 0;
    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.headers.set('etag', '"stable"');
        request.response.contentLength = 12;
        await request.response.close();
        return;
      }
      requests++;
      if (requests == 1) {
        request.response.headers.set('etag', '"stable"');
        request.response.contentLength = 12;
        final socket = await request.response.detachSocket(writeHeaders: true);
        socket.add(utf8.encode('abc'));
        await socket.flush();
        socket.destroy();
      } else {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      }
    });
    try {
      final url = proxy.register(
        Uri.parse('http://127.0.0.1:${upstream.port}/video'),
      );
      final response = await (await client.getUrl(url)).close();
      await expectLater(response.drain<void>(), throwsA(isA<Exception>()));
      expect(requests, 7);
      expect(proxy.diagnostics['recoveryAttempts'], 6);
      expect(proxy.diagnostics['recoveryFailures'], 1);
      expect(
        proxy.diagnostics['lastValidationFailure'],
        'foreground-resume-exhausted',
      );
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 50)));

  test(
    'VOD HLS prefetches only the next selected segment into session cache',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cache = await SessionByteCache.open(memoryLimitBytes: 1024 * 1024);
      final proxy = await PlaybackHttpProxy.create(cache: cache);
      final client = HttpClient();
      final counts = <String, int>{};
      upstream.listen((request) async {
        final path = request.uri.path;
        counts[path] = (counts[path] ?? 0) + 1;
        if (path == '/index.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts\n#EXTINF:2,\nc.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          request.response.headers.set('etag', '"segments"');
          request.response.headers.set('cache-control', 'max-age=120');
          if (request.headers.value('range') != null) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set('content-range', 'bytes 0-3/4');
          }
          request.response.contentLength = 4;
          request.response.write('data');
        }
        await request.response.close();
      });
      final origin = Uri.parse('http://127.0.0.1:${upstream.port}');
      Future<String> get(Uri url) async => (await (await client.getUrl(
        url,
      )).close()).transform(utf8.decoder).join();
      try {
        final playlistResponse = await (await client.getUrl(
          proxy.register(origin.resolve('/index.m3u8')),
        )).close();
        final playlist = await playlistResponse.transform(utf8.decoder).join();
        expect(playlistResponse.contentLength, utf8.encode(playlist).length);
        final segments = playlist
            .split('\n')
            .where((line) => line.startsWith('http://127.0.0.1:'))
            .map(Uri.parse)
            .toList();
        expect(segments, hasLength(3));
        expect(await get(segments[0]), 'data');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (((counts['/b.ts'] ?? 0) == 0 ||
                proxy.diagnostics['segmentPrefetchActive'] == true ||
                proxy.diagnostics['activeRequests'] != 0) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(counts['/b.ts'], 1);
        expect(counts['/init.mp4'], 1);
        expect(counts['/c.ts'], isNull);
        final map = RegExp('URI="([^"]+)"').firstMatch(playlist)![1]!;
        expect(await get(Uri.parse(map)), 'data');
        expect(counts['/init.mp4'], 1);
        expect(await get(segments[1]), 'data');
        expect(counts['/b.ts'], 1);
      } finally {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
      }
    },
  );

  test('foreground segment cancels stalled HLS prefetch', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cache = await SessionByteCache.open(memoryLimitBytes: 1024 * 1024);
    final proxy = await PlaybackHttpProxy.create(cache: cache);
    final client = HttpClient();
    final stalled = <HttpResponse>[];
    var backgroundStarted = false;
    upstream.listen((request) async {
      if (request.uri.path == '/index.m3u8') {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts\n#EXTINF:2,\nc.ts\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
      } else if (request.uri.path == '/b.ts') {
        stalled.add(request.response);
        backgroundStarted = true;
        request.response.contentLength = 4;
        await request.response.flush();
      } else {
        request.response.contentLength = 4;
        request.response.write('data');
        await request.response.close();
      }
    });
    final origin = Uri.parse('http://127.0.0.1:${upstream.port}');
    Future<String> get(Uri url) async => (await (await client.getUrl(
      url,
    )).close()).transform(utf8.decoder).join();
    try {
      final playlist = await get(proxy.register(origin.resolve('/index.m3u8')));
      final segments = playlist
          .split('\n')
          .where((line) => line.startsWith('http://127.0.0.1:'))
          .map(Uri.parse)
          .toList();
      expect(segments, hasLength(3));
      expect(await get(segments[0]), 'data');
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!backgroundStarted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(backgroundStarted, isTrue);
      proxy.cancelPendingReads(preserveSubtitles: true);
      final watch = Stopwatch()..start();
      expect(
        await get(segments[2]).timeout(const Duration(seconds: 2)),
        'data',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      final settled = DateTime.now().add(const Duration(seconds: 2));
      while (proxy.diagnostics['activeRequests'] != 0 &&
          DateTime.now().isBefore(settled)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(proxy.diagnostics['activeRequests'], 0);
    } finally {
      client.close(force: true);
      await proxy.close();
      for (final response in stalled) {
        try {
          await response.close();
        } catch (_) {}
      }
      await upstream.close(force: true);
    }
  });

  test(
    'separate HLS audio and video retain both next-segment prefetches',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cache = await SessionByteCache.open(memoryLimitBytes: 1024 * 1024);
      final proxy = await PlaybackHttpProxy.create(cache: cache);
      final client = HttpClient();
      final counts = <String, int>{};
      final stalled = <HttpResponse>[];
      upstream.listen((request) async {
        final path = request.uri.path;
        counts[path] = (counts[path] ?? 0) + 1;
        if (path.endsWith('.m3u8')) {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          final prefix = path == '/audio.m3u8' ? 'a' : 'v';
          request.response.write(
            '#EXTM3U\n#EXTINF:2,\n${prefix}0.ts\n'
            '#EXTINF:2,\n${prefix}1.ts\n#EXT-X-ENDLIST\n',
          );
          await request.response.close();
        } else if (path == '/a1.ts' && counts[path] == 1) {
          stalled.add(request.response);
          request.response.headers.set('etag', '"audio"');
          request.response.contentLength = 4;
          await request.response.flush();
        } else {
          request.response.headers.set('etag', '"$path"');
          request.response.headers.set('cache-control', 'max-age=120');
          if (request.headers.value('range') != null) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set('content-range', 'bytes 0-3/4');
          }
          request.response.contentLength = 4;
          request.response.write('data');
          await request.response.close();
        }
      });
      final origin = Uri.parse('http://127.0.0.1:${upstream.port}');
      Future<String> get(Uri url) async => (await (await client.getUrl(
        url,
      )).close()).transform(utf8.decoder).join();
      Future<List<Uri>> segments(String path) async =>
          (await get(proxy.register(origin.resolve(path))))
              .split('\n')
              .where((line) => line.startsWith('http://127.0.0.1:'))
              .map(Uri.parse)
              .toList();
      try {
        final audio = await segments('/audio.m3u8');
        final video = await segments('/video.m3u8');
        expect(await get(audio.first), 'data');
        final started = DateTime.now().add(const Duration(seconds: 3));
        while ((counts['/a1.ts'] ?? 0) == 0 &&
            DateTime.now().isBefore(started)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(counts['/a1.ts'], 1);
        expect(await get(video.first), 'data');
        final settled = DateTime.now().add(const Duration(seconds: 8));
        while (((counts['/a1.ts'] ?? 0) < 2 ||
                (counts['/v1.ts'] ?? 0) == 0 ||
                proxy.diagnostics['segmentPrefetchActive'] == true ||
                proxy.diagnostics['segmentPrefetchPending'] != 0) &&
            DateTime.now().isBefore(settled)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(counts['/a1.ts'], greaterThanOrEqualTo(2));
        expect(counts['/v1.ts'], 1);
        expect(proxy.diagnostics['segmentPrefetchPending'], 0);
        expect(await get(video.last), 'data');
        expect(counts['/v1.ts'], 1);
      } finally {
        client.close(force: true);
        await proxy.close();
        for (final response in stalled) {
          try {
            await response.close();
          } catch (_) {}
        }
        await upstream.close(force: true);
      }
    },
  );

  test(
    'temporary upstream failure retries without counting cached bytes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (requests == 1) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          request.response.write('recovered');
        }
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create();
      try {
        final url = proxy.register(
          Uri.parse('http://127.0.0.1:${server.port}/video'),
        );
        final response = await (await client.getUrl(url)).close();
        expect(await response.transform(utf8.decoder).join(), 'recovered');
        expect(requests, 2);
        expect(proxy.upstreamBytes, 9);
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );

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
    'busy integrity snapshot withdraws timeline without degrading disk',
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
        const Duration(seconds: 10),
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

  test('same-length disk corruption withdraws a published timeline', () async {
    final fixture = await _CacheFixture.open(
      memoryBytes: 0,
      disk: true,
      sessionBuffering: true,
      readAheadBytes: 2 * 1024 * 1024,
    );
    fixture.body = 'x' * (2 * 1024 * 1024);
    await fixture.read('bytes=0-2097151');
    await fixture.settle();
    const duration = Duration(seconds: 30);
    // Integrity work is bounded per snapshot; the complete two-block range
    // becomes visible after the verifier has visited both blocks.
    for (var attempt = 0; attempt < 3; attempt++) {
      await fixture.proxy.refreshTimeline(duration);
      if ((fixture.proxy.diagnostics['cachedTimeRanges'] as List).isNotEmpty) {
        break;
      }
    }
    expect(fixture.proxy.diagnostics['cachedTimeRanges'], isNotEmpty);

    final blocks = fixture.root!
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.block'))
        .toList();
    expect(blocks, isNotEmpty);
    final block = blocks.first;
    final data = await block.readAsBytes();
    data[0] ^= 0xff;
    await block.writeAsBytes(data, flush: true);
    // The worker memoizes only unchanged file metadata. Explicitly advance the
    // mtime so this test is stable on filesystems with coarse timestamps.
    await block.setLastModified(DateTime.now().add(const Duration(seconds: 2)));
    await fixture.proxy.refreshTimeline(duration);
    expect(fixture.proxy.diagnostics['cachedTimeRanges'], isEmpty);
    expect(fixture.cache.diagnostics['pendingBytes'], 0);
  });

  test('retry invalidates published timeline identity and ranges', () async {
    final fixture = await _CacheFixture.open(
      disk: true,
      sessionBuffering: true,
      readAheadBytes: 2 * 1024 * 1024,
    );
    fixture.body = 'x' * (2 * 1024 * 1024);
    await fixture.read('bytes=0-2097151');
    await fixture.settle();
    await fixture.proxy.refreshTimeline(const Duration(seconds: 30));
    final before = fixture.proxy.diagnostics;
    expect(before['timelineIdentity'], isNotEmpty);
    expect(before['cachedTimeRanges'], isNotEmpty);

    await fixture.proxy.retryReadAhead();
    final after = fixture.proxy.diagnostics;
    expect(after['timelineIdentity'], '');
    expect(after['cachedTimeRanges'], isEmpty);
    expect(after['timelineUnknownReason'], 'indexUnavailable');
    expect(
      after['timelineSequence'],
      greaterThan(before['timelineSequence'] as int),
    );
  });

  test(
    'sealed private subtitle serves bounded ranges without remote access',
    () async {
      final temp = await Directory.systemTemp.createTemp('rillight-subtitles-');
      final file = File('${temp.path}${Platform.pathSeparator}1.srt');
      await file.writeAsString('1\n00:00:01,000 --> 00:00:02,000\nhello\n');
      final outside = File(
        '${temp.parent.path}${Platform.pathSeparator}other.srt',
      );
      await outside.writeAsString('outside');
      final proxy = await PlaybackHttpProxy.create();
      final client = HttpClient();
      try {
        expect(
          () =>
              proxy.register(outside.uri, role: PlaybackResourceRole.subtitle),
          throwsArgumentError,
        );
        expect(
          () => proxy.register(file.uri, role: PlaybackResourceRole.media),
          throwsArgumentError,
        );
        final sealed = proxy.register(
          file.uri,
          role: PlaybackResourceRole.subtitle,
        );
        expect(sealed.host, '127.0.0.1');
        expect(sealed.pathSegments.last, 'subtitle.srt');
        final first = await (await client.getUrl(sealed)).close();
        expect(first.statusCode, HttpStatus.ok);
        expect(await first.transform(utf8.decoder).join(), contains('hello'));
        final partialRequest = await client.getUrl(sealed);
        partialRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final partial = await partialRequest.close();
        expect(partial.statusCode, HttpStatus.partialContent);
        expect(await partial.transform(utf8.decoder).join(), '1');
        final head = await (await client.headUrl(sealed)).close();
        expect(head.statusCode, HttpStatus.ok);
        expect(head.contentLength, await file.length());
        await head.drain<void>();
      } finally {
        client.close(force: true);
        await proxy.close();
        await temp.delete(recursive: true);
        await outside.delete();
      }
    },
  );

  test(
    'upstream authentication status is observable without error parsing',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create();
      final client = HttpClient();
      try {
        final source = Uri.parse('http://127.0.0.1:${upstream.port}/media');
        final response = await (await client.getUrl(
          proxy.register(source),
        )).close();
        expect(response.statusCode, HttpStatus.unauthorized);
        await response.drain<void>();
        expect(
          proxy.diagnostics['lastUpstreamStatus'],
          HttpStatus.unauthorized,
        );
        expect(
          proxy.diagnostics['authenticationStatus'],
          HttpStatus.unauthorized,
        );
      } finally {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
      }
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
      final mediaBefore =
          fixture.proxy.diagnostics['mediaDownloadBytes'] as int;
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.proxy.upstreamBytes - before, 1);
      expect(fixture.proxy.diagnostics['mediaDownloadBytes'], mediaBefore);
      expect(fixture.proxy.diagnostics['controlDownloadBytes'], greaterThan(0));
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

  // 同配置(read-ahead + 磁盘 + 会话缓冲)的两个场景共用一次 socket/缓存
  // 生命周期:磁盘字节服务与不重下 seek、变更内容重校验、无盘旁路。
  test(
    'read-ahead serves disk bytes, revalidates changes and bypasses no disk',
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
      // 变更内容:不得把磁盘上的旧 'x' 当作命中返回。
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

  // 等价断言已由 'disconnect also cancels the cached-prefix gap producer'
  // 覆盖(客户端断开 → activeRequests 归零、上游不再拖完整部影片),
  // 纯媒体无前缀的取消路径是同一代码路径的重复变体,故删除
  // 'disconnected player stops its upstream body instead of draining it'。

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
  test(
    'same ETag gap immediately applies tightened control before its next hit',
    () async {
      // 'no-cache' 与 'max-age=0' 是等价的收紧控制变体,只保留 no-cache。
      final fixture = await _CacheFixture.open();
      await fixture.read('bytes=0-7');
      await fixture.settle();
      fixture.control = 'no-cache';
      expect((await fixture.read('bytes=4-11')).$2, 'efghijkl');
      final before = fixture.proxy.upstreamBytes;
      expect((await fixture.read('bytes=8-11')).$2, 'ijkl');
      expect(fixture.methods, ['GET', 'GET', 'HEAD']);
      expect(fixture.proxy.upstreamBytes, before);
    },
  );

  test(
    'complete 512KiB no-validator response reuses bounded disk and memory reads',
    () async {
      // 生产恒带 SessionByteCache,只保留磁盘路径;内存路径与路由封印注释
      // 同理(见 4096-entry HLS 用例说明),是等价存储变体。
      final fixture = await _CacheFixture.open(memoryBytes: 0, disk: true);
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

  // cache=false 与 cache=true 走同一份路由封印/淘汰代码,生产恒带
  // SessionByteCache,这里只保留带缓存的完整路径。
  test(
    '4096-entry >512KiB HLS keeps sealed first last and rewind routes',
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
      final cache = await SessionByteCache.open();
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

      final playlistRoute = proxy.register(origin.resolve('/index.m3u8'));
      final result = await get(playlistRoute);
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
      // 260 个微路由逐个串行往返是本用例的耗时主体;代理并发上限为 8,
      // 按 8 个一批并发后断言不变。
      final bulk = routes.skip(1).take(260).toList();
      for (var i = 0; i < bulk.length; i += 8) {
        final results = await Future.wait(bulk.skip(i).take(8).map(get));
        for (final result in results) {
          expect(result.$1, 200);
        }
      }
      expect((await get(routes.first)).$2, '/segment0.ts');
      expect(proxy.diagnostics['registeredResources'], lessThanOrEqualTo(256));
      final before = requests;
      final segments = routes.first.pathSegments.toList();
      final token = segments[1];
      segments[1] = '${token[0] == 'A' ? 'B' : 'A'}${token.substring(1)}';
      expect((await get(routes.first.replace(pathSegments: segments))).$1, 404);
      expect(requests, before);
      // 重新注册生成新 nonce;整份播放列表的再次拉取(200 + 新路由)由
      // 'HLS refresh isolates reused URLs by sequence' 等价覆盖,此处不再
      // 重复一次 512KiB 清单下载(本用例的次要耗时来源)。
      final same = proxy.register(origin.resolve('/index.m3u8'));
      expect(same, isNot(playlistRoute));
    },
  );

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

  // 同一共享 gap 代码路径的两个变体(一个消费者取消 / 两个并发)共用一次
  // socket 生命周期:先取消变体,再用新 gap 验证并发共享。
  test(
    'shared gap downloads survive one cancelled consumer and serve concurrency',
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

      fixture.delay = const Duration(milliseconds: 50);
      final responses = await Future.wait([
        fixture.read('bytes=16-23'),
        fixture.read('bytes=16-23'),
      ]);
      expect(responses.map((r) => r.$2), ['qrstuvwx', 'qrstuvwx']);
      expect(fixture.ranges.where((r) => r == 'bytes=16-23'), hasLength(1));
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

  // 删除 'disk hit works after memory eviction and does not count as upstream':
  // 等价断言(memoryBytes:4 + disk 下二读 diskHitBytes==8、upstreamBytes 不变)
  // 由 'opt-in no-store session buffer writes disk and validates reuse' 覆盖。

  // 原 'no-store and unsupported Vary never reuse bodies' 的 Vary 半边由
  // 'session buffering still rejects unknown Vary and unvalidated reuse'
  // 等价覆盖;no-store 半边不可并入会话缓冲锚点:非会话缓冲模式走
  // http_cache_policy 的 storable 假分支(绝不入缓存、二读全量重下),
  // 与 sessionBuffering 的 storable=true + lifetime=0 分支不同,
  // 保留为独立小用例。
  test(
    'plain no-store without session buffering never reuses bodies',
    () async {
      final fixture = await _CacheFixture.open();
      fixture.control = 'no-store';
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      await fixture.settle();
      expect((await fixture.read('bytes=0-7')).$2, 'abcdefgh');
      expect(fixture.requests, 2);
      expect(fixture.cache.diagnostics['indexEntries'], 0);
    },
  );

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
      expect(fixture.proxy.upstreamBytes, before);
      // 变更后的表示不得回吐旧字节:'rotating signed redirect' 与
      // 'HEAD failure validates a tiny range' 的收尾段已含等价断言
      // (etag/body 变更 → 新内容、GET/HEAD/GET 序列),此处只保留 304 路径。
      fixture.body = fixture.body.toUpperCase();
      fixture.etag = '"second"';
      expect((await fixture.read('bytes=0-7')).$2, 'ABCDEFGH');
      expect(fixture.methods, ['GET', 'HEAD', 'HEAD', 'GET']);
    },
  );

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

  // 删除 'weak response eviction falls back before emitting cached bytes':
  // 无验证器不复用的等价断言(requests==2、二次读取重新下载)由
  // 'no validator and no freshness keeps ordinary streaming functional' 覆盖。

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

  // 删除 'cached gap downloads are shared between concurrent consumers':
  // 并发共享 gap 的等价断言已并入上例第二段(同一 fixture、新 gap)。

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
      expect(foreignRequests.length, greaterThanOrEqualTo(3));
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
  _CacheFixture(this.server, this.cache, this.root);
  final HttpServer server;
  final SessionByteCache cache;
  final Directory? root;
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
      root,
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
