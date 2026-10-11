import 'package:rillight/auth/auth_controller.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/cloud_credentials.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/media_server_client.dart';

// This is an authority-contract fake, not an Emby-derived protocol adapter.
class IdentityClient extends MediaServerClient {
  IdentityClient(this.serviceType, {this.gate, this.returnedUser});
  @override
  final MediaServerType serviceType;
  final Completer<void>? gate;
  final String? returnedUser;
  @override
  Uri? baseUrl;
  @override
  String? accessToken;
  @override
  String? userId;
  @override
  String? customUserAgent;
  @override
  void Function()? onSessionExpired;
  @override
  Future<bool> Function()? onRefreshSession;
  @override
  bool get hasSession => accessToken != null;
  @override
  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
    String? userAgent,
  }) {
    this.baseUrl = baseUrl;
    this.accessToken = accessToken;
    this.userId = userId;
    customUserAgent = userAgent;
  }

  @override
  void setUserAgent(String? userAgent) => customUserAgent = userAgent;
  @override
  void clearSession() {
    baseUrl = null;
    accessToken = null;
    userId = null;
  }

  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async =>
      const PublicServerInfo(id: 'same-remote', serverName: 'same-name');
  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async {
    await gate?.future;
    return MediaUser(id: returnedUser ?? userId!, name: 'same-name');
  }

  @override
  Future<LibraryCounts> getItemCounts() async =>
      const LibraryCounts(movie: 0, series: 0, episode: 0, others: []);
  @override
  Future<void> logout() async => clearSession();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SavedServer source(
  String id,
  MediaServerType type, {
  AccessRegion region = AccessRegion.ordinary,
  String? home,
  String? cloud,
}) => SavedServer(
  id: id,
  name: 'same-name',
  username: 'same-name',
  serviceType: type,
  region: region,
  verifiedServerId: 'same-remote',
  homeUserId: home,
  cloudAccountId: cloud == null ? null : 'cloud-account',
  cloudCredentialRef: cloud,
  resourceCredentialRef: cloud == null ? null : 'resource-$id-$home',
  libraryIds: const ['library'],
  scopeKnown: true,
  lines: const [ServerLine(id: 'line', address: 'https://server.test/prefix')],
);
StoredCredentials credential(SavedServer server, {String user = 'same-user'}) =>
    StoredCredentials(
      accessToken: 'resource-token-${server.id}-$user',
      userId: user,
      username: 'same-name',
      serviceType: server.serviceType,
      cloudAccountId: server.cloudAccountId,
      cloudCredentialRef: server.cloudCredentialRef,
      homeUserId: server.homeUserId,
      resourceCredentialRef: server.resourceCredentialRef,
    );

void main() {
  test('legacy source/history default to Emby without discarding identity', () {
    final old = source('legacy-id', MediaServerType.emby).toJson()
      ..remove('serviceType');
    final restored = SavedServer.fromJson(old);
    expect(restored.serviceType, MediaServerType.emby);
    expect(restored.id, 'legacy-id');
    expect(restored.libraryIds, ['library']);
    final ref = decodeSource({
      'region': 'ordinary',
      'server': 'legacy-id',
      'verifiedServer': 'same-remote',
      'user': 'same-user',
      'item': '42',
      'version': null,
    });
    expect(ref.account.serviceType, MediaServerType.emby);
    final distinct = SourceReference(
      account: SourceAccount(
        region: AccessRegion.ordinary,
        serviceType: MediaServerType.plex,
        configuredServerId: 'legacy-id',
        verifiedServerId: 'same-remote',
        userId: 'same-user',
      ),
      itemId: '42',
    );
    expect(ref.key, isNot(distinct.key));
    expect(ref.account, isNot(distinct.account));
    expect(decodeSource(encodeSource(distinct)), distinct);
  });

  for (final corrupt in [
    '{private-secret',
    '[]',
    '{"servers":[{"id":"broken"}]}',
  ]) {
    test(
      'corrupt server file is preserved and cannot be overwritten: $corrupt',
      () async {
        final dir = await Directory.systemTemp.createTemp('source-corruption');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/servers.json');
        await file.writeAsString(corrupt);
        final store = FileServerListStore(file);
        await expectLater(store.load(), throwsFormatException);
        await expectLater(
          store.save(const ServerListSnapshot(servers: [])),
          throwsFormatException,
        );
        expect(await file.readAsString(), corrupt);
      },
    );
  }

  test(
    'corrupt credentials are an error, not missing credentials or an empty write',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'credential-corruption',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/credentials.json');
      const raw = '{"password":"secret';
      await file.writeAsString(raw);
      final store = FileCredentialStore(file);
      await expectLater(store.read('missing'), throwsFormatException);
      await expectLater(
        store.write('new', credential(source('new', MediaServerType.plex))),
        throwsFormatException,
      );
      await expectLater(store.delete('missing'), throwsFormatException);
      expect(await file.readAsString(), raw);
    },
  );

  test(
    'secure legacy credentials copy to versioned key and malformed secure data never falls back',
    () async {
      final old = credential(source('legacy', MediaServerType.emby)).toJson()
        ..remove('version')
        ..remove('serviceType');
      final values = {'rillight.emby.v1.legacy': jsonEncode(old)};
      final store = SecureCredentialStore(
        fallback: MemoryCredentialStore(),
        readSecure: (key) async => values[key],
        writeSecure: (key, value) async {
          values[key] = value;
        },
        deleteSecure: (key) async {
          values.remove(key);
        },
      );
      expect((await store.read('legacy'))!.userId, 'same-user');
      expect(values, contains('rillight.media.v2.legacy'));
      expect(values, contains('rillight.emby.v1.legacy'));
      values['rillight.media.v2.legacy'] = '{secret';
      await expectLater(store.read('legacy'), throwsFormatException);
      expect(values['rillight.media.v2.legacy'], '{secret');
    },
  );

  test(
    'concurrent file writes preserve cloud, device and source credentials',
    () async {
      final dir = await Directory.systemTemp.createTemp('credential-parallel');
      addTearDown(() => dir.delete(recursive: true));
      final backend = FileCredentialStore(File('${dir.path}/creds.json'));
      final cloud = CloudCredentialStore(backend);
      final material = {
        'kind': 'device',
        'deviceId': 'stable-device',
        'signingKey': {'seed': 'synthetic', 'kid': 'key-1', 'x': 'public'},
        'extra': [1, 2],
      };
      await Future.wait([
        cloud.writeCredential('device', material),
        cloud.writeCredential('cloud', {
          'kind': 'cloud',
          'accountId': 'account',
          'accessToken': 'grant',
        }),
        backend.write(
          'source',
          credential(source('source', MediaServerType.jellyfin)),
        ),
      ]);
      expect(await cloud.readCredential('device'), material);
      expect((await cloud.read('device'))!.toJson()['extra'], [1, 2]);
      expect(
        (await backend.read('source'))!.serviceType,
        MediaServerType.jellyfin,
      );
    },
  );

  test(
    'all three providers isolate identical remote IDs and sessionOnly scope',
    () async {
      final saved = [
        for (final type in MediaServerType.values) source(type.name, type),
      ];
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: MemoryServerListStore(ServerListSnapshot(servers: saved)),
        credentials: MemoryCredentialStore({
          for (final s in saved) s.id: credential(s),
        }),
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: IdentityClient.new,
      );
      addTearDown(registry.dispose);
      await registry.load();
      final sessions = [
        for (final s in saved) await registry.authenticate(s.id),
      ];
      expect(
        sessions
            .map((s) => SourceReference(account: s.account, itemId: '42').key)
            .toSet(),
        hasLength(3),
      );
      final old = registry.permit(sessions.last.account);
      await registry.configureScope(
        saved.last.id,
        participates: false,
        libraryIds: {},
      );
      expect(old.isValid, isFalse);
      expect(
        registry.permit(sessions.last.account, sessionOnly: true).isValid,
        isTrue,
      );
      expect(() => registry.permit(sessions.last.account), throwsStateError);
    },
  );

  test(
    'provider mismatch rejects legacy factory and mismatched stored credentials',
    () async {
      final saved = source('jelly', MediaServerType.jellyfin);
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: MemoryServerListStore(ServerListSnapshot(servers: [saved])),
        credentials: MemoryCredentialStore({'jelly': credential(saved)}),
        createClient: () => IdentityClient(MediaServerType.emby),
      );
      addTearDown(registry.dispose);
      await registry.load();
      await expectLater(registry.ensureSession('jelly'), throwsStateError);
    },
  );

  test(
    'Home replacement revokes immediately, clears selected libraries, and retains shared cloud',
    () async {
      final a = source(
        'a',
        MediaServerType.plex,
        cloud: 'shared',
        home: 'parent',
      );
      final b = source(
        'b',
        MediaServerType.plex,
        cloud: 'shared',
        home: 'parent',
      );
      final credentials = MemoryCredentialStore({
        'a': credential(a),
        'b': credential(b),
      });
      final cloud = CloudCredentialStore(credentials);
      await cloud.writeCredential('shared', {
        'accountId': 'cloud-account',
        'accessToken': 'cloud-token',
      });
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: MemoryServerListStore(ServerListSnapshot(servers: [a, b])),
        credentials: credentials,
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: IdentityClient.new,
      );
      addTearDown(registry.dispose);
      await registry.load();
      final parent = await registry.authenticate('a');
      final sibling = await registry.authenticate('b');
      final parentPermit = registry.permit(parent.account);
      final siblingPermit = registry.permit(sibling.account);
      final attempt = await registry.beginAuthorization(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
        configuredServerId: 'a',
      );
      expect(parentPermit.isValid, isFalse);
      await expectLater(registry.ensureSession('a'), throwsStateError);
      final child = source(
        'a',
        MediaServerType.plex,
        cloud: 'shared',
        home: 'child',
      );
      final session = await registry.commitAuthorization(
        attempt,
        server: child,
        value: credential(child, user: 'child-user'),
      );
      expect(session.account.homeUserId, 'child');
      expect(
        registry
            .project(AccessRegion.ordinary)
            .firstWhere((s) => s.id == 'a')
            .libraryIds,
        isEmpty,
      );
      expect(siblingPermit.isValid, isTrue);
      await registry.logoutSource('a', remove: true);
      expect(await cloud.readCredential('shared'), isNotNull);
      expect(siblingPermit.isValid, isTrue);
      expect(await credentials.read('a'), isNull);
      final pendingImport = await registry.beginAuthorization(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
      );
      await registry.disconnectCloudAccount('shared', cloud);
      expect(pendingImport.isValid, isFalse);
      expect(siblingPermit.isValid, isFalse);
      expect(await credentials.read('b'), isNull);
      expect(await cloud.readCredential('shared'), isNull);
    },
  );

  test(
    'private lock and cancelled attempts discard late verified user and polling results',
    () async {
      final access = RegionAccessController();
      await access.setPin('1234', '1234', (_) async {});
      await access.unlock('1234');
      final gate = Completer<void>();
      final credentials = MemoryCredentialStore();
      final store = MemoryServerListStore();
      final registry = SourceSessionRegistry(
        access: access,
        store: store,
        credentials: credentials,
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: (type) => IdentityClient(type, gate: gate),
      );
      addTearDown(registry.dispose);
      final attempt = await registry.beginAuthorization(
        serviceType: MediaServerType.jellyfin,
        region: AccessRegion.private,
      );
      final saved = source(
        attempt.id,
        MediaServerType.jellyfin,
        region: AccessRegion.private,
      );
      final commit = registry.commitAuthorization(
        attempt,
        server: saved,
        value: credential(saved),
      );
      final rejected = expectLater(commit, throwsStateError);
      await access.lock();
      gate.complete();
      await rejected;
      expect((await store.load()).servers, isEmpty);
      expect(await credentials.read(attempt.id), isNull);
      expect(registry.project(AccessRegion.private), isEmpty);
      final ordinary = await registry.beginAuthorization(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
      );
      final poll = PendingAttempt();
      final pending = ordinary.poll(poll);
      final cancelled = expectLater(pending, throwsStateError);
      ordinary.cancel();
      poll.gate.complete(AuthorizationStatus.authorized);
      await cancelled;
    },
  );

  test(
    'wrong effective user cannot commit an authorized-looking grant',
    () async {
      final store = MemoryServerListStore();
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: store,
        credentials: MemoryCredentialStore(),
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: (type) =>
            IdentityClient(type, returnedUser: 'other-user'),
      );
      addTearDown(registry.dispose);
      final attempt = await registry.beginAuthorization(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
      );
      final saved = source(attempt.id, MediaServerType.plex);
      await expectLater(
        registry.commitAuthorization(
          attempt,
          server: saved,
          value: credential(saved),
        ),
        throwsStateError,
      );
      expect((await store.load()).servers, isEmpty);
    },
  );

  test(
    'unknown legacy preferences never bind to a new Plex item with the same ID',
    () async {
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: MemoryServerListStore(),
        credentials: MemoryCredentialStore(),
        createClient: () => IdentityClient(MediaServerType.emby),
      );
      addTearDown(registry.dispose);
      await registry.load();
      final writer = await HistoryWriter.open(
        registry: registry,
        store: MemoryHistoryStore(),
      );
      addTearDown(writer.close);
      final source = SourceReference(
        account: const SourceAccount(
          region: AccessRegion.ordinary,
          serviceType: MediaServerType.plex,
          configuredServerId: 'new',
          verifiedServerId: 'same-remote',
          userId: 'same-user',
        ),
        itemId: '42',
        mediaSourceId: 'version',
      );
      expect(
        await writer.migrateLegacy(
          seriesId: '42',
          settings: const PlayerSeriesPreference(),
          candidates: [PreferenceCandidate(source, 'library')],
          inventoryComplete: true,
        ),
        PreferenceFailure.ambiguousLegacy,
      );
    },
  );

  test(
    'failed identity persistence retains credentials and configuration but cannot revive old permits',
    () async {
      final old = source(
        'a',
        MediaServerType.plex,
        home: 'parent',
        cloud: 'shared',
      );
      final store = RejectingStore(ServerListSnapshot(servers: [old]));
      final credentials = MemoryCredentialStore({'a': credential(old)});
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: store,
        credentials: credentials,
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: IdentityClient.new,
      );
      addTearDown(registry.dispose);
      await registry.load();
      final permit = registry.permit(
        (await registry.authenticate('a')).account,
      );
      final attempt = await registry.beginAuthorization(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
        configuredServerId: 'a',
      );
      final child = source(
        'a',
        MediaServerType.plex,
        home: 'child',
        cloud: 'shared',
      );
      store.reject = true;
      await expectLater(
        registry.commitAuthorization(
          attempt,
          server: child,
          value: credential(child, user: 'child'),
        ),
        throwsStateError,
      );
      expect(permit.isValid, isFalse);
      expect((await credentials.read('a'))!.homeUserId, 'parent');
      expect((await store.load()).servers.single.homeUserId, 'parent');
      expect(attempt.isValid, isFalse);
    },
  );

  test(
    'session notification removes current identity from memory and disk only',
    () async {
      final disk = IdentityCatalogDisk();
      final a = CatalogCache()..debugSetDiskStore(disk);
      final b = CatalogCache()..debugSetDiskStore(disk);
      const request = CatalogRequest('views');
      a.attachSession(
        serverId: 'same',
        userId: 'same',
        serviceType: MediaServerType.emby,
      );
      b.attachSession(
        serverId: 'same',
        userId: 'same',
        serviceType: MediaServerType.plex,
        homeUserId: 'child',
      );
      await a.write(request, {'source': 'a'});
      await b.write(request, {'source': 'b'});
      await Future.wait([a.flushPendingWrites(), b.flushPendingWrites()]);
      expect(disk.values, hasLength(2));
      await a.invalidateSession();
      expect(await a.lookup(request), isNull);
      expect(disk.values, hasLength(1));
      final restored = CatalogCache()..debugSetDiskStore(disk);
      restored.attachSession(
        serverId: 'same',
        userId: 'same',
        serviceType: MediaServerType.emby,
      );
      expect(await restored.lookup(request), isNull);
      expect((await b.lookup(request))!.json, {'source': 'b'});
      restored.attachSession(
        serverId: 'same',
        userId: 'same',
        serviceType: MediaServerType.plex,
        homeUserId: 'child',
      );
      expect((await restored.lookup(request))!.json, {'source': 'b'});
    },
  );

  final invalidFields = <String, Object?>{
    'region': 'privat',
    'participates': 'true',
    'scopeKnown': 1,
    'libraryIds': ['library', 42],
    'activeLineId': 'missing',
    'lines': [
      const ServerLine(id: 'line', address: 'https://server.test').toJson(),
      {'id': 'broken'},
    ],
  };
  for (final invalid in invalidFields.entries) {
    test(
      'explicit invalid ${invalid.key} cannot be normalized or overwrite the original',
      () async {
        final dir = await Directory.systemTemp.createTemp('invalid-source');
        addTearDown(() => dir.delete(recursive: true));
        final record = source(
          'private',
          MediaServerType.emby,
          region: AccessRegion.private,
        ).toJson();
        record[invalid.key] = invalid.value;
        final raw = jsonEncode({
          'version': 3,
          'servers': [record],
        });
        final file = File('${dir.path}/servers.json');
        await file.writeAsString(raw);
        final store = FileServerListStore(file);
        await expectLater(store.load(), throwsFormatException);
        await expectLater(
          store.save(const ServerListSnapshot(servers: [])),
          throwsFormatException,
        );
        expect(await file.readAsString(), raw);
      },
    );
  }
  for (final region in [null, 42, true]) {
    test(
      'non-string region $region is rejected instead of becoming ordinary',
      () {
        final record = source('private', MediaServerType.emby).toJson()
          ..['region'] = region;
        expect(() => SavedServer.fromJson(record), throwsFormatException);
      },
    );
  }
  test(
    'malformed and duplicate lines reject rather than silently retaining a subset',
    () {
      for (final lines in [
        [null],
        [],
        'not-a-list',
        [
          {'id': 'line', 'address': 42},
        ],
        [
          {'id': 'line', 'address': 'ftp://server.test'},
        ],
        [
          const ServerLine(id: 'line', address: 'https://server.test').toJson(),
          const ServerLine(id: 'line', address: 'https://other.test').toJson(),
        ],
      ]) {
        final record = source('a', MediaServerType.emby).toJson()
          ..['lines'] = lines;
        expect(() => SavedServer.fromJson(record), throwsFormatException);
      }
    },
  );

  for (final failedKey in ['rillight.media.v2.a', 'rillight.emby.v1.a']) {
    test(
      'partial deletion of $failedKey remains revoked after credential store restart',
      () async {
        final dir = await Directory.systemTemp.createTemp('revocation-marker');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/credentials.json');
        final a = source('a', MediaServerType.emby);
        final b = source('b', MediaServerType.emby);
        final values = {
          'rillight.emby.v1.a': jsonEncode(credential(a).toJson()),
          'rillight.media.v2.b': jsonEncode(credential(b).toJson()),
        };
        SecureCredentialStore open() => SecureCredentialStore(
          fallback: FileCredentialStore(file),
          readSecure: (key) async => values[key],
          writeSecure: (key, value) async {
            values[key] = value;
          },
          deleteSecure: (key) async {
            if (key == failedKey) {
              throw const OSError('synthetic keychain failure');
            }
            values.remove(key);
          },
        );
        final store = open();
        expect((await store.read('a'))!.userId, 'same-user');
        await expectLater(
          store.delete('a'),
          throwsA(isA<CredentialRevocationException>()),
        );
        expect(await store.read('a'), isNull);
        final restarted = open();
        expect(await restarted.read('a'), isNull);
        expect(
          (await restarted.read('b'))!.accessToken,
          credential(b).accessToken,
        );
        await restarted.write('a', credential(a, user: 'new-user'));
        expect((await restarted.read('a'))!.userId, 'new-user');
      },
    );
  }

  test(
    'ordinary logout does not roll back durable revocation when old-key deletion fails',
    () async {
      final saved = source('a', MediaServerType.emby);
      final values = {
        'rillight.emby.v1.a': jsonEncode(credential(saved).toJson()),
      };
      final fallback = MemoryCredentialStore();
      SecureCredentialStore open() => SecureCredentialStore(
        fallback: fallback,
        readSecure: (key) async => values[key],
        writeSecure: (key, value) async {
          values[key] = value;
        },
        deleteSecure: (key) async {
          if (key.contains('emby.v1')) throw const OSError('failed');
          values.remove(key);
        },
      );
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: MemoryServerListStore(ServerListSnapshot(servers: [saved])),
        credentials: open(),
        createClient: () => IdentityClient(MediaServerType.emby),
      );
      addTearDown(registry.dispose);
      await registry.load();
      final permit = registry.permit(
        (await registry.authenticate('a')).account,
      );
      final commit = await registry.beginOrdinaryCredentials('a');
      await expectLater(
        registry.commitOrdinaryCredentials(commit, null),
        throwsA(isA<CredentialRevocationException>()),
      );
      expect(permit.isValid, isFalse);
      expect(await open().read('a'), isNull);
      await expectLater(registry.ensureSession('a'), throwsStateError);
    },
  );

  test(
    'membership revocation during credential deletion restores only the still-owned source',
    () async {
      final access = RegionAccessController();
      await access.setPin('1234', '1234', (_) async {});
      await access.unlock('1234');
      final saved = source('a', MediaServerType.emby);
      final credentials = GatedDeletion({'a': credential(saved)});
      final registry = SourceSessionRegistry(
        access: access,
        store: MemoryServerListStore(ServerListSnapshot(servers: [saved])),
        credentials: credentials,
        createClient: () => IdentityClient(MediaServerType.emby),
      );
      addTearDown(registry.dispose);
      await registry.load();
      final pending = registry.commitOrdinaryCredentials(
        await registry.beginOrdinaryCredentials('a'),
        null,
      );
      final rejected = expectLater(pending, throwsStateError);
      await credentials.started.future;
      final moving = registry.move('a', AccessRegion.private);
      credentials.release.complete();
      await rejected;
      await moving;
      expect(
        (await credentials.read('a'))!.accessToken,
        credential(saved).accessToken,
      );
      expect(registry.project(AccessRegion.ordinary), isEmpty);
      expect(registry.project(AccessRegion.private).single.id, 'a');
    },
  );

  test(
    'identity verification rejection and late response cannot establish or restore a Plex session',
    () async {
      final saved = source(
        'a',
        MediaServerType.plex,
        cloud: 'cloud',
        home: 'child',
      );
      final gate = Completer<void>();
      final started = Completer<void>();
      var reject = true;
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: MemoryServerListStore(ServerListSnapshot(servers: [saved])),
        credentials: MemoryCredentialStore({'a': credential(saved)}),
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: IdentityClient.new,
        sessionIdentityVerifier: (server, stored, client) async {
          expect(server.homeUserId, 'child');
          expect(client.accessToken, stored.accessToken);
          if (reject) throw StateError('Synthetic remote identity mismatch');
          if (!started.isCompleted) started.complete();
          await gate.future;
        },
      );
      addTearDown(registry.dispose);
      await registry.load();
      await expectLater(registry.ensureSession('a'), throwsStateError);
      await expectLater(registry.authenticate('a'), throwsStateError);
      reject = false;
      final pending = registry.ensureSession('a');
      final rejected = expectLater(pending, throwsStateError);
      await started.future;
      await registry.logoutSource('a');
      gate.complete();
      await rejected;
      await expectLater(registry.ensureSession('a'), throwsStateError);
    },
  );

  test(
    'selected Plex restore requires verifier before exposing AuthSession',
    () async {
      final saved = source(
        'a',
        MediaServerType.plex,
        cloud: 'cloud',
        home: 'child',
      );
      final store = MemoryServerListStore(
        ServerListSnapshot(servers: [saved], lastServerId: 'a'),
      );
      final credentials = MemoryCredentialStore({'a': credential(saved)});
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: store,
        credentials: credentials,
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: IdentityClient.new,
        sessionIdentityVerifier: (_, _, _) async =>
            throw StateError('Synthetic invalid identity'),
      );
      final client = IdentityClient(MediaServerType.plex);
      final auth = AuthController(
        client: client,
        credentials: credentials,
        servers: store,
        sources: registry,
      );
      addTearDown(auth.dispose);
      await expectLater(auth.restore(), throwsStateError);
      expect(auth.isLoggedIn, isFalse);
      expect(client.hasSession, isFalse);
    },
  );

  test(
    'selected logout reports partial cleanup while remaining signed out and not busy',
    () async {
      final saved = source('a', MediaServerType.emby);
      final values = {
        'rillight.emby.v1.a': jsonEncode(credential(saved).toJson()),
      };
      final credentials = SecureCredentialStore(
        fallback: MemoryCredentialStore(),
        readSecure: (key) async => values[key],
        writeSecure: (key, value) async {
          values[key] = value;
        },
        deleteSecure: (key) async {
          if (key.contains('emby.v1')) throw const OSError('failed');
          values.remove(key);
        },
      );
      final store = MemoryServerListStore(
        ServerListSnapshot(servers: [saved], lastServerId: 'a'),
      );
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: store,
        credentials: credentials,
        createClient: () => IdentityClient(MediaServerType.emby),
      );
      final auth = AuthController(
        client: IdentityClient(MediaServerType.emby),
        credentials: credentials,
        servers: store,
        sources: registry,
      );
      addTearDown(auth.dispose);
      await auth.restore();
      expect(auth.isLoggedIn, isTrue);
      await auth.logout();
      expect(auth.isLoggedIn, isFalse);
      expect(auth.isBusy, isFalse);
      expect(auth.failure, isNotNull);
      expect(await credentials.read('a'), isNull);
    },
  );

  for (final deletedId in ['a', 'b']) {
    test(
      'delete $deletedId after durable revocation clears only its selected session when cleanup fails',
      () async {
        final a = source('a', MediaServerType.emby);
        final b = source('b', MediaServerType.emby);
        final values = {
          'rillight.emby.v1.a': jsonEncode(credential(a).toJson()),
          'rillight.emby.v1.b': jsonEncode(credential(b).toJson()),
        };
        final credentials = SecureCredentialStore(
          fallback: MemoryCredentialStore(),
          readSecure: (key) async => values[key],
          writeSecure: (key, value) async {
            values[key] = value;
          },
          deleteSecure: (key) async {
            if (key == 'rillight.emby.v1.$deletedId') {
              throw const OSError('synthetic cleanup failure');
            }
            values.remove(key);
          },
        );
        final store = MemoryServerListStore(
          ServerListSnapshot(servers: [a, b], lastServerId: 'a'),
        );
        final registry = SourceSessionRegistry(
          access: RegionAccessController(),
          store: store,
          credentials: credentials,
          createClient: () => IdentityClient(MediaServerType.emby),
        );
        final client = IdentityClient(MediaServerType.emby);
        final auth = AuthController(
          client: client,
          credentials: credentials,
          servers: store,
          sources: registry,
        );
        addTearDown(auth.dispose);
        await auth.restore();
        await auth.loadLibraryCounts();
        final bPermit = registry.permit(
          (await registry.authenticate('b')).account,
        );
        final notifiedSessions = <String?>[];
        auth.addListener(() => notifiedSessions.add(auth.session?.server.id));
        await expectLater(
          auth.deleteServer(deletedId),
          throwsA(isA<CredentialRevocationException>()),
        );
        expect(await credentials.read(deletedId), isNull);
        if (deletedId == 'a') {
          expect(auth.isLoggedIn, isFalse);
          expect(client.hasSession, isFalse);
          expect(client.accessToken, isNull);
          expect(auth.libraryCounts, isNull);
          expect(auth.libraryCountsServerId, isNull);
          expect(auth.failure, isNotNull);
          expect(notifiedSessions, contains(null));
          expect(bPermit.isValid, isTrue);
          expect(
            (await credentials.read('b'))!.accessToken,
            credential(b).accessToken,
          );
        } else {
          expect(auth.session!.server.id, 'a');
          expect(client.accessToken, credential(a).accessToken);
          expect(auth.libraryCounts, isNotNull);
          expect(bPermit.isValid, isFalse);
          expect(
            (await credentials.read('a'))!.accessToken,
            credential(a).accessToken,
          );
        }
        // Configuration stays available for retry when credential cleanup failed.
        expect((await store.load()).servers.map((s) => s.id), ['a', 'b']);
      },
    );
  }

  test(
    'cancelled authorization discards the verifier result before publishing a session',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final store = MemoryServerListStore();
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: store,
        credentials: MemoryCredentialStore(),
        createClient: () => IdentityClient(MediaServerType.emby),
        createProviderClient: IdentityClient.new,
        sessionIdentityVerifier: (_, _, _) async {
          started.complete();
          await gate.future;
        },
      );
      addTearDown(registry.dispose);
      final attempt = await registry.beginAuthorization(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
      );
      final saved = source(attempt.id, MediaServerType.plex);
      final pending = registry.commitAuthorization(
        attempt,
        server: saved,
        value: credential(saved),
      );
      final rejected = expectLater(pending, throwsStateError);
      await started.future;
      attempt.cancel();
      gate.complete();
      await rejected;
      expect((await store.load()).servers, isEmpty);
    },
  );

  test(
    'catalog cache separates provider and Home identities; image keys cannot collide on delimiters',
    () async {
      final cache = CatalogCache()..debugSetDiskStore(null);
      const request = CatalogRequest('views');
      cache.attachSession(
        serverId: 'same',
        userId: 'same',
        serviceType: MediaServerType.emby,
      );
      await cache.write(request, {'provider': 'emby'});
      cache.attachSession(
        serverId: 'same',
        userId: 'same',
        serviceType: MediaServerType.plex,
        homeUserId: 'parent',
      );
      expect(await cache.lookup(request), isNull);
      await cache.write(request, {'provider': 'plex'});
      cache.attachSession(
        serverId: 'same',
        userId: 'same',
        serviceType: MediaServerType.plex,
        homeUserId: 'child',
      );
      expect(await cache.lookup(request), isNull);
      expect(
        MediaImageCache.key(
          serverId: 'a|b',
          itemId: 'c',
          type: 'Primary',
          maxWidth: 100,
        ),
        isNot(
          MediaImageCache.key(
            serverId: 'a',
            itemId: 'b|c',
            type: 'Primary',
            maxWidth: 100,
          ),
        ),
      );
    },
  );
}

class PendingAttempt implements AuthorizationAttempt {
  final gate = Completer<AuthorizationStatus>();
  @override
  Future<AuthorizationStatus> poll() => gate.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RejectingStore extends MemoryServerListStore {
  RejectingStore(super.seed);
  bool reject = false;
  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    if (reject) throw StateError('Synthetic disk failure');
    await super.save(snapshot);
  }
}

class IdentityCatalogDisk implements PrefixCatalogDiskStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String body) async {
    values[key] = body;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<void> clear() async => values.clear();
  @override
  Future<void> removePrefix(String prefix) async =>
      values.removeWhere((key, _) => key.startsWith(prefix));
}

class GatedDeletion extends MemoryCredentialStore {
  GatedDeletion(super.seed);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> delete(String id) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    await super.delete(id);
  }
}
