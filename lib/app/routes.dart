abstract final class AppRoutes {
  static const home = '/';
  static const connect = '/connect';
  static const search = '/search';
  static const shelfResume = '/shelf/resume';
  static const shelfNextUp = '/shelf/nextup';
  static const shelfLatestMovies = '/shelf/latest-movies';
  static const shelfLatestSeries = '/shelf/latest-series';

  static String library(String viewId) => '/library/$viewId';
  static String item(String itemId) => '/item/$itemId';

  static String shelfItems({
    String? parentId,
    String? includeItemTypes,
    String? title,
    bool recursive = false,
    bool moviesOrSeriesOnly = false,
  }) {
    return Uri(
      path: '/shelf/items',
      queryParameters: {
        if (parentId != null && parentId.isNotEmpty) 'parentId': parentId,
        if (includeItemTypes != null && includeItemTypes.isNotEmpty)
          'includeItemTypes': includeItemTypes,
        if (recursive) 'recursive': '1',
        if (moviesOrSeriesOnly) 'filter': 'movieseries',
        if (title != null && title.isNotEmpty) 'title': title,
      },
    ).toString();
  }

  static String shelfSimilar(String itemId, {String? title}) {
    return Uri(
      path: '/shelf/similar',
      queryParameters: {
        'itemId': itemId,
        if (title != null && title.isNotEmpty) 'title': title,
      },
    ).toString();
  }
}
