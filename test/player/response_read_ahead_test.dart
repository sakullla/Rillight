import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/http_cache_policy.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

const _mib = 1024 * 1024;

void main() {
  test(
    'cached seek continues downloading beyond the old window on the same socket',
    () async {
      final fixture = await _Direct.open(length: 65 * _mib + 37);
      try {
        final old = await fixture.read();
        expect(await old.moveNext(), isTrue);
        await fixture.waitFor(
          () =>
              (fixture.proxy.diagnostics['responseReadAheadPublishedBytes']
                  as int) >=
              8 * _mib,
        );
        final downloaded = fixture.proxy.upstreamBytes;
        fixture.proxy.cancelPendingReads();
        await old.cancel();
        final reader = await fixture.read(start: 2 * _mib);
        var position = 2 * _mib;
        while (position < 24 * _mib && await reader.moveNext()) {
          position = _verify(reader.current, position);
        }
        await fixture.waitFor(
          () => fixture.proxy.upstreamBytes > downloaded + _mib,
        );
        expect(fixture.requests, 1);
        while (await reader.moveNext()) {
          position = _verify(reader.current, position);
        }
        expect(position, fixture.length);
        expect(fixture.requests, 1);
        await reader.cancel();
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'seek reuses retained response bytes without an upstream request',
    () async {
      final fixture = await _Direct.open();
      try {
        final old = await fixture.read();
        expect(await old.moveNext(), isTrue);
        await fixture.waitFor(
          () =>
              (fixture.proxy.diagnostics['responseReadAheadPublishedBytes']
                  as int) >=
              8 * _mib,
        );
        fixture.proxy.cancelPendingReads();
        await old.cancel();
        await fixture.waitForCoverage();
        expect(fixture.proxy.diagnostics['cachedByteRanges'], isNotEmpty);
        final before = fixture.requests;
        final reader = await fixture.read(start: 2 * _mib, end: 3 * _mib - 1);
        var position = 2 * _mib;
        while (await reader.moveNext()) {
          position = _verify(reader.current, position);
        }
        expect(position, 3 * _mib);
        expect(fixture.requests, before);
        await reader.cancel();
        await fixture.proxy.close();
        expect(fixture.proxy.diagnostics['cachedByteRanges'], isEmpty);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'response coverage uses original offsets and retracts after eviction',
    () async {
      final fixture = await _Direct.open();
      try {
        const start = 7958;
        final reader = await fixture.read(start: start);
        expect(await reader.moveNext(), isTrue);
        await fixture.waitFor(
          () =>
              (fixture.proxy.diagnostics['responseReadAheadPublishedBytes']
                  as int) >=
              4 * _mib,
        );
        fixture.proxy.cancelPendingReads();
        await reader.cancel();
        await fixture.waitForCoverage();
        final diagnostics = fixture.proxy.diagnostics;
        expect(diagnostics['cachedByteTotal'], fixture.length);
        final ranges = diagnostics['cachedByteRanges'] as List;
        expect(ranges, isNotEmpty);
        expect((ranges.first as Map)['start'], start);
        final identity = diagnostics['cachedByteIdentity'] as String;
        await fixture.proxy.cache!.discardResource(identity);
        expect(fixture.proxy.diagnostics['cachedByteRanges'], isEmpty);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'completed untagged download remains available to later ranges',
    () async {
      final fixture = await _Direct.open(length: 4 * _mib + 37);
      try {
        final first = await fixture.read();
        while (await first.moveNext()) {}
        await first.cancel();
        final reader = await fixture.read(start: _mib);
        var position = _mib;
        while (await reader.moveNext()) {
          position = _verify(reader.current, position);
        }
        expect(position, fixture.length);
        expect(fixture.requests, 1);
        await reader.cancel();
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'untagged foreground 403 retires the old stream and retries serially',
    () async {
      final fixture = await _Direct.open(refuseSecond: true);
      try {
        final first = await fixture.read();
        expect(await first.moveNext(), isTrue);
        final next = await fixture.read(start: 12 * _mib);
        var position = 12 * _mib;
        while (await next.moveNext()) {
          position = _verify(next.current, position);
        }
        expect(position, fixture.length);
        expect(fixture.requests, 3);
        expect(fixture.proxy.diagnostics['serialUpstream'], isTrue);
        expect(fixture.proxy.diagnostics['authenticationStatus'], isNull);
        await first.cancel();
        await next.cancel();
      } finally {
        await fixture.close();
      }
    },
  );

  test('one untagged response crosses multiple download windows', () async {
    final fixture = await _Direct.open(length: 65 * _mib + 37);
    try {
      final reader = await fixture.read();
      var position = 0;
      while (await reader.moveNext()) {
        position = _verify(reader.current, position);
      }
      expect(position, fixture.length);
      expect(fixture.requests, 1);
      await reader.cancel();
    } finally {
      await fixture.close();
    }
  });

  test('closing a stalled untagged response releases its producer', () async {
    final fixture = await _Direct.open(holdAfter: 64 * 1024);
    try {
      final reader = await fixture.read();
      expect(await reader.moveNext(), isTrue);
      await fixture.proxy.close().timeout(const Duration(seconds: 2));
      await reader.cancel();
    } finally {
      await fixture.close();
    }
  });

  test('untagged response downloads ahead while decoder is paused', () async {
    final fixture = await _Direct.open();
    try {
      final reader = await fixture.read();
      expect(await reader.moveNext(), isTrue);
      var position = _verify(reader.current, 0);
      await fixture.waitFor(() => fixture.proxy.upstreamBytes >= 8 * _mib);
      expect(fixture.requests, 1);
      expect(fixture.proxy.diagnostics['responseReadAheadActive'], 1);
      while (await reader.moveNext()) {
        position = _verify(reader.current, position);
      }
      expect(position, fixture.length);
      expect(fixture.requests, 1);
      await reader.cancel();
    } finally {
      await fixture.close();
    }
  });

  test(
    'source renewal discards untagged buffered bytes and reads the new response',
    () async {
      final fixture = await _Direct.open();
      try {
        final old = await fixture.read();
        expect(await old.moveNext(), isTrue);
        await fixture.waitFor(() => fixture.proxy.upstreamBytes >= 8 * _mib);
        fixture.proxy.cancelPendingReads();
        await old.cancel();
        fixture.revision = 19;
        fixture.proxy.refreshSourceUrl(fixture.uri, fixture.origin);
        const offset = 12 * _mib;
        final reader = await fixture.read(start: offset);
        var position = offset;
        while (await reader.moveNext()) {
          position = _verify(reader.current, position, revision: 19);
        }
        expect(position, fixture.length);
        expect(fixture.requests, 2);
        await reader.cancel();
      } finally {
        await fixture.close();
      }
    },
  );

  test('pause and resume keep the original untagged response', () async {
    final fixture = await _Direct.open();
    try {
      final reader = await fixture.read();
      expect(await reader.moveNext(), isTrue);
      var position = _verify(reader.current, 0);
      fixture.proxy.setPlaybackActive(false);
      // Drain some foreground bytes while optional prefetch is disabled.
      while (position < 2 * _mib && await reader.moveNext()) {
        position = _verify(reader.current, position);
      }
      fixture.proxy.setPlaybackActive(true);
      while (await reader.moveNext()) {
        position = _verify(reader.current, position);
      }
      expect(position, fixture.length);
      expect(fixture.requests, 1);
      await reader.cancel();
    } finally {
      await fixture.close();
    }
  });
}

int _verify(List<int> bytes, int position, {int revision = 0}) {
  for (final byte in bytes) {
    if (byte != ((position + revision) % 251)) {
      fail('Wrong byte at $position');
    }
    position++;
  }
  return position;
}

class _Direct {
  _Direct(
    this.root,
    this.server,
    this.proxy,
    this.length,
    this.holdAfter,
    this.refuseSecond,
  );
  final Directory root;
  final HttpServer server;
  final PlaybackHttpProxy proxy;
  final client = HttpClient();
  final int length;
  final int? holdAfter;
  final bool refuseSecond;
  final stopping = Completer<void>();
  int requests = 0;
  int revision = 0;

  static Future<_Direct> open({
    int length = 20 * _mib,
    int? holdAfter,
    bool refuseSecond = false,
  }) async {
    final root = await Directory.systemTemp.createTemp('rillight-response-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cache = await SessionByteCache.open(
      root: root,
      memoryLimitBytes: 2 * _mib,
      diskLimitBytes: 64 * _mib,
    );
    final proxy = await PlaybackHttpProxy.create(
      cache: cache,
      sessionBuffering: true,
      readAheadBytes: 8 * _mib,
    );
    final fixture = _Direct(
      root,
      server,
      proxy,
      length,
      holdAfter,
      refuseSecond,
    );
    server.listen(fixture.serve);
    return fixture;
  }

  Future<void> serve(HttpRequest request) async {
    requests++;
    final sourceRevision = revision;
    try {
      if (refuseSecond && requests == 2) {
        request.response.statusCode = 403;
        request.response.write('origin busy');
        await request.response.close();
        return;
      }
      final range = MediaByteRange.resolve(
        request.headers.value('range'),
        length,
      )!;
      request.response.statusCode = 206;
      request.response.headers.set(
        'content-range',
        'bytes ${range.start}-${range.end}/$length',
      );
      request.response.contentLength = range.length;
      for (var position = range.start; position <= range.end;) {
        final count = min(64 * 1024, range.end - position + 1);
        request.response.add(
          List.generate(count, (i) => (position + i + sourceRevision) % 251),
        );
        position += count;
        await Future.any([request.response.flush(), stopping.future]);
        if (stopping.isCompleted) return;
        if (holdAfter != null && position >= holdAfter!) {
          await stopping.future;
          return;
        }
      }
      await Future.any([request.response.close(), stopping.future]);
    } catch (_) {
      // Seek and teardown close the active response.
    }
  }

  Uri get origin => Uri.parse('http://127.0.0.1:${server.port}/video.mkv');
  Uri get uri => proxy.register(origin);

  Future<StreamIterator<List<int>>> read({int start = 0, int? end}) async {
    final request = await client.getUrl(uri);
    request.headers.set('range', 'bytes=$start-${end ?? ''}');
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(response.statusCode, 206);
    return StreamIterator(response.timeout(const Duration(seconds: 10)));
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: '${proxy.diagnostics}');
  }

  Future<void> waitForCoverage() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    do {
      // Integrity snapshots deliberately yield to pending foreground disk I/O.
      // Poll as the backend does instead of requiring its first attempt to win.
      await proxy.refreshTimeline(const Duration(minutes: 20));
      if ((proxy.diagnostics['cachedByteRanges'] as List).isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    } while (DateTime.now().isBefore(deadline));
    fail('No verified response coverage: ${proxy.diagnostics}');
  }

  Future<void> close() async {
    client.close(force: true);
    stopping.complete();
    await proxy.close().timeout(const Duration(seconds: 5));
    await server.close(force: true);
    await root.delete(recursive: true);
  }
}
