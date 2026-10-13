import '../helpers/region_access_fixture.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart'
    show SourceReference;
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/playback_session_snapshot.dart';

class CleanupClient extends MediaServerClient {
  CleanupClient(this.serviceType);
  @override
  final MediaServerType serviceType;
  final reports = <PlaybackReport>[];
  final releases = <PlaybackReport>[];
  bool fail = false;
  bool failRelease = false;
  final releaseTokens = <String?>[];
  String? token;
  @override
  void Function()? onSessionExpired;
  @override
  Future<bool> Function()? onRefreshSession;
  @override
  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
    String? userAgent,
  }) => token = accessToken;
  @override
  void clearSession() => token = null;
  @override
  Future<void> reportStopped(PlaybackReport report) async {
    reports.add(report);
    if (fail) throw StateError('offline');
  }

  @override
  Future<void> releasePlayback(PlaybackReport report) async {
    releases.add(report);
    releaseTokens.add(token);
    if (failRelease) throw StateError('cleanup offline');
  }

  // Any authentication, metadata or playback negotiation is a test failure.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DelayedCredentials extends MemoryCredentialStore {
  DelayedCredentials(super.seed);
  Completer<void>? gate;
  @override
  Future<StoredCredentials?> read(String serverId) async {
    final captured = await super.read(serverId);
    await gate?.future;
    return captured;
  }
}

class RecoveryFixture {
  RecoveryFixture(this.primary, this.target, this.registry, this.runtime);
  final CleanupClient primary, target;
  final SourceSessionRegistry registry;
  final PlaybackRuntime runtime;

  static Future<RecoveryFixture> create({
    CredentialStore? credentialStore,
  }) async {
    final primary = CleanupClient(MediaServerType.emby);
    final target = CleanupClient(MediaServerType.plex);
    final servers = MemoryServerListStore(
      ServerListSnapshot(
        servers: [
          for (final type in [MediaServerType.emby, MediaServerType.plex])
            SavedServer(
              id: type.name,
              name: type.name,
              username: type.name,
              serviceType: type,
              verifiedServerId: type.name,
              scopeKnown: true,
              libraryIds: const ['library'],
              lines: [
                ServerLine(id: 'line', address: 'https://${type.name}.test'),
              ],
            ),
        ],
      ),
    );
    final credentials =
        credentialStore ??
        MemoryCredentialStore({
          for (final type in [MediaServerType.emby, MediaServerType.plex])
            type.name: StoredCredentials(
              serviceType: type,
              accessToken: 'resource-${type.name}',
              userId: type.name,
              username: type.name,
            ),
        });
    final registry = SourceSessionRegistry(
      access: TestRegionAccessController(),
      store: servers,
      credentials: credentials,
      createClient: () => primary,
      createProviderClient: (type) =>
          type == MediaServerType.plex ? target : primary,
      sessionIdentityVerifier: (_, _, _) async =>
          throw StateError('must never reauthorize cleanup'),
    );
    await registry.load();
    final auth = AuthController(
      client: primary,
      credentials: credentials,
      servers: servers,
      sources: registry,
    );
    final history = await HistoryWriter.open(
      registry: registry,
      store: MemoryHistoryStore(),
    );
    return RecoveryFixture(
      primary,
      target,
      registry,
      PlaybackRuntime(auth: auth, history: history),
    );
  }

  PlaybackSessionSnapshot snapshot(
    MediaServerType type, {
    bool cleanupOnly = false,
  }) => PlaybackSessionSnapshot(
    itemId: 'item',
    mediaSourceId: 'version',
    playSessionId: 'session-${type.name}',
    position: Duration.zero,
    baseUrl: 'https://${type.name}.test',
    userId: type.name,
    timestamp: DateTime.utc(2026),
    serviceType: type,
    cleanupOnly: cleanupOnly,
    libraryId: 'library',
    source: SourceReference(
      account: SourceAccount(
        serviceType: type,
        region: AccessRegion.ordinary,
        configuredServerId: type.name,
        verifiedServerId: type.name,
        userId: type.name,
      ),
      itemId: 'item',
      mediaSourceId: 'version',
    ),
  );

  Future<void> dispose() async {
    await runtime.history.close();
    runtime.auth.dispose();
  }
}

void main() {
  test(
    'logout during pending credential read skips the retired authority and recovers main',
    () async {
      final credentials = DelayedCredentials({
        for (final type in [MediaServerType.emby, MediaServerType.plex])
          type.name: StoredCredentials(
            serviceType: type,
            accessToken: 'resource-${type.name}',
            userId: type.name,
            username: type.name,
          ),
      });
      final fixture = await RecoveryFixture.create(
        credentialStore: credentials,
      );
      addTearDown(fixture.dispose);
      final store = MemoryPlaybackSessionSnapshotStore(
        fixture.snapshot(MediaServerType.emby).withPendingCleanups([
          fixture.snapshot(MediaServerType.plex, cleanupOnly: true),
        ]),
      );
      credentials.gate = Completer<void>();
      final recovery = recoverAndroidSession(
        fixture.primary,
        store,
        runtime: fixture.runtime,
      );
      await Future<void>.delayed(Duration.zero);
      await fixture.registry.logoutSource('plex');
      credentials.gate!.complete();
      expect(await recovery, isTrue);
      expect(fixture.target.releases, isEmpty);
      expect(fixture.primary.reports.single.playSessionId, 'session-emby');
      expect(await store.read(), isNull);
    },
  );
  test(
    'cross-provider pending cleanup retains whole snapshot and its own token on retry',
    () async {
      final primary = CleanupClient(MediaServerType.emby);
      final target = CleanupClient(MediaServerType.plex)..failRelease = true;
      final servers = MemoryServerListStore(
        ServerListSnapshot(
          servers: [
            for (final type in [MediaServerType.emby, MediaServerType.plex])
              SavedServer(
                id: type.name,
                name: type.name,
                username: type.name,
                serviceType: type,
                verifiedServerId: type.name,
                scopeKnown: true,
                libraryIds: const ['library'],
                lines: [
                  ServerLine(id: 'line', address: 'https://${type.name}.test'),
                ],
              ),
          ],
        ),
      );
      final credentials = MemoryCredentialStore({
        for (final type in [MediaServerType.emby, MediaServerType.plex])
          type.name: StoredCredentials(
            serviceType: type,
            accessToken: 'resource-${type.name}',
            userId: type.name,
            username: type.name,
          ),
      });
      final registry = SourceSessionRegistry(
        access: TestRegionAccessController(),
        store: servers,
        credentials: credentials,
        createClient: () => primary,
        createProviderClient: (type) =>
            type == MediaServerType.plex ? target : primary,
      );
      await registry.load();
      final auth = AuthController(
        client: primary,
        credentials: credentials,
        servers: servers,
        sources: registry,
      );
      final history = await HistoryWriter.open(
        registry: registry,
        store: MemoryHistoryStore(),
      );
      addTearDown(() async {
        await history.close();
        auth.dispose();
      });
      final runtime = PlaybackRuntime(auth: auth, history: history);
      PlaybackSessionSnapshot snapshot(
        MediaServerType type, {
        bool cleanupOnly = false,
      }) => PlaybackSessionSnapshot(
        itemId: 'item',
        mediaSourceId: 'version',
        playSessionId: 'session-${type.name}',
        position: Duration.zero,
        baseUrl: 'https://${type.name}.test',
        userId: type.name,
        timestamp: DateTime.utc(2026),
        serviceType: type,
        cleanupOnly: cleanupOnly,
        source: SourceReference(
          account: SourceAccount(
            serviceType: type,
            region: AccessRegion.ordinary,
            configuredServerId: type.name,
            verifiedServerId: type.name,
            userId: type.name,
          ),
          itemId: 'item',
          mediaSourceId: 'version',
        ),
        libraryId: 'library',
      );
      final original = snapshot(MediaServerType.emby).withPendingCleanups([
        snapshot(MediaServerType.plex, cleanupOnly: true),
      ]);
      final store = MemoryPlaybackSessionSnapshotStore(original);
      await expectLater(
        recoverAndroidSession(primary, store, runtime: runtime),
        throwsStateError,
      );
      expect((await store.read())!.pendingCleanups, hasLength(1));
      expect((await store.read())!.cleanupOnly, isTrue);
      expect(primary.reports.single.playSessionId, 'session-emby');
      expect(target.reports, isEmpty);
      target.failRelease = false;
      expect(
        await recoverAndroidSession(primary, store, runtime: runtime),
        isTrue,
      );
      expect(await store.read(), isNull);
      expect(target.releaseTokens, ['resource-plex', 'resource-plex']);
      expect(target.releases.map((r) => r.playSessionId), [
        'session-plex',
        'session-plex',
      ]);
      expect(primary.reports.single.playSessionId, 'session-emby');
      expect(primary.releaseTokens, ['resource-emby', 'resource-emby']);
    },
  );
  for (final revocation in [
    'scope',
    'logout',
    'delete',
    'private-generation',
  ]) {
    test(
      '$revocation pending owner cannot block the still authorized main session',
      () async {
        final fixture = await RecoveryFixture.create();
        addTearDown(fixture.dispose);
        var pending = fixture.snapshot(MediaServerType.plex, cleanupOnly: true);
        switch (revocation) {
          case 'scope':
            await fixture.registry.configureScope(
              'plex',
              participates: false,
              libraryIds: {},
            );
          case 'logout':
            await fixture.registry.logoutSource('plex');
          case 'delete':
            await fixture.registry.logoutSource('plex', remove: true);
          case 'private-generation':
            pending = PlaybackSessionSnapshot.fromJson({
              ...pending.toJson(),
              'source': {
                ...(pending.toJson()['source'] as Map),
                'region': 'private',
              },
              'regionGeneration': -1,
            })!;
        }
        final store = MemoryPlaybackSessionSnapshotStore(
          fixture.snapshot(MediaServerType.emby).withPendingCleanups([pending]),
        );
        expect(
          await recoverAndroidSession(
            fixture.primary,
            store,
            runtime: fixture.runtime,
          ),
          isTrue,
        );
        expect(fixture.target.releases, isEmpty);
        expect(fixture.target.reports, isEmpty);
        expect(fixture.primary.reports.single.playSessionId, 'session-emby');
        expect(await store.read(), isNull);
      },
    );
  }

  test(
    'revoked pending is pruned while a different temporary failure stays retryable',
    () async {
      final fixture = await RecoveryFixture.create();
      addTearDown(fixture.dispose);
      await fixture.registry.configureScope(
        'plex',
        participates: false,
        libraryIds: {},
      );
      fixture.primary.fail = true;
      final store = MemoryPlaybackSessionSnapshotStore(
        fixture.snapshot(MediaServerType.emby).withPendingCleanups([
          fixture.snapshot(MediaServerType.plex, cleanupOnly: true),
        ]),
      );
      await expectLater(
        recoverAndroidSession(fixture.primary, store, runtime: fixture.runtime),
        throwsStateError,
      );
      expect((await store.read())!.pendingCleanups, isEmpty);
      expect((await store.read())!.cleanupOnly, isFalse);
      fixture.primary.fail = false;
      expect(
        await recoverAndroidSession(
          fixture.primary,
          store,
          runtime: fixture.runtime,
        ),
        isTrue,
      );
      expect(await store.read(), isNull);
      expect(fixture.target.releases, isEmpty);
    },
  );
  for (final type in MediaServerType.values) {
    test(
      '${type.name} crash cleanup uses only original resource/session',
      () async {
        final client = CleanupClient(type);
        final registry = await setup(type, client);
        addTearDown(registry.dispose);
        expect(await cleanup(registry, type), isTrue);
        expect(
          client.reports.single.playSessionId,
          'jf-play-v1.opaque-original',
        );
        expect(client.releases.single, same(client.reports.single));
        expect(client.token, isNull);
        expect(
          registry.sessionAccount(
            'configured',
            region: AccessRegion.ordinary,
            libraryId: 'library',
          ),
          isNull,
        );
      },
    );
  }

  test('failure retains original cleanup identity for retry', () async {
    final client = CleanupClient(MediaServerType.plex)..fail = true;
    final registry = await setup(MediaServerType.plex, client);
    addTearDown(registry.dispose);
    await expectLater(
      cleanup(registry, MediaServerType.plex),
      throwsStateError,
    );
    client.fail = false;
    expect(await cleanup(registry, MediaServerType.plex), isTrue);
    expect(client.releases.map((r) => r.playSessionId).toSet(), {
      'jf-play-v1.opaque-original',
    });
  });

  test(
    'preflight crash only releases resource and never reports viewing',
    () async {
      final client = CleanupClient(MediaServerType.plex);
      final registry = await setup(MediaServerType.plex, client);
      addTearDown(registry.dispose);
      expect(
        await cleanup(registry, MediaServerType.plex, cleanupOnly: true),
        isTrue,
      );
      expect(client.reports, isEmpty);
      expect(
        client.releases.single.playSessionId,
        'jf-play-v1.opaque-original',
      );
    },
  );

  test(
    'wrong user, server, provider and locked region cannot clean another session',
    () async {
      final client = CleanupClient(MediaServerType.plex);
      final registry = await setup(MediaServerType.plex, client);
      addTearDown(registry.dispose);
      expect(
        await cleanup(registry, MediaServerType.plex, user: 'foreign'),
        isFalse,
      );
      await expectLater(
        cleanup(registry, MediaServerType.plex, server: 'foreign'),
        throwsStateError,
      );
      await expectLater(
        cleanup(registry, MediaServerType.jellyfin),
        throwsStateError,
      );
      await expectLater(
        cleanup(registry, MediaServerType.plex, region: AccessRegion.private),
        throwsStateError,
      );
      expect(client.reports, isEmpty);
    },
  );

  test(
    'logout during stored resource token read invalidates compensation',
    () async {
      final credentials = DelayedCredentials({
        'configured': credential(MediaServerType.plex),
      });
      final client = CleanupClient(MediaServerType.plex);
      final registry = await setup(
        MediaServerType.plex,
        client,
        credentials: credentials,
      );
      addTearDown(registry.dispose);
      credentials.gate = Completer<void>();
      final pending = cleanup(registry, MediaServerType.plex);
      await Future<void>.delayed(Duration.zero);
      final rejected = expectLater(pending, throwsStateError);
      await registry.logoutSource('configured');
      credentials.gate!.complete();
      await rejected;
      expect(client.reports, isEmpty);
    },
  );
}

StoredCredentials credential(MediaServerType type) => StoredCredentials(
  accessToken: 'resource-only',
  userId: 'user',
  username: 'user',
  serviceType: type,
);

Future<SourceSessionRegistry> setup(
  MediaServerType type,
  CleanupClient client, {
  CredentialStore? credentials,
}) async {
  final registry = SourceSessionRegistry(
    access: TestRegionAccessController(),
    store: MemoryServerListStore(
      ServerListSnapshot(
        servers: [
          SavedServer(
            id: 'configured',
            name: 'source',
            username: 'user',
            serviceType: type,
            verifiedServerId: 'server',
            scopeKnown: true,
            libraryIds: const ['library'],
            lines: const [
              ServerLine(id: 'line', address: 'https://source.test'),
            ],
          ),
        ],
      ),
    ),
    credentials:
        credentials ?? MemoryCredentialStore({'configured': credential(type)}),
    createClient: () => client,
    createProviderClient: (_) => client,
    sessionIdentityVerifier: (_, _, _) async =>
        throw StateError('cloud access forbidden'),
  );
  await registry.load();
  return registry;
}

Future<bool> cleanup(
  SourceSessionRegistry registry,
  MediaServerType type, {
  String user = 'user',
  String server = 'server',
  AccessRegion region = AccessRegion.ordinary,
  bool cleanupOnly = false,
}) => registry.recoverPlayback(
  account: SourceAccount(
    region: region,
    configuredServerId: 'configured',
    verifiedServerId: server,
    userId: user,
    serviceType: type,
  ),
  report: const PlaybackReport(
    itemId: 'item',
    mediaSourceId: 'version',
    playSessionId: 'jf-play-v1.opaque-original',
    playMethod: PlayMethod.transcode,
    position: Duration(seconds: 17),
  ),
  baseUrl: Uri.parse('https://source.test'),
  libraryId: 'library',
  cleanupOnly: cleanupOnly,
);
