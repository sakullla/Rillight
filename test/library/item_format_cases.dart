import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_models.dart';
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
    EmbyItem episode(String name) => EmbyItem.fromJson({
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
    EmbyItem episode(String name, int? number) => EmbyItem.fromJson({
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
}
