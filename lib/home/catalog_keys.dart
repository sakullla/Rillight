import 'package:flutter/widgets.dart';

abstract final class CatalogKeys {
  static const resumeRow = Key('catalog-row-resume');
  static const nextUpRow = Key('catalog-row-nextup');
  static const latestMoviesRow = Key('catalog-row-latest-movies');
  static const latestSeriesRow = Key('catalog-row-latest-series');
  static const searchField = Key('catalog-search-field');
  static const searchSubmit = Key('catalog-search-submit');
  static const searchNoResults = Key('catalog-search-no-results');
  static const playedToggle = Key('catalog-played-toggle');
  static const resumeProgress = Key('catalog-resume-progress');
  static const back = Key('catalog-back');

  static Key item(String id) => Key('catalog-item-$id');
  static Key library(String id) => Key('catalog-library-$id');
  static Key season(String id) => Key('catalog-season-$id');
  static Key episode(String id) => Key('catalog-episode-$id');
}
