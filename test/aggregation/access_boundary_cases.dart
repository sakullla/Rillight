import '../helpers/server_access_fixture.dart';

import 'package:dio/dio.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/server_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';

class TestClient extends EmbyClient {
  TestClient()
    : super(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'test',
          version: '1',
        ),
      );
  @override
  MediaServerClient withRequestGuard(void Function() guard) {
    final copy = _GuardedTestClient(this, guard);
    if (hasSession) {
      copy.attachSession(
        baseUrl: baseUrl!,
        accessToken: accessToken!,
        userId: userId!,
        userAgent: customUserAgent,
      );
    }
    copy.onSessionExpired = onSessionExpired;
    copy.onRefreshSession = onRefreshSession;
    return copy;
  }

  Completer<void>? gate;
  final List<Uri> publicUrls = [];
  String? identity;
  Completer<void>? loginGate;
  Completer<void>? logoutGate;
  Completer<void>? logoutStarted;
  Completer<void>? loginStarted;
  String loginUser = 'replacement';
  bool rejectLogin = false;
  @override
  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    String? serverId,
  }) async {
    loginStarted?.complete();
    await loginGate?.future;
    if (rejectLogin || password == 'bad') {
      throw const MediaServerException(
        MediaServerFailureKind.invalidCredentials,
      );
    }
    return AuthenticationResult(
      accessToken: 'replacement-token',
      user: MediaUser(id: loginUser, name: username),
      serverId: serverId ?? baseUrl.host,
    );
  }

  @override
  Future<void> logout() async {
    logoutStarted?.complete();
    await logoutGate?.future;
  }

  bool expired = false;
  int userRequests = 0;
  Completer<void>? userGate;
  Completer<void>? userStarted;
  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    publicUrls.add(baseUrl);
    await gate?.future;
    return PublicServerInfo(
      id: identity ?? baseUrl.host,
      serverName: baseUrl.host,
    );
  }

  @override
  Future<List<MediaItem>> getViews() async => [
    const MediaItem(id: 'movies', name: 'Movies', type: 'CollectionFolder'),
    const MediaItem(
      id: 'new-library',
      name: 'New library',
      type: 'CollectionFolder',
    ),
  ];

  @override
  Future<LibraryCounts> getItemCounts() async =>
      const LibraryCounts(movie: 1, series: 1, episode: 1, others: []);
  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async {
    userRequests++;
    userStarted?.complete();
    await userGate?.future;
    if (expired) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    return MediaUser(id: userId!, name: 'user');
  }
}

class _GuardedTestClient extends TestClient {
  _GuardedTestClient(this.delegate, this.guard);
  final TestClient delegate;
  final void Function() guard;
  Future<T> checked<T>(Future<T> Function() operation) async {
    guard();
    final value = await operation();
    guard();
    return value;
  }

  @override
  Future<PublicServerInfo> getPublicInfo(Uri url) =>
      checked(() => delegate.getPublicInfo(url));
  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) =>
      checked(() => delegate.getUser(cancelToken: cancelToken));
  @override
  Future<List<MediaItem>> getViews() => checked(delegate.getViews);
  @override
  Future<LibraryCounts> getItemCounts() => checked(delegate.getItemCounts);
  @override
  Future<void> logout() => checked(delegate.logout);
  @override
  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    String? serverId,
  }) => checked(
    () => delegate.authenticateByName(
      baseUrl: baseUrl,
      username: username,
      password: password,
      serverId: serverId,
    ),
  );
}

class GatedCredentials extends MemoryCredentialStore {
  GatedCredentials(super.seed);
  final started = Completer<void>();
  final release = Completer<void>();
  bool gated = true;
  @override
  Future<void> write(String id, StoredCredentials value) async {
    if (gated) {
      gated = false;
      started.complete();
      await release.future;
    }
    await super.write(id, value);
  }
}

class FailingStore extends MemoryServerListStore {
  FailingStore(super.seed);
  bool fail = false;
  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    if (fail) throw const FileSystemException('Synthetic persistence failure');
    await super.save(snapshot);
  }
}

SavedServer server(String id, {bool protected = false}) => SavedServer(
  id: id,
  name: id,
  username: 'user',
  protectionRef: protected ? 'test:$id' : null,
  lines: [
    ServerLine(id: 'one', address: 'https://$id'),
    ServerLine(id: 'two', address: 'https://$id/emby'),
  ],
  activeLineId: 'one',
);

Future<SourceSessionRegistry> registry(
  ServerAccessController access,
  List<SavedServer> servers,
  List<TestClient> clients, {
  MemoryServerListStore? store,
}) async {
  final result = SourceSessionRegistry(
    access: access,
    store: store ?? MemoryServerListStore(ServerListSnapshot(servers: servers)),
    credentials: MemoryCredentialStore({
      for (final s in servers)
        s.id: StoredCredentials(
          accessToken: 'token-${s.id}',
          userId: 'user-${s.id}',
          username: 'user',
        ),
    }),
    createClient: () {
      final client = TestClient();
      clients.add(client);
      return client;
    },
  );
  await result.load();
  for (final saved in servers) {
    if (saved.protectionRef != null) await access.unlock(saved.id, '1234');
  }
  addTearDown(result.dispose);
  return result;
}

void main() {
  test('management write gate makes actual Auth logout wait then delete permanently', () async {
    final credentials = GatedCredentials({
      'a': const StoredCredentials(
        accessToken: 'old',
        userId: 'old',
        username: 'old',
      ),
    });
    final selectedClient = TestClient()..logoutStarted = Completer<void>();
    var createdClients = 0;
    final r = SourceSessionRegistry(
      access: TestServerAccessController(),
      store: MemoryServerListStore(
        ServerListSnapshot(servers: [server('a')], lastServerId: 'a'),
      ),
      credentials: credentials,
      createClient: () => createdClients++ == 0 ? selectedClient : TestClient(),
    );
    await r.load();
    final client = TestClient()..logoutStarted = Completer<void>();
    final auth = AuthController(
      client: client,
      credentials: credentials,
      servers: r.store,
      sources: r,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    expect(auth.session, isNotNull);
    final management = r.login('a', 'new', 'secret');
    await credentials.started.future;
    var loggedOut = false;
    final logout = auth.logout().then((_) => loggedOut = true);
    await Future<void>.delayed(Duration.zero);
    expect(loggedOut, isFalse);
    credentials.release.complete();
    await management;
    await logout;
    expect(loggedOut, isTrue);
    expect(await credentials.read('a'), isNull);
    expect(auth.session, isNull);
    expect(client.hasSession, isFalse);
  });

  test(
    'queued private login rechecks generation before credential IO',
    () async {
      final access = TestServerAccessController(
        passwords: const {'a': '1234', 'b': '1234', 'secret': '1234'},
      );
      final credentials = GatedCredentials({
        for (final id in ['a', 'b'])
          id: const StoredCredentials(
            accessToken: 'old',
            userId: 'old',
            username: 'old',
          ),
      });
      final r = SourceSessionRegistry(
        access: access,
        store: MemoryServerListStore(
          ServerListSnapshot(
            servers: [server('a', protected: true), server('b')],
          ),
        ),
        credentials: credentials,
        createClient: TestClient.new,
      );
      await r.load();
      for (final saved in r.project()) {
        if (saved.protectionRef != null) await access.unlock(saved.id, '1234');
      }
      addTearDown(r.dispose);
      final ticket = await r.beginCredentials('b');
      final blocking = r.commitCredentials(
        ticket,
        const StoredCredentials(
          accessToken: 'b-new',
          userId: 'b-new',
          username: 'b-new',
        ),
      );
      await credentials.started.future;
      final login = r.login('a', 'new', 'secret');
      final rejected = expectLater(login, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await access.lock('a');
      credentials.release.complete();
      await blocking;
      await rejected;
      expect((await credentials.read('a'))?.accessToken, 'old');
      expect((await credentials.read('b'))?.accessToken, 'b-new');
    },
  );

  test(
    'parallel management logins preserve every service in FileCredentialStore',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        't7-credentials-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final credentials = FileCredentialStore(
        File('${directory.path}/credentials.json'),
      );
      final r = SourceSessionRegistry(
        access: TestServerAccessController(),
        store: MemoryServerListStore(
          ServerListSnapshot(servers: [server('a'), server('b')]),
        ),
        credentials: credentials,
        createClient: TestClient.new,
      );
      await r.load();
      addTearDown(r.dispose);
      await Future.wait([
        r.login('a', 'alice', 'secret'),
        r.login('b', 'bob', 'secret'),
      ]);
      expect((await credentials.read('a'))?.username, 'alice');
      expect((await credentials.read('b'))?.username, 'bob');
    },
  );

  for (final expected in ManualCheckStatus.values.where(
    (s) => [
      ManualCheckStatus.available,
      ManualCheckStatus.timeout,
      ManualCheckStatus.identityMismatch,
      ManualCheckStatus.needsLogin,
    ].contains(s),
  )) {
    test(
      'explicit backup line check $expected preserves active source permit',
      () async {
        final checking = TestClient();
        if (expected == ManualCheckStatus.timeout) {
          checking.gate = Completer<void>();
        }
        if (expected == ManualCheckStatus.identityMismatch) {
          checking.identity = 'wrong';
        }
        if (expected == ManualCheckStatus.needsLogin) checking.expired = true;
        var forCheck = false;
        final r = SourceSessionRegistry(
          access: TestServerAccessController(),
          store: MemoryServerListStore(
            ServerListSnapshot(servers: [server('a')]),
          ),
          credentials: MemoryCredentialStore({
            'a': const StoredCredentials(
              accessToken: 'old',
              userId: 'user-a',
              username: 'alice',
            ),
          }),
          createClient: () => forCheck ? checking : TestClient(),
        );
        await r.load();
        addTearDown(r.dispose);
        final session = await r.authenticate('a');
        final permit = r.permit(session.account);
        forCheck = true;
        final result = await r.check(
          'a',
          lineId: 'two',
          timeout: const Duration(milliseconds: 5),
        );
        expect(result.status, expected);
        expect(checking.publicUrls, [Uri.parse('https://a/emby')]);
        final saved = (await r.store.load()).servers.single;
        expect(saved.activeLineId, 'one');
        expect(saved.lines.first.checkStatus, 'unknown');
        expect(saved.lines.last.checkStatus, expected.name);
        expect(saved.lines.last.checkedAt, result.checkedAt);
        expect(saved.checkStatus, 'unknown');
        expect(permit.isValid, isTrue);
        expect(session.client.hasSession, isTrue);
        expect(
          checking.userRequests,
          expected == ManualCheckStatus.available ||
                  expected == ManualCheckStatus.needsLogin
              ? 1
              : 0,
        );
        checking.gate?.complete();
        await Future<void>.delayed(Duration.zero);
      },
    );
  }

  test(
    'parallel target checks retain independent per-line status and time',
    () async {
      final first = TestClient()..gate = Completer<void>();
      final second = TestClient()..identity = 'wrong';
      final clients = [first, second];
      final r = SourceSessionRegistry(
        access: TestServerAccessController(),
        store: MemoryServerListStore(
          ServerListSnapshot(servers: [server('a')]),
        ),
        credentials: MemoryCredentialStore({
          'a': const StoredCredentials(
            accessToken: 'old',
            userId: 'old',
            username: 'old',
          ),
        }),
        createClient: () => clients.removeAt(0),
      );
      await r.load();
      addTearDown(r.dispose);
      final pending = r.check('a', lineId: 'one');
      final backup = await r.check('a', lineId: 'two');
      first.gate!.complete();
      final active = await pending;
      final saved = (await r.store.load()).servers.single;
      expect(saved.activeLineId, 'one');
      expect(saved.lines.first.checkStatus, 'available');
      expect(saved.lines.first.checkedAt, active.checkedAt);
      expect(saved.lines.last.checkStatus, 'identityMismatch');
      expect(saved.lines.last.checkedAt, backup.checkedAt);
      expect(
        SavedServer.fromJson(saved.toJson()).lines.last.checkedAt,
        backup.checkedAt,
      );
    },
  );

  test('ordinary stale line editor preserves checks until the target address changes', () async {
    final r = await registry(TestServerAccessController(), [server('a')], []);
    final auth = AuthController(
      client: TestClient(),
      credentials: r.credentials,
      servers: r.store,
      sources: r,
    );
    addTearDown(auth.dispose);
    await r.renameLine('a', 'two', '备用');
    await auth.restore();
    final result = await r.check('a', lineId: 'two');
    await auth.renameServer('a', '重命名服务');
    var line = (await r.store.load()).servers.single.lines.last;
    expect(line.checkStatus, 'available');
    expect(line.checkedAt, result.checkedAt);
    expect(await auth.updateLineAddress('a', 'two', 'https://a/new'), isTrue);
    line = (await r.store.load()).servers.single.lines.last;
    expect(line.checkStatus, 'unknown');
    expect(line.checkedAt, isNull);
    expect(line.nickname, '备用');
  });

  test('two independent services, isolated expiry, nickname and ordering preserve session', () async {
    final clients = <TestClient>[];
    final r = await registry(TestServerAccessController(), [
      server('a'),
      server('b'),
    ], clients);
    final a = await r.authenticate('a');
    final b = await r.authenticate('b');
    final pa = r.permit(a.account, libraryId: 'movies');
    final pb = r.permit(b.account);
    expect(a.client, isNot(same(b.client)));
    expect(
      await Future.wait([
        pa.dispatch((c) async => c.accessToken),
        pb.dispatch((c) async => c.accessToken),
      ]),
      ['token-a', 'token-b'],
    );
    await r.rename('a', 'new name');
    await r.renameLine('a', 'two', 'backup');
    await r.reorderServers(['b', 'a']);
    await r.reorderLines('a', ['two', 'one']);
    expect(r.project().last.activeLineId, 'one');
    expect(pa.isValid, true);
    a.client.onSessionExpired!();
    expect(pa.isValid, false);
    expect(pb.isValid, true);
    expect(b.client.accessToken, 'token-b');
  });
  test('manual check classification does not switch session and persists timestamp', () async {
    final clients = <TestClient>[];
    final store = MemoryServerListStore(
      ServerListSnapshot(servers: [server('a')]),
    );
    final r = await registry(
      TestServerAccessController(),
      [server('a')],
      clients,
      store: store,
    );
    final session = await r.authenticate('a');
    final permit = r.permit(session.account);
    expect((await r.check('a')).status, ManualCheckStatus.available);
    expect((await store.load()).servers.single.checkedAt, isNotNull);
    expect(clients.last.hasSession, false);
    expect(session.client.accessToken, 'token-a');
    expect(permit.isValid, true);
  });
  test('late check after lock never sends authentication request', () async {
    final access = TestServerAccessController(
      passwords: const {'a': '1234', 'b': '1234', 'secret': '1234'},
    );
    final gate = Completer<void>();
    final client = TestClient()..gate = gate;
    final r = SourceSessionRegistry(
      access: access,
      store: MemoryServerListStore(
        ServerListSnapshot(servers: [server('secret', protected: true)]),
      ),
      credentials: MemoryCredentialStore(),
      createClient: () => client,
    );
    addTearDown(r.dispose);
    await r.load();
    for (final saved in r.project()) {
      if (saved.protectionRef != null) await access.unlock(saved.id, '1234');
    }
    final check = r.check('secret', lineId: 'two');
    final rejected = expectLater(check, throwsStateError);
    await access.lock('secret');
    gate.complete();
    await rejected;
    expect(client.userRequests, 0);
    expect(client.hasSession, false);
    expect((await r.store.load()).servers.single.lines.last.checkedAt, isNull);
    final lockedCheck = await r.check('secret', lineId: 'two');
    expect(lockedCheck.status, ManualCheckStatus.needsLogin);
    expect(client.userRequests, 0);
    expect(access.allows('secret'), isFalse);
  });
  test(
    'backup check user response after private lock cannot publish status',
    () async {
      final access = TestServerAccessController(
        passwords: const {'a': '1234', 'b': '1234', 'secret': '1234'},
      );
      final client = TestClient()
        ..userGate = Completer<void>()
        ..userStarted = Completer<void>();
      final credentials = MemoryCredentialStore({
        'secret': const StoredCredentials(
          accessToken: 'old',
          userId: 'old',
          username: 'old',
        ),
      });
      final r = SourceSessionRegistry(
        access: access,
        store: MemoryServerListStore(
          ServerListSnapshot(servers: [server('secret', protected: true)]),
        ),
        credentials: credentials,
        createClient: () => client,
      );
      await r.load();
      for (final saved in r.project()) {
        if (saved.protectionRef != null) await access.unlock(saved.id, '1234');
      }
      addTearDown(r.dispose);
      final check = r.check('secret', lineId: 'two');
      final rejected = expectLater(check, throwsStateError);
      await client.userStarted!.future;
      await access.lock('secret');
      client.userGate!.complete();
      await rejected;
      expect(
        (await r.store.load()).servers.single.lines.last.checkedAt,
        isNull,
      );
      expect((await credentials.read('secret'))?.accessToken, 'old');
      expect(client.hasSession, isFalse);
      expect(r.project().single.id, 'secret');
      expect(access.allows('secret'), isFalse);
    },
  );

  test(
    'new account preserves sibling permits and logout revokes only its own',
    () async {
      final r = await registry(TestServerAccessController(), [server('a')], []);
      final auth = AuthController(
        client: TestClient(),
        credentials: r.credentials,
        servers: r.store,
        sources: r,
      );
      addTearDown(auth.dispose);
      await auth.restore();
      final original = r.permit((await r.authenticate('a')).account);
      expect(
        await auth.connect(
          address: 'https://a',
          username: 'new',
          password: 'pw',
        ),
        true,
      );
      expect(original.isValid, true);
      final addedId = auth.session!.server.id;
      expect(addedId, isNot('a'));
      final replacement = r.permit((await r.authenticate(addedId)).account);
      await auth.logout();
      expect(replacement.isValid, false);
      expect(await r.credentials.read(addedId), isNull);
      expect((await r.credentials.read('a'))!.accessToken, 'token-a');
      expect(original.isValid, true);
    },
  );

  test('failed login may preserve an unchanged authorized account', () async {
    final clients = <TestClient>[];
    final r = await registry(TestServerAccessController(), [
      server('a'),
    ], clients);
    final auth = AuthController(
      client: TestClient()..rejectLogin = true,
      credentials: r.credentials,
      servers: r.store,
      sources: r,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    await auth.switchTo('a');
    final permit = r.permit((await r.authenticate('a')).account);
    for (final client in clients) {
      client.rejectLogin = true;
    }
    expect(
      await auth.connect(
        address: 'https://a',
        username: 'new',
        password: 'bad',
        preserveSessionOnFailure: true,
      ),
      false,
    );
    expect(auth.session!.userId, 'user-a');
    expect(auth.client.accessToken, 'token-a');
    expect(permit.isValid, true);
  });

  for (final lineId in ['one', 'two']) {
    test('editing loaded named line $lineId preserves its metadata', () async {
      final r = await registry(TestServerAccessController(), [server('a')], []);
      await r.renameLine('a', lineId, 'named backup');
      final auth = AuthController(
        client: TestClient(),
        credentials: r.credentials,
        servers: r.store,
        sources: r,
      );
      addTearDown(auth.dispose);
      await auth.restore();
      await auth.switchTo('a');
      final before = auth.savedServers.single;
      final session = auth.session!;
      final other = before.lines.firstWhere((l) => l.id != lineId);
      expect(
        before.lines.firstWhere((l) => l.id == lineId).nickname,
        'named backup',
      );

      expect(
        await auth.updateLineAddress('a', lineId, 'https://a/new-address'),
        true,
      );

      final saved = (await r.store.load()).servers.single;
      final edited = saved.lines.firstWhere((l) => l.id == lineId);
      expect(edited.address, 'https://a/new-address');
      expect(edited.nickname, 'named backup');
      expect(saved.lines.map((l) => l.id), before.lines.map((l) => l.id));
      expect(saved.activeLineId, before.activeLineId);
      expect(
        saved.lines.firstWhere((l) => l.id != lineId).toJson(),
        other.toJson(),
      );
      expect(auth.session!.userId, session.userId);
      expect(auth.session!.accessToken, session.accessToken);
      expect(
        auth.client.baseUrl.toString(),
        lineId == before.activeLineId ? edited.address : before.baseUrl,
      );
      await auth.restore();
      expect(
        auth.savedServers.single.lines
            .firstWhere((l) => l.id == lineId)
            .nickname,
        'named backup',
      );
    });
  }

  test('login address rebuild preserves a loaded line nickname', () async {
    final r = await registry(TestServerAccessController(), [server('a')], []);
    await r.renameLine('a', 'two', 'named backup');
    final auth = AuthController(
      client: TestClient(),
      credentials: r.credentials,
      servers: r.store,
      sources: r,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    expect(
      await auth.connect(
        address: 'https://a/new-address',
        username: 'user',
        password: 'pw',
        lineId: 'two',
      ),
      true,
    );
    final saved = (await r.store.load()).servers.single;
    expect(saved.lines.map((l) => l.id), ['one', 'two']);
    expect(saved.activeLineId, 'two');
    expect(saved.lines.last.address, 'https://a/new-address');
    expect(saved.lines.last.nickname, 'named backup');
  });

  test('stale Auth edits preserve registry line and service order', () async {
    final r = await registry(TestServerAccessController(), [
      server('a'),
      server('b'),
    ], []);
    final auth = AuthController(
      client: TestClient(),
      credentials: r.credentials,
      servers: r.store,
      sources: r,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    await r.renameLine('a', 'two', 'backup');
    await r.reorderLines('a', ['two', 'one']);
    await r.reorderServers(['b', 'a']);
    await auth.renameServer('b', 'B');
    await auth.renameServer('a', 'A');
    final saved = (await r.store.load()).servers;
    expect(saved.map((s) => s.id), ['b', 'a']);
    expect(saved.last.lines.map((l) => l.id), ['two', 'one']);
    expect(saved.last.lines.first.nickname, 'backup');
  });

  test(
    'pending source authentication is revoked by account replacement',
    () async {
      final gate = Completer<void>();
      final credentials = MemoryCredentialStore({
        'a': const StoredCredentials(
          accessToken: 'old',
          userId: 'old',
          username: 'old',
        ),
      });
      final r = SourceSessionRegistry(
        access: TestServerAccessController(),
        store: MemoryServerListStore(
          ServerListSnapshot(servers: [server('a')]),
        ),
        credentials: credentials,
        createClient: () => TestClient()..gate = gate,
      );
      addTearDown(r.dispose);
      await r.load();
      final pending = r.authenticate('a');
      final rejected = expectLater(pending, throwsStateError);
      await r.commitCredentials(
        await r.beginCredentials('a'),
        const StoredCredentials(
          accessToken: 'new',
          userId: 'new',
          username: 'new',
        ),
      );
      gate.complete();
      await rejected;
      final current = await r.authenticate('a');
      expect(current.account.userId, 'new');
      expect(r.permit(current.account).isValid, isTrue);
      expect(r.permit(current.account).isValid, true);
    },
  );

  test('timeout check does not continue to authenticated requests', () async {
    final gate = Completer<void>();
    final client = TestClient()..gate = gate;
    final r = SourceSessionRegistry(
      access: TestServerAccessController(),
      store: MemoryServerListStore(ServerListSnapshot(servers: [server('a')])),
      credentials: MemoryCredentialStore(),
      createClient: () => client,
    );
    addTearDown(r.dispose);
    await r.load();
    expect(
      (await r.check('a', timeout: const Duration(milliseconds: 1))).status,
      ManualCheckStatus.timeout,
    );
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(client.userRequests, 0);
  });

  test('all configured servers stay visible while content requires their own permit', () async {
    final access = TestServerAccessController(passwords: const {'a': '1234'});
    final r = SourceSessionRegistry(
      access: access,
      store: MemoryServerListStore(
        ServerListSnapshot(
          servers: [server('a', protected: true), server('b')],
        ),
      ),
      credentials: MemoryCredentialStore({
        for (final id in ['a', 'b'])
          id: StoredCredentials(
            accessToken: 'token-$id',
            userId: 'user-$id',
            username: 'user',
          ),
      }),
      createClient: TestClient.new,
    );
    addTearDown(r.dispose);
    await r.load();
    expect(r.project().map((s) => s.id), ['a', 'b']);
    await expectLater(r.authenticate('a'), throwsStateError);
    await expectLater(r.ensureSession('a'), throwsStateError);
    final b = await r.authenticate('b');
    final permitB = r.permit(b.account, libraryId: 'unconfigured-library');
    expect(permitB.isValid, isTrue);
    expect(await access.unlock('a', 'bad'), isFalse);
    expect(permitB.isValid, isTrue);
    expect(await r.credentials.read('a'), isNotNull);
  });

  test(
    'preparing protected entry never publishes content before password commit',
    () async {
      final access = TestServerAccessController(passwords: const {'a': '1234'});
      final r = await registry(access, [
        server('a', protected: true),
        server('b'),
      ], []);
      await access.lock('a');
      final candidate = await r.prepareEntrySession('a');
      expect(candidate.account.configuredServerId, 'a');
      expect(access.allows('a'), isFalse);
      expect(() => r.permit(candidate.account), throwsStateError);
      final unlock = await access.prepareUnlock('a', '1234');
      expect(access.allows('a'), isFalse);
      expect(access.commitEntry('a', unlock), isTrue);
      expect(r.permit(candidate.account).isValid, isTrue);
    },
  );

  for (final phase in ['identity', 'account']) {
    test(
      'locking during $phase preparation rejects late results without deleting credentials',
      () async {
        final access = TestServerAccessController(
          passwords: const {'a': '1234'},
        );
        final client = TestClient();
        final r = SourceSessionRegistry(
          access: access,
          store: MemoryServerListStore(
            ServerListSnapshot(servers: [server('a', protected: true)]),
          ),
          credentials: MemoryCredentialStore({
            'a': const StoredCredentials(
              accessToken: 'token-a',
              userId: 'user-a',
              username: 'user',
            ),
          }),
          createClient: () => client,
        );
        addTearDown(r.dispose);
        await r.load();
        await access.unlock('a', '1234');
        final gate = Completer<void>();
        if (phase == 'identity') {
          client.gate = gate;
        } else {
          client.userGate = gate;
          client.userStarted = Completer<void>();
        }
        final pending = r.authenticate('a');
        final rejected = expectLater(pending, throwsStateError);
        if (phase == 'account') {
          await client.userStarted!.future;
        } else {
          while (client.publicUrls.isEmpty) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        await access.lock('a');
        gate.complete();
        await rejected;
        expect(r.project().single.id, 'a');
        expect((await r.credentials.read('a'))!.accessToken, 'token-a');
        expect(client.hasSession, isFalse);
        if (phase == 'identity') expect(client.userRequests, 0);
      },
    );
  }

  test('successful other-server entry revokes only protected source and keeps remote login', () async {
    final access = TestServerAccessController(passwords: const {'a': '1234'});
    final r = await registry(access, [
      server('a', protected: true),
      server('b'),
    ], []);
    final a = await r.authenticate('a');
    final b = await r.authenticate('b');
    final permitA = r.permit(a.account), permitB = r.permit(b.account);
    access.didEnter('a');
    expect(permitA.isValid, isTrue);
    access.didEnter('b');
    expect(permitA.isValid, isFalse);
    expect(permitB.isValid, isTrue);
    expect((await r.credentials.read('a'))!.accessToken, 'token-a');
    expect(r.project(), hasLength(2));
  });

  test(
    'cancelled unlock cannot reveal target or revoke current source',
    () async {
      final access = TestServerAccessController(
        passwords: const {'a': '1234', 'b': '1234'},
      );
      final r = await registry(access, [
        server('a', protected: true),
        server('b', protected: true),
      ], []);
      await access.lock('b');
      final a = await r.authenticate('a');
      final permitA = r.permit(a.account);
      final candidate = (await access.prepareUnlock('b', '1234'))!;
      candidate.cancel();
      expect(access.commitEntry('b', candidate), isFalse);
      expect(permitA.isValid, isTrue);
      expect(access.allows('b'), isFalse);
    },
  );

  test(
    'password persistence failure preserves original permit and configuration',
    () async {
      final store = FailingStore(ServerListSnapshot(servers: [server('a')]));
      final access = TestServerAccessController();
      final r = await registry(access, [server('a')], [], store: store);
      final a = await r.authenticate('a');
      final permit = r.permit(a.account);
      store.fail = true;
      await expectLater(
        access.setPassword(
          'a',
          '1234',
          '1234',
          persistReference: (ref) => r.persistProtectionReference('a', ref),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(permit.isValid, isTrue);
      expect(r.project().single.protectionRef, isNull);
      store.fail = false;
      await access.setPassword(
        'a',
        '1234',
        '1234',
        persistReference: (ref) => r.persistProtectionReference('a', ref),
      );
      expect(permit.isValid, isFalse);
      expect(access.allows('a'), isFalse);
      expect((await r.credentials.read('a'))!.accessToken, 'token-a');
    },
  );

  test(
    'missing verifier remains locked yet removal needs no password',
    () async {
      final access = TestServerAccessController();
      final r = await registry(access, [
        server('a', protected: true),
        server('b'),
      ], []);
      expect(access.isUnavailable('a'), isTrue);
      await expectLater(r.authenticate('a'), throwsStateError);
      final b = await r.authenticate('b');
      final permitB = r.permit(b.account);
      await r.logoutSource('a', remove: true);
      expect(r.project().single.id, 'b');
      expect(await r.credentials.read('a'), isNull);
      expect(permitB.isValid, isTrue);
    },
  );
}
