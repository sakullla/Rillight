import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_http_proxy.dart';
import 'package:rillight/player/playback_recovery_coordinator.dart';
import 'package:rillight/player/playback_transport_session.dart';

Future<void> _read(HttpClient client, Uri url) async {
  try {
    final response = await (await client.getUrl(url)).close();
    await response.drain<void>();
  } on HttpException {
    // Cancellation may close before the response headers arrive.
  }
}

void main() {
  test(
    'healthy headers beyond five seconds retain the configured timeout',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        await Future<void>.delayed(const Duration(seconds: 6));
        request.response.write('healthy');
        await request.response.close();
      });
      final proxy = await PlaybackHttpProxy.create(
        mediaHeaderTimeout: const Duration(seconds: 10),
      );
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          proxy.register(Uri.parse('http://127.0.0.1:${server.port}/media')),
        )).close();
        expect(response.statusCode, HttpStatus.ok);
        expect(
          await response.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          ),
          'healthy'.codeUnits,
        );
        expect(requests, 1);
        expect(proxy.diagnostics['mediaHeaderTimeouts'], 0);
        expect(proxy.diagnostics['recoveryAttempts'], 0);
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );

  test('released isolate budget cannot expire healthy reads and next fault accepts a fresh budget', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stalled = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/stall') {
        if (!stalled.isCompleted) stalled.complete();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      request.response.write('healthy');
      await request.response.close();
    });
    final transport = await PlaybackTransportSession.start(readAheadBytes: 0);
    final client = HttpClient();
    final first = PlaybackRecoveryBudget(
      total: const Duration(milliseconds: 150),
    );
    try {
      transport.recoveryBudget = first;
      // Commands share a FIFO port; diagnostics acknowledges release before IO.
      transport.recoveryBudget = null;
      await transport.diagnostics;
      final healthy = await transport.register(
        Uri.parse('http://127.0.0.1:${server.port}/healthy'),
      );
      final response = await (await client.getUrl(healthy)).close();
      expect(response.statusCode, HttpStatus.ok);
      expect(
        await response.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
        'healthy'.codeUnits,
      );
      expect(first.isExpired, true);
      final next = PlaybackRecoveryBudget();
      transport.recoveryBudget = next;
      final route = await transport.register(
        Uri.parse('http://127.0.0.1:${server.port}/stall'),
      );
      final read = _read(client, route);
      await stalled.future.timeout(const Duration(seconds: 2));
      next.cancel();
      await read.timeout(const Duration(seconds: 1));
    } finally {
      client.close(force: true);
      await transport.close();
      await server.close(force: true);
    }
  });

  test(
    'proxy external deadline ends a stalled response and nested retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) {
        requests++;
      });
      final budget = PlaybackRecoveryBudget(
        total: const Duration(milliseconds: 150),
      );
      final proxy = await PlaybackHttpProxy.create(recoveryBudget: budget);
      final client = HttpClient();
      final watch = Stopwatch()..start();
      try {
        await _read(
          client,
          proxy.register(Uri.parse('http://127.0.0.1:${server.port}/media')),
        ).timeout(const Duration(seconds: 2));
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        expect(requests, 1);
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'proxy cancellation interrupts headers without awaiting their timeout',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      server.listen((request) {
        if (!started.isCompleted) started.complete();
      });
      final budget = PlaybackRecoveryBudget();
      final proxy = await PlaybackHttpProxy.create(recoveryBudget: budget);
      final client = HttpClient();
      try {
        final read = _read(
          client,
          proxy.register(Uri.parse('http://127.0.0.1:${server.port}/media')),
        );
        await started.future.timeout(const Duration(seconds: 2));
        budget.cancel();
        await read.timeout(const Duration(seconds: 1));
      } finally {
        client.close(force: true);
        await proxy.close();
        await server.close(force: true);
      }
    },
  );

  for (final status in [401, 403, 429]) {
    test(
      'proxy HTTP $status does not add retries beyond authorization or Retry-After',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        server.listen((request) async {
          requests++;
          request.response.statusCode = status;
          if (status == 429) request.response.headers.set('retry-after', '90');
          await request.response.close();
        });
        final proxy = await PlaybackHttpProxy.create(
          recoveryBudget: PlaybackRecoveryBudget(
            total: const Duration(milliseconds: 200),
          ),
        );
        final client = HttpClient();
        try {
          await _read(
            client,
            proxy.register(Uri.parse('http://127.0.0.1:${server.port}/media')),
          ).timeout(const Duration(seconds: 2));
          expect(requests, 1);
        } finally {
          client.close(force: true);
          await proxy.close();
          await server.close(force: true);
        }
      },
    );
  }

  test(
    'transport isolate forwards external cancellation to active proxy',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      server.listen((request) {
        if (!started.isCompleted) started.complete();
      });
      final transport = await PlaybackTransportSession.start(readAheadBytes: 0);
      final budget = PlaybackRecoveryBudget();
      transport.recoveryBudget = budget;
      final client = HttpClient();
      try {
        final route = await transport.register(
          Uri.parse('http://127.0.0.1:${server.port}/media'),
        );
        final read = _read(client, route);
        await started.future.timeout(const Duration(seconds: 2));
        budget.cancel();
        await read.timeout(const Duration(seconds: 1));
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    },
  );
}
