abstract final class AppRoutes {
  static const home = '/';
  static const connect = '/connect';
  static const search = '/search';
  static const settings = '/settings';
  static const shelfResume = '/shelf/resume';
  static const shelfNextUp = '/shelf/nextup';
  static const shelfLatestMovies = '/shelf/latest-movies';
  static const shelfLatestSeries = '/shelf/latest-series';

  /// 完整库导航只在首页显示。
  static bool showsBrowseNav(String path) => path == home;

  /// 条目详情:顶栏浮在 backdrop 上,不占一条实心底。
  static bool isItem(String path) => path.startsWith('/item/');

  static String library(String viewId) => '/library/$viewId';
  static String item(String itemId, {String? seasonId}) {
    final season = seasonId?.trim() ?? '';
    if (season.isEmpty) {
      return '/item/$itemId';
    }
    return Uri(
      path: '/item/$itemId',
      queryParameters: {'season': season},
    ).toString();
  }

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
