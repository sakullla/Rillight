import 'package:flutter/widgets.dart';

abstract final class CatalogKeys {
  static const librariesMenu = Key('catalog-libraries-menu');
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
  static const similarRow = Key('catalog-row-similar');
  static const episodesRow = Key('catalog-row-episodes');
  static const sortBy = Key('catalog-sort-by');
  static const mediaSource = Key('catalog-media-source');
  static const detailAudio = Key('catalog-detail-audio');
  static const librarySwitcher = Key('catalog-library-switcher');
  static const heroPrev = Key('catalog-hero-prev');
  static const heroNext = Key('catalog-hero-next');

  static const shelfResume = 'resume';
  static const shelfNextUp = 'nextup';
  static const shelfLatestMovies = 'latest-movies';
  static const shelfLatestSeries = 'latest-series';
  static const shelfSimilar = 'similar';
  static const shelfEpisodes = 'episodes';

  static Key item(String id) => Key('catalog-item-$id');
  static Key library(String id) => Key('catalog-library-$id');
  static Key season(String id) => Key('catalog-season-$id');
  static Key episode(String id) => Key('catalog-episode-$id');
  static Key shelfMore(String shelfId) => Key('catalog-more-$shelfId');
  static Key shelfScrollLeft(String shelfId) =>
      Key('catalog-scroll-left-$shelfId');
  static Key shelfScrollRight(String shelfId) =>
      Key('catalog-scroll-right-$shelfId');
  static Key sortOption(String sortBy) => Key('catalog-sort-$sortBy');
  static Key chapter(int index) => Key('catalog-chapter-$index');
}
