import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/hls_cache_index.dart';
import 'package:rillight/player/cache/matroska_cache_index.dart';
import 'package:rillight/player/cache/mp4_cache_index.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';

import 'mp4_fixture.dart';

void main() {
  group('progressive MP4 cache index', () {
    test('CRC failure retracts only the affected disk-backed GOP', () async {
      final root = await Directory.systemTemp.createTemp('rillight-mp4-crc-');
      final cache = await SessionByteCache.open(
        root: root,
        memoryLimitBytes: 0,
        diskLimitBytes: 1024 * 1024,
      );
      try {
        final fixture = progressiveMp4Fixture();
        const resource = 'mp4-crc-fixture';
        for (final (start, end) in [
          (0, 28),
          (28, 32),
          (32, 36),
          (36, 40),
          (40, 44),
          (44, fixture.length),
        ]) {
          expect(
            await cache.put(
              resource: resource,
              generation: 1,
              offset: start,
              bytes: Uint8List.sublistView(fixture, start, end),
            ),
            isTrue,
          );
        }
        Future<Uint8List?> read(int offset, int length) async {
          final output = BytesBuilder(copy: false);
          while (output.length < length) {
            final hit = await cache.read(
              resource: resource,
              generation: 1,
              offset: offset + output.length,
              maxLength: length - output.length,
              countHit: false,
            );
            if (hit == null) return null;
            output.add(hit.bytes);
          }
          return output.takeBytes();
        }

        final index = await Mp4CacheIndex.load(
          total: fixture.length,
          read: read,
        );
        expect(index, isNotNull);
        Future<List<(int, int)>> times() async => index!
            .ranges(
              (await cache.availableRanges(
                resource: resource,
                generation: 1,
                verifyChecksum: true,
              ))!,
              const Duration(seconds: 4),
            )
            .map((range) => (range.start.inSeconds, range.end.inSeconds))
            .toList();
        expect(await times(), [(0, 4)]);

        final firstVideo = root
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.block'))
            .firstWhere((file) {
              final bytes = file.readAsBytesSync();
              return bytes.length == 4 && bytes[0] == fixture[28];
            });
        final bytes = await firstVideo.readAsBytes();
        bytes[0] ^= 0xff;
        await firstVideo.writeAsBytes(bytes, flush: true);
        await firstVideo.setLastModified(
          DateTime.now().add(const Duration(seconds: 2)),
        );
        expect(await times(), [(2, 4)]);
      } finally {
        await cache.close();
        await root.delete(recursive: true);
      }
    });

    test('requires complete GOP, selected audio, and moov bytes', () async {
      final fixture = progressiveMp4Fixture();
      final index = await Mp4CacheIndex.load(
        total: fixture.length,
        read: (offset, length) async =>
            Uint8List.sublistView(fixture, offset, offset + length),
      );
      expect(index, isNotNull);
      final metadata = CachedByteRange(44, fixture.length);
      final header = CachedByteRange(0, 28);
      List<(int, int)> times(List<CachedByteRange> bytes) => index!
          .ranges(bytes, const Duration(seconds: 4))
          .map((range) => (range.start.inSeconds, range.end.inSeconds))
          .toList();

      expect(times([header, metadata, CachedByteRange(28, 44)]), [(0, 4)]);
      expect(
        times([
          header,
          metadata,
          CachedByteRange(28, 32),
          CachedByteRange(36, 40),
        ]),
        [(0, 2)],
      );
      expect(
        times([
          header,
          metadata,
          CachedByteRange(28, 36),
          CachedByteRange(40, 44),
        ]),
        [(2, 4)],
      );
      expect(times([header, CachedByteRange(28, 44)]), isEmpty);
      expect(times([metadata, CachedByteRange(28, 44)]), isEmpty);
      expect(times([header, metadata, CachedByteRange(28, 38)]), isEmpty);

      // A proxy can build the index from cached headers and moov while an
      // earlier GOP is absent. Reading 16 bytes from every mdat header would
      // incorrectly require payload from that earlier GOP.
      final sparse = [
        CachedByteRange(0, 28),
        CachedByteRange(32, 36),
        CachedByteRange(40, fixture.length),
      ];
      final sparseIndex = await Mp4CacheIndex.load(
        total: fixture.length,
        read: (offset, length) async =>
            sparse.any(
              (range) => range.start <= offset && range.end >= offset + length,
            )
            ? Uint8List.sublistView(fixture, offset, offset + length)
            : null,
      );
      expect(sparseIndex, isNotNull);
      expect(
        sparseIndex!
            .ranges(sparse, const Duration(seconds: 4))
            .map((range) => (range.start.inSeconds, range.end.inSeconds)),
        [(2, 4)],
      );
    });

    test('rejects unindexed fragments and unselected tracks', () async {
      final progressive = progressiveMp4Fixture();
      final withFragment = Uint8List.fromList([
        ...progressive,
        0,
        0,
        0,
        8,
        109,
        111,
        111,
        102,
      ]);
      expect(
        await Mp4CacheIndex.load(
          total: withFragment.length,
          read: (offset, length) async =>
              Uint8List.sublistView(withFragment, offset, offset + length),
        ),
        isNull,
      );
      // A track selection not represented by this file cannot borrow another
      // track's byte coverage.
      expect(
        await Mp4CacheIndex.load(
          total: progressive.length,
          selectedAudioTrackId: 9,
          read: (offset, length) async =>
              Uint8List.sublistView(progressive, offset, offset + length),
        ),
        isNull,
      );
    });

    test(
      'fMP4 requires complete independent fragment and selected audio',
      () async {
        final fixture = fragmentedMp4Fixture();
        final index = await Mp4CacheIndex.load(
          total: fixture.bytes.length,
          read: (offset, length) async =>
              Uint8List.sublistView(fixture.bytes, offset, offset + length),
        );
        expect(index, isNotNull);
        List<(int, int)> times(List<CachedByteRange> ranges) => index!
            .ranges(ranges, const Duration(seconds: 4))
            .map((r) => (r.start.inSeconds, r.end.inSeconds))
            .toList();
        expect(times([CachedByteRange(0, fixture.bytes.length)]), [(0, 4)]);
        final firstEnd = fixture.firstFragmentEnd;
        expect(times([CachedByteRange(0, firstEnd)]), [(0, 2)]);
        expect(
          times([
            CachedByteRange(0, firstEnd - 2),
            CachedByteRange(firstEnd, fixture.bytes.length),
          ]),
          [(2, 4)],
        );
        expect(
          times([
            CachedByteRange(0, firstEnd - 1),
            CachedByteRange(firstEnd, fixture.bytes.length),
          ]),
          [(2, 4)],
        );
        expect(
          times([
            CachedByteRange(0, fixture.firstMoofStart),
            CachedByteRange(fixture.firstMdatStart, fixture.bytes.length),
          ]),
          [(2, 4)],
        );
      },
    );

    test('fMP4 without explicit random-access start remains unknown', () async {
      final bytes = fragmentedMp4Fixture(videoStartsWithSync: false).bytes;
      expect(
        await Mp4CacheIndex.load(
          total: bytes.length,
          read: (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        ),
        isNull,
      );
    });
  });

  group('HLS cache index', () {
    final playlistUri = Uri.parse('https://media.example/video/playlist.m3u8');
    const manifest = '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:100
#EXT-X-MAP:URI="init.mp4",BYTERANGE="8@0"
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:2.0,
#EXT-X-BYTERANGE:4@0
seg.m4s
#EXTINF:2.0,
#EXT-X-BYTERANGE:4
seg.m4s
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=NONE
#EXTINF:2.0,
later.m4s
#EXT-X-ENDLIST
''';

    Map<int, HlsVerifiedSegmentTime> verified() => {
      100: const HlsVerifiedSegmentTime(
        start: Duration.zero,
        end: Duration(seconds: 2),
        timelineEpoch: 0,
        decodeStartVerified: true,
      ),
      101: const HlsVerifiedSegmentTime(
        start: Duration(seconds: 2),
        end: Duration(seconds: 4),
        timelineEpoch: 0,
        decodeStartVerified: true,
      ),
      102: const HlsVerifiedSegmentTime(
        start: Duration(seconds: 4),
        end: Duration(seconds: 6),
        timelineEpoch: 1,
        decodeStartVerified: true,
      ),
    };

    test('needs actual timing, complete byte ranges, init and session key', () {
      final index = HlsCacheIndex.parseMediaPlaylist(
        text: manifest,
        playlistUri: playlistUri,
        verifiedTimes: verified(),
      );
      expect(index, isNotNull);
      expect(index!.segments[1].byteRange!.start, 4);
      final init = playlistUri.resolve('init.mp4');
      final media = playlistUri.resolve('seg.m4s');
      final later = playlistUri.resolve('later.m4s');
      final key = playlistUri.resolve('key.bin');
      final available = <Uri, HlsCachedResource>{
        init: const HlsCachedResource(
          length: 8,
          ranges: [CachedByteRange(0, 8)],
        ),
        media: const HlsCachedResource(
          length: 8,
          ranges: [CachedByteRange(0, 4), CachedByteRange(4, 8)],
        ),
        later: const HlsCachedResource(
          length: 4,
          ranges: [CachedByteRange(0, 4)],
        ),
      };
      List<(int, int)> times(Set<Uri> keys) => index
          .ranges(resources: available, usableSessionKeys: keys)
          .map((range) => (range.start.inSeconds, range.end.inSeconds))
          .toList();
      expect(times({key}), [(0, 4), (4, 6)]);
      expect(times({}), [(4, 6)]);
      available.remove(init);
      expect(times({key}), isEmpty);
      available[init] = const HlsCachedResource(
        length: 8,
        ranges: [CachedByteRange(0, 8)],
      );
      available[media] = const HlsCachedResource(
        length: 8,
        ranges: [CachedByteRange(0, 4)],
      );
      expect(times({key}), [(0, 2), (4, 6)]);
      expect(
        HlsCacheIndex.parseMediaPlaylist(
          text: manifest,
          playlistUri: playlistUri,
          verifiedTimes: const {},
        )!.ranges(resources: available, usableSessionKeys: {key}),
        isEmpty,
      );
    });

    test(
      'selected audio intersection and unsupported playlists stay unknown',
      () {
        final video = HlsCacheIndex.parseMediaPlaylist(
          text: manifest,
          playlistUri: playlistUri,
          verifiedTimes: verified(),
        )!;
        final audio = HlsCacheIndex.parseMediaPlaylist(
          text: '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:7
#EXTINF:2,
audio0.aac
#EXTINF:2,
audio1.aac
#EXT-X-ENDLIST
''',
          playlistUri: playlistUri,
          verifiedTimes: {
            7: const HlsVerifiedSegmentTime(
              start: Duration.zero,
              end: Duration(seconds: 2),
              timelineEpoch: 0,
              decodeStartVerified: true,
            ),
            8: const HlsVerifiedSegmentTime(
              start: Duration(seconds: 2),
              end: Duration(seconds: 4),
              timelineEpoch: 0,
              decodeStartVerified: false,
            ),
          },
        )!;
        final resources = <Uri, HlsCachedResource>{
          for (final segment in video.segments)
            segment.uri: const HlsCachedResource(
              length: 8,
              ranges: [CachedByteRange(0, 8)],
            ),
          playlistUri.resolve('init.mp4'): const HlsCachedResource(
            length: 8,
            ranges: [CachedByteRange(0, 8)],
          ),
          for (final segment in audio.segments)
            segment.uri: const HlsCachedResource(
              length: 8,
              ranges: [CachedByteRange(0, 8)],
            ),
        };
        expect(
          video
              .ranges(
                resources: resources,
                usableSessionKeys: {playlistUri.resolve('key.bin')},
                selectedAudio: audio,
              )
              .map((range) => (range.start.inSeconds, range.end.inSeconds)),
          [(0, 2)],
        );
        expect(
          HlsCacheIndex.parseMediaPlaylist(
            text: '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nother.m3u8',
            playlistUri: playlistUri,
            verifiedTimes: const {},
          ),
          isNull,
        );
        expect(
          HlsCacheIndex.parseMediaPlaylist(
            text:
                '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"\n'
                '#EXTINF:2,\none.ts',
            playlistUri: playlistUri,
            verifiedTimes: const {},
          ),
          isNull,
        );
        expect(
          HlsCacheIndex.parseMediaPlaylist(
            text: '#EXTM3U\n#EXTINF:2,\nsegment.m4s\n#EXT-X-ENDLIST',
            playlistUri: playlistUri,
            verifiedTimes: {
              0: const HlsVerifiedSegmentTime(
                start: Duration.zero,
                end: Duration(seconds: 2),
                timelineEpoch: 0,
                decodeStartVerified: true,
                requiresInitialization: true,
              ),
            },
          )!.ranges(
            resources: {
              playlistUri.resolve('segment.m4s'): const HlsCachedResource(
                length: 8,
                ranges: [CachedByteRange(0, 8)],
              ),
            },
            usableSessionKeys: const {},
          ),
          isEmpty,
        );
        final wrongEpoch = verified();
        wrongEpoch[102] = const HlsVerifiedSegmentTime(
          start: Duration(seconds: 4),
          end: Duration(seconds: 6),
          timelineEpoch: 0,
          decodeStartVerified: true,
        );
        expect(
          HlsCacheIndex.parseMediaPlaylist(
            text: manifest,
            playlistUri: playlistUri,
            verifiedTimes: wrongEpoch,
          ),
          isNull,
        );
      },
    );
  });
}
