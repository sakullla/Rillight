import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_codec.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';

class _StrmClient extends EmbyClient {
  _StrmClient()
    : super(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'strm-quality',
          version: '1',
        ),
      ) {
    attachSession(
      baseUrl: Uri.parse('http://synthetic.invalid/emby'),
      accessToken: 'synthetic',
      userId: 'test',
    );
  }
  int sourceBitrate = 20000000;
  int? transcodeBitrate = 8000000;
  bool readFails = false;
  bool offersTranscode = true;
  MediaServerException? pointerFailure;
  @override
  Future<MediaItem> getItem(
    String id, {
    String? fields,
    CancelToken? cancelToken,
  }) async => MediaItem(
    id: id,
    name: 'STRM',
    type: 'Movie',
    runtime: const Duration(minutes: 20),
  );
  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async =>
      const MediaUser(id: 'test', name: 'Test');
  @override
  Future<PlaybackInfo> getPlaybackInfo({
    required String itemId,
    String? mediaSourceId,
    int? maxStreamingBitrate,
    Duration? startPosition,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackCapabilities? capabilities,
    bool forceTranscode = false,
  }) async => decodeEmbyPlaybackInfo({
    'PlaySessionId': 'strm-session',
    'MediaSources': [
      {
        'Id': 'strm',
        'Container': 'strm',
        'Path': '/library/film.strm',
        'SupportsDirectPlay': true,
        'SupportsTranscoding': true,
        'Bitrate': sourceBitrate,
        if (offersTranscode)
          'TranscodingUrl':
              '/Videos/film/master.m3u8?session=strm'
              '${transcodeBitrate == null ? '' : '&VideoBitrate=${transcodeBitrate! - 192000}&AudioBitrate=192000'}',
        'MediaStreams': [
          {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'IsDefault': true},
        ],
      },
    ],
  });
  @override
  Future<List<int>> readAuthorizedBytes(
    Uri uri, {
    Duration receiveTimeout = const Duration(seconds: 60),
    int attempts = 3,
    int? maxBytes,
    CancelToken? cancelToken,
  }) async {
    if (pointerFailure != null) throw pointerFailure!;
    if (readFails) throw StateError('synthetic missing pointer');
    return utf8.encode('# pointer has no target');
  }

  @override
  Future<void> reportPlaying(PlaybackReport report) async {}
  @override
  Future<void> reportProgress(PlaybackReport report) async {}
  @override
  Future<void> reportStopped(PlaybackReport report) async {}
  @override
  Future<void> releasePlayback(PlaybackReport report) async {}
}

void main() {
  test(
    'unavailable STRM preserves HTTP failure instead of reporting no stream',
    () async {
      final failure = const MediaServerException(
        MediaServerFailureKind.unknown,
        statusCode: 404,
        detail: 'HTTP 404',
      );
      final client = _StrmClient()
        ..offersTranscode = false
        ..pointerFailure = failure;
      final backend = FakeVideoBackend();
      final player = PlayerController(
        client: client,
        itemId: 'film',
        backend: backend,
        window: PlayerWindow(),
        autoResume: false,
        settingsStore: MemoryPlayerSettingsStore(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      );
      addTearDown(() async {
        await player.disposeAsync();
        player.dispose();
      });
      await player.start();
      expect(player.error, PlayerErrorKind.load);
      expect(player.loadFailure, same(failure));
      expect(player.isPlaying, isFalse);
      expect(backend.openedUrl, isNull);
    },
  );

  for (final readFails in [false, true]) {
    for (final sample in <(int, int?, int, bool)>[
      (20000000, 8000000, 8000000, true),
      (2000000, 8000000, 4000000, false),
      (2000000, null, 4000000, false),
    ]) {
      test(
        'STRM fallback readFails=$readFails source=${sample.$1} output=${sample.$2} uses transcode quality evidence',
        () async {
          final client = _StrmClient()..readFails = readFails;
          final player = PlayerController(
            client: client,
            itemId: 'film',
            backend: FakeVideoBackend(),
            window: PlayerWindow(),
            autoResume: false,
            settingsStore: MemoryPlayerSettingsStore(),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
          );
          addTearDown(() async {
            await player.disposeAsync();
            player.dispose();
          });
          await player.start();
          expect(player.error, isNull);
          expect(player.resolved!.playMethod, PlayMethod.transcode);
          client.sourceBitrate = sample.$1;
          client.transcodeBitrate = sample.$2;
          await player.setMaxBitrate(sample.$3);
          expect(player.resolved!.outputBitrate, sample.$2);
          expect(
            player.maxStreamingBitrate,
            sample.$4 ? sample.$3 : kCoreMaxStreamingBitrate,
          );
          expect(player.trackFailure, sample.$4 ? isNull : isNotNull);
        },
      );
    }
  }
}
