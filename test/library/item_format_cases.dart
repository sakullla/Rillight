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
}
