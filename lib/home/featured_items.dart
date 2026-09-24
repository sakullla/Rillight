import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';

/// 首页轮播只推有背景图、还没看完的电影和剧集。
///
/// 继续观看单独成行，不重复放进轮播。没有背景图时退回最新电影和剧集，避免横幅空白。
List<EmbyItem> featuredHomeItems(CatalogController catalog, {int limit = 5}) {
  final seen = <String>{};
  final items = <EmbyItem>[];

  void add(EmbyItem item, {required bool requireBackdrop}) {
    if (items.length >= limit) {
      return;
    }
    if (!item.isMovie && !item.isSeries) {
      return;
    }
    if (item.userData.played) {
      return;
    }
    final backdrop = item.backdropImageTag;
    if (requireBackdrop && (backdrop == null || backdrop.isEmpty)) {
      return;
    }
    if (seen.add(item.id)) {
      items.add(item);
    }
  }

  final latest = [...catalog.latestMovies.items, ...catalog.latestSeries.items];
  for (final item in latest) {
    add(item, requireBackdrop: true);
  }
  if (items.isEmpty) {
    for (final item in latest) {
      add(item, requireBackdrop: false);
    }
  }
  return items;
}
