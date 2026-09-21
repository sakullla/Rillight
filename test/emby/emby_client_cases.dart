import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations_zh.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';

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
  EmbyException responseFailure(
    Object data, {
    String? contentType,
    int status = 403,
  }) {
    final request = RequestOptions(path: '/');
    return EmbyException.fromDio(
      DioException(
        requestOptions: request,
        type: DioExceptionType.badResponse,
        response: Response<Object>(
          requestOptions: request,
          statusCode: status,
          data: data,
          headers: Headers.fromMap({
            if (contentType != null) Headers.contentTypeHeader: [contentType],
          }),
        ),
      ),
      authenticating: true,
    );
  }

  test(
    'HTML response strings, bytes, JSON messages and MIME types are suppressed',
    () {
      for (final body in <Object>[
        '<!DOCTYPE HTML><HTML><body>Denied</body></HTML>',
        utf8.encode('<html>Denied</html>'),
        Uint8List.fromList(utf8.encode('<h1>Denied</h1>')),
        {'Message': '<div>Denied</div>'},
      ]) {
        final error = responseFailure(body);
        expect(error.statusCode, 403);
        expect(error.kind, EmbyFailureKind.unknown);
        expect(error.detail, 'HTTP 403');
      }
      for (final mime in [
        'text/html; charset=utf-8',
        'application/xhtml+xml',
      ]) {
        expect(
          responseFailure('unmarked page', contentType: mime).detail,
          'HTTP 403',
        );
      }
      final message = embyFailureMessage(
        AppLocalizationsZh(),
        responseFailure('<html>Denied</html>'),
      );
      expect(message, contains('HTTP 403'));
      expect(message, contains('检查地址或线路'));
      expect(message, isNot(contains('密码错误')));
    },
  );

  test('plain text stays bounded, without controls or broken Unicode', () {
    final error = responseFailure('线路\u0000禁用\n${'😀' * 300}');
    expect(error.detail, startsWith('HTTP 403: 线路 禁用 '));
    expect(error.detail!.runes.length, lessThanOrEqualTo(251));
    expect(error.detail, endsWith('…'));
    expect(error.detail, isNot(contains('\ufffd')));
    expect(error.detail, isNot(contains('\n')));
  });

  test(
    'catalog, search and player load feedback retain status and short server text',
    () {
      final l10n = AppLocalizationsZh();
      for (final status in [403, 500, 503]) {
        final error = responseFailure({'Message': '该线路已被禁用'}, status: status);
        final expected = 'HTTP $status: 该线路已被禁用';
        expect(error.statusCode, status);
        expect(embyFailureMessage(l10n, error), expected);
        // PlayerPage uses catalogFailureMessage for its Emby loadFailure.
        expect(catalogFailureMessage(l10n, error), expected);
        expect(searchFailureMessage(l10n, error), expected);
      }
    },
  );

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

  Future<EmbyClient> signedInClient() async {
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
    return emby;
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

  test('fromJson parses PremiereDate, DateCreated and People', () {
    final item = EmbyItem.fromJson({
      'Id': 'ep-1',
      'Name': 'The Pilot',
      'Type': 'Episode',
      // Emby 小数秒可达 7 位 ticks,解析应截断而非失败。
      'PremiereDate': '2024-05-02T00:00:00.0000000Z',
      'DateCreated': '2024-05-01T10:20:30.1234567Z',
      'People': [
        {
          'Name': '演员甲',
          'Type': 'Actor',
          'Role': '角色 A',
          'PrimaryImageTag': 'tag-actor',
        },
        {'Name': '导演乙', 'Type': 'Director'},
      ],
    });

    expect(item.premiereDate, DateTime.utc(2024, 5, 2));
    expect(item.dateCreated, DateTime.utc(2024, 5, 1, 10, 20, 30, 123, 456));
    expect(item.people, hasLength(2));
    expect(item.people[0].name, '演员甲');
    expect(item.people[0].type, 'Actor');
    expect(item.people[0].role, '角色 A');
    expect(item.people[0].primaryImageTag, 'tag-actor');
    expect(item.people[1].name, '导演乙');
    expect(item.people[1].type, 'Director');
    expect(item.people[1].role, isNull);
    expect(item.people[1].primaryImageTag, isNull);
  });

  test(
    'canResume treats PlayedPercentage as progress when ticks are missing',
    () {
      final item = EmbyItem.fromJson({
        'Id': 'movie-percent',
        'Name': 'Percent Only',
        'Type': 'Movie',
        'RunTimeTicks': 10000000 * 60 * 100,
        'UserData': {'Played': false, 'PlayedPercentage': 37},
      });
      expect(item.canResume, isTrue);
      expect(item.playbackProgress, closeTo(0.37, 0.001));
      expect(item.resumePositionTicks, 10000000 * 60 * 37);
    },
  );

  test('canResume hides continue when Played or past MaxResumePct', () {
    final markedPlayed = EmbyItem.fromJson({
      'Id': 'movie-played',
      'Name': 'Played',
      'Type': 'Movie',
      'UserData': {
        'Played': true,
        'PlaybackPositionTicks': 10000000,
        'PlayedPercentage': 37,
      },
    });
    expect(markedPlayed.canResume, isFalse);

    final finished = EmbyItem.fromJson({
      'Id': 'movie-finished',
      'Name': 'Finished',
      'Type': 'Movie',
      'UserData': {
        'Played': true,
        'PlaybackPositionTicks': 0,
        'PlayedPercentage': 100,
      },
    });
    expect(finished.canResume, isFalse);

    final watching = EmbyItem.fromJson({
      'Id': 'movie-watching',
      'Name': 'Watching',
      'Type': 'Movie',
      'UserData': {'Played': false, 'PlayedPercentage': 89},
    });
    expect(watching.canResume, isTrue);

    final pastThreshold = EmbyItem.fromJson({
      'Id': 'movie-ending',
      'Name': 'Ending',
      'Type': 'Movie',
      'UserData': {'Played': false, 'PlayedPercentage': 91},
    });
    expect(pastThreshold.canResume, isFalse);
  });

  test('fromJson parses PlaybackPositionTicks sent as a decimal string', () {
    final item = EmbyItem.fromJson({
      'Id': 'movie-ticks',
      'Name': 'Ticks',
      'Type': 'Movie',
      'UserData': {'Played': false, 'PlaybackPositionTicks': '2240000000.0'},
    });
    expect(item.userData.playbackPositionTicks, 2240000000);
    expect(item.canResume, isTrue);
  });

  test('fromJson maps missing or invalid dates to null and empty people', () {
    final item = EmbyItem.fromJson({
      'Id': 'ep-2',
      'Name': 'No Dates',
      'Type': 'Episode',
      'PremiereDate': 'not-a-date',
      'DateCreated': 12345,
    });

    expect(item.premiereDate, isNull);
    expect(item.dateCreated, isNull);
    expect(item.people, isEmpty);
  });

  test('copyWith keeps premiereDate, dateCreated and people', () {
    final item = EmbyItem.fromJson({
      'Id': 'ep-3',
      'Name': 'Copy',
      'Type': 'Episode',
      'PremiereDate': '2024-05-02T00:00:00Z',
      'DateCreated': '2024-05-01T00:00:00Z',
      'People': [
        {'Name': '演员甲', 'Type': 'Actor'},
      ],
    });

    final copy = item.copyWith(userData: const EmbyUserData(played: true));
    expect(copy.userData.played, isTrue);
    expect(copy.premiereDate, item.premiereDate);
    expect(copy.dateCreated, item.dateCreated);
    expect(copy.people, same(item.people));
  });

  test('getItem parses detail dates and People from the server', () async {
    server.items.add(
      FakeEmbyItem(
        id: 'episode-people',
        name: '有演职员集',
        type: 'Episode',
        parentId: 'season-friends-1',
        seriesId: 'series-friends',
        seasonId: 'season-friends-1',
        premiereDate: DateTime.utc(1994, 9, 22),
        people: const [
          FakePerson(
            name: '演员甲',
            type: 'Actor',
            role: '角色 A',
            imageTag: 'tag-actor',
          ),
          FakePerson(name: '导演乙', type: 'Director'),
        ],
      ),
    );
    final emby = await signedInClient();

    final item = await emby.getItem(
      'episode-people',
      fields: '${EmbyClient.itemFields},People',
    );
    expect(server.requests.last, contains('Fields='));
    expect(server.requests.last, contains('People'));
    expect(item.premiereDate, DateTime.utc(1994, 9, 22));
    expect(item.dateCreated, DateTime.utc(2024, 1, 1));
    expect(item.people, hasLength(2));
    expect(item.people[0].name, '演员甲');
    expect(item.people[0].role, '角色 A');
    expect(item.people[0].primaryImageTag, 'tag-actor');
    expect(item.people[1].type, 'Director');
  });

  test('getItem defaults to itemFields without People', () async {
    final emby = await signedInClient();

    await emby.getItem('movie-inception');
    final request = server.requests.last;
    expect(request, contains('Fields='));
    expect(request, contains('MediaSources'));
    expect(request, isNot(contains('People')));
  });

  test('season window queryItems never requests People', () async {
    final emby = await signedInClient();

    // 默认网格字段。
    await emby.queryItems(parentId: 'season-friends-1');
    expect(server.requests.last, isNot(contains('People')));

    // 季列表窗口显式传 itemFields 时同样不含 People。
    await emby.queryItems(
      parentId: 'season-friends-1',
      includeItemTypes: 'Episode',
      fields: EmbyClient.itemFields,
    );
    final request = server.requests.last;
    expect(request, contains('PremiereDate'));
    expect(request, isNot(contains('People')));
  });
}
