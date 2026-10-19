import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/library/source_selection.dart';
import 'package:rillight/media_server/models.dart';

void main() {
  test('version faces keep codec, range, audio and subtitle buckets', () {
    final item = _item([
      _source(
        id: 'hevc',
        name: 'Show.2160p.HDR10.HEVC.AAC-GROUP',
        width: 3840,
        height: 2160,
        video: 'hevc',
        range: 'HDR',
        rangeType: 'HDR10',
        audio: 'aac',
        audioChannels: 6,
        subtitles: const [_Subtitle('chi', '简体'), _Subtitle('eng', 'English')],
      ),
      _source(
        id: 'av1',
        name: 'Show.1080p.DV.AV1.TrueHD-GROUP',
        width: 1920,
        height: 1080,
        video: 'av1',
        rangeType: 'DOVI',
        audio: 'truehd',
        subtitles: const [_Subtitle('jpn', '日本語', external: true)],
      ),
    ]);

    expect(sourceSelectionFaces(item), [
      (
        resolution: '4K',
        range: 'HDR',
        video: 'H.265',
        subtitle: 'zh',
        audio: 'AAC',
      ),
      (
        resolution: '1080p',
        range: '杜比视界',
        video: 'AV1',
        subtitle: 'external',
        audio: 'TrueHD',
      ),
    ]);
    expect(
      sourceSelectionAccepts(item, resolution: '4K', video: 'H.265'),
      isTrue,
    );
    expect(
      sourceSelectionAccepts(item, resolution: '4K', video: 'AV1'),
      isFalse,
    );
    expect(
      sourceSelectionAccepts(item, resolution: '1080p', range: '杜比视界'),
      isTrue,
    );
  });

  test('missing streams stay unknown and are not labeled as no subtitles', () {
    final unnamed = _item([
      const ItemMediaSource(id: 'pixels', width: 1280, height: 720),
    ]);
    expect(sourceSelectionFaces(unnamed).single, (
      resolution: '720p',
      range: null,
      video: null,
      subtitle: null,
      audio: null,
    ));
    expect(sourceSelectionAccepts(unnamed, subtitle: 'none'), isFalse);

    final named = _item([
      const ItemMediaSource(
        id: 'release',
        name: 'Show.2160p.HDR.HEVC.Atmos-GROUP',
      ),
    ]);
    expect(sourceSelectionFaces(named).single, (
      resolution: '4K',
      range: 'HDR',
      video: 'H.265',
      subtitle: null,
      audio: 'Atmos',
    ));
  });

  test('subtitle buckets prefer Chinese, then English, then external', () {
    expect(
      _subtitleOf([
        const _Subtitle('en-GB', 'English'),
        const _Subtitle('zh-Hant', '繁体'),
      ]),
      'zh',
    );
    expect(_subtitleOf([const _Subtitle(null, '中字')]), 'zh');
    expect(_subtitleOf([const _Subtitle('eng', 'commentary')]), 'en');
    expect(_subtitleOf([const _Subtitle(null, 'english')]), 'en');
    expect(
      _subtitleOf([const _Subtitle('fre', 'english subtitles')]),
      'present',
    );
    expect(
      _subtitleOf([const _Subtitle('environment', 'OpenEnglish')]),
      'present',
    );
    expect(
      _subtitleOf([
        const _Subtitle('jpn', '日本語', external: true),
        const _Subtitle('kor', '한국어', external: true),
      ]),
      'external',
    );
    expect(
      _subtitleOf([
        const _Subtitle('jpn', '日本語', external: true),
        const _Subtitle('kor', '한국어'),
      ]),
      'present',
    );
    expect(_subtitleOf(const []), 'none');
  });

  test('an empty item stays visible until a filter is set', () {
    const item = MediaItem(id: 'empty', name: '空', type: 'Movie');
    expect(sourceSelectionFaces(item), isEmpty);
    expect(sourceSelectionAccepts(item), isTrue);
    expect(sourceSelectionAccepts(item, resolution: '1080p'), isFalse);
  });
}

String? _subtitleOf(List<_Subtitle> subtitles) {
  return sourceSelectionFaces(
    _item([_source(id: 'tracked', video: 'h264', subtitles: subtitles)]),
  ).single.subtitle;
}

MediaItem _item(List<ItemMediaSource> sources) =>
    MediaItem(id: 'movie', name: '合成作品', type: 'Movie', mediaSources: sources);

ItemMediaSource _source({
  required String id,
  String? name,
  int? width,
  int? height,
  String? video,
  String? range,
  String? rangeType,
  String? audio,
  int? audioChannels,
  List<_Subtitle> subtitles = const [],
}) {
  return ItemMediaSource(
    id: id,
    name: name,
    width: width,
    height: height,
    streams: [
      if (video != null)
        ItemMediaStream(
          index: 0,
          type: 'Video',
          codec: video,
          width: width,
          height: height,
          videoRange: range,
          videoRangeType: rangeType,
        ),
      if (audio != null)
        ItemMediaStream(
          index: 1,
          type: 'Audio',
          codec: audio,
          channels: audioChannels,
        ),
      for (var index = 0; index < subtitles.length; index++)
        ItemMediaStream(
          index: index + 2,
          type: 'Subtitle',
          language: subtitles[index].language,
          label: subtitles[index].label,
          isExternal: subtitles[index].external,
        ),
    ],
  );
}

class _Subtitle {
  const _Subtitle(this.language, this.label, {this.external = false});
  final String? language;
  final String? label;
  final bool external;
}
