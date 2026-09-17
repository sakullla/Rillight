import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/media_source_format.dart';

void main() {
  test('scene filename becomes specs plus release group', () {
    final view = formatMediaSource(
      name: '2160p.BILI.WD.265.AAC-SonyHD',
      sizeBytes: 12400000000,
      bitrate: 62000000,
    );
    expect(view.headline, '4K · H.265 · AAC');
    expect(view.detail, 'BILI · WEB-DL · SonyHD · 12.4 GB · 62 Mbps');
    expect(view.compact, '4K H.265');
  });

  test('HDR token and streams win over filename leftovers', () {
    final view = formatMediaSource(
      name: '2160p.WD.265.HDR.AAC-HDSWEB',
      height: 2160,
      videoCodec: 'hevc',
      videoRangeType: 'Hdr10',
      audioCodec: 'aac',
      sizeBytes: 18000000000,
    );
    expect(view.headline, '4K HDR · H.265 · AAC');
    expect(view.detail, contains('HDSWEB'));
    expect(view.detail, contains('WEB-DL'));
    expect(view.compact, '4K HDR');
  });

  test('human edition names stay readable', () {
    final view = formatMediaSource(
      name: '导演剪辑',
      height: 1080,
      videoCodec: 'h264',
    );
    expect(view.headline, '1080p · H.264');
    expect(view.detail, '导演剪辑');
    expect(view.compact, '导演剪辑');
  });

  test('item source presentation uses MediaStreams', () {
    final source = ItemMediaSource.fromJson({
      'Id': 'src-1',
      'Name': '2160p.BILI.WD.264.AAC-UBWEB',
      'Size': 8500000000,
      'Bitrate': 38000000,
      'MediaStreams': [
        {
          'Index': 0,
          'Type': 'Video',
          'Codec': 'h264',
          'Width': 3840,
          'Height': 2160,
          'VideoRange': 'SDR',
        },
        {
          'Index': 1,
          'Type': 'Audio',
          'Codec': 'aac',
          'Channels': 2,
          'DisplayTitle': 'AAC stereo',
        },
      ],
    });
    expect(source.presentation.headline, '4K · H.264 · AAC 2.0');
    expect(source.presentation.detail, contains('BILI'));
    expect(source.presentation.detail, contains('8.5 GB'));
  });
}
