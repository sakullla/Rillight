import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';

class BrowseController extends ChangeNotifier {
  BrowseController({
    required this.auth,
    required this.cache,
    required this.parentId,
    this.includeItemTypes = 'Movie,Series',
  }) {
    _restoreSortFromMemory();
    _identity = _currentIdentity;
    auth.addListener(_onAuth);
  }
  final AuthController auth;
  final CatalogCache cache;
  final String parentId;
  final String includeItemTypes;

  /// 与桌面货架每页 60 条相同。
  static const pageSize = 60;

  List<MediaItem> items = const [];
  bool loading = false, loadingMore = false, hasMore = false;

  /// 服务器报告的当前查询总条数;不报告时为 null。
  int? totalCount;
  bool _liveFirstPageReady = false;
  String? type, watch, genre;
  int? year;
  List<int> years = const [];
  List<String> genres = const [];
  String searchTerm = '';
  late String sortBy;
  String? _sortOrderOverride;

  CatalogSort get defaultSort =>
      CatalogSort.initialFor(auth.client.capabilities);

  CatalogSort get currentSort => CatalogSort.tryBySortBy(sortBy) ?? defaultSort;

  String get sortOrder {
    final override = _sortOrderOverride;
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return _defaultSortOrderFor(sortBy);
  }

  set sortOrder(String value) {
    _sortOrderOverride = CatalogSort.normalizeSortOrder(
      value,
      fallback: currentSort,
    );
  }

  String get _serverKey =>
      auth.session?.server.id ?? auth.client.baseUrl?.toString() ?? '';

  void _restoreSortFromMemory() {
    final remembered = LibrarySortMemory.read(
      serverKey: _serverKey,
      parentId: parentId,
      capabilities: auth.client.capabilities,
    );
    if (remembered != null) {
      sortBy = remembered.$1.sortBy;
      _sortOrderOverride = remembered.$2;
    } else {
      sortBy = defaultSort.sortBy;
      _sortOrderOverride = defaultSort.sortOrder;
    }
  }

  void _persistSortToMemory() {
    final resolved = CatalogSort.tryBySortBy(sortBy);
    if (resolved == null) return;
    LibrarySortMemory.write(
      serverKey: _serverKey,
      parentId: parentId,
      sort: resolved,
      sortOrder: sortOrder,
    );
  }

  MediaServerException? error;
  int _revision = 0, _offset = 0;
  bool _disposed = false;
  late Object _identity;
  Object get _currentIdentity =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);
  void _onAuth() {
    if (_identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _restoreSortFromMemory();
    searchTerm = '';
    _revision++;
    items = const [];
    _offset = 0;
    loading = loadingMore = hasMore = false;
    _liveFirstPageReady = false;
    error = null;
    notifyListeners();
  }

  bool _owns(int revision) =>
      !_disposed && revision == _revision && _identity == _currentIdentity;
  CatalogRequest _request(int startIndex) {
    final trimmedSearch = searchTerm.trim();
    return catalogItemsRequest(
      userId: auth.client.userId ?? '',
      parentId: parentId,
      searchTerm: trimmedSearch.isEmpty ? null : trimmedSearch,
      recursive: true,
      includeItemTypes: type ?? includeItemTypes,
      limit: pageSize,
      startIndex: startIndex,
      sortBy: sortBy,
      sortOrder: sortOrder,
      filters: watch == null ? null : [watch!],
      genres: genres.isNotEmpty
          ? genres
          : genre == null
          ? null
          : [genre!],
      years: years.isNotEmpty
          ? years
          : year == null
          ? null
          : [year!],
    );
  }

  void _apply(MediaItemPage page, int offset, {required bool more}) {
    if (more) {
      final before = items.length;
      items = {
        for (final item in [...items, ...page.items]) item.id: item,
      }.values.toList();
      _offset = offset + page.items.length;
      if (page.items.length < pageSize || items.length == before) {
        hasMore = false;
        return;
      }
    } else {
      items = page.items;
      totalCount = page.totalRecordCount;
      _offset = page.items.length;
      if (page.items.length < pageSize) {
        hasMore = false;
        return;
      }
    }
    hasMore = page.hasMore(fetched: _offset, pageSize: pageSize);
  }

  Future<void> load({bool more = false}) async {
    if (more && (loading || loadingMore || !hasMore || !_liveFirstPageReady)) {
      return;
    }
    final revision = more ? _revision : ++_revision;
    final offset = more ? _offset : 0;
    if (!more) {
      _offset = 0;
      hasMore = false;
      _liveFirstPageReady = false;
    }
    if (more) {
      loadingMore = true;
    } else {
      loading = true;
    }
    error = null;
    notifyListeners();
    if (!_owns(revision)) return;
    final request = _request(offset);
    // Start the live request before a potentially slow or unavailable disk read.
    final network = cache.fetch(auth.client, request);
    var livePageApplied = false;
    // 首屏先画缓存，再后台重拉。已有条目时不拿较短的缓存页盖住，失败也留着。
    if (!more && items.isEmpty) {
      unawaited(() async {
        try {
          final hit = await cache.lookupWhenReady(request);
          if (!_owns(revision) || livePageApplied || hit == null) return;
          _apply(parseCatalogPage(hit.json), offset, more: false);
          loading = false;
          notifyListeners();
        } catch (_) {
          // A damaged cached page must not prevent delivery of the live page.
        }
      }());
    }
    try {
      final page = parseCatalogPage(await network);
      if (!_owns(revision)) return;
      livePageApplied = true;
      if (!more) _liveFirstPageReady = true;
      _apply(page, offset, more: more);
    } catch (failure) {
      if (!_owns(revision)) return;
      error = failure is MediaServerException
          ? failure
          : MediaServerException(
              MediaServerFailureKind.unknown,
              cause: failure,
            );
    }
    if (!_owns(revision)) return;
    loading = false;
    loadingMore = false;
    notifyListeners();
  }

  /// 年份、流派省略或为 null 时清除。二者可选，电视片库可以不传。
  /// 失败的新查询保留已有条目，避免把海报清成空白。
  Future<void> filter({
    String? type,
    String? watch,
    required String sortBy,
    String? sortOrder,
    int? year,
    String? genre,
    List<int>? years,
    List<String>? genres,
    String? searchTerm,
  }) {
    this.type = type;
    this.watch = watch;
    this.years = years ?? (year == null ? const [] : [year]);
    this.year = this.years.firstOrNull;
    this.genres = (genres ?? (genre == null ? const <String>[] : [genre]))
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toSet()
        .toList();
    this.genre = this.genres.firstOrNull;
    this.sortBy = sortBy;
    final resolvedSort = CatalogSort.tryBySortBy(sortBy);
    if (resolvedSort != null && !resolvedSort.supportsOrderToggle) {
      _sortOrderOverride = resolvedSort.sortOrder;
    } else if (sortOrder != null && sortOrder.isNotEmpty) {
      _sortOrderOverride = CatalogSort.normalizeSortOrder(
        sortOrder,
        fallback: resolvedSort,
      );
    } else {
      _sortOrderOverride = _defaultSortOrderFor(sortBy);
    }
    if (searchTerm != null) {
      this.searchTerm = searchTerm.trim();
    }
    _persistSortToMemory();
    return load();
  }

  /// 切换排序字段或正/倒序；若再次选择当前非随机排序且未显式指定方向，则翻转方向。
  Future<void> selectSort(CatalogSort sort, {String? sortOrder}) {
    final String nextOrder;
    if (!sort.supportsOrderToggle) {
      nextOrder = sort.sortOrder;
    } else if (sortOrder != null && sortOrder.isNotEmpty) {
      nextOrder = CatalogSort.normalizeSortOrder(sortOrder, fallback: sort);
    } else if (sort.sortBy == sortBy) {
      nextOrder = CatalogSort.flipSortOrder(this.sortOrder);
    } else {
      nextOrder = sort.sortOrder;
    }
    sortBy = sort.sortBy;
    _sortOrderOverride = nextOrder;
    _persistSortToMemory();
    return load();
  }

  /// 一键翻转当前正/倒序。
  Future<void> toggleSortOrder() {
    if (!currentSort.supportsOrderToggle) return Future<void>.value();
    _sortOrderOverride = CatalogSort.flipSortOrder(sortOrder);
    _persistSortToMemory();
    return load();
  }

  /// 设置库内搜索词并刷新。
  Future<void> setSearchTerm(String value) {
    final next = value.trim();
    if (next == searchTerm) return Future<void>.value();
    searchTerm = next;
    return load();
  }

  /// 切换单个流派胶囊选中态并立即刷新。
  Future<void> toggleGenre(String? targetGenre) {
    if (targetGenre == null || targetGenre.trim().isEmpty) {
      genres = const [];
      genre = null;
      return load();
    }
    final normalized = targetGenre.trim();
    final next = [...genres];
    if (next.isEmpty && genre != null && genre!.isNotEmpty) {
      next.add(genre!);
    }
    if (next.contains(normalized)) {
      next.remove(normalized);
    } else {
      next.add(normalized);
    }
    genres = next;
    genre = genres.firstOrNull;
    return load();
  }

  String _defaultSortOrderFor(String targetSortBy) {
    for (final sort in CatalogSort.values) {
      if (sort.sortBy == targetSortBy) {
        return sort.sortOrder;
      }
    }
    return targetSortBy == 'SortName' ? 'Ascending' : 'Descending';
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
