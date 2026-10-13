import '../helpers/region_access_fixture.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/playback.dart';
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

const _fixtureDevice = device;

class _RecordingPlexClient extends PlexClient {
  _RecordingPlexClient(this.reports) : super(device: _fixtureDevice);
  final List<PlaybackReport> reports;
  @override
  Future<void> reportPlaying(PlaybackReport report) async {
    reports.add(report);
    await super.reportPlaying(report);
  }

  @override
  Future<void> reportProgress(PlaybackReport report) async {
    reports.add(report);
    await super.reportProgress(report);
  }
}

class _LimitedBackend extends FakeVideoBackend
    implements VideoBackendCapabilities {
  _LimitedBackend() : super(duration: const Duration(seconds: 60));
  @override
  Future<PlaybackCapabilities> playbackCapabilities(
    int maxStreamingBitrate,
  ) async => const PlaybackCapabilities(h264: true, aac: true);
}

Map<String, dynamic> copyVersion(FakePlex fake) => Map<String, dynamic>.from(
  jsonDecode(jsonEncode((fake.movie['Media'] as List).first)) as Map,
);

Future<PlayerController> savedPreferencePlayer(
  FakePlex fake, {
  required String version,
  required PlayerSeriesPreference settings,
  required Future<void> Function(
    PlayerController,
    List<PlaybackReport>,
    FakeVideoBackend,
  )
  check,
}) async {
  final fixture = await scopedFixture(fake);
  await fixture.runtime.history.savePreference(
    SourcePreference(
      owner: fixture.work,
      target: SourceReference(
        account: fixture.account,
        itemId: '42',
        mediaSourceId: version,
      ),
      libraryId: 'section:1',
      lineId: 'local',
      settings: settings,
    ),
  );
  final backend = _LimitedBackend();
  final player = PlayerController(
    client: fixture.runtime.auth.client,
    itemId: '42',
    backend: backend,
    window: PlayerWindow(),
    runtime: fixture.runtime,
    autoResume: false,
    settingsStore: MemoryPlayerSettingsStore(),
    snapshotStore: MemoryPlaybackSessionSnapshotStore(),
    openRequest: PlayerOpenRequest(
      itemId: '42',
      source: fixture.work,
      libraryId: 'section:1',
    ),
  );
  addTearDown(() async {
    await player.disposeAsync();
    player.dispose();
  });
  await player.start();
  await check(player, fixture.reports, backend);
  return player;
}

Future<
  ({
    PlaybackRuntime runtime,
    SourceAccount account,
    SourceReference work,
    List<PlaybackReport> reports,
  })
>
scopedFixture(FakePlex fake) async {
  final reports = <PlaybackReport>[];
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
  final cloud = ((await login.exchange()) as CloudAuthorizationGrant).account;
  final resource = (await authentication.discoverResources(cloud)).single;
  final token =
      secrets[resource.resourceCredentialRef]!['accessToken'] as String;
  final servers = MemoryServerListStore();
  final credentials = MemoryCredentialStore();
  final registry = SourceSessionRegistry(
    access: TestRegionAccessController(),
    store: servers,
    credentials: credentials,
    createClient: () => _RecordingPlexClient(reports),
    createProviderClient: (_) => _RecordingPlexClient(reports),
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
    client: _RecordingPlexClient(reports),
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
  return (
    runtime: runtime,
    account: session.account,
    work: work,
    reports: reports,
  );
}

void main() {
  test(
    'saved exact second audio ID agrees across Plex transcode selection display and report',
    () async {
      final fake = FakePlex();
      await fake.start();
      addTearDown(fake.close);
      final media = copyVersion(fake);
      final part = (media['Part'] as List).first as Map;
      final streams = part['Stream'] as List;
      final firstAudio = Map<String, dynamic>.from(
        streams.firstWhere((s) => (s as Map)['streamType'] == 2) as Map,
      )..['title'] = 'Same stereo';
      streams.removeWhere((s) => (s as Map)['streamType'] == 2);
      streams.addAll([
        firstAudio,
        {...firstAudio, 'id': 14, 'selected': false},
      ]);
      fake.mediaVersions = [media];
      await savedPreferencePlayer(
        fake,
        version: '7',
        settings: const PlayerSeriesPreference(
          mediaSourceId: '7',
          audioStreamIndex: 14,
          audioLanguage: 'eng',
          audioTitle: 'Same stereo',
          subtitleOff: true,
          maxStreamingBitrate: 8000000,
        ),
        check: (player, reports, backend) async {
          expect(
            player.error,
            isNull,
            reason: '${player.loadFailure}; ${player.disconnectDetail}',
          );
          expect(player.resolved!.playMethod, PlayMethod.transcode);
          expect(fake.selectedStreams['101']?['audioStreamID'], 14);
          expect(player.audioStreamIndex, 14);
          for (var n = 0; n < 50 && reports.isEmpty; n++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(reports, isNotEmpty);
          expect(reports.last.audioStreamIndex, 14);
        },
      );
    },
  );

  test(
    'saved subtitle off bypasses forbidden default ASS burn before any decision',
    () async {
      final fake = FakePlex()
        ..defaultSubtitleSelected = true
        ..subtitleCodec = 'ass'
        ..transcodeDenied = true;
      await fake.start();
      addTearDown(fake.close);
      await savedPreferencePlayer(
        fake,
        version: '7',
        settings: const PlayerSeriesPreference(
          mediaSourceId: '7',
          subtitleOff: true,
        ),
        check: (player, reports, backend) async {
          expect(
            player.error,
            isNull,
            reason: '${player.loadFailure}; ${player.disconnectDetail}',
          );
          expect(player.resolved!.playMethod, PlayMethod.directPlay);
          expect(player.subtitleStreamIndex, isNull);
          expect(backend.subtitleOff, isTrue);
          expect(
            fake.requests.where((r) => r.path.endsWith('/decision')),
            isEmpty,
          );
          expect(fake.sessions, isEmpty);
        },
      );
    },
  );

  for (final failure in ['unsupported-video', 'missing-part']) {
    test(
      'saved playable version bypasses $failure default before any decision',
      () async {
        final fake = FakePlex()..transcodeDenied = true;
        await fake.start();
        addTearDown(fake.close);
        final invalid = copyVersion(fake);
        final playable = copyVersion(fake)..['id'] = 8;
        if (failure == 'missing-part') {
          invalid['Part'] = <Map<String, dynamic>>[];
        } else {
          final part = (invalid['Part'] as List).first as Map;
          for (final stream in part['Stream'] as List) {
            if ((stream as Map)['streamType'] == 1) stream['codec'] = 'hevc';
          }
        }
        fake.mediaVersions = [invalid, playable];
        await savedPreferencePlayer(
          fake,
          version: '8',
          settings: const PlayerSeriesPreference(
            mediaSourceId: '8',
            subtitleOff: true,
          ),
          check: (player, reports, backend) async {
            expect(
              player.error,
              isNull,
              reason: '${player.loadFailure}; ${player.disconnectDetail}',
            );
            expect(player.resolved!.mediaSource.id, '8');
            expect(player.resolved!.playMethod, PlayMethod.directPlay);
            expect(
              fake.requests.where((r) => r.path.endsWith('/decision')),
              isEmpty,
            );
            expect(fake.sessions, isEmpty);
          },
        );
      },
    );
  }
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
      final fixture = await scopedFixture(fake);
      final runtime = fixture.runtime;
      final history = runtime.history;
      final auth = runtime.auth;
      final work = fixture.work;
      final selected = SourceReference(
        account: fixture.account,
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
