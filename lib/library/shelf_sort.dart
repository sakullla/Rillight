import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';

/// 片库排序,字段与 Emby/Jellyfin 中文客户端对齐;默认 [dateUpdated]。
enum CatalogSort {
  dateUpdated('DateLastContentAdded', 'Descending'),
  dateCreated('DateCreated', 'Descending'),
  name('SortName', 'Ascending'),
  communityRating('CommunityRating', 'Descending'),
  criticRating('CriticRating', 'Descending'),
  productionYear('ProductionYear', 'Descending'),
  premiereDate('PremiereDate', 'Descending'),
  officialRating('OfficialRating', 'Ascending'),
  datePlayed('DatePlayed', 'Descending'),
  runtime('Runtime', 'Descending'),
  random('Random', 'Ascending'),
  indexNumber('IndexNumber', 'Ascending');

  const CatalogSort(this.sortBy, this.sortOrder);

  final String sortBy;
  final String sortOrder;

  static const CatalogSort initial = CatalogSort.dateUpdated;

  String label(AppLocalizations l10n) {
    switch (this) {
      case CatalogSort.dateUpdated:
        return l10n.sortByDateUpdated;
      case CatalogSort.dateCreated:
        return l10n.sortByDateCreated;
      case CatalogSort.name:
        return l10n.sortByName;
      case CatalogSort.communityRating:
        return l10n.sortByCommunityRating;
      case CatalogSort.criticRating:
        return l10n.sortByCriticRating;
      case CatalogSort.productionYear:
        return l10n.sortByProductionYear;
      case CatalogSort.premiereDate:
        return l10n.sortByPremiereDate;
      case CatalogSort.officialRating:
        return l10n.sortByOfficialRating;
      case CatalogSort.datePlayed:
        return l10n.sortByDatePlayed;
      case CatalogSort.runtime:
        return l10n.sortByRuntime;
      case CatalogSort.random:
        return l10n.sortByRandom;
      case CatalogSort.indexNumber:
        return l10n.sortByIndexNumber;
    }
  }

  static List<CatalogSort> optionsFor(List<EmbyItem> items) {
    final episodes = items.isNotEmpty && items.every((item) => item.isEpisode);
    if (episodes) {
      return [
        CatalogSort.indexNumber,
        CatalogSort.dateUpdated,
        CatalogSort.dateCreated,
        CatalogSort.name,
      ];
    }
    return const [
      CatalogSort.dateUpdated,
      CatalogSort.dateCreated,
      CatalogSort.name,
      CatalogSort.productionYear,
      CatalogSort.communityRating,
      CatalogSort.random,
    ];
  }
}

/// 片库已看状态筛选,映射到服务端 `Filters` 官方参数。
enum CatalogWatchFilter {
  all(null, '全部'),
  unplayed('IsUnplayed', '未看'),
  played('IsPlayed', '已看');

  const CatalogWatchFilter(this.param, this.label);

  /// /Items 的 Filters 值;null 表示不筛选。
  final String? param;
  final String label;
}

/// 片库类型筛选:收窄服务端 `IncludeItemTypes`(电影/剧集混合库)。
enum CatalogTypeFilter {
  all(null, '全部'),
  movie('Movie', '电影'),
  series('Series', '剧集');

  const CatalogTypeFilter(this.itemType, this.label);

  /// 收窄后的 IncludeItemTypes;null 表示不筛选。
  final String? itemType;
  final String label;
}

/// 片库页组合筛选状态:类型/年份/流派/已看可任意组合,可整体清除。
///
/// 年份与流派在请求侧是多值(Years/Genres 逗号分隔);当前 UI 每维度单选,
/// 多值能力保留给 [EmbyClient.queryItems] 的 API 调用方。
class ShelfFilters {
  const ShelfFilters({
    this.type = CatalogTypeFilter.all,
    this.watch = CatalogWatchFilter.all,
    this.years = const [],
    this.genres = const [],
  });

  final CatalogTypeFilter type;
  final CatalogWatchFilter watch;
  final List<int> years;
  final List<String> genres;

  bool get isEmpty =>
      type == CatalogTypeFilter.all &&
      watch == CatalogWatchFilter.all &&
      years.isEmpty &&
      genres.isEmpty;

  bool get isNotEmpty => !isEmpty;

  ShelfFilters copyWith({
    CatalogTypeFilter? type,
    CatalogWatchFilter? watch,
    List<int>? years,
    List<String>? genres,
  }) {
    return ShelfFilters(
      type: type ?? this.type,
      watch: watch ?? this.watch,
      years: years ?? this.years,
      genres: genres ?? this.genres,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShelfFilters &&
      other.type == type &&
      other.watch == watch &&
      _listEquals(other.years, years) &&
      _listEquals(other.genres, genres);

  @override
  int get hashCode =>
      Object.hash(type, watch, Object.hashAll(years), Object.hashAll(genres));
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
