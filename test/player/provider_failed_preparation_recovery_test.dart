import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/plex/plex_client.dart';

import '../plex/fake_plex.dart';

const device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'cold-recovery',
  deviceId: 'cold-recovery',
  version: '1',
);

void main() {
  test(
    'different-item failed Plex preparation survives real cold runtime recovery',
    () async {
      final fake = FakePlex();
      await fake.start();
      addTearDown(fake.close);
      // Reuse the fixture's complete movie representation for a second item.
      // Only metadata is aliased: real decision/start/stop HTTP remains unchanged.
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.uri.path.endsWith('/library/metadata/43')) {
                options.extra['nextItem'] = true;
                options.path = options.path.replaceFirst(
                  '/metadata/43',
                  '/metadata/42',
                );
              }
              handler.next(options);
            },
            onResponse: (response, handler) {
              if (response.requestOptions.extra['nextItem'] == true) {
                final container =
                    (response.data as Map)['MediaContainer'] as Map;
                final rows = container['Metadata'] as List;
                rows[0] = {...(rows[0] as Map), 'ratingKey': '43'};
              }
              handler.next(response);
            },
          ),
        );
      final client = PlexClient(device: device, dio: dio)
        ..attachSession(
          baseUrl: fake.url,
          accessToken: 'owner-resource',
          userId: '1',
        );
      const account = SourceAccount(
        region: AccessRegion.ordinary,
        configuredServerId: 'source',
        verifiedServerId: 'server-a',
        userId: '1',
        serviceType: MediaServerType.plex,
      );
      const originalSource = SourceReference(account: account, itemId: '42');
      expect(originalSource.mediaSourceId, isNull);
      final snapshots = MemoryPlaybackSessionSnapshotStore();
      final player = PlayerController(
        client: client,
        itemId: '42',
        backend: FakeVideoBackend(duration: const Duration(seconds: 60)),
        window: PlayerWindow(),
        autoResume: false,
        openRequest: const PlayerOpenRequest(
          itemId: '42',
          source: originalSource,
          libraryId: 'section:1',
          subtitleOff: true,
        ),
        settingsStore: MemoryPlayerSettingsStore(),
        snapshotStore: snapshots,
      );
      addTearDown(() async {
        await player.disposeAsync();
        player.dispose();
      });
      await player.start();
      expect(player.error, isNull, reason: player.disconnectDetail);
      fake.transcodeDenied = true;
      fake.failStops = true;
      player.maxStreamingBitrate = 8000000;
      await player.playEpisode(
        const MediaItem(id: '43', name: 'Next item', type: 'Movie'),
      );
      expect(player.error, isNotNull);
      final saved = (await snapshots.read())!;
      final pending = saved.cleanupOnly ? saved : saved.pendingCleanups.single;
      expect(pending.cleanupOnly, isTrue);
      expect(pending.itemId, '43');
      expect(pending.source!.itemId, '43');
      expect(pending.source!.account, account);
      expect(pending.mediaSourceId, isNotEmpty);
      expect(pending.source!.mediaSourceId, pending.mediaSourceId);
      expect(fake.sessions, contains(pending.playSessionId));

      // A new registry has no acquired session, verified cloud proof or in-memory
      // lease. Recovery gets only the serialized ownership and stored resource token.
      final coldStore = MemoryPlaybackSessionSnapshotStore(
        PlaybackSessionSnapshot.fromJson(
          jsonDecode(jsonEncode(saved.toJson())),
        ),
      );
      final servers = MemoryServerListStore(
        ServerListSnapshot(
          servers: [
            SavedServer(
              id: 'source',
              name: 'Plex',
              username: 'Owner',
              serviceType: MediaServerType.plex,
              verifiedServerId: 'server-a',
              scopeKnown: true,
              libraryIds: const ['section:1'],
              lines: [ServerLine(id: 'line', address: fake.url.toString())],
            ),
          ],
        ),
      );
      final credentials = MemoryCredentialStore({
        'source': const StoredCredentials(
          accessToken: 'owner-resource',
          userId: '1',
          username: 'Owner',
          serviceType: MediaServerType.plex,
        ),
      });
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: servers,
        credentials: credentials,
        createClient: () => PlexClient(device: device),
        createProviderClient: (_) => PlexClient(device: device),
        sessionIdentityVerifier: (_, _, _) async =>
            throw StateError('cleanup must not authorize'),
      );
      await registry.load();
      final coldAuth = AuthController(
        client: PlexClient(device: device),
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
        coldAuth.dispose();
      });
      final runtime = PlaybackRuntime(auth: coldAuth, history: history);
      expect(runtime.canRecoverSnapshot(pending), isTrue);
      fake.failStops = false;
      final before = fake.requests.length;
      expect(
        await recoverAndroidSession(
          coldAuth.client,
          coldStore,
          runtime: runtime,
        ),
        isTrue,
      );
      expect(await coldStore.read(), isNull);
      expect(fake.sessions, isEmpty);
      final recoveryRequests = fake.requests.skip(before).toList();
      expect(recoveryRequests, isNotEmpty);
      expect(
        recoveryRequests.every((request) => request.path.endsWith('/stop')),
        isTrue,
      );
      expect(
        recoveryRequests.every(
          (request) => request.query['session'] == pending.playSessionId,
        ),
        isTrue,
      );
      expect(
        registry.sessionAccount(
          'source',
          region: AccessRegion.ordinary,
          libraryId: 'section:1',
        ),
        isNull,
      );
    },
  );
}
