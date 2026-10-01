import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/hero_artwork.dart';

/// 首页轮播候选:继续观看优先(进行中的电影与剧集集),其次最新电影、最新
/// 剧集,按电影/所属剧集去重,最多 [limit] 条。桌面、手机与 TV 共用这一份候选。
///
/// 首轮只收有正式背景或海报的条目(单集仅用所属剧集宣传图),避免横幅空白;全部落空时放宽
/// 宣传图要求兜底,仍保持同样的优先级与去重顺序。
List<EmbyItem> featuredHomeItems(CatalogController catalog, {int limit = 5}) {
  final seen = <String>{};
  final items = <EmbyItem>[];

  bool hasArtwork(EmbyItem item) {
    return !heroArtworkSources(
      item,
      series: catalog.latestSeries.items,
    ).isEmpty;
  }

  void add(EmbyItem item, {required bool requireArtwork}) {
    if (items.length >= limit) {
      return;
    }
    if (!item.isMovie && !item.isSeries && !item.isEpisode) {
      return;
    }
    if (item.userData.played) {
      return;
    }
    if (requireArtwork && !hasArtwork(item)) {
      return;
    }
    final identity = item.isEpisode && item.seriesId?.isNotEmpty == true
        ? item.seriesId!
        : item.id;
    if (seen.add(identity)) {
      items.add(item);
    }
  }

  List<EmbyItem> candidates() => [
    ...continueWatchingItems(catalog.resume.items, catalog.nextUp.items),
    ...catalog.latestMovies.items,
    ...catalog.latestSeries.items,
  ];

  for (final item in candidates()) {
    add(item, requireArtwork: true);
  }
  if (items.isEmpty) {
    for (final item in candidates()) {
      add(item, requireArtwork: false);
    }
  }
  return items;
}
