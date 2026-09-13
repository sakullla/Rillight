import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_models.dart';

void main() {
  test('TotalRecordCount drives hasMore past a short first page', () {
    const page = EmbyItemPage(
      items: [EmbyItem(id: 'a', name: 'A', type: 'Series')],
      totalRecordCount: 80,
    );
    expect(page.hasMore(fetched: 1, pageSize: 60), isTrue);
    expect(parseEmbyTotalCount({'Items': [], 'TotalRecordCount': 80}), 80);
  });

  test('parses episode thumb and series image tags', () {
    final item = EmbyItem.fromJson({
      'Id': 'ep-1',
      'Name': '北风',
      'Type': 'Episode',
      'SeriesId': 'series-1',
      'ImageTags': {'Thumb': 'thumb-1'},
      'SeriesPrimaryImageTag': 'series-primary',
      'ParentBackdropItemId': 'series-1',
      'ParentBackdropImageTags': ['back-1'],
    });
    expect(item.thumbImageTag, 'thumb-1');
    expect(item.primaryImageTag, isNull);
    expect(item.seriesPrimaryImageTag, 'series-primary');
    expect(item.parentBackdropItemId, 'series-1');
    expect(item.parentBackdropImageTag, 'back-1');
    expect(ItemChapter.fromJson({'Name': 'C', 'ImageIndex': 2}).imageIndex, 2);

    final refs = item.imageCandidates(preferThumb: true);
    expect(refs.first.type, 'Thumb');
    expect(refs.first.itemId, 'ep-1');
    expect(
      refs.map((ref) => '${ref.itemId}:${ref.type}'),
      isNot(contains('series-1:Primary')),
    );
  });

  test('episode without a still falls back to series landscape art', () {
    final item = EmbyItem.fromJson({
      'Id': 'ep-empty',
      'Name': '无剧照',
      'Type': 'Episode',
      'SeriesId': 'series-1',
      'ParentThumbItemId': 'series-1',
      'ParentThumbImageTag': 'series-thumb',
      'ParentBackdropItemId': 'series-1',
      'ParentBackdropImageTags': ['back-1'],
    });
    final refs = item.imageCandidates(preferThumb: true);
    expect(
      refs.map((ref) => '${ref.itemId}:${ref.type}').toList(),
      containsAll(['series-1:Thumb', 'series-1:Backdrop']),
    );
    expect(
      refs.map((ref) => '${ref.itemId}:${ref.type}'),
      isNot(contains('series-1:Primary')),
    );
  });

  test('episode landscape skips series poster used as Primary', () {
    final item = EmbyItem.fromJson({
      'Id': 'ep-2',
      'Name': '无剧照',
      'Type': 'Episode',
      'SeriesId': 'series-1',
      'ImageTags': {'Primary': 'series-primary'},
      'SeriesPrimaryImageTag': 'series-primary',
    });
    final refs = item.imageCandidates(preferThumb: true);
    expect(
      refs.map((ref) => '${ref.itemId}:${ref.type}'),
      isNot(contains('ep-2:Thumb')),
    );
    expect(
      refs.map((ref) => '${ref.itemId}:${ref.type}'),
      isNot(contains('series-1:Primary')),
    );
    expect(
      refs.where((ref) => ref.itemId == 'ep-2' && ref.type == 'Primary'),
      isEmpty,
    );
  });

  test('episode billboard prefers episode thumb over series backdrop', () {
    final item = EmbyItem.fromJson({
      'Id': 'ep-3',
      'Name': '小魔崽子',
      'Type': 'Episode',
      'SeriesId': 'series-1',
      'ImageTags': {'Thumb': 'thumb-3'},
      'ParentBackdropItemId': 'series-1',
      'ParentBackdropImageTags': ['back-1'],
    });
    final refs = item.imageCandidates(preferBackdrop: true);
    expect(refs.first.itemId, 'ep-3');
    expect(refs.first.type, 'Thumb');
    expect(
      refs.map((ref) => '${ref.itemId}:${ref.type}').toList(),
      containsAllInOrder(['ep-3:Thumb', 'series-1:Backdrop']),
    );
  });
}
