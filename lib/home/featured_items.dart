import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';

/// 首页轮播候选:继续观看优先(进行中的电影与剧集集),其次最新电影、最新
/// 剧集,按 id 去重,最多 [limit] 条。桌面、手机与 TV 共用这一份候选。
///
/// 首轮只收有背景图的条目(集用父级背景图),避免横幅空白;全部落空时放宽
/// 背景图要求兜底,仍保持同样的优先级与去重顺序。
List<EmbyItem> featuredHomeItems(CatalogController catalog, {int limit = 5}) {
  final seen = <String>{};
  final items = <EmbyItem>[];

  bool hasBackdrop(EmbyItem item) {
    final backdrop = item.backdropImageTag ?? item.parentBackdropImageTag;
    return backdrop != null && backdrop.isNotEmpty;
  }

  void add(EmbyItem item, {required bool requireBackdrop}) {
    if (items.length >= limit) {
      return;
    }
    if (!item.isMovie && !item.isSeries && !item.isEpisode) {
      return;
    }
    if (item.userData.played) {
      return;
    }
    if (requireBackdrop && !hasBackdrop(item)) {
      return;
    }
    if (seen.add(item.id)) {
      items.add(item);
    }
  }

  List<EmbyItem> candidates() => [
    ...continueWatchingItems(catalog.resume.items, catalog.nextUp.items),
    ...catalog.latestMovies.items,
    ...catalog.latestSeries.items,
  ];

  for (final item in candidates()) {
    add(item, requireBackdrop: true);
  }
  if (items.isEmpty) {
    for (final item in candidates()) {
      add(item, requireBackdrop: false);
    }
  }
  return items;
}
