import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';

import '../plex/fake_plex.dart';

const device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'preference',
  deviceId: 'test-device',
  version: '1',
);

void main() {
  test(
    'scoped saved second version and quality preserve Part 2 resume and track intent',
    () async {
      final fake = FakePlex()
        ..defaultSubtitleSelected = true
        ..subtitleCodec = 'ass';
      await fake.start();
      addTearDown(fake.close);
      final original = Map<String, dynamic>.from(
        (fake.movie['Media'] as List).first as Map,
      );
      final alternate = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(original)) as Map,
      )..['id'] = 8;
      fake.mediaVersions = [original, alternate];
      final secrets = <String, Map<String, dynamic>>{};
      final authentication = PlexAuthentication(
        device: device,
        accountUrl: fake.url,
        homeUrl: fake.url,
        readCredential: (ref) async => secrets[ref],
        writeCredential: (ref, value) async {
          secrets[ref] = value;
        },
        deleteCredential: (ref) async {
          secrets.remove(ref);
        },
      );
      final login = await authentication.begin(AuthorizationMethod.browserPin);
      fake.authorized = true;
      await login.poll();
      final cloud =
          ((await login.exchange()) as CloudAuthorizationGrant).account;
      final resource = (await authentication.discoverResources(cloud)).single;
      final token =
          secrets[resource.resourceCredentialRef]!['accessToken'] as String;
      final servers = MemoryServerListStore();
      final credentials = MemoryCredentialStore();
      final registry = SourceSessionRegistry(
        access: RegionAccessController(),
        store: servers,
        credentials: credentials,
        createClient: () => PlexClient(device: device),
        createProviderClient: (_) => PlexClient(device: device),
        sessionIdentityVerifier: (server, stored, attached) async {
          final proof = await authentication.verifyResourceIdentity(
            cloudCredentialRef: server.cloudCredentialRef!,
            resourceCredentialRef: server.resourceCredentialRef!,
            cloudAccountId: server.cloudAccountId!,
            serverId: server.verifiedServerId!,
            userId: stored.userId,
            resourceToken: stored.accessToken,
            connection: Uri.parse(server.baseUrl),
          );
          (attached as PlexClient).bindVerifiedIdentity(proof);
        },
      );
      await registry.load();
      final transaction = await registry.beginAuthorization(
        serviceType: MediaServerType.plex,
        region: AccessRegion.ordinary,
      );
      final session = await registry.commitAuthorization(
        transaction,
        server: SavedServer(
          id: transaction.id,
          name: 'Plex',
          username: 'Owner',
          serviceType: MediaServerType.plex,
          verifiedServerId: resource.server.id,
          cloudAccountId: cloud.id,
          cloudCredentialRef: cloud.credentialRef,
          resourceCredentialRef: resource.resourceCredentialRef,
          scopeKnown: true,
          libraryIds: const ['section:1'],
          lines: [ServerLine(id: 'local', address: fake.url.toString())],
        ),
        value: StoredCredentials(
          accessToken: token,
          userId: resource.user.id,
          username: 'Owner',
          serviceType: MediaServerType.plex,
          cloudAccountId: cloud.id,
          cloudCredentialRef: cloud.credentialRef,
          resourceCredentialRef: resource.resourceCredentialRef,
        ),
      );
      await registry.configureScope(
        transaction.id,
        participates: true,
        libraryIds: {'section:1'},
      );
      final auth = AuthController(
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
        auth.dispose();
      });
      final runtime = PlaybackRuntime(auth: auth, history: history);
      final work = SourceReference(account: session.account, itemId: '42');
      final selected = SourceReference(
        account: session.account,
        itemId: '42',
        mediaSourceId: '8',
      );
      await history.savePreference(
        SourcePreference(
          owner: work,
          target: selected,
          libraryId: 'section:1',
          lineId: 'local',
          settings: const PlayerSeriesPreference(
            mediaSourceId: '8',
            maxStreamingBitrate: 8000000,
            audioStreamIndex: 22,
            audioLanguage: 'eng',
            subtitleOff: true,
          ),
        ),
      );
      final previous = await history.beginSession(
        source: selected,
        work: work,
        libraryId: 'section:1',
      );
      final observed = await history.observe(
        session: previous,
        eventSequence: 1,
        positionTicks: 750000000,
        actuallyPlaying: true,
        timeline: const WatchTimeline(durationTicks: 1200000000),
      );
      history.endSession(previous);
      final backend = FakeVideoBackend(duration: const Duration(seconds: 60));
      final player = PlayerController(
        client: auth.client,
        itemId: '42',
        backend: backend,
        window: PlayerWindow(),
        runtime: runtime,
        // The history entry supplies only position; version, bitrate, and tracks
        // must be recovered by the actual source-scoped preference consumer.
        startPosition: Duration(microseconds: observed!.positionTicks ~/ 10),
        openRequest: PlayerOpenRequest(
          itemId: '42',
          source: work,
          libraryId: 'section:1',
        ),
        settingsStore: MemoryPlayerSettingsStore(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      );
      addTearDown(() async {
        await player.disposeAsync();
        player.dispose();
      });
      final before = fake.requests.length;
      await player.start();
      expect(
        player.error,
        isNull,
        reason:
            '${player.disconnectDetail}; ${player.loadFailure}; '
            '${fake.requests.skip(before).map((r) => '${r.path} ${r.query}').toList()}',
      );
      expect(player.resolved!.mediaSource.id, '8');
      expect(player.resolved!.partIndex, 1);
      expect(player.position, const Duration(seconds: 75));
      expect(player.resolved!.outputBitrate, 8000000);
      expect(player.audioStreamIndex, 22);
      expect(player.subtitleStreamIndex, isNull);
      expect(backend.subtitleOff, isTrue);
      final decisions = fake.requests
          .skip(before)
          .where((request) => request.path.endsWith('/decision'))
          .toList();
      expect(decisions, isNotEmpty);
      final decision = decisions.last.query;
      expect(decision['mediaIndex'], '1');
      expect(decision['partIndex'], '1');
      expect(decision['offset'], '15.0');
      expect(fake.selectedStreams['102']?['audioStreamID'], 22);
      expect(decision['subtitles'], 'none');
      expect(decision['videoBitrate'], '8000');
    },
  );
}
