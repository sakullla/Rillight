import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';

class _ImageTransport implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final entered = Completer<void>();
  Completer<void>? responseGate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!entered.isCompleted) entered.complete();
    await responseGate?.future;
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

EmbyClient _client(_ImageTransport transport) =>
    EmbyClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'synthetic',
        deviceId: 'guard-test',
        version: '1',
      ),
      dio: Dio()..httpClientAdapter = transport,
    )..attachSession(
      baseUrl: Uri.parse('https://emby.test'),
      accessToken: 'synthetic-token',
      userId: 'synthetic-user',
    );

void main() {
  test(
    'revocation after the request interceptor prevents transport dispatch',
    () async {
      final transport = _ImageTransport();
      final client = _client(transport);
      var allowed = true;
      final guarded = client.withRequestGuard(() {
        if (!allowed) throw StateError('Source permission revoked');
        // Dio yields between onRequest and HttpClientAdapter.fetch, including
        // its asynchronous request transformation. Revoke in that exact gap.
        scheduleMicrotask(() => allowed = false);
      });
      await expectLater(
        guarded.getChapterImage('movie', index: 1, tag: 'chapter'),
        throwsA(isA<MediaServerException>()),
      );
      expect(allowed, isFalse);
      expect(transport.requests, isEmpty);
      // The shared parent transport is still usable by an authorized consumer.
      expect(await client.getChapterImage('movie', index: 2), [1, 2, 3]);
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'revocation after dispatch rejects the response and blocks fallback',
    () async {
      final transport = _ImageTransport()..responseGate = Completer<void>();
      var allowed = true;
      final guarded = _client(transport).withRequestGuard(() {
        if (!allowed) throw StateError('Source permission revoked');
      });
      final rejected = expectLater(
        guarded.getChapterImage('movie', index: 1, tag: 'chapter'),
        throwsA(isA<MediaServerException>()),
      );
      await transport.entered.future;
      allowed = false;
      transport.responseGate!.complete();
      await rejected;
      expect(transport.requests, hasLength(1));
    },
  );
}
