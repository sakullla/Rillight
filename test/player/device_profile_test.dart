import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/device_profile.dart';

void main() {
  test('mpv DeviceProfile declares honest Direct Play codecs', () {
    final profile = mpvDeviceProfile();
    final direct = profile['DirectPlayProfiles'] as List<dynamic>;
    final video = Map<String, dynamic>.from(
      direct.cast<Map>().firstWhere((item) => item['Type'] == 'Video'),
    );
    expect(video['Container'], contains('mkv'));
    expect(video['Container'], contains('mp4'));
    expect(video['VideoCodec'], contains('h264'));
    expect(video['VideoCodec'], contains('hevc'));
    expect(video['AudioCodec'], contains('aac'));
    expect(video['AudioCodec'], contains('ac3'));
    expect(direct.toString(), isNot(contains('html5')));
  });

  test('text subtitles are External and PGS is locally renderable', () {
    final profile = mpvDeviceProfile();
    final subs = (profile['SubtitleProfiles'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    expect(
      subs.any(
        (item) => item['Format'] == 'srt' && item['Method'] == 'External',
      ),
      isTrue,
    );
    // pgs/pgssub 声明 Embedded:直连场景服务端不强制烧录,mpv 本地渲染内嵌轨道。
    expect(
      subs.any(
        (item) => item['Format'] == 'pgs' && item['Method'] == 'Embedded',
      ),
      isTrue,
    );
    expect(
      subs.any(
        (item) => item['Format'] == 'pgssub' && item['Method'] == 'Embedded',
      ),
      isTrue,
    );
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
    final profile = mpvDeviceProfile();
    final transcoding = Map<String, dynamic>.from(
      (profile['TranscodingProfiles'] as List).first as Map,
    );
    expect(transcoding['Protocol'], 'hls');
    expect(transcoding['Container'], 'ts');
    expect(transcoding['VideoCodec'], 'h264');
    expect(transcoding['AudioCodec'], 'aac');
  });
}
