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
