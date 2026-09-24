abstract final class AppRoutes {
  static const home = '/';
  static const connect = '/connect';
  static const search = '/search';
  static const settings = '/settings';

  /// 手机端"我的"页:底部 tab 移除后经顶栏头像入口进入(仅 phone 路由树注册)。
  static const mine = '/mine';

  /// 手机首页行的顺序和显示。从首页进入，不放在「我的」。
  static const homeEdit = '/home-edit';
  static const shelfResume = '/shelf/resume';
  static const shelfNextUp = '/shelf/nextup';
  static const shelfLatestMovies = '/shelf/latest-movies';
  static const shelfLatestSeries = '/shelf/latest-series';

  /// 完整库导航只在首页显示。
  static bool showsBrowseNav(String path) => path == home;

  /// 条目详情:顶栏浮在 backdrop 上,不占一条实心底。
  static bool isItem(String path) => path.startsWith('/item/');

  static String library(String viewId) => '/library/$viewId';
  static String item(String itemId, {String? seasonId, String? episodeId}) {
    final season = seasonId?.trim() ?? '';
    final episode = episodeId?.trim() ?? '';
    if (season.isEmpty && episode.isEmpty) {
      return '/item/$itemId';
    }
    return Uri(
      path: '/item/$itemId',
      queryParameters: {
        if (season.isNotEmpty) 'season': season,
        if (episode.isNotEmpty) 'episode': episode,
      },
    ).toString();
  }

  static String shelfItems({
    String? parentId,
    String? includeItemTypes,
    String? title,
    String? genre,
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
        if (genre != null && genre.isNotEmpty) 'genre': genre,
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
