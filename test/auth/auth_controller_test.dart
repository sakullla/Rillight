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

  test('401 clears the session and reports expiry', () async {
    final auth = controller();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    server.expireAuthenticatedRequests = true;

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
    expect(await auth.credentials.read(server.serverId), isNull);
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
}
