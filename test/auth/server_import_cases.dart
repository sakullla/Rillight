import '../helpers/region_access_fixture.dart';
import 'package:dio/dio.dart';
import 'package:rillight/media_server/device.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_import_models.dart';
import 'package:rillight/auth/server_import_service.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';

class ImportClient extends EmbyClient {
  ImportClient()
    : super(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'test',
          version: '1',
        ),
      );
  String identity = 'remote';
  int requests = 0;
  bool expired = false;
  Completer<void>? gate;
  Completer<void>? started;
  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    requests++;
    started?.complete();
    await gate?.future;
    return PublicServerInfo(id: identity, serverName: 'Synthetic');
  }

  @override
  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    required String serverId,
  }) async {
    requests++;
    if (password != 'synthetic') {
      throw const MediaServerException(
        MediaServerFailureKind.invalidCredentials,
      );
    }
    return AuthenticationResult(
      accessToken: 'token-$username',
      user: MediaUser(id: 'user-$username', name: username),
      serverId: serverId,
    );
  }

  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async {
    requests++;
    if (expired) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    return MediaUser(id: userId!, name: 'Synthetic');
  }

  @override
  Future<LibraryCounts> getItemCounts() async =>
      const LibraryCounts(movie: 0, series: 0, episode: 0, others: []);
}

class ImportCredentials extends MemoryCredentialStore {
  bool failNext = false;
  Completer<void>? gate;
  Completer<void>? started;
  final written = <String>[];
  @override
  Future<void> write(String id, StoredCredentials credentials) async {
    written.add(id);
    await super.write(id, credentials);
    started?.complete();
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('Synthetic write failed after mutation');
    }
  }
}

class ImportStore extends MemoryServerListStore {
  bool failNext = false;
  Completer<void>? gate;
  Completer<void>? started;
  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    await super.save(snapshot);
    final pending = gate;
    gate = null;
    started?.complete();
    started = null;
    await pending?.future;
    if (failNext) {
      failNext = false;
      throw StateError('Synthetic write failed after mutation');
    }
  }
}

ServerImportDraft draft(
  String username, {
  String address = 'https://example.test/proxy',
  bool isPrivate = false,
  StoredCredentials? credentials,
  bool password = true,
}) => ServerImportDraft(
  name: 'Same display name',
  username: username,
  lines: [ServerImportLine(address: address)],
  isPrivate: isPrivate,
  credentials:
      credentials ??
      (password
          ? StoredCredentials(
              accessToken: '',
              userId: '',
              username: username,
              password: 'synthetic',
            )
          : null),
);

void main() {
  late ImportStore store;
  late ImportCredentials credentials;
  late RegionAccessController access;
  late SourceSessionRegistry sources;
  late List<ImportClient> clients;
  setUp(() async {
    store = ImportStore();
    credentials = ImportCredentials();
    access = TestRegionAccessController();
    clients = [];
    sources = SourceSessionRegistry(
      access: access,
      store: store,
      credentials: credentials,
      createClient: () {
        final client = ImportClient();
        clients.add(client);
        return client;
      },
    );
    await sources.load();
  });
  tearDown(() {
    sources.dispose();
    access.dispose();
  });

  test(
    'offline partial merge preserves active client, remembered ID and scope',
    () async {
      final active = ImportClient();
      final auth = AuthController(
        client: active,
        credentials: credentials,
        servers: store,
        sources: sources,
      );
      await auth.restore();
      expect(
        await auth.connect(
          address: 'https://active.test',
          username: 'active',
          password: 'synthetic',
        ),
        isTrue,
      );
      final session = auth.session;
      final remembered = (await store.load()).lastServerId;
      final requests = active.requests;
      final result = await auth.importServers([
        draft('alice'),
        draft('alice', address: 'https://EXAMPLE.test:443/proxy/'),
        draft('bob'),
        draft('bad', address: 'ftp://invalid'),
      ]);
      expect(result.items.map((item) => item.status), [
        ServerImportStatus.added,
        ServerImportStatus.duplicate,
        ServerImportStatus.added,
        ServerImportStatus.failed,
      ]);
      expect(identical(auth.session, session), isTrue);
      expect(active.requests, requests);
      expect(clients, isEmpty);
      expect((await store.load()).lastServerId, remembered);
      final imported = auth.savedServers.where(
        (server) => server.identityPending,
      );
      expect(imported.length, 2);
      for (final server in imported) {
        expect(server.id, isNot('remote'));
        expect(server.verifiedServerId, isNull);
        expect(server.libraryIds, isEmpty);
        expect(server.scopeKnown, isFalse);
      }
      expect(
        (await auth.importServers([
          draft('alice'),
          draft('bob'),
        ])).count(ServerImportStatus.duplicate),
        2,
      );
      auth.dispose();
    },
  );

  test(
    'same-address accounts authenticate independently using saved passwords',
    () async {
      final result = await ServerImportService(
        sources,
      ).commit([draft('alice'), draft('bob')]);
      final first = await sources.ensureSession(result.items[0].serverId!);
      final second = await sources.ensureSession(result.items[1].serverId!);
      expect(first.account.verifiedServerId, 'remote');
      expect(second.account.verifiedServerId, 'remote');
      expect(
        first.account.configuredServerId,
        isNot(second.account.configuredServerId),
      );
      expect(first.client.accessToken, 'token-alice');
      expect(second.client.accessToken, 'token-bob');
      expect(first.client, isNot(same(second.client)));
      expect(
        sources.project(AccessRegion.ordinary).every((s) => !s.identityPending),
        isTrue,
      );
      expect(
        () => sources.permit(first.account, libraryId: 'movies'),
        throwsStateError,
      );
    },
  );

  test(
    'token import is verified on first connection and remote mismatch stays rejected',
    () async {
      final result = await sources.importServers([
        draft(
          'alice',
          credentials: const StoredCredentials(
            accessToken: 'synthetic-token',
            userId: 'user-alice',
            username: 'alice',
          ),
        ),
      ]);
      final id = result.items.single.serverId!;
      final session = await sources.ensureSession(id);
      expect(session.account.userId, 'user-alice');
      expect(clients.single.requests, 2);
      sources.dispose();
      sources = SourceSessionRegistry(
        access: access,
        store: store,
        credentials: credentials,
        createClient: () => ImportClient()..identity = 'impostor',
      );
      await sources.load();
      await expectLater(sources.authenticate(id), throwsStateError);
      expect((await credentials.read(id))!.accessToken, 'synthetic-token');
    },
  );

  test('missing or invalid credentials retain pending configuration', () async {
    final result = await sources.importServers([
      draft('missing', password: false),
      draft(
        'expired',
        credentials: const StoredCredentials(
          accessToken: '',
          userId: '',
          username: 'expired',
          password: 'wrong',
        ),
      ),
    ]);
    for (final item in result.items) {
      await expectLater(
        sources.ensureSession(item.serverId!),
        throwsA(anything),
      );
    }
    expect(sources.project(AccessRegion.ordinary).length, 2);
    expect(
      sources.project(AccessRegion.ordinary).every((s) => s.identityPending),
      isTrue,
    );
  });

  for (final credentialFailure in [true, false]) {
    test(
      '${credentialFailure ? 'credential' : 'configuration'} write rolls back and later records survive',
      () async {
        credentials.failNext = credentialFailure;
        store.failNext = !credentialFailure;
        final result = await sources.importServers([
          draft('failed'),
          draft('success'),
        ]);
        expect(result.items.first.reason, ServerImportReason.persistenceFailed);
        expect(result.items.last.status, ServerImportStatus.added);
        expect(await credentials.read(credentials.written.first), isNull);
        expect((await store.load()).servers.single.username, 'success');
        expect(
          sources.project(AccessRegion.ordinary).single.username,
          'success',
        );
      },
    );
  }

  test('private records never pass through the ordinary projection', () async {
    final rejected = await sources.importServers([
      draft('private', isPrivate: true),
    ]);
    expect(rejected.items.single.status, ServerImportStatus.skipped);
    expect(credentials.written, isEmpty);
    await access.setPin('1234', '1234', (_) async {});
    await access.unlock('1234');
    final added = await sources.importServers([
      draft('private', isPrivate: true),
    ], region: AccessRegion.private);
    expect(added.items.single.status, ServerImportStatus.added);
    expect(sources.project(AccessRegion.ordinary), isEmpty);
    expect(sources.project(AccessRegion.private).length, 1);
    await access.lock();
    expect(sources.project(AccessRegion.private), isEmpty);
    expect(
      (await sources.importServers([
        draft('private', isPrivate: true),
      ], region: AccessRegion.private)).items.single.reason,
      ServerImportReason.privateAccessRequired,
    );
  });

  for (final duringCredentials in [true, false]) {
    test(
      'lock during ${duringCredentials ? 'credential' : 'configuration'} IO revokes import and rolls back',
      () async {
        await access.setPin('1234', '1234', (_) async {});
        await access.unlock('1234');
        final started = Completer<void>();
        final release = Completer<void>();
        if (duringCredentials) {
          credentials.started = started;
          credentials.gate = release;
        } else {
          store.started = started;
          store.gate = release;
        }
        final pending = sources.importServers([
          draft('private', isPrivate: true),
        ], region: AccessRegion.private);
        await started.future;
        expect(sources.project(AccessRegion.private), isEmpty);
        final locking = access.lock();
        release.complete();
        final result = await pending;
        await locking;
        expect(result.items.single.reason, ServerImportReason.accessRevoked);
        expect((await store.load()).servers, isEmpty);
        expect(await credentials.read(credentials.written.single), isNull);
      },
    );
  }

  test(
    'query and embedded credentials are reported, never silently stripped',
    () async {
      final result = await sources.importServers([
        draft('alice', address: 'https://example.test/proxy?key=synthetic'),
        draft('bob', address: 'https://user:synthetic@example.test'),
      ]);
      expect(
        result.items.every(
          (item) =>
              item.reason == ServerImportReason.unsupportedConnectionOptions,
        ),
        isTrue,
      );
      expect((await store.load()).servers, isEmpty);
    },
  );

  test(
    'unknown accounts are not collapsed by display name or address',
    () async {
      final result = await sources.importServers([
        draft('', password: false),
        draft('', password: false),
        draft('Alice'),
        draft('alice'),
      ]);
      expect(result.count(ServerImportStatus.added), 4);
    },
  );

  test(
    'ordinary connect verifies the existing imported configuration in place',
    () async {
      final auth = AuthController(
        client: ImportClient(),
        credentials: credentials,
        servers: store,
        sources: sources,
      );
      await auth.restore();
      final imported = await auth.importServers([draft('alice')]);
      final id = imported.items.single.serverId!;
      expect(
        await auth.connect(
          address: 'https://example.test/proxy',
          username: 'alice',
          password: 'synthetic',
        ),
        isTrue,
      );
      expect(auth.savedServers.single.id, id);
      expect(auth.session!.server.verifiedServerId, 'remote');
      expect((await store.load()).servers.single.identityPending, isFalse);
      expect((await store.load()).servers.single.verifiedServerId, 'remote');
      await auth.appendLines(['https://backup.test/proxy']);
      final otherLine = auth.savedServers.single.lines.last;
      await auth.switchTo(id, lineId: otherLine.id);
      expect(auth.lineSwitchFailure, isNull);
      expect(auth.client.baseUrl.toString(), otherLine.address);
      auth.dispose();
    },
  );

  test(
    'switch connects pending password account without disturbing another source',
    () async {
      final auth = AuthController(
        client: ImportClient(),
        credentials: credentials,
        servers: store,
        sources: sources,
      );
      await auth.restore();
      final result = await auth.importServers([draft('alice'), draft('bob')]);
      await auth.switchTo(result.items.first.serverId!);
      expect(auth.session!.userId, 'user-alice');
      final first = await sources.ensureSession(result.items.first.serverId!);
      final permit = sources.permit(first.account, sessionOnly: true);
      await auth.switchTo(result.items.last.serverId!);
      expect(auth.session!.userId, 'user-bob');
      expect(permit.isValid, isTrue);
      expect(first.client.accessToken, 'token-alice');
      final remembered = (await store.load()).lastServerId;
      await auth.restore();
      expect(auth.session!.server.id, remembered);
      auth.dispose();
    },
  );

  test(
    'expired imported token can use its password, without changing account identity',
    () async {
      sources.dispose();
      sources = SourceSessionRegistry(
        access: access,
        store: store,
        credentials: credentials,
        createClient: () => ImportClient()..expired = true,
      );
      await sources.load();
      final result = await sources.importServers([
        draft(
          'alice',
          credentials: const StoredCredentials(
            accessToken: 'expired',
            userId: 'user-alice',
            username: 'alice',
            password: 'synthetic',
          ),
        ),
      ]);
      final id = result.items.single.serverId!;
      final session = await sources.ensureSession(id);
      expect(session.account.userId, 'user-alice');
      expect((await credentials.read(id))!.accessToken, 'token-alice');
      final wrongAccount = await sources.importServers([
        draft(
          'bob',
          credentials: const StoredCredentials(
            accessToken: 'expired',
            userId: 'different-user',
            username: 'bob',
            password: 'synthetic',
          ),
        ),
      ]);
      await expectLater(
        sources.ensureSession(wrongAccount.items.single.serverId!),
        throwsStateError,
      );
      expect(
        (await credentials.read(
          wrongAccount.items.single.serverId!,
        ))!.accessToken,
        'expired',
      );
    },
  );

  test(
    'independent login verifies a credential-free configuration and records username',
    () async {
      final result = await sources.importServers([draft('', password: false)]);
      final id = result.items.single.serverId!;
      await sources.login(id, 'alice', 'synthetic');
      final saved = sources.project(AccessRegion.ordinary).single;
      expect(saved.id, id);
      expect(saved.username, 'alice');
      expect(saved.identityPending, isFalse);
      expect(saved.verifiedServerId, 'remote');
      expect((await sources.ensureSession(id)).account.userId, 'user-alice');
    },
  );

  test(
    'pending identity authentication cannot revive a configuration deleted during IO',
    () async {
      final result = await sources.importServers([draft('alice')]);
      final id = result.items.single.serverId!;
      final gate = Completer<void>();
      final started = Completer<void>();
      sources.dispose();
      sources = SourceSessionRegistry(
        access: access,
        store: store,
        credentials: credentials,
        createClient: () => ImportClient()
          ..gate = gate
          ..started = started,
      );
      await sources.load();
      await sources.ordinaryStore.load();
      final pending = sources.ensureSession(id);
      final rejected = expectLater(pending, throwsStateError);
      await started.future;
      await sources.ordinaryStore.save(const ServerListSnapshot(servers: []));
      gate.complete();
      await rejected;
      expect((await store.load()).servers, isEmpty);
      expect((await credentials.read(id))!.accessToken, isEmpty);
    },
  );

  test(
    'manual connect does not overwrite another account on the same remote',
    () async {
      final auth = AuthController(
        client: ImportClient(),
        credentials: credentials,
        servers: store,
        sources: sources,
      );
      await auth.restore();
      for (final user in ['alice', 'bob', 'alice']) {
        expect(
          await auth.connect(
            address: 'https://example.test',
            username: user,
            password: 'synthetic',
          ),
          isTrue,
        );
      }
      expect(auth.savedServers.length, 2);
      for (final server in auth.savedServers) {
        expect((await credentials.read(server.id))!.username, server.username);
        expect(server.verifiedServerId, 'remote');
      }
      auth.dispose();
    },
  );
}
