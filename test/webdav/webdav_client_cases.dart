import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/webdav/webdav_client.dart';

typedef _Responder = Future<ResponseBody> Function(RequestOptions options);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.responder);

  final _Responder responder;
  final requests = <RequestOptions>[];
  final bodies = <String, List<int>>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
      bodies['${options.method}:${options.uri.path}'] = body;
    }
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

const _basicUserPass = 'Basic dXNlcjpwYXNz';

ResponseBody _bytes(int status, [List<int> data = const []]) =>
    ResponseBody.fromBytes(data, status);

Dio _dio(_Adapter adapter) => Dio()..httpClientAdapter = adapter;

WebDavClient _client(_Adapter adapter) => WebDavClient(
  address: 'http://192.0.2.10:5005/dav',
  username: 'user',
  password: 'pass',
  directory: 'rillight',
  dio: _dio(adapter),
);

void main() {
  group('testConnection', () {
    test('PROPFIND 207 succeeds with Depth 0 and Basic auth', () async {
      final adapter = _Adapter((options) async => _bytes(207));
      final client = _client(adapter);
      expect(await client.testConnection(), isA<WebDavConnectionSuccess>());
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.method, 'PROPFIND');
      expect(request.headers['Depth'], '0');
      expect(request.headers['Authorization'], _basicUserPass);
      expect(request.uri.toString(), 'http://192.0.2.10:5005/dav/rillight');
    });

    test('PROPFIND 200 succeeds', () async {
      final client = _client(_Adapter((options) async => _bytes(200)));
      expect(await client.testConnection(), isA<WebDavConnectionSuccess>());
    });

    test('401 maps to credential error', () async {
      final client = _client(_Adapter((options) async => _bytes(401)));
      final result = await client.testConnection();
      expect(result, isA<WebDavConnectionCredentialError>());
      expect((result as WebDavConnectionCredentialError).statusCode, 401);
    });

    test('403 maps to credential error', () async {
      final client = _client(_Adapter((options) async => _bytes(403)));
      expect(
        await client.testConnection(),
        isA<WebDavConnectionCredentialError>(),
      );
    });

    test('404 maps to directory missing', () async {
      final client = _client(_Adapter((options) async => _bytes(404)));
      expect(
        await client.testConnection(),
        isA<WebDavConnectionDirectoryMissing>(),
      );
    });

    test('transport failure maps to unreachable', () async {
      final client = _client(
        _Adapter((options) async => throw const SocketException('synthetic')),
      );
      expect(await client.testConnection(), isA<WebDavConnectionUnreachable>());
    });

    test('non-http address maps to unreachable without any request', () async {
      final adapter = _Adapter((options) async => _bytes(207));
      final client = WebDavClient(
        address: 'ftp://192.0.2.10/dav',
        username: 'user',
        password: 'pass',
        directory: 'rillight',
        dio: _dio(adapter),
      );
      expect(await client.testConnection(), isA<WebDavConnectionUnreachable>());
      expect(adapter.requests, isEmpty);
    });

    test('client installs 15 second timeouts', () {
      final client = _client(_Adapter((options) async => _bytes(207)));
      expect(client.dio.options.connectTimeout, kWebDavTimeout);
      expect(client.dio.options.sendTimeout, kWebDavTimeout);
      expect(client.dio.options.receiveTimeout, kWebDavTimeout);
    });
  });

  group('upload', () {
    test('MKCOL 201 then PUT overwrites the backup file', () async {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final adapter = _Adapter((options) async {
        if (options.method == 'MKCOL') return _bytes(201);
        return _bytes(200);
      });
      final client = _client(adapter);
      expect(await client.upload(payload), isA<WebDavUploadSuccess>());
      expect(
        adapter.requests.map((r) => '${r.method} ${r.uri.path}').toList(),
        ['MKCOL /dav/rillight', 'PUT /dav/rillight/rillight-backup.json'],
      );
      final put = adapter.bodies['PUT:/dav/rillight/rillight-backup.json']!;
      expect(put, payload);
      expect(adapter.requests[1].headers['Authorization'], _basicUserPass);
    });

    test('MKCOL 405 counts as existing and still uploads', () async {
      final adapter = _Adapter((options) async {
        if (options.method == 'MKCOL') return _bytes(405);
        return _bytes(204);
      });
      final client = _client(adapter);
      expect(
        await client.upload(Uint8List.fromList([9])),
        isA<WebDavUploadSuccess>(),
      );
      expect(adapter.requests, hasLength(2));
    });

    test('MKCOL failure aborts before PUT', () async {
      final adapter = _Adapter((options) async => _bytes(500));
      final client = _client(adapter);
      final result = await client.upload(Uint8List.fromList([9]));
      expect(result, isA<WebDavUploadFailure>());
      expect((result as WebDavUploadFailure).kind, WebDavFailureKind.httpError);
      expect(result.statusCode, 500);
      expect(adapter.requests.map((r) => r.method), ['MKCOL']);
    });

    test('PUT failure fails the upload', () async {
      final adapter = _Adapter((options) async {
        if (options.method == 'MKCOL') return _bytes(201);
        return _bytes(500);
      });
      final client = _client(adapter);
      final result = await client.upload(Uint8List.fromList([9]));
      expect(result, isA<WebDavUploadFailure>());
      expect((result as WebDavUploadFailure).statusCode, 500);
    });
  });

  group('download', () {
    test('GET 200 returns the backup bytes', () async {
      final payload = [5, 6, 7, 8];
      final client = _client(_Adapter((options) async => _bytes(200, payload)));
      final result = await client.download();
      expect(result, isA<WebDavDownloadSuccess>());
      expect((result as WebDavDownloadSuccess).bytes, payload);
    });

    test('GET 404 maps to no backup', () async {
      final client = _client(_Adapter((options) async => _bytes(404)));
      expect(await client.download(), isA<WebDavDownloadNoBackup>());
    });

    test('GET 500 maps to download failure', () async {
      final client = _client(_Adapter((options) async => _bytes(500)));
      final result = await client.download();
      expect(result, isA<WebDavDownloadFailure>());
      expect(
        (result as WebDavDownloadFailure).kind,
        WebDavFailureKind.httpError,
      );
    });

    test('transport failure maps to download failure as unreachable', () async {
      final client = _client(
        _Adapter((options) async => throw const SocketException('synthetic')),
      );
      final result = await client.download();
      expect(result, isA<WebDavDownloadFailure>());
      expect(
        (result as WebDavDownloadFailure).kind,
        WebDavFailureKind.unreachable,
      );
    });
  });
}
