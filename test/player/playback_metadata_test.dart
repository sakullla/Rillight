import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_server/playback_metadata.dart';
import 'package:rillight/plex/plex_client.dart';

import '../plex/fake_plex.dart';

const _device = ClientDeviceInfo(
  clientName: 'metadata-test',
  deviceName: 'synthetic',
  deviceId: 'metadata-device',
  version: '1',
);

void main() {
  test(
    'catalog conversion preserves version and exact track identity/defaults',
    () {
      const item = MediaItem(
        id: 'item',
        name: 'Synthetic',
        type: 'Movie',
        runtime: Duration(seconds: 120),
        mediaSources: [
          ItemMediaSource(
            id: 'version',
            name: 'Edition',
            container: 'mkv',
            size: 300,
            bitrate: 20000000,
            width: 3840,
            height: 2160,
            runtime: Duration(seconds: 125),
            streams: [
              ItemMediaStream(
                index: 0,
                type: 'Video',
                codec: 'hevc',
                width: 3840,
                height: 2160,
                bitRate: 19000000,
                videoRange: 'HDR',
                videoRangeType: 'HDR10',
              ),
              ItemMediaStream(
                index: 11,
                type: 'Audio',
                codec: 'aac',
                language: 'eng',
                label: 'Same title',
                channels: 2,
              ),
              ItemMediaStream(
                index: 12,
                type: 'Audio',
                codec: 'aac',
                language: 'eng',
                label: 'Same title',
                channels: 6,
                isDefault: true,
              ),
              ItemMediaStream(
                index: 13,
                type: 'Subtitle',
                codec: 'ass',
                language: 'zho',
                label: '中文',
                isDefault: true,
                isExternal: true,
              ),
            ],
          ),
          ItemMediaSource(id: 'unknown', streams: []),
        ],
      );
      final sources = playbackSourcesFromItem(item);
      final source = sources.first;
      expect(sources.map((source) => source.id), ['version', 'unknown']);
      expect(source.name, 'Edition');
      expect(source.container, 'mkv');
      expect(source.size, 300);
      expect(source.bitrate, 20000000);
      expect((source.width, source.height), (3840, 2160));
      expect(source.runtime, const Duration(seconds: 125));
      expect(source.defaultAudioStreamIndex, 12);
      expect(source.defaultSubtitleStreamIndex, 13);
      expect(source.audioStreams.map((s) => s.index), [11, 12]);
      expect(source.audioStreams.map((s) => s.displayTitle), [
        'Same title',
        'Same title',
      ]);
      expect(source.audioStreams.last.channels, 6);
      expect(source.mediaStreams.first.bitRate, 19000000);
      expect(source.mediaStreams.first.videoRangeType, 'HDR10');
      expect(source.subtitleStreams.single.isExternal, isTrue);
      expect(sources.last.defaultAudioStreamIndex, isNull);
      expect(sources.last.defaultSubtitleStreamIndex, isNull);
      expect(source.transcodingUrl, isNull);
      expect(source.directStreamUrl, isNull);
      expect(source.supportsTranscoding, isFalse);
    },
  );

  group('Plex discovery', () {
    late FakePlex fake;
    late PlexClient client;
    setUp(() async {
      fake = FakePlex()..transcodeDenied = true;
      await fake.start();
      client = PlexClient(device: _device)
        ..attachSession(
          baseUrl: fake.url,
          accessToken: 'owner-resource',
          userId: '1',
        );
    });
    tearDown(() => fake.close());

    void expectReadOnly(int count) {
      expect(fake.requests, hasLength(count));
      for (final request in fake.requests) {
        expect(request.method, 'GET');
        expect(request.path, '/library/metadata/42');
      }
      expect(fake.sessions, isEmpty);
      expect(fake.selectedStreams, isEmpty);
      expect(fake.stops, 0);
    }

    test(
      'catalog failure remains an error rather than an empty discovery',
      () async {
        fake.errorStatus = 403;
        await expectLater(
          client.getPlaybackSources(itemId: '42'),
          throwsA(
            isA<MediaServerException>().having(
              (error) => error.kind,
              'kind',
              MediaServerFailureKind.forbidden,
            ),
          ),
        );
        expectReadOnly(1);
      },
    );

    test(
      'unplayable first version does not block saved playable version metadata',
      () async {
        final playable =
            (fake.movie['Media'] as List).single as Map<String, dynamic>;
        fake.mediaVersions = [
          {'id': 6, 'videoResolution': 'broken', 'Part': []},
          {
            ...playable,
            'videoResolution': '1080',
            'width': 1920,
            'height': 1080,
          },
        ];
        final provider = client as PlaybackMetadataProvider;
        final sources = await provider.getPlaybackSources(
          itemId: '42',
          position: const Duration(seconds: 75),
        );
        expect(sources.map((source) => source.id), ['6', '7']);
        expect(sources.first.mediaStreams, isEmpty);
        final source = sources.last;
        expect(source.name, '1080');
        expect(source.container, 'mkv');
        expect(source.runtime, const Duration(seconds: 120));
        expect(source.bitrate, 20000000);
        expect((source.width, source.height), (1920, 1080));
        expect(source.mediaStreams.map((s) => s.index), [21, 22]);
        expect(source.defaultAudioStreamIndex, 22);
        expect(source.directStreamUrl, isNull);
        expect(source.transcodingUrl, isNull);
        expectReadOnly(1);
      },
    );

    test(
      'each version locates its own Part at the same whole-film position',
      () async {
        fake.defaultSubtitleSelected = true;
        final first =
            (fake.movie['Media'] as List).single as Map<String, dynamic>;
        final parts = first['Part'] as List;
        fake.mediaVersions = [
          first,
          {
            ...first,
            'id': 8,
            'Part': [
              {...parts[0] as Map<String, dynamic>, 'duration': 90000},
              {...parts[1] as Map<String, dynamic>, 'duration': 30000},
            ],
          },
        ];
        final sources = await client.getPlaybackSources(
          itemId: '42',
          position: const Duration(seconds: 75),
        );
        expect(sources.first.defaultAudioStreamIndex, 22);
        expect(sources.first.defaultSubtitleStreamIndex, isNull);
        expect(sources.last.defaultAudioStreamIndex, 12);
        expect(sources.last.defaultSubtitleStreamIndex, 13);
        final boundary = await client.getPlaybackSources(
          itemId: '42',
          position: const Duration(seconds: 60),
        );
        expect(boundary.first.defaultAudioStreamIndex, 22);
        expect(boundary.last.defaultAudioStreamIndex, 12);
        expectReadOnly(2);
      },
    );

    test(
      'unknown Part duration never substitutes first-Part tracks for a seek',
      () async {
        fake.missingPartDuration = true;
        final positive = await client.getPlaybackSources(
          itemId: '42',
          position: const Duration(seconds: 75),
        );
        expect(positive.single.id, '7');
        expect(positive.single.runtime, const Duration(seconds: 120));
        expect(positive.single.mediaStreams, isEmpty);
        expect(positive.single.defaultAudioStreamIndex, isNull);
        final zero = await client.getPlaybackSources(itemId: '42');
        expect(zero.single.defaultAudioStreamIndex, 12);
        expectReadOnly(2);
      },
    );
  });
}
