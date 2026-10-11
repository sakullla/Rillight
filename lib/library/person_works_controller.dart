import 'package:flutter/foundation.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/library/shelf_grid_page.dart';

/// 当前服务器上某个人物的电影和剧集。
///
/// 请求按上映时间向服务器要页，可见顺序再在客户端排一次：有上映日期的从新到旧，
/// 没有日期的按名称排在后面。非电影、非剧集丢弃。分页失败保留已有条目。
class PersonWorksController extends ChangeNotifier {
  PersonWorksController({
    required this.client,
    required this.cache,
    required this.personId,
  });

  final MediaServerClient client;
  final CatalogCache cache;
  final String personId;

  /// 与片库货架同一页大小。
  static const pageSize = ShelfGridPage.pageSize;

  static const includeItemTypes = 'Movie,Series';

  List<MediaItem> items = const [];
  bool loading = true;
  bool loadingMore = false;
  bool hasMore = false;
  MediaServerException? error;
  MediaServerException? pageError;

  var _fetched = 0;
  var _generation = 0;
  var _disposed = false;

  CatalogRequest requestAt(int startIndex) {
    return catalogItemsRequest(
      userId: client.userId ?? '',
      personIds: [personId],
      includeItemTypes: includeItemTypes,
      recursive: true,
      limit: pageSize,
      startIndex: startIndex,
      sortBy: 'PremiereDate',
      sortOrder: 'Descending',
      fields: MediaServerClient.gridFields,
    );
  }

  /// 有上映日期的从新到旧；没有日期的按名称排在后面。同键保持先出现的顺序。
  /// 非电影、非剧集和重复 id 丢弃。
  static List<MediaItem> arrange(Iterable<MediaItem> source) {
    final accepted = <MediaItem>[];
    final seen = <String>{};
    for (final item in source) {
      if (!item.isMovieOrSeries || !seen.add(item.id)) continue;
      accepted.add(item);
    }
    final order = <String, int>{
      for (var i = 0; i < accepted.length; i++) accepted[i].id: i,
    };
    final dated = <MediaItem>[];
    final undated = <MediaItem>[];
    for (final item in accepted) {
      (item.premiereDate == null ? undated : dated).add(item);
    }
    int tie(MediaItem a, MediaItem b) => order[a.id]!.compareTo(order[b.id]!);
    dated.sort((a, b) {
      final byDate = b.premiereDate!.compareTo(a.premiereDate!);
      return byDate != 0 ? byDate : tie(a, b);
    });
    undated.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : tie(a, b);
    });
    return [...dated, ...undated];
  }

  Future<void> load() async {
    if (_disposed) return;
    if (personId.trim().isEmpty) {
      items = const [];
      loading = false;
      hasMore = false;
      error = null;
      pageError = null;
      _emit();
      return;
    }
    final generation = ++_generation;
    loading = true;
    loadingMore = false;
    error = null;
    pageError = null;
    if (items.isEmpty) {
      hasMore = false;
      _fetched = 0;
    }
    _emit();
    try {
      final page = await _fetch(0);
      if (!_owns(generation)) return;
      items = arrange(page.items);
      _fetched = page.items.length;
      hasMore = page.hasMore(fetched: _fetched, pageSize: pageSize);
      loading = false;
      _emit();
    } catch (error) {
      if (!_owns(generation)) return;
      loading = false;
      this.error = _asEmby(error);
      _emit();
    }
  }

  Future<void> loadMore() async {
    if (_disposed || !hasMore || loading || loadingMore) return;
    final generation = _generation;
    final start = _fetched;
    loadingMore = true;
    pageError = null;
    _emit();
    try {
      final page = await _fetch(start);
      if (!_owns(generation)) return;
      final before = items.length;
      items = arrange([...items, ...page.items]);
      _fetched = start + page.items.length;
      hasMore =
          items.length > before &&
          page.hasMore(fetched: _fetched, pageSize: pageSize);
      loadingMore = false;
      _emit();
    } catch (error) {
      if (!_owns(generation)) return;
      loadingMore = false;
      pageError = _asEmby(error);
      _emit();
    }
  }

  bool _owns(int generation) => !_disposed && generation == _generation;

  Future<MediaItemPage> _fetch(int startIndex) async {
    final json = await cache.fetch(client, requestAt(startIndex));
    return parseCatalogPage(json);
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  MediaServerException _asEmby(Object error) {
    if (error is MediaServerException) return error;
    return MediaServerException(MediaServerFailureKind.unknown, cause: error);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
