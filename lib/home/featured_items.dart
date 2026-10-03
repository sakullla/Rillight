import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/hero_artwork.dart';

/// 首页轮播候选:继续观看优先(进行中的电影与剧集集),其次最新电影、最新
/// 剧集,按电影/所属剧集去重,最多 [limit] 条。桌面、手机与 TV 共用这一份候选。
///
/// 只收有正式背景或海报的条目(单集仅用所属剧集宣传图):仅海报的条目走
/// 海报聚焦版式,两者皆无的条目直接剔除,全部落空时各端隐藏轮播。
List<EmbyItem> featuredHomeItems(CatalogController catalog, {int limit = 5}) {
  final seen = <String>{};
  final items = <EmbyItem>[];

  bool hasArtwork(EmbyItem item) {
    return !heroArtworkSources(
      item,
      series: catalog.latestSeries.items,
    ).isEmpty;
  }

  void add(EmbyItem item) {
    if (items.length >= limit) {
      return;
    }
    if (!item.isMovie && !item.isSeries && !item.isEpisode) {
      return;
    }
    if (item.userData.played) {
      return;
    }
    if (!hasArtwork(item)) {
      return;
    }
    final identity = item.isEpisode && item.seriesId?.isNotEmpty == true
        ? item.seriesId!
        : item.id;
    if (seen.add(identity)) {
      items.add(item);
    }
  }

  for (final item in candidates(catalog)) {
    add(item);
  }
  return items;
}

List<EmbyItem> candidates(CatalogController catalog) => [
  ...continueWatchingItems(catalog.resume.items, catalog.nextUp.items),
  ...catalog.latestMovies.items,
  ...catalog.latestSeries.items,
];
