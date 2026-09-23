import 'package:flutter/foundation.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/shelf_sort.dart';

class BrowseController extends ChangeNotifier {
  BrowseController({
    required this.auth,
    required this.cache,
    required this.parentId,
  }) {
    _identity = _currentIdentity;
    auth.addListener(_onAuth);
  }
  final AuthController auth;
  final CatalogCache cache;
  final String parentId;
  List<EmbyItem> items = const [];
  bool loading = false, hasMore = false;
  String? type, watch, genre;
  int? year;
  String sortBy = 'SortName';
  EmbyException? error;
  int _revision = 0, _offset = 0;
  bool _disposed = false;
  late Object _identity;
  Object get _currentIdentity =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);
  void _onAuth() {
    if (_identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _revision++;
    items = const [];
    _offset = 0;
    loading = hasMore = false;
    error = null;
    notifyListeners();
  }

  bool _owns(int revision) =>
      !_disposed && revision == _revision && _identity == _currentIdentity;
  Future<void> load({bool more = false}) async {
    if (more && (loading || !hasMore)) return;
    final revision = more ? _revision : ++_revision;
    final offset = more ? _offset : 0;
    if (!more) {
      _offset = 0;
      hasMore = false;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final page = parseCatalogPage(
        await cache.fetch(
          auth.client,
          catalogItemsRequest(
            userId: auth.client.userId ?? '',
            parentId: parentId,
            recursive: true,
            includeItemTypes: type ?? 'Movie,Series',
            limit: 50,
            startIndex: offset,
            sortBy: sortBy,
            sortOrder: _sortOrder,
            filters: watch == null ? null : [watch!],
            genres: genre == null ? null : [genre!],
            years: year == null ? null : [year!],
          ),
        ),
      );
      if (!_owns(revision)) return;
      items = {
        for (final item in [...(more ? items : <EmbyItem>[]), ...page.items])
          item.id: item,
      }.values.toList();
      _offset = offset + page.items.length;
      hasMore = page.totalRecordCount == null
          ? page.items.length == 50
          : _offset < page.totalRecordCount!;
    } catch (failure) {
      if (!_owns(revision)) return;
      error = failure is EmbyException
          ? failure
          : EmbyException(EmbyFailureKind.unknown, cause: failure);
    }
    if (!_owns(revision)) return;
    loading = false;
    notifyListeners();
  }

  /// 年份、流派省略或为 null 时清除。二者可选，电视片库可以不传。
  /// 失败的新查询保留已有条目，避免把海报清成空白。
  Future<void> filter({
    String? type,
    String? watch,
    required String sortBy,
    int? year,
    String? genre,
  }) {
    this.type = type;
    this.watch = watch;
    this.year = year;
    final trimmed = genre?.trim();
    this.genre = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    this.sortBy = sortBy;
    return load();
  }

  String get _sortOrder {
    for (final sort in CatalogSort.values) {
      if (sort.sortBy == sortBy) {
        return sort.sortOrder;
      }
    }
    return sortBy == 'SortName' ? 'Ascending' : 'Descending';
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
