import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-auth',
  version: '0.1.0',
);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
  });

  AuthController controller({
    CredentialStore? credentials,
    ServerListStore? servers,
    Duration timeout = const Duration(seconds: 5),
  }) {
    return AuthController(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(adapter, timeout: timeout),
      ),
      credentials: credentials ?? MemoryCredentialStore(),
      servers: servers ?? MemoryServerListStore(),
    );
  }

  test('correct address and account enter the signed-in state', () async {
    final auth = controller();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );

    expect(auth.isLoggedIn, isTrue);
    expect(auth.session?.server.id, server.serverId);
    expect(auth.session?.username, 'alice');
    expect(auth.failure, isNull);
    expect(auth.savedServers, hasLength(1));
    final stored = await auth.credentials.read(server.serverId);
    expect(stored?.accessToken, isNotEmpty);
  });

  test('wrong password stays signed out with a reason', () async {
    final auth = controller();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'nope',
    );

    expect(auth.isLoggedIn, isFalse);
    expect(auth.failure?.kind, EmbyFailureKind.invalidCredentials);
    expect(await auth.credentials.read(server.serverId), isNull);
  });

  test('certificate errors stay signed out with a reason', () async {
    adapter.certificateError = true;
    final auth = controller();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );

    expect(auth.isLoggedIn, isFalse);
    expect(auth.failure?.kind, EmbyFailureKind.certificate);
  });

  for (final duringAuthentication in [false, true]) {
    test(
      'HTML 403 leaves credentials and server store untouched (auth=$duringAuthentication)',
      () async {
        const html = '<html><body>Access denied</body></html>';
        if (duringAuthentication) {
          server.authenticationStatus = 403;
          server.authenticationRawBody = html;
        } else {
          server.publicInfoStatus = 403;
          server.publicInfoRawBody = html;
        }
        final auth = controller();
        await auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'unpersisted-password',
        );
        expect(auth.isLoggedIn, isFalse);
        expect(auth.client.baseUrl, isNull);
        expect(auth.failure?.kind, EmbyFailureKind.unknown);
        expect(auth.failure?.statusCode, 403);
        expect(auth.failure?.detail, 'HTTP 403');
        expect(
          auth.failure.toString(),
          isNot(contains('unpersisted-password')),
        );
        expect(await auth.credentials.read(server.serverId), isNull);
        expect((await auth.servers.load()).servers, isEmpty);
        auth.dispose();
      },
    );
  }

  test('unreachable address stays signed out with a reason', () async {
    final auth = controller();
    await auth.connect(
      address: 'http://emby.invalid:8096',
      username: 'alice',
      password: 'correct-horse',
    );

    expect(auth.isLoggedIn, isFalse);
    expect(auth.failure?.kind, EmbyFailureKind.unreachable);
  });

  test(
    'saved server can be selected again after logout requires auth',
    () async {
      final credentials = MemoryCredentialStore();
      final servers = MemoryServerListStore();
      final auth = controller(credentials: credentials, servers: servers);
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;
      await auth.logout();

      expect(auth.isLoggedIn, isFalse);
      expect(auth.savedServers.single.baseUrl, server.baseUrl.toString());
      expect(await credentials.read(server.serverId), isNull);
      expect(server.loggedOutTokens, contains(token));

      await auth.selectSavedServer(server.serverId);
      expect(auth.prefill?.id, server.serverId);
      expect(auth.prefill?.username, 'alice');
      expect(auth.isLoggedIn, isFalse);
    },
  );

  test('401 with a stored password re-authenticates and retries', () async {
    final credentials = MemoryCredentialStore();
    final auth = controller(credentials: credentials);
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final expired = auth.session!.accessToken;
    server.issuedTokens.remove(expired);

    final info = await auth.client.getJson('/System/Info');
    expect(info['ServerName'], server.serverName);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.session!.accessToken, isNot(expired));
    expect(
      (await credentials.read(server.serverId))?.accessToken,
      auth.session!.accessToken,
    );
    expect(auth.failure, isNull);
  });

  test('401 without a stored password signs out to the connect form', () async {
    final credentials = MemoryCredentialStore();
    final auth = controller(credentials: credentials);
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final stored = await credentials.read(server.serverId);
    await credentials.write(
      server.serverId,
      StoredCredentials(
        accessToken: stored!.accessToken,
        userId: stored.userId,
        username: stored.username,
      ),
    );
    server.issuedTokens.remove(stored.accessToken);

    await expectLater(
      auth.client.getJson('/System/Info'),
      throwsA(
        isA<EmbyException>().having(
          (error) => error.kind,
          'kind',
          EmbyFailureKind.sessionExpired,
        ),
      ),
    );
    await pumpEventQueue();

    expect(auth.isLoggedIn, isFalse);
    expect(auth.failure?.kind, EmbyFailureKind.sessionExpired);
    expect(auth.prefill?.id, server.serverId);
    expect((await credentials.read(server.serverId))?.username, 'alice');
  });

  test('tokens stay bound to server id when switching', () async {
    final second = FakeEmbyServer(
      serverId: 'server-id-2',
      serverName: '第二台',
      baseUrl: Uri.parse('http://emby-two.test:8096'),
    );
    adapter.add(second);

    final credentials = MemoryCredentialStore();
    final servers = MemoryServerListStore();
    final auth = controller(credentials: credentials, servers: servers);

    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final firstToken = auth.session!.accessToken;

    await auth.connect(
      address: second.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final secondToken = auth.session!.accessToken;
    expect(auth.session?.server.id, 'server-id-2');
    expect(secondToken, isNot(firstToken));
    expect((await credentials.read('server-id-1'))?.accessToken, firstToken);

    await auth.switchTo('server-id-1');
    expect(auth.isLoggedIn, isTrue);
    expect(auth.session?.server.id, 'server-id-1');
    expect(auth.session?.accessToken, firstToken);
    expect(auth.client.accessToken, firstToken);
    expect(auth.client.baseUrl, server.baseUrl);
  });

  test(
    'keychain failure falls back to a local file without blocking login',
    () async {
      final dir = await Directory.systemTemp.createTemp('rillight-creds');
      addTearDown(() => dir.delete(recursive: true));
      final fallback = FileCredentialStore(
        File('${dir.path}/credentials.json'),
      );
      final credentials = SecureCredentialStore(
        writeSecure: (key, value) => throw const OSError('no keychain'),
        readSecure: (key) => throw const OSError('no keychain'),
        deleteSecure: (key) => throw const OSError('no keychain'),
        fallback: fallback,
      );
      final auth = controller(credentials: credentials);

      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );

      expect(auth.isLoggedIn, isTrue);
      expect((await fallback.read(server.serverId))?.accessToken, isNotEmpty);
    },
  );

  test(
    'same ServerId keeps two lines and failed line does not switch',
    () async {
      final wan = FakeEmbyServer(
        serverId: server.serverId,
        serverName: server.serverName,
        baseUrl: Uri.parse('http://emby-wan.test:8096'),
      );
      adapter.add(wan);
      final auth = controller();

      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: 'LineWan/2',
      );

      expect(auth.isLoggedIn, isTrue);
      expect(auth.savedServers, hasLength(1));
      expect(auth.savedServers.single.lines, hasLength(2));
      expect(auth.savedServers.single.baseUrl, wan.baseUrl.toString());
      expect(auth.client.userAgent, 'LineWan/2');
      expect(auth.client.sessionHeaders['User-Agent'], 'LineWan/2');

      final lanLine = auth.savedServers.single.lines.firstWhere(
        (line) => line.address == server.baseUrl.toString(),
      );
      final wanLineId = auth.savedServers.single.activeLineId;
      server.publicInfoStatus = 403;
      server.publicInfoRawBody = '该线路已被禁用';

      await auth.logout();
      await auth.connect(
        address: lanLine.address,
        username: 'alice',
        password: 'correct-horse',
        lineId: lanLine.id,
      );

      expect(auth.isLoggedIn, isFalse);
      expect(auth.client.baseUrl, isNull);
      expect(auth.savedServers.single.lines, hasLength(2));
      expect(auth.savedServers.single.activeLineId, wanLineId);
      expect(auth.failure?.detail, 'HTTP 403: 该线路已被禁用');
    },
  );

  test('line User-Agent is sent on API and cleared back to default', () async {
    final auth = controller();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
      userAgent: 'CustomUA/1.0',
    );

    expect(server.lastUserAgent, 'CustomUA/1.0');
    expect(auth.client.sessionHeaders['User-Agent'], 'CustomUA/1.0');
    expect(
      auth.client.sessionHeaders['Authorization'],
      contains('Client="Rillight"'),
    );

    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
      userAgent: '   ',
    );

    expect(server.lastUserAgent, 'Rillight/0.1.0');
    expect(auth.client.userAgent, 'Rillight/0.1.0');
    expect(auth.savedServers.single.lines.single.normalizedUserAgent, isNull);
  });

  test(
    'switching a line with a token probes and failure returns to login',
    () async {
      final wan = FakeEmbyServer(
        serverId: server.serverId,
        serverName: server.serverName,
        baseUrl: Uri.parse('http://emby-wan.test:8096'),
      );
      adapter.add(wan);
      final auth = controller();
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final lanLine = auth.savedServers.single.lines.firstWhere(
        (line) => line.address == server.baseUrl.toString(),
      );
      server.publicInfoStatus = 500;
      server.publicInfoRawBody = 'upstream timeout';

      await auth.switchTo(server.serverId, lineId: lanLine.id);

      expect(auth.isLoggedIn, isFalse);
      expect(auth.client.baseUrl, isNull);
      expect(auth.prefill?.activeLineId, lanLine.id);
      expect(auth.savedServers.single.baseUrl, wan.baseUrl.toString());
      expect(auth.failure?.detail, 'HTTP 500: upstream timeout');
    },
  );

  test(
    'switchTo a line with a different UA sends that UA on later requests',
    () async {
      final wan = FakeEmbyServer(
        serverId: server.serverId,
        serverName: server.serverName,
        baseUrl: Uri.parse('http://emby-wan.test:8096'),
      );
      adapter.add(wan);
      final auth = controller();
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: 'LanUA/1',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: 'WanUA/2',
      );
      expect(auth.client.userAgent, 'WanUA/2');

      final lanLine = auth.savedServers.single.lines.firstWhere(
        (line) => line.address == server.baseUrl.toString(),
      );
      await auth.switchTo(server.serverId, lineId: lanLine.id);

      expect(auth.isLoggedIn, isTrue);
      expect(auth.client.baseUrl, server.baseUrl);
      expect(auth.client.userAgent, 'LanUA/1');
      await auth.client.getJson('/System/Info');
      expect(server.lastUserAgent, 'LanUA/1');
    },
  );

  test('switchTo an empty-UA line uses Rillight/version', () async {
    final wan = FakeEmbyServer(
      serverId: server.serverId,
      serverName: server.serverName,
      baseUrl: Uri.parse('http://emby-wan.test:8096'),
    );
    adapter.add(wan);
    final auth = controller();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await auth.connect(
      address: wan.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
      userAgent: 'WanUA/2',
    );

    final lanLine = auth.savedServers.single.lines.firstWhere(
      (line) => line.address == server.baseUrl.toString(),
    );
    await auth.switchTo(server.serverId, lineId: lanLine.id);

    expect(auth.client.userAgent, 'Rillight/0.1.0');
    await auth.client.getJson('/System/Info');
    expect(server.lastUserAgent, 'Rillight/0.1.0');
  });

  test(
    'deleteLine of the active line remounts client onto the remaining line',
    () async {
      final wan = FakeEmbyServer(
        serverId: server.serverId,
        serverName: server.serverName,
        baseUrl: Uri.parse('http://emby-wan.test:8096'),
      );
      adapter.add(wan);
      final auth = controller();
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: 'LanUA/1',
      );
      await auth.connect(
        address: wan.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
        userAgent: 'WanUA/2',
      );
      expect(auth.client.baseUrl, wan.baseUrl);
      expect(auth.client.userAgent, 'WanUA/2');
      final wanLine = auth.savedServers.single.lines.firstWhere(
        (line) => line.address == wan.baseUrl.toString(),
      );

      await auth.deleteLine(server.serverId, wanLine.id);

      expect(auth.isLoggedIn, isTrue);
      expect(auth.savedServers.single.lines, hasLength(1));
      expect(auth.client.baseUrl, server.baseUrl);
      expect(auth.client.userAgent, 'LanUA/1');
      await auth.client.getJson('/System/Info');
      expect(server.lastUserAgent, 'LanUA/1');
    },
  );

  test('deleteLine keeps the remaining line', () async {
    final wan = FakeEmbyServer(
      serverId: server.serverId,
      serverName: server.serverName,
      baseUrl: Uri.parse('http://emby-wan.test:8096'),
    );
    adapter.add(wan);
    final auth = controller();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await auth.connect(
      address: wan.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final lanLine = auth.savedServers.single.lines.firstWhere(
      (line) => line.address == server.baseUrl.toString(),
    );

    await auth.deleteLine(server.serverId, lanLine.id);

    expect(auth.savedServers.single.lines, hasLength(1));
    expect(auth.savedServers.single.baseUrl, wan.baseUrl.toString());
    await auth.deleteLine(
      server.serverId,
      auth.savedServers.single.lines.single.id,
    );
    expect(auth.savedServers.single.lines, hasLength(1));
  });

  test('session refresh does not reactivate after logout', () async {
    final gated = _GatedCredentialStore(MemoryCredentialStore());
    final auth = controller(credentials: gated);
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    expect(auth.isLoggedIn, isTrue);

    gated.holdWrite = Completer<void>();
    final refresh = auth.client.onRefreshSession!();
    await auth.logout();
    expect(auth.isLoggedIn, isFalse);
    gated.holdWrite!.complete();
    expect(await refresh, isFalse);
    expect(auth.isLoggedIn, isFalse);
    expect(await gated.read(server.serverId), isNull);
  });
}

class _GatedCredentialStore implements CredentialStore {
  _GatedCredentialStore(this.inner);

  final CredentialStore inner;
  Completer<void>? holdWrite;

  @override
  Future<StoredCredentials?> read(String serverId) {
    return inner.read(serverId);
  }

  @override
  Future<void> write(String serverId, StoredCredentials credentials) async {
    final pending = holdWrite;
    if (pending != null) {
      await pending.future;
    }
    return inner.write(serverId, credentials);
  }

  @override
  Future<void> delete(String serverId) {
    return inner.delete(serverId);
  }
}
