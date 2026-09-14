import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';

import 'fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-test',
  version: '0.1.0',
);

Matcher _kind(EmbyFailureKind kind) =>
    isA<EmbyException>().having((error) => error.kind, 'kind', kind);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
  });

  EmbyClient client({Duration timeout = const Duration(seconds: 5)}) {
    return EmbyClient(
      device: _device,
      dio: dioForFakeEmby(adapter, timeout: timeout),
    );
  }

  test('Public Info returns server id and name', () async {
    final info = await client().getPublicInfo(server.baseUrl);
    expect(info.id, 'server-id-1');
    expect(info.serverName, '灯川测试');
    expect(server.requests, contains('GET /System/Info/Public'));
  });

  test('non-Emby Public Info stays as notEmby', () async {
    server.publicInfoHtml = true;
    expect(
      () => client().getPublicInfo(server.baseUrl),
      throwsA(_kind(EmbyFailureKind.notEmby)),
    );
  });

  test('connection errors map to unreachable', () {
    final mapped = EmbyException.fromDio(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
        error: const SocketException('Connection refused'),
      ),
    );
    expect(mapped.kind, EmbyFailureKind.unreachable);
  });

  test('unknown host stays unreachable', () async {
    expect(
      () => client().getPublicInfo(Uri.parse('http://missing.invalid:8096')),
      throwsA(_kind(EmbyFailureKind.unreachable)),
    );
  });

  test('hung Public Info maps to timeout', () async {
    server.hangPublicInfo = true;
    expect(
      () => client(
        timeout: const Duration(milliseconds: 80),
      ).getPublicInfo(server.baseUrl),
      throwsA(_kind(EmbyFailureKind.timeout)),
    );
  });

  test('maps certificate failures from Dio', () {
    final mapped = EmbyException.fromDio(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
        error: const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      ),
    );
    expect(mapped.kind, EmbyFailureKind.certificate);
  });

  test('AuthenticateByName returns token for correct password', () async {
    final emby = client();
    final info = await emby.getPublicInfo(server.baseUrl);
    final auth = await emby.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: info.id,
    );
    expect(auth.accessToken, isNotEmpty);
    expect(auth.user.id, 'user-alice');
    expect(auth.serverId, info.id);
  });

  test('forbidden Public Info keeps the server body', () async {
    server.publicInfoStatus = 403;
    server.publicInfoRawBody = '该客户端/设备已被服务端禁用';
    expect(
      () => client().getPublicInfo(server.baseUrl),
      throwsA(
        isA<EmbyException>()
            .having((error) => error.statusCode, 'statusCode', 403)
            .having(
              (error) => error.detail,
              'detail',
              'HTTP 403: 该客户端/设备已被服务端禁用',
            ),
      ),
    );
  });

  test('wrong password does not yield a session', () async {
    expect(
      () => client().authenticateByName(
        baseUrl: server.baseUrl,
        username: 'alice',
        password: 'wrong',
        serverId: server.serverId,
      ),
      throwsA(_kind(EmbyFailureKind.invalidCredentials)),
    );
  });

  test('401 on authenticated request reports session expired', () async {
    final emby = client();
    var expired = false;
    emby.onSessionExpired = () => expired = true;
    final auth = await emby.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    emby.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
    );
    server.issuedTokens.remove(auth.accessToken);

    expect(
      emby.getJson('/System/Info'),
      throwsA(_kind(EmbyFailureKind.sessionExpired)),
    );
    await pumpEventQueue();
    expect(expired, isTrue);
  });

  test('401 retries once after onRefreshSession issues a new token', () async {
    final emby = client();
    final first = await emby.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    emby.attachSession(
      baseUrl: server.baseUrl,
      accessToken: first.accessToken,
      userId: first.user.id,
    );
    server.issuedTokens.remove(first.accessToken);
    emby.onRefreshSession = () async {
      final next = await emby.authenticateByName(
        baseUrl: server.baseUrl,
        username: 'alice',
        password: 'correct-horse',
        serverId: server.serverId,
      );
      emby.attachSession(
        baseUrl: server.baseUrl,
        accessToken: next.accessToken,
        userId: next.user.id,
      );
      return true;
    };

    final info = await emby.getJson('/System/Info');
    expect(info['ServerName'], server.serverName);
    expect(emby.accessToken, isNot(first.accessToken));
  });

  test('customUserAgent returns the normalized custom value or null', () {
    final emby = client();
    expect(emby.customUserAgent, isNull);

    emby.setUserAgent('  LineUA/9  ');
    expect(emby.customUserAgent, 'LineUA/9');
    expect(emby.userAgent, 'LineUA/9');

    emby.setUserAgent('  ');
    expect(emby.customUserAgent, isNull);
    expect(emby.userAgent, 'Rillight/0.1.0');

    emby.setUserAgent('Keep/1');
    emby.attachSession(
      baseUrl: server.baseUrl,
      accessToken: 'tok',
      userId: 'u',
    );
    expect(emby.customUserAgent, isNull);
    expect(emby.userAgent, 'Rillight/0.1.0');
  });

  test('custom User-Agent is sent on API and stream headers', () async {
    final emby = client();
    emby.setUserAgent('LineUA/9');
    expect(emby.customUserAgent, 'LineUA/9');
    await emby.getPublicInfo(server.baseUrl);
    expect(server.lastUserAgent, 'LineUA/9');
    expect(server.lastAuthorization, contains('Client="Rillight"'));
    expect(server.lastAuthorization, isNot(contains('LineUA/9')));

    final auth = await emby.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    emby.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
      userAgent: 'LineUA/9',
    );
    expect(emby.sessionHeaders['User-Agent'], 'LineUA/9');
    expect(emby.sessionHeaders['Authorization'], contains('Client="Rillight"'));
    await emby.getJson('/System/Info');
    expect(server.lastUserAgent, 'LineUA/9');
  });

  test('blank User-Agent falls back to Rillight/version', () async {
    final emby = client();
    emby.setUserAgent('  ');
    expect(emby.customUserAgent, isNull);
    await emby.getPublicInfo(server.baseUrl);
    expect(server.lastUserAgent, 'Rillight/0.1.0');
    expect(emby.sessionHeaders['User-Agent'], 'Rillight/0.1.0');
  });

  test('logout revokes the current token', () async {
    final emby = client();
    final auth = await emby.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    emby.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
    );
    await emby.logout();
    expect(server.loggedOutTokens, contains(auth.accessToken));
    expect(server.requests, contains('POST /Sessions/Logout'));
  });

  test('queryItems sends Filters, Genres and Years when provided', () async {
    final emby = client();
    final auth = await emby.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    emby.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
    );

    await emby.queryItems(
      parentId: 'view-movies',
      recursive: true,
      limit: 60,
      filters: const ['IsPlayed'],
      genres: const ['SciFi', 'Action'],
      years: const [2025, 2024],
    );
    final request = server.requests.last;
    expect(request, contains('Filters=IsPlayed'));
    expect(request, contains('Genres=SciFi%2CAction'));
    expect(request, contains('Years=2025%2C2024'));

    // 不传筛选时不携带对应参数。
    await emby.queryItems(parentId: 'view-movies', recursive: true);
    expect(server.requests.last, isNot(contains('Filters=')));
    expect(server.requests.last, isNot(contains('Genres=')));
    expect(server.requests.last, isNot(contains('Years=')));

    // getItems 透传筛选参数。
    await emby.getItems(
      parentId: 'view-movies',
      recursive: true,
      filters: const ['IsUnplayed'],
      genres: const ['Drama'],
      years: const [1994],
    );
    expect(server.requests.last, contains('Filters=IsUnplayed'));
    expect(server.requests.last, contains('Genres=Drama'));
    expect(server.requests.last, contains('Years=1994'));
  });
}
