abstract final class AppRoutes {
  static const home = '/';
  static const connect = '/connect';
  static const search = '/search';
  static const settings = '/settings';
  static const shelfResume = '/shelf/resume';
  static const shelfNextUp = '/shelf/nextup';
  static const shelfLatestMovies = '/shelf/latest-movies';
  static const shelfLatestSeries = '/shelf/latest-series';

  /// 首页和片库浏览保留库名导航;详情/更多/搜索只留返回与窗口控件。
  static bool showsBrowseNav(String path) {
    if (path == home) {
      return true;
    }
    return path.startsWith('/library/');
  }

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
