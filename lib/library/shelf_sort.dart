import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';

enum CatalogSort {
  name('SortName', 'Ascending'),
  dateCreated('DateCreated', 'Descending'),
  premiereDate('PremiereDate', 'Descending'),
  rating('CommunityRating', 'Descending');

  const CatalogSort(this.sortBy, this.sortOrder);

  final String sortBy;
  final String sortOrder;

  static const CatalogSort initial = CatalogSort.dateCreated;

  String label(AppLocalizations l10n) {
    switch (this) {
      case CatalogSort.name:
        return l10n.sortByName;
      case CatalogSort.dateCreated:
        return l10n.sortByDateCreated;
      case CatalogSort.premiereDate:
        return l10n.sortByPremiereDate;
      case CatalogSort.rating:
        return l10n.sortByRating;
    }
  }

  static List<CatalogSort> optionsFor(List<EmbyItem> items) {
    return [
      CatalogSort.name,
      CatalogSort.dateCreated,
      CatalogSort.premiereDate,
      if (items.any((item) => item.communityRating != null)) CatalogSort.rating,
    ];
  }
}
