import 'package:rillight/emby/emby_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/library/item_format.dart';

void main() {
  test('plainOverview strips tags and entities', () {
    expect(
      plainOverview('<p>Hello<br/>world &amp; friends</p>'),
      'Hello\nworld & friends',
    );
    expect(plainOverview('  '), isNull);
    expect(plainOverview(null), isNull);
  });

  test('continue watching keeps a real episode title and drops filenames', () {
    MediaItem episode(String name) => decodeEmbyMediaItem({
      'Id': 'ep',
      'Name': name,
      'Type': 'Episode',
      'SeriesName': '示例剧集',
      'ParentIndexNumber': 1,
      'IndexNumber': 155,
    });

    expect(continueWatchingSubtitle(episode('第一集')), 'S1E155 · 第一集');
    expect(
      continueWatchingSubtitle(
        episode('S1E155 - S01E155 - 1080p.FLAC.265 10bit.BDRIP'),
      ),
      'S1E155',
    );
  });

  test('numbered episode titles do not repeat a number already named', () {
    MediaItem episode(String name, int? number) => decodeEmbyMediaItem({
      'Id': 'ep',
      'Name': name,
      'Type': 'Episode',
      'IndexNumber': ?number,
    });

    expect(numberedEpisodeTitle(episode('勇者的相遇', 1)), '1. 勇者的相遇');
    expect(numberedEpisodeTitle(episode('第 3 集 · 重逢', 3)), '第 3 集 · 重逢');
    expect(numberedEpisodeTitle(episode('第3话', 3)), '第3话');
    expect(numberedEpisodeTitle(episode('EP03 Pilot', 3)), 'EP03 Pilot');
    expect(numberedEpisodeTitle(episode('03', 3)), '03');
    // 集名里的数字不是本集集数时仍加编号。
    expect(numberedEpisodeTitle(episode('第 2 集', 3)), '3. 第 2 集');
    expect(numberedEpisodeTitle(episode('1984', 2)), '2. 1984');
    expect(numberedEpisodeTitle(episode('无编号', null)), '无编号');
  });

  test('release filenames use resolution and codec, readable names stay', () {
    const release = ItemMediaSource(
      id: 'release',
      name: 'NF.WD.264.AAC-SonyHD',
      height: 1080,
      streams: [
        ItemMediaStream(index: 0, type: 'Video', codec: 'h264', height: 1080),
      ],
    );
    const edition = ItemMediaSource(
      id: 'edition',
      name: '导演剪辑版',
      streams: [
        ItemMediaStream(index: 0, type: 'Video', codec: 'hevc', height: 2160),
      ],
    );
    const twin = ItemMediaSource(
      id: 'twin',
      name: 'Other.Group.1080p.x264-TEAM',
      streams: [
        ItemMediaStream(index: 0, type: 'Video', codec: 'h264', height: 1080),
      ],
    );
    const readable = ItemMediaSource(id: 'short', name: '1080p SDR');
    final sources = [release, edition, twin];
    expect(isReleaseSourceName(release.name!), isTrue);
    expect(isReleaseSourceName(edition.name!), isFalse);
    expect(isReleaseSourceName(readable.name!), isFalse);
    expect(phoneSourceVersionLabel(release, sources), '1080p · H.264 · SonyHD');
    expect(phoneSourceVersionLabel(edition, sources), '导演剪辑版');
    expect(phoneSourceVersionLabel(twin, sources), '1080p · H.264 · TEAM');
    expect(phoneSourceVersionLabel(readable, [readable]), '1080p SDR');
    expect(
      releaseSourcePrimaryText(
        const ItemMediaSource(id: 'parsed', name: 'Show.1080p.HEVC-GROUP'),
      ),
      '1080p · H.265',
    );
  });
}
