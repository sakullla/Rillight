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
