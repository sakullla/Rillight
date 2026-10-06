import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/device_profile.dart';

void main() {
  test(
    'Android profile gates the verified baseline and offers HLS fallback',
    () {
      final profile = androidDeviceProfile(h264: true, aac: true);
      final direct = (profile['DirectPlayProfiles'] as List).single as Map;
      expect(direct['VideoCodec'], 'h264');
      expect(direct['AudioCodec'], 'aac');
      final fallback = (profile['TranscodingProfiles'] as List).single as Map;
      expect(fallback['Protocol'], 'hls');
      expect(fallback['MaxAudioChannels'], '2');
      expect(
        androidDeviceProfile(h264: false, aac: true)['DirectPlayProfiles'],
        isEmpty,
      );
      expect(
        androidDeviceProfile(h264: true, aac: false)['TranscodingProfiles'],
        isEmpty,
      );
    },
  );
  test('owned core profile only advertises the verified video baseline', () {
    final profile = ownedCoreDeviceProfile(h264: true, aac: true);
    final direct = profile['DirectPlayProfiles'] as List<dynamic>;
    final video = Map<String, dynamic>.from(
      direct.cast<Map>().firstWhere((item) => item['Type'] == 'Video'),
    );
    expect(video['Container'], contains('mkv'));
    expect(video['Container'], contains('mp4'));
    expect(profile['Name'], 'Rillight owned FFmpeg core');
    expect(video['VideoCodec'], 'h264');
    expect(video['AudioCodec'], 'aac');
    expect(direct.toString(), isNot(contains('hevc')));
    expect(direct.toString(), isNot(contains('ac3')));
    expect(profile.containsKey('CodecProfiles'), isFalse);
  });

  test('probed HEVC and Dolby audio are direct and not capped at 1080p', () {
    final profile = ownedCoreDeviceProfile(
      h264: true,
      aac: true,
      hevc: true,
      ac3: true,
      eac3: true,
      truehd: true,
    );
    final direct = (profile['DirectPlayProfiles'] as List).single as Map;
    expect(direct['VideoCodec'], 'h264,hevc');
    expect(direct['AudioCodec'], 'aac,ac3,eac3,truehd');
    expect(profile.containsKey('CodecProfiles'), isFalse);
    expect(direct.toString(), isNot(contains('dts')));

    final ac3Only = ownedCoreDeviceProfile(
      h264: false,
      aac: false,
      hevc: true,
      ac3: true,
    );
    final narrowed = (ac3Only['DirectPlayProfiles'] as List).single as Map;
    expect(narrowed['VideoCodec'], 'hevc');
    expect(narrowed['AudioCodec'], 'ac3');
    expect(narrowed['AudioCodec'], isNot(contains('eac3')));
    expect(narrowed['AudioCodec'], isNot(contains('truehd')));
  });

  test('text subtitles are External and bitmap subtitles require burn-in', () {
    final profile = ownedCoreDeviceProfile(h264: true, aac: true);
    final subs = (profile['SubtitleProfiles'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    expect(
      subs.any(
        (item) => item['Format'] == 'srt' && item['Method'] == 'External',
      ),
      isTrue,
    );
    expect(
      subs.any((item) => item['Format'] == 'pgs' && item['Method'] == 'Encode'),
      isTrue,
    );
    expect(
      subs.any(
        (item) => item['Format'] == 'pgssub' && item['Method'] == 'Encode',
      ),
      isTrue,
    );
    // 不出现自造值 Embedded(严格服务端会拒绝整个 PlaybackInfo 请求)。
    expect(subs.any((item) => item['Method'] == 'Embedded'), isFalse);
    // dvdsub/dvbsub 仍为 Encode(转码烧录)。
    expect(
      subs.any(
        (item) => item['Format'] == 'dvdsub' && item['Method'] == 'Encode',
      ),
      isTrue,
    );
    expect(
      subs.any(
        (item) => item['Format'] == 'dvbsub' && item['Method'] == 'Encode',
      ),
      isTrue,
    );
  });

  test('transcode fallback is HLS TS H.264 AAC', () {
    final profile = ownedCoreDeviceProfile(h264: true, aac: true);
    final transcoding = Map<String, dynamic>.from(
      (profile['TranscodingProfiles'] as List).first as Map,
    );
    expect(transcoding['Protocol'], 'hls');
    expect(transcoding['Container'], 'ts');
    expect(transcoding['VideoCodec'], 'h264');
    expect(transcoding['AudioCodec'], 'aac');
  });

  test('verified ASS and SSA support avoids forced subtitle burn-in', () {
    for (final build in [androidDeviceProfile, ownedCoreDeviceProfile]) {
      final profile = build(h264: true, aac: true, ass: true, ssa: true);
      final subtitles = (profile['SubtitleProfiles'] as List).cast<Map>();
      for (final format in ['ass', 'ssa']) {
        expect(
          subtitles.singleWhere((s) => s['Format'] == format)['Method'],
          'Embed',
        );
      }
      final absent = (build(h264: true, aac: true)['SubtitleProfiles'] as List)
          .cast<Map>();
      for (final format in ['ass', 'ssa']) {
        expect(
          absent.singleWhere((s) => s['Format'] == format)['Method'],
          'Encode',
        );
      }
      expect(
        subtitles.singleWhere((s) => s['Format'] == 'pgs')['Method'],
        'Encode',
      );
    }
  });
}
