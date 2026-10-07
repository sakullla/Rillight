import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/hero_artwork.dart';

/// 首页轮播候选:只取片库里最近入库/更新的电影与剧集,电影与剧集交替排列,
/// 最多 [limit] 条。桌面、手机与 TV 共用这一份候选。
///
/// 轮播是片库的「橱窗」,不是观看记录:继续观看、下一集与已看进度一律不进
/// 候选,也不参与排序;观看记录由各自的货架行承载。
///
/// 只收有正式背景或海报的条目:仅海报的条目走海报聚焦版式,两者皆无的条目
/// 直接剔除,全部落空时各端隐藏轮播。
List<EmbyItem> featuredHomeItems(CatalogController catalog, {int limit = 5}) {
  final seen = <String>{};
  final items = <EmbyItem>[];

  bool hasArtwork(EmbyItem item) {
    return !heroArtworkSources(
      item,
      series: catalog.latestSeries.items,
    ).isEmpty;
  }

  bool add(EmbyItem item) {
    if (items.length >= limit) {
      return false;
    }
    if (!item.isMovie && !item.isSeries) {
      return false;
    }
    if (!hasArtwork(item)) {
      return false;
    }
    if (!seen.add(item.id)) {
      return false;
    }
    items.add(item);
    return true;
  }

  final movies = catalog.latestMovies.items.iterator;
  final series = catalog.latestSeries.items.iterator;
  var moviesLeft = true;
  var seriesLeft = true;
  // 交替取一部电影、一部剧集;一侧耗尽后由另一侧补满。
  while (items.length < limit && (moviesLeft || seriesLeft)) {
    if (moviesLeft) {
      moviesLeft = _addNext(movies, add);
    }
    if (items.length >= limit) break;
    if (seriesLeft) {
      seriesLeft = _addNext(series, add);
    }
  }
  return items;
}

/// 从 [source] 推进到下一条可入选的条目;源耗尽时返回 false。
bool _addNext(Iterator<EmbyItem> source, bool Function(EmbyItem) add) {
  while (source.moveNext()) {
    if (add(source.current)) {
      return true;
    }
  }
  return false;
}
