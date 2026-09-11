abstract final class AppRoutes {
  static const home = '/';
  static const connect = '/connect';
  static const search = '/search';

  static String library(String viewId) => '/library/$viewId';
  static String item(String itemId) => '/item/$itemId';
  static String play(String itemId, {bool resume = false}) {
    final path = '/play/$itemId';
    return resume ? '$path?resume=1' : path;
  }
}
