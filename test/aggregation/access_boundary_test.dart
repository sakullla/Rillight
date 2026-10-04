import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/pin_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/emby_errors.dart';

class TestClient extends EmbyClient {
  TestClient()
    : super(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'test',
          version: '1',
        ),
      );
  Completer<void>? gate;
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
    if (rejectLogin) {
      throw const EmbyException(EmbyFailureKind.invalidCredentials);
    }
    return AuthenticationResult(
      accessToken: 'replacement-token',
      user: EmbyUser(id: loginUser, name: username),
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
    await gate?.future;
    return PublicServerInfo(
      id: identity ?? baseUrl.host,
      serverName: baseUrl.host,
    );
  }

  @override
  Future<LibraryCounts> getItemCounts() async =>
      const LibraryCounts(movie: 1, series: 1, episode: 1, others: []);
  @override
  Future<EmbyUser> getUser() async {
    userRequests++;
    userStarted?.complete();
    await userGate?.future;
    if (expired) throw const EmbyException(EmbyFailureKind.sessionExpired);
    return EmbyUser(id: userId!, name: 'user');
  }
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

SavedServer server(String id, {AccessRegion region = AccessRegion.ordinary}) =>
    SavedServer(
      id: id,
      name: id,
      username: 'user',
      region: region,
      lines: [
        ServerLine(id: 'one', address: 'https://$id'),
        ServerLine(id: 'two', address: 'https://$id/emby'),
      ],
      activeLineId: 'one',
      libraryIds: const ['movies'],
      scopeKnown: true,
    );

Future<SourceSessionRegistry> registry(
  RegionAccessController access,
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
  addTearDown(result.dispose);
  return result;
}

void main() {
  late PinVerifier verifier;
  setUpAll(() async {
    verifier = await PinVerifier.create('1234');
  });
  test(
    'salted versioned PIN, persisted startup locked and wrong PIN throttled',
    () async {
      final second = await PinVerifier.create('1234');
      expect(second.salt, isNot(verifier.salt));
      expect(verifier.toJson().toString(), isNot(contains('1234')));
      final dir = await Directory.systemTemp.createTemp('rillight-pin-');
      addTearDown(() => dir.delete(recursive: true));
      final store = FilePinStore(File('${dir.path}/pin.json'));
      await store.save(verifier);
      var now = DateTime(2026);
      final access = RegionAccessController(
        verifier: await store.load(),
        clock: () => now,
      );
      expect(access.state, PrivateAccessState.locked);
      expect(await access.unlock('9999'), false);
      expect(access.retryAt, isNotNull);
      expect(await access.unlock('1234'), false);
      now = now.add(const Duration(seconds: 3));
      expect(await access.unlock('1234'), true);
      expect(
        RegionAccessController(verifier: await store.load()).state,
        PrivateAccessState.locked,
      );
      await access.lock();
      expect(access.state, PrivateAccessState.locked);
    },
  );
  test(
    'two independent services, isolated expiry, nickname and ordering preserve session',
    () async {
      final clients = <TestClient>[];
      final r = await registry(RegionAccessController(), [
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
      await r.reorder(AccessRegion.ordinary, ['b', 'a']);
      await r.reorderLines('a', ['two', 'one']);
      expect(r.project(AccessRegion.ordinary).last.activeLineId, 'one');
      expect(pa.isValid, true);
      a.client.onSessionExpired!();
      expect(pa.isValid, false);
      expect(pb.isValid, true);
      expect(b.client.accessToken, 'token-b');
    },
  );
  test(
    'lock revokes late results, hides private projection and bounds cleanup',
    () async {
      final access = RegionAccessController(verifier: verifier);
      await access.unlock('1234');
      final r = await registry(access, [
        server('public'),
        server('secret', region: AccessRegion.private),
      ], []);
      final session = await r.authenticate('secret');
      final permit = r.permit(session.account);
      final gate = Completer<String>();
      final pending = permit.dispatch((_) => gate.future);
      final rejected = expectLater(pending, throwsStateError);
      RestrictedStopPermit? stop;
      var terminated = false;
      access.addTerminationHook(() {
        terminated = true;
      });
      access.addCleanupHook((p) {
        stop = p;
        return Completer<void>().future;
      });
      final locking = access.lock(budget: const Duration(milliseconds: 5));
      expect(permit.isValid, false);
      expect(access.state, PrivateAccessState.locking);
      expect(stop!.isValid, true);
      gate.complete('secret response');
      await rejected;
      await locking;
      expect(terminated, true);
      expect(stop!.isValid, false);
      expect(session.client.hasSession, false);
      expect(r.project(AccessRegion.private), isEmpty);
      expect(r.project(AccessRegion.ordinary).map((s) => s.id), ['public']);
      await expectLater(r.check('secret'), throwsStateError);
    },
  );
  test(
    'member migration clears contribution before commit, failure retains original region',
    () async {
      final access = RegionAccessController(verifier: verifier);
      await access.unlock('1234');
      final r = await registry(access, [server('a')], []);
      final session = await r.authenticate('a');
      final permit = r.permit(session.account);
      final gate = Completer<void>();
      Future<void> hook(SourceAccount? account, String id) => gate.future;
      r.addMembershipCleanup(hook);
      final moving = r.move('a', AccessRegion.private);
      expect(permit.isValid, false);
      expect(r.project(AccessRegion.ordinary), isEmpty);
      gate.complete();
      await moving;
      expect(r.project(AccessRegion.ordinary), isEmpty);
      expect(r.project(AccessRegion.private).single.id, 'a');
      r.removeMembershipCleanup(hook);
      r.addMembershipCleanup((_, _) async {
        throw StateError('stop failed');
      });
      await expectLater(r.move('a', AccessRegion.ordinary), throwsStateError);
      expect(r.project(AccessRegion.private).single.id, 'a');
    },
  );
  test('legacy scope stays unknown, removed libraries never widen', () async {
    final legacy = SavedServer.fromJson({
      'id': 'a',
      'name': 'A',
      'baseUrl': 'https://a',
      'username': 'user',
    });
    expect(legacy.region, AccessRegion.ordinary);
    expect(legacy.participates, true);
    final store = MemoryServerListStore(ServerListSnapshot(servers: [legacy]));
    final r = await registry(
      RegionAccessController(),
      [legacy],
      [],
      store: store,
    );
    final session = await r.authenticate('a');
    expect(() => r.permit(session.account), throwsStateError);
    await r.configureScope(
      'a',
      participates: true,
      libraryIds: {'movies', 'removed'},
    );
    final permit = r.permit(session.account);
    await r.reconcileLibraries('a', {'movies', 'new'});
    expect(permit.isValid, false);
    expect((await store.load()).servers.single.libraryIds, ['movies']);
    final json = (await store.load()).servers.single.toJson();
    expect(SavedServer.fromJson(json).libraryIds, ['movies']);
  });
  test(
    'manual check classification does not switch session and persists timestamp',
    () async {
      final clients = <TestClient>[];
      final store = MemoryServerListStore(
        ServerListSnapshot(servers: [server('a')]),
      );
      final r = await registry(
        RegionAccessController(),
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
    },
  );
  test('late check after lock never sends authentication request', () async {
    final access = RegionAccessController(verifier: verifier);
    await access.unlock('1234');
    final gate = Completer<void>();
    final client = TestClient()..gate = gate;
    final r = SourceSessionRegistry(
      access: access,
      store: MemoryServerListStore(
        ServerListSnapshot(
          servers: [server('secret', region: AccessRegion.private)],
        ),
      ),
      credentials: MemoryCredentialStore(),
      createClient: () => client,
    );
    addTearDown(r.dispose);
    await r.load();
    final check = r.check('secret');
    final rejected = expectLater(check, throwsStateError);
    await access.lock();
    gate.complete();
    await rejected;
    expect(client.userRequests, 0);
    expect(client.hasSession, false);
  });
  test(
    'ordinary Auth compatibility cannot leak private or overwrite managed scope',
    () async {
      final ordinary = server('a');
      final secret = server('secret', region: AccessRegion.private);
      final store = MemoryServerListStore(
        ServerListSnapshot(servers: [ordinary, secret], lastServerId: 'secret'),
      );
      final access = RegionAccessController(verifier: verifier);
      final r = await registry(access, [ordinary, secret], [], store: store);
      final auth = AuthController(
        client: TestClient(),
        credentials: r.credentials,
        servers: store,
        sources: r,
      );
      addTearDown(auth.dispose);
      await auth.restore();
      expect(auth.session, isNull);
      expect(auth.savedServers.map((s) => s.id), ['a']);
      expect(
        await auth.connect(
          address: 'https://secret',
          username: 'attacker',
          password: '0000',
        ),
        false,
      );
      expect((await r.credentials.read('secret'))!.accessToken, 'token-secret');
      final oldSnapshot = await auth.servers.load();
      await r.configureScope('a', participates: false, libraryIds: {'chosen'});
      await r.rename('a', 'managed nickname');
      await auth.servers.save(
        ServerListSnapshot(
          servers: [
            oldSnapshot.servers.single.copyWith(name: 'new server name'),
          ],
          lastServerId: 'a',
        ),
      );
      final persisted = await store.load();
      expect(persisted.servers.last.region, AccessRegion.private);
      expect(persisted.servers.first.libraryIds, ['chosen']);
      expect(persisted.servers.first.participates, false);
      expect(persisted.servers.first.nickname, 'managed nickname');
      await auth.restore();
      expect(auth.session?.server.id, 'a');
      await access.unlock('1234');
      await r.move('a', AccessRegion.private);
      expect(auth.session, isNull);
      expect(auth.client.hasSession, false);
      expect(auth.savedServers, isEmpty);
      expect(r.project(AccessRegion.ordinary), isEmpty);
      expect(r.project(AccessRegion.private), hasLength(2));
    },
  );
  test('account replacement and logout revoke old source permits', () async {
    final r = await registry(RegionAccessController(), [server('a')], []);
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
      await auth.connect(address: 'https://a', username: 'new', password: 'pw'),
      true,
    );
    expect(original.isValid, false);
    final replacement = r.permit((await r.authenticate('a')).account);
    await auth.logout();
    expect(replacement.isValid, false);
    expect(await r.credentials.read('a'), isNull);
  });

  test('failed login may preserve an unchanged authorized account', () async {
    final r = await registry(RegionAccessController(), [server('a')], []);
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

  test('late login cannot overwrite migrated locked credentials', () async {
    final access = RegionAccessController(verifier: verifier);
    await access.unlock('1234');
    final r = await registry(access, [server('a')], []);
    final client = TestClient()
      ..loginGate = Completer<void>()
      ..loginStarted = Completer<void>();
    final auth = AuthController(
      client: client,
      credentials: r.credentials,
      servers: r.store,
      sources: r,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    await auth.switchTo('a');
    final login = auth.connect(
      address: 'https://a',
      username: 'new',
      password: 'pw',
      preserveSessionOnFailure: true,
    );
    await client.loginStarted!.future;
    await r.move('a', AccessRegion.private);
    await access.lock();
    client.loginGate!.complete();
    expect(await login, false);
    expect(auth.session, isNull);
    expect(auth.client.hasSession, false);
    expect((await r.credentials.read('a'))!.accessToken, 'token-a');
    await expectLater(
      auth.restoreSavedServer(
        server('a'),
        const StoredCredentials(
          accessToken: 'undo',
          userId: 'undo',
          username: 'undo',
        ),
      ),
      throwsStateError,
    );
    expect((await r.credentials.read('a'))!.accessToken, 'token-a');
    await expectLater(
      auth.restoreSavedServer(
        server('unknown-secret', region: AccessRegion.private),
        const StoredCredentials(
          accessToken: 'undo',
          userId: 'undo',
          username: 'undo',
        ),
      ),
      throwsStateError,
    );
    expect(await r.credentials.read('unknown-secret'), isNull);
  });

  test('stale Auth edits preserve registry line and service order', () async {
    final r = await registry(RegionAccessController(), [
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
    await r.reorder(AccessRegion.ordinary, ['b', 'a']);
    await auth.renameServer('b', 'B');
    await auth.renameServer('a', 'A');
    final saved = (await r.store.load()).servers;
    expect(saved.map((s) => s.id), ['b', 'a']);
    expect(saved.last.lines.map((l) => l.id), ['two', 'one']);
    expect(saved.last.lines.first.nickname, 'backup');
  });

  test(
    'credential IO rolls back before competing private migration commits',
    () async {
      final access = RegionAccessController(verifier: verifier);
      await access.unlock('1234');
      final credentials = GatedCredentials({
        'a': const StoredCredentials(
          accessToken: 'old',
          userId: 'old',
          username: 'old',
        ),
      });
      final r = SourceSessionRegistry(
        access: access,
        store: MemoryServerListStore(
          ServerListSnapshot(servers: [server('a')]),
        ),
        credentials: credentials,
        createClient: TestClient.new,
      );
      addTearDown(r.dispose);
      await r.load();
      final old = r.permit((await r.authenticate('a')).account);
      final ticket = await r.beginOrdinaryCredentials('a');
      final write = r.commitOrdinaryCredentials(
        ticket,
        const StoredCredentials(
          accessToken: 'new',
          userId: 'new',
          username: 'new',
        ),
      );
      final rejected = expectLater(write, throwsStateError);
      await credentials.started.future;
      expect(old.isValid, false);
      await expectLater(r.authenticate('a'), throwsStateError);
      final migration = r.move('a', AccessRegion.private);
      credentials.release.complete();
      await rejected;
      await migration;
      await access.lock();
      expect((await credentials.read('a'))!.accessToken, 'old');
      expect(
        (await r.store.load()).servers.single.region,
        AccessRegion.private,
      );
    },
  );

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
        access: RegionAccessController(),
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
      await r.commitOrdinaryCredentials(
        await r.beginOrdinaryCredentials('a'),
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
      expect(r.permit(current.account).isValid, true);
    },
  );

  test(
    'pending verified account response cannot revive a migrated locked session',
    () async {
      final access = RegionAccessController(verifier: verifier);
      await access.unlock('1234');
      final gate = Completer<void>();
      final started = Completer<void>();
      final client = TestClient()
        ..userGate = gate
        ..userStarted = started;
      final r = SourceSessionRegistry(
        access: access,
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
        createClient: () => client,
      );
      addTearDown(r.dispose);
      await r.load();
      final pending = r.authenticate('a');
      final rejected = expectLater(pending, throwsStateError);
      await started.future;
      await r.move('a', AccessRegion.private);
      await access.lock();
      gate.complete();
      await rejected;
      expect(client.hasSession, false);
      expect(r.project(AccessRegion.ordinary), isEmpty);
      expect((await r.credentials.read('a'))!.accessToken, 'old');
      await expectLater(r.authenticate('a'), throwsStateError);
    },
  );

  test('late logout does not delete migrated private credentials', () async {
    final access = RegionAccessController(verifier: verifier);
    await access.unlock('1234');
    final r = await registry(access, [server('a')], []);
    final client = TestClient()
      ..logoutGate = Completer<void>()
      ..logoutStarted = Completer<void>();
    final auth = AuthController(
      client: client,
      credentials: r.credentials,
      servers: r.store,
      sources: r,
    );
    addTearDown(auth.dispose);
    await auth.restore();
    await auth.switchTo('a');
    final logout = auth.logout();
    await client.logoutStarted!.future;
    await r.move('a', AccessRegion.private);
    await access.lock();
    client.logoutGate!.complete();
    await logout;
    expect((await r.credentials.read('a'))!.accessToken, 'token-a');
    expect(auth.isBusy, false);
  });

  test(
    'stale ordinary snapshot does not remove a migrated-in member',
    () async {
      final access = RegionAccessController(verifier: verifier);
      final r = await registry(access, [
        server('a', region: AccessRegion.private),
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
      await access.unlock('1234');
      await r.move('a', AccessRegion.ordinary);
      await auth.renameServer('b', 'B');
      expect((await r.store.load()).servers.map((s) => s.id), ['a', 'b']);
    },
  );

  test(
    'failed member persistence is not committed and writer recovers',
    () async {
      final access = RegionAccessController(verifier: verifier);
      await access.unlock('1234');
      final store = FailingStore(ServerListSnapshot(servers: [server('a')]));
      final r = await registry(access, [server('a')], [], store: store);
      store.fail = true;
      await expectLater(
        r.move('a', AccessRegion.private),
        throwsA(isA<FileSystemException>()),
      );
      expect(r.project(AccessRegion.ordinary).single.id, 'a');
      expect(r.project(AccessRegion.private), isEmpty);
      store.fail = false;
      await r.rename('a', 'recovered');
      expect((await store.load()).servers.single.nickname, 'recovered');
      await Future.wait([
        r.rename('a', 'parallel'),
        r.renameLine('a', 'two', 'parallel line'),
      ]);
      expect((await store.load()).servers.single.nickname, 'parallel');
      expect(
        (await store.load()).servers.single.lines.last.nickname,
        'parallel line',
      );
    },
  );
  test(
    'PIN setup requires confirmation and persistence before activation',
    () async {
      final access = RegionAccessController();
      await expectLater(
        access.setPin('1234', '0000', (_) async {}),
        throwsArgumentError,
      );
      expect(access.hasPin, false);
      await expectLater(
        access.setPin('1234', '1234', (_) async {
          throw StateError('disk');
        }),
        throwsStateError,
      );
      expect(access.hasPin, false);
      await access.setPin('1234', '1234', (_) async {});
      expect(access.hasPin, true);
      expect(access.state, PrivateAccessState.locked);
      await expectLater(
        access.setPin('5678', '5678', (_) async {}),
        throwsStateError,
      );
      expect(await access.unlock('1234'), true);
    },
  );
  test('timeout check does not continue to authenticated requests', () async {
    final gate = Completer<void>();
    final client = TestClient()..gate = gate;
    final r = SourceSessionRegistry(
      access: RegionAccessController(),
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
}
