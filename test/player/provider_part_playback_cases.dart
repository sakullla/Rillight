import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/plex/plex_client.dart';
import '../plex/fake_plex.dart';

const device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'test',
  deviceId: 'part-player',
  version: '1',
);

class _Backend extends FakeVideoBackend implements VideoBackendCapabilities {
  @override
  Future<PlaybackCapabilities> playbackCapabilities(int bitrate) async =>
      PlaybackCapabilities(h264: true, aac: true, maxStreamingBitrate: bitrate);
  _Backend() : super(duration: const Duration(seconds: 60));
  final requests = <VideoOpenRequest>[];
  Completer<void>? openGate;
  @override
  Future<void> open(VideoOpenRequest request) async {
    requests.add(request);
    await openGate?.future;
    await super.open(request);
  }
}

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 4));
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  late FakePlex fake;
  late PlexClient client;
  late _Backend backend;
  late MemoryPlaybackSessionSnapshotStore snapshots;
  PlayerController? player;
  setUp(() async {
    fake = FakePlex();
    await fake.start();
    client = PlexClient(device: device)
      ..attachSession(
        baseUrl: fake.url,
        accessToken: 'owner-resource',
        userId: '1',
      );
    backend = _Backend();
    snapshots = MemoryPlaybackSessionSnapshotStore();
  });
  tearDown(() async {
    await player?.disposeAsync();
    player?.dispose();
    player = null;
    await fake.close();
  });
  Future<PlayerController> start({int seconds = 10, int? bitrate}) async {
    final value = player = PlayerController(
      client: client,
      autoResume: seconds != 0,
      itemId: '42',
      backend: backend,
      window: PlayerWindow(),
      startPosition: Duration(seconds: seconds),
      openRequest: PlayerOpenRequest(
        itemId: '42',
        subtitleOff: true,
        maxStreamingBitrate: bitrate,
      ),
      settingsStore: MemoryPlayerSettingsStore(),
      snapshotStore: snapshots,
    );
    await value.start();
    expect(value.error, isNull, reason: value.disconnectDetail);
    return value;
  }

  test(
    'direct Plex playback offers and confirms actual negotiated qualities',
    () async {
      final value = await start(seconds: 75);
      expect(value.resolved!.playMethod, PlayMethod.directPlay);
      expect(value.availableBitrates, contains(8000000));
      await value.togglePlay();
      expect(value.isPlaying, false);
      await value.setMaxBitrate(8000000);
      expect(value.trackFailure, isNull);
      expect(value.maxStreamingBitrate, 8000000);
      expect(value.resolved!.outputBitrate, 8000000);
      expect(value.position, const Duration(seconds: 75));
      expect(value.isPlaying, false);
      fake.decisionBitrateKbps = 4000;
      await value.setMaxBitrate(4000000);
      expect(value.trackFailure, isNull);
      expect(value.maxStreamingBitrate, 4000000);
      expect(value.resolved!.outputBitrate, 4000000);
      expect(value.position, const Duration(seconds: 75));
      expect(value.resolved!.partIndex, 1);
    },
  );
  for (final returnedBitrate in <int?>[12000, 4000, null]) {
    test(
      'unconfirmed Plex quality $returnedBitrate cannot replace original',
      () async {
        final value = await start();
        fake.decisionBitrateKbps = returnedBitrate;
        await value.setMaxBitrate(8000000);
        expect(value.trackFailure, isNotNull);
        expect(value.maxStreamingBitrate, kCoreMaxStreamingBitrate);
        expect(value.resolved!.playMethod, PlayMethod.directPlay);
        expect(value.position, const Duration(seconds: 10));
      },
    );
  }
  test(
    'default ASS stays off through reopen, version switch and suspend',
    () async {
      fake.defaultSubtitleSelected = true;
      fake.subtitleCodec = 'ass';
      final first = Map<String, dynamic>.from(
        (fake.movie['Media'] as List).first as Map,
      );
      fake.mediaVersions = [
        first,
        {...first, 'id': 8},
      ];
      final value = await start(bitrate: 8000000);
      expect(value.subtitleStreamIndex, isNull);
      expect(
        fake.requests
            .lastWhere((r) => r.path.endsWith('/decision'))
            .query['subtitles'],
        'none',
      );
      await value.setSubtitle(13);
      expect(value.subtitleStreamIndex, 13);
      expect(
        fake.requests
            .lastWhere((r) => r.path.endsWith('/decision'))
            .query['subtitles'],
        'burn',
      );
      await value.setSubtitle(null);
      expect(value.subtitleStreamIndex, isNull);
      expect(
        fake.requests
            .lastWhere((r) => r.path.endsWith('/decision'))
            .query['subtitles'],
        'none',
      );
      await value.switchMediaSource('8');
      if (value.switchConfirmation != null) {
        await value.confirmMediaSourceSwitch(
          SwitchResumeChoice.currentPosition,
        );
      }
      expect(value.error, isNull, reason: value.disconnectDetail);
      expect(value.trackFailure, isNull);
      expect(value.resolved!.mediaSource.id, '8');
      expect(value.subtitleStreamIndex, isNull);
      expect(
        fake.requests
            .lastWhere((r) => r.path.endsWith('/decision'))
            .query['subtitles'],
        'none',
      );
      await value.suspendPlayback();
      await value.restorePlayback();
      expect(value.error, isNull, reason: value.disconnectDetail);
      expect(value.subtitleStreamIndex, isNull);
      expect(
        fake.requests
            .lastWhere((r) => r.path.endsWith('/decision'))
            .query['subtitles'],
        'none',
      );
    },
  );
  test(
    'Part 2 mid-start uses local decoder time and reports global film time',
    () async {
      final value = await start(seconds: 75);
      expect(backend.openedStart, const Duration(seconds: 15));
      expect(value.position, const Duration(seconds: 75));
      expect(value.duration, const Duration(seconds: 120));
      expect(backend.openedUrl!.path, contains('/102/'));
      backend.emitEvent(VideoEventKind.buffer, const Duration(seconds: 25));
      backend.emitEvent(
        VideoEventKind.bufferSnapshot,
        BufferSnapshot(
          sessionId: backend.sessionId,
          resourceId: 'part2',
          representationVersion: 'part2',
          trackVersion: 0,
          sequence: 1,
          ranges: const [
            BufferedRange(Duration(seconds: 15), Duration(seconds: 25)),
          ],
        ),
      );
      await until(() => value.buffer == const Duration(seconds: 85));
      expect(
        value.bufferSnapshot.ranges.single,
        const BufferedRange(Duration(seconds: 75), Duration(seconds: 85)),
      );
      await backend.seek(const Duration(seconds: 20));
      await until(() => value.position == const Duration(seconds: 80));
    },
  );
  test(
    'global seek maps forward and backward Part audio language, not IDs',
    () async {
      final value = await start();
      expect(value.audioStreamIndex, 12);
      await value.seekTo(const Duration(seconds: 75));
      expect(value.trackFailure, isNull);
      expect(value.resolved!.partIndex, 1);
      expect(value.audioStreamIndex, 22);
      expect(backend.openedStart, const Duration(seconds: 15));
      await value.seekTo(const Duration(seconds: 20));
      expect(value.resolved!.partIndex, 0);
      expect(value.audioStreamIndex, 12);
      expect(value.position, const Duration(seconds: 20));
      await value.seekTo(const Duration(seconds: 25));
      expect(backend.position, const Duration(seconds: 25));
    },
  );
  test(
    'only true Part end continues; intermediate completion is ignored',
    () async {
      final value = await start();
      backend.emitEvent(VideoEventKind.completed, true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(backend.openCount, 1);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 60));
      backend.emitEvent(VideoEventKind.completed, true);
      await until(() => backend.openCount == 2 && !value.loading);
      expect(value.resolved!.partIndex, 1);
      expect(value.position, const Duration(seconds: 60));
      expect(value.playbackEnded, false);
    },
  );
  test(
    'transcoded Part 2 starts decoder zero, preserving global 75s',
    () async {
      final value = await start(seconds: 75, bitrate: 8000000);
      expect(value.resolved!.startsAtRequestedPosition, true);
      expect(backend.openedStart, Duration.zero);
      expect(value.position, const Duration(seconds: 75));
      expect(backend.openedUrl!.queryParameters['partIndex'], '1');
      expect(backend.openedUrl!.queryParameters['offset'], '15.0');
      await backend.seek(const Duration(seconds: 4));
      await until(() => value.position == const Duration(seconds: 79));
      await value.close();
      expect(fake.sessions, isEmpty);
    },
  );
  test(
    'unknown duration prevents cross-Part seek and does not invent film length',
    () async {
      fake.missingPartDuration = true;
      final value = await start(seconds: 0);
      expect(value.duration, Duration.zero);
      await value.seekTo(const Duration(seconds: 75));
      expect(backend.openCount, 1);
      expect(value.trackFailure, contains('unknown'));
    },
  );
  test(
    'failed Part preparation retains old playback and retries original cleanup',
    () async {
      final value = await start();
      fake.secondAudioCodec = 'dts';
      // Request a bitrate that requires server negotiation on the next Part.
      value.maxStreamingBitrate = 8000000;
      fake.transcodeDenied = true;
      fake.failStops = true;
      await value.seekTo(const Duration(seconds: 75));
      expect(backend.openCount, 1);
      expect(value.resolved!.partIndex, 0);
      expect(value.trackFailure, isNotNull);
      final pendingSnapshot = await snapshots.read();
      expect(pendingSnapshot!.cleanupOnly, false);
      expect(pendingSnapshot.pendingCleanups, hasLength(1));
      expect(pendingSnapshot.pendingCleanups.single.cleanupOnly, true);
      final decisions = fake.requests
          .where((r) => r.path.endsWith('/decision'))
          .length;
      fake.failStops = false;
      await value.retryResourceCleanup();
      expect(
        fake.requests.where((r) => r.path.endsWith('/decision')).length,
        decisions,
      );
      expect(fake.sessions, isEmpty);
      expect((await snapshots.read())!.pendingCleanups, isEmpty);
    },
  );
  test(
    'pre-open snapshot is cleanup-only; failure retains it until original lease retry',
    () async {
      final snapshots = MemoryPlaybackSessionSnapshotStore();
      backend.openGate = Completer<void>();
      fake.failStops = true;
      final value = player = PlayerController(
        client: client,
        itemId: '42',
        backend: backend,
        window: PlayerWindow(),
        autoResume: false,
        openRequest: const PlayerOpenRequest(
          itemId: '42',
          subtitleOff: true,
          maxStreamingBitrate: 8000000,
        ),
        settingsStore: MemoryPlayerSettingsStore(),
        snapshotStore: snapshots,
      );
      final starting = value.start();
      await until(() => backend.requests.isNotEmpty);
      final before = await snapshots.read();
      expect(before!.cleanupOnly, true);
      expect(
        fake.requests.where((r) => r.path.endsWith('/:/timeline')),
        isEmpty,
      );
      backend.openGate!.completeError(StateError('synthetic decoder failure'));
      await starting;
      expect(value.error, isNotNull);
      expect((await snapshots.read())!.playSessionId, before.playSessionId);
      final decisions = fake.requests
          .where((r) => r.path.endsWith('/decision'))
          .length;
      fake.failStops = false;
      await value.retryResourceCleanup();
      expect(await snapshots.read(), isNull);
      expect(
        fake.requests.where((r) => r.path.endsWith('/decision')).length,
        decisions,
      );
      expect(fake.sessions, isEmpty);
    },
  );
  test(
    'an IntroStart without a real end never fabricates a skip interval',
    () async {
      final value = await start();
      value.item = const MediaItem(
        id: '42',
        name: 'Film',
        type: 'Movie',
        runtime: Duration(seconds: 120),
        chapters: [
          ItemChapter(
            name: 'Intro',
            startPosition: Duration(seconds: 10),
            markerType: 'IntroStart',
          ),
        ],
      );
      await value.setSkipEnabled(PlayerSkipKind.intro, true);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 15));
      await until(() => value.position == const Duration(seconds: 15));
      expect(value.activeSkipSegment, isNull);
    },
  );
  test(
    'different Part language presents actual choices; cancel preserves old playback',
    () async {
      final value = await start();
      fake.secondAudioLanguage = 'jpn';
      await value.seekTo(const Duration(seconds: 75));
      expect(backend.openCount, 1);
      expect(value.switchConfirmation!.audioNeedsChoice, true);
      expect(value.switchConfirmation!.audioChoices.single.language, 'jpn');
      await value.confirmMediaSourceSwitch(SwitchResumeChoice.cancel);
      expect(backend.openCount, 1);
      expect(value.position, const Duration(seconds: 10));
      await value.seekTo(const Duration(seconds: 75));
      await value.confirmMediaSourceSwitch(
        SwitchResumeChoice.currentPosition,
        audioIndex: 22,
      );
      expect(value.error, isNull, reason: value.disconnectDetail);
      expect(value.resolved!.partIndex, 1);
      expect(value.audioStreamIndex, 22);
      expect(value.position, const Duration(seconds: 75));
    },
  );
  test(
    'revocation preserves failed cleanup evidence and retries without new authority',
    () async {
      final value = await start(bitrate: 8000000);
      final sessionId = value.resolved!.playSessionId;
      fake.failStops = true;
      await value.revokeFromHost(reportStopped: false);
      expect(client.hasSession, false);
      final retained = await snapshots.read();
      expect(retained!.playSessionId, sessionId);
      expect(retained.cleanupOnly, true);
      final count = fake.requests
          .where((r) => r.path.endsWith('/decision'))
          .length;
      fake.failStops = false;
      await value.retryResourceCleanup();
      expect(await snapshots.read(), isNull);
      expect(fake.sessions, isEmpty);
      expect(
        fake.requests.where((r) => r.path.endsWith('/decision')).length,
        count,
      );
      expect(
        fake.requests.where(
          (r) =>
              r.path.endsWith('/:/timeline') && r.query['state'] == 'stopped',
        ),
        isEmpty,
      );
    },
  );
}
