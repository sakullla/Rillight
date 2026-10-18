import 'dart:async';
import 'dart:math' as math;

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/desktop_scroll.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/option_pill.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/media_image/media_image.dart';

const Map<ShortcutActivator, Intent> catalogGridArrowShortcuts = {
  SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
    TraversalDirection.left,
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
    TraversalDirection.right,
  ),
  SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
    TraversalDirection.up,
  ),
  SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
    TraversalDirection.down,
  ),
};

/// 网格头部手动刷新按钮(绕过缓存立即重拉)的 key。
const Key gridRefreshKey = Key('catalog-grid-refresh');

/// 网格头部筛选总入口;点开后选择类型/观看状态/年份/流派。
const Key gridFilterMenuKey = Key('catalog-grid-filter-menu');

/// 筛选面板本体;须是不透明表面,海报墙不能透过文字。
const Key gridFilterPanelKey = Key('catalog-grid-filter-panel');

/// 网格头部筛选按钮 key(按维度:type/watch/year/genre)。
Key gridFilterKey(String dimension) => Key('catalog-grid-filter-$dimension');

/// 网格头部筛选选项 key(维度+值)。
Key gridFilterOption(String dimension, String value) =>
    Key('catalog-grid-filter-$dimension-$value');

/// 网格头部清除全部筛选按钮 key。
const Key gridFilterClearKey = Key('catalog-grid-filter-clear');

/// 其他服务器的片库网格使用该服务器会话，而不是首页当前会话。
class ShelfClientOverride extends InheritedWidget {
  const ShelfClientOverride({
    super.key,
    required this.client,
    required super.child,
  });

  final MediaServerClient client;

  static MediaServerClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShelfClientOverride>()?.client;

  @override
  bool updateShouldNotify(ShelfClientOverride oldWidget) =>
      client != oldWidget.client;
}

/// 片库海报的打开方式。未提供时仍进入当前会话的条目路由。
class ShelfItemOpen extends InheritedWidget {
  const ShelfItemOpen({super.key, required this.onOpen, required super.child});

  final ValueChanged<MediaItem> onOpen;

  static ValueChanged<MediaItem>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShelfItemOpen>()?.onOpen;

  @override
  bool updateShouldNotify(ShelfItemOpen oldWidget) =>
      onOpen != oldWidget.onOpen;
}

class ShelfGridPage extends StatefulWidget {
  const ShelfGridPage({
    super.key,
    required this.source,
    this.parentId,
    this.includeItemTypes,
    this.itemId,
    this.title = '',
    this.titleOverride,
    this.showTitle = true,
    this.recursive = false,
    this.moviesOrSeriesOnly = false,
    this.initialGenre,
  });

  final String source;
  final String? parentId;
  final String? includeItemTypes;
  final String? itemId;
  final String title;

  /// 非空时替换头部标题文本(如库页的媒体库切换器)。
  final Widget? titleOverride;

  /// 顶栏已标出当前库时不再在网格上重复库名。
  final bool showTitle;
  final bool recursive;
  final bool moviesOrSeriesOnly;
  final String? initialGenre;

  /// 每页条数:分页加载,避免一次拉全库导致卡顿。similar 只取这一页。
  static const int pageSize = 60;

  /// 滚动距底部不足该像素时预取下一页。
  static const double loadMoreThreshold = 600;

  /// 海报网格列宽上限,随宽度缩放:手机(360–412dp)110、紧凑 180、
  /// 中等 200、宽松 220。手机档让 360dp 得 3 列、412dp 得 4 列。
  static double maxCrossAxisExtentFor(double screenWidth) {
    if (screenWidth < 600) {
      return 110;
    }
    if (screenWidth < AppBreakpoints.compact) {
      return 180;
    }
    if (screenWidth < AppBreakpoints.large) {
      return 200;
    }
    return 220;
  }

  /// 分集横图列宽上限。
  static double maxEpisodeExtentFor(double screenWidth) {
    if (screenWidth < AppBreakpoints.compact) {
      return 260;
    }
    if (screenWidth < AppBreakpoints.large) {
      return 300;
    }
    return 340;
  }

  /// 网格 delegate:列数由可用宽度与列宽上限推导,单元格被卡片精确填满;
  /// 宽高比吸收 PosterCard 竖版海报(2:3)与标题行高,避免溢出。
  static SliverGridDelegate gridDelegateFor({
    required double screenWidth,
    required double availableWidth,
    bool episodes = false,
    bool wide = false,
    double labelExtent = 54.0,
  }) {
    const spacing = AppSpacing.md;
    final landscape = episodes || wide;
    final maxExtent = landscape
        ? maxEpisodeExtentFor(screenWidth)
        : maxCrossAxisExtentFor(screenWidth);
    final count = math.max(1, (availableWidth / maxExtent).ceil());
    final cellWidth = (availableWidth - (count - 1) * spacing) / count;
    final imageHeight = landscape ? cellWidth * 9 / 16 : cellWidth * 1.5;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: count,
      mainAxisSpacing: spacing,
      crossAxisSpacing: spacing,
      mainAxisExtent: (imageHeight + labelExtent).ceilToDouble(),
    );
  }

  /// 网格卡片:宽度取自单元格约束,顶部对齐,多余高度留在底部。
  static Widget gridCard(
    BuildContext context,
    MediaItem item, {
    required VoidCallback onTap,
    ValueChanged<MediaItem>? onRemoveFromResume,
    bool wide = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Align(
          alignment: Alignment.topCenter,
          child: RepaintBoundary(
            child: item.isEpisode
                ? EpisodeThumbCard(
                    item: item,
                    width: constraints.maxWidth,
                    onTap: onTap,
                  )
                : PosterCard(
                    item: item,
                    width: constraints.maxWidth,
                    wide: wide,
                    showProgress: !wide || onRemoveFromResume != null,
                    hoverScale: 1,
                    onTap: onTap,
                    onRemoveFromResume: onRemoveFromResume,
                  ),
          ),
        );
      },
    );
  }

  /// 分页追加按 itemId 去重:服务器排序窗口重叠时不会出现重复条目。
  static List<MediaItem> mergeItemsById(
    Iterable<MediaItem> existing,
    Iterable<MediaItem> incoming,
  ) {
    final merged = List<MediaItem>.of(existing);
    final seen = <String>{for (final item in merged) item.id};
    for (final item in incoming) {
      if (seen.add(item.id)) {
        merged.add(item);
      }
    }
    return merged;
  }

  factory ShelfGridPage.fromState(GoRouterState state) {
    final query = state.uri.queryParameters;
    return ShelfGridPage(
      source: state.pathParameters['source'] ?? '',
      parentId: query['parentId'],
      includeItemTypes: query['includeItemTypes'],
      itemId: query['itemId'],
      title: query['title'] ?? '',
      recursive: query['recursive'] == '1',
      moviesOrSeriesOnly: query['filter'] == 'movieseries',
      initialGenre: query['genre'],
    );
  }

  @override
  State<ShelfGridPage> createState() => _ShelfGridPageState();
}

class _ShelfGridPageState extends State<ShelfGridPage> {
  List<MediaItem> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _refreshing = false;
  bool _hasMore = false;

  /// 服务器报告的条目总数;客户端二次过滤时不可信,置空。
  int? _total;

  /// 页头显示的数量:优先服务器总数,否则只在已全部载入时给出。
  int? get _knownCount {
    if (_items.isEmpty) return null;
    return _total ?? (_hasMore ? null : _items.length);
  }

  MediaServerException? _error;
  MediaServerException? _pageError;
  CatalogSort? _sortState;
  String? _sortOrderOverride;
  String _searchTerm = '';
  final TextEditingController _searchController = TextEditingController();

  CatalogSort get _sort => _sortState ?? _defaultSort;
  String get _sortOrder =>
      CatalogSort.normalizeSortOrder(_sortOrderOverride, fallback: _sort);

  /// 片库组合筛选:类型/年份/流派/已看,与排序叠加生效。
  late ShelfFilters _filters = widget.initialGenre == null
      ? const ShelfFilters()
      : ShelfFilters(genres: [widget.initialGenre!]);

  /// 筛选取值维度:从已加载条目聚合,只增不减,翻页/筛选后取值稳定。
  final Set<int> _knownYears = {};
  final Set<String> _knownGenres = {};
  bool _genresRequested = false;

  CatalogCache? _scopeCache;
  MediaServerClient? _overrideClient;
  final CatalogCache _isolatedCache = CatalogCache();

  /// 目录缓存:其他服务器的网格不写入首页会话缓存。
  CatalogCache get _cache {
    if (_overrideClient != null) {
      return _isolatedCache;
    }
    return _scopeCache ??=
        CatalogScope.maybeOf(context)?.cache ?? CatalogCache();
  }

  MediaServerClient _activeClient() =>
      _overrideClient ?? AuthScope.of(context).client;

  String get _serverKey => _activeClient().baseUrl?.toString() ?? '';

  void _initOrRestoreSort() {
    if (_filterable && widget.parentId != null) {
      final remembered = LibrarySortMemory.read(
        serverKey: _serverKey,
        parentId: widget.parentId!,
        capabilities: _activeClient().capabilities,
      );
      if (remembered != null) {
        _sortState = remembered.$1;
        _sortOrderOverride = remembered.$2;
        return;
      }
    }
    _sortState = _defaultSort;
    _sortOrderOverride = _defaultSort.sortOrder;
  }

  void _persistSort() {
    if (!_filterable || widget.parentId == null) return;
    LibrarySortMemory.write(
      serverKey: _serverKey,
      parentId: widget.parentId!,
      sort: _sort,
      sortOrder: _sortOrder,
    );
  }

  void _prefetchLibraryGenres() {
    if (!_filterable || _genresRequested) return;
    _genresRequested = true;
    final parentId = widget.parentId;
    unawaited(() async {
      try {
        final result = await _activeClient().getLibraryGenres(parentId);
        if (mounted && result.isNotEmpty) {
          setState(() => _knownGenres.addAll(result));
        }
      } catch (_) {}
    }());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _overrideClient = ShelfClientOverride.maybeOf(context);
    if (_sortState == null) {
      _initOrRestoreSort();
      _prefetchLibraryGenres();
    }
  }

  CatalogSort get _defaultSort => widget.includeItemTypes == 'Episode'
      ? CatalogSort.indexNumber
      : CatalogSort.initialFor(_activeClient().capabilities);

  bool get _episodes => widget.includeItemTypes == 'Episode';
  bool get _wideGrid =>
      _episodes || widget.source == 'resume' || widget.source == 'nextup';
  final ScrollController _scrollController = DesktopScrollController();
  int _loadGen = 0;

  /// 已拉取的原始条数(过滤前),作为下一页的 StartIndex。
  int _fetched = 0;

  /// 首屏撑不满时最多自动补的页数,避免把全库连续拉完卡死。
  int _autoFills = 0;
  static const int _maxAutoFills = 2;

  /// similar 接口不支持 StartIndex,只取单页。
  bool get _paged => widget.source != 'similar';

  /// 片库页才提供服务端筛选:其余来源(resume/nextup/similar/latest)的
  /// 接口不支持 Filters/Genres/Years 参数。
  bool get _filterable => widget.source == 'items';

  /// 类型筛选仅在电影+剧集混合的网格上有意义。
  bool get _typeFilterable {
    final types = widget.includeItemTypes?.split(',') ?? const <String>[];
    return types.contains('Movie') && types.contains('Series');
  }

  /// 类型筛选收窄后的 IncludeItemTypes。
  String? get _effectiveIncludeItemTypes {
    final narrowed = _filters.type.itemType;
    if (narrowed != null && _typeFilterable) {
      return narrowed;
    }
    return widget.includeItemTypes;
  }

  List<int> get _yearOptions =>
      [..._knownYears]..sort((a, b) => b.compareTo(a));

  List<String> get _genreOptions => [..._knownGenres]..sort();

  void _collectFilterDimensions(List<MediaItem> items) {
    for (final item in items) {
      final year = item.productionYear;
      if (year != null) {
        _knownYears.add(year);
      }
      _knownGenres.addAll(item.genres);
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  void didUpdateWidget(ShelfGridPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.parentId != widget.parentId ||
        oldWidget.includeItemTypes != widget.includeItemTypes ||
        oldWidget.itemId != widget.itemId ||
        oldWidget.recursive != widget.recursive ||
        oldWidget.moviesOrSeriesOnly != widget.moviesOrSeriesOnly) {
      _genresRequested = false;
      _initOrRestoreSort();
      _prefetchLibraryGenres();
      _filters = const ShelfFilters();
      _searchTerm = '';
      _searchController.clear();
      _knownYears.clear();
      _knownGenres.clear();
      _scrollToTop();
      _load();
    }
  }

  void _maybeLoadMore() {
    if (!_paged ||
        !_hasMore ||
        _loading ||
        _loadingMore ||
        _refreshing ||
        _pageError != null) {
      return;
    }
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    if (position.pixels >=
        position.maxScrollExtent - ShelfGridPage.loadMoreThreshold) {
      _loadMore();
    }
  }

  void _fillViewportIfNeeded() {
    if (!_paged || !_hasMore || _loading || _loadingMore || _refreshing) {
      return;
    }
    if (_autoFills >= _maxAutoFills) {
      return;
    }
    if (!_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _fillViewportIfNeeded();
        }
      });
      return;
    }
    if (!_scrollController.position.hasContentDimensions) return;
    if (_scrollController.position.maxScrollExtent >
        ShelfGridPage.loadMoreThreshold) {
      return;
    }
    _autoFills++;
    _loadMore();
  }

  List<MediaItem> _applyFilter(List<MediaItem> items) {
    if (!widget.moviesOrSeriesOnly) {
      return items;
    }
    return items.where((item) => item.isMovieOrSeries).toList();
  }

  Future<void> _load({bool preserveContent = false}) async {
    final gen = ++_loadGen;
    setState(() {
      _pageError = null;
      if (preserveContent) {
        _refreshing = true;
        _error = null;
      } else {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _items = const [];
        _hasMore = false;
        _total = null;
        _fetched = 0;
        _autoFills = 0;
      }
    });
    final client = _activeClient();
    if (!preserveContent) {
      final hit = await _cache.lookup(
        _requestFor(client, 0, ShelfGridPage.pageSize),
      );
      if (!mounted || gen != _loadGen) {
        return;
      }
      if (hit != null) {
        final page = parseCatalogPage(hit.json);
        _collectFilterDimensions(page.items);
        setState(() {
          _items = ShelfGridPage.mergeItemsById(
            const [],
            _applyFilter(page.items),
          );
          _fetched = page.items.length;
          _hasMore =
              _paged &&
              page.hasMore(fetched: _fetched, pageSize: ShelfGridPage.pageSize);
          _loading = false;
        });
      }
    }
    try {
      final page = await _fetch(client, 0, ShelfGridPage.pageSize);
      if (!mounted || gen != _loadGen) {
        return;
      }
      _collectFilterDimensions(page.items);
      setState(() {
        _items = _applyFilter(page.items);
        _fetched = page.items.length;
        _hasMore =
            _paged &&
            page.hasMore(fetched: _fetched, pageSize: ShelfGridPage.pageSize);
        _total = widget.moviesOrSeriesOnly ? null : page.totalRecordCount;
        _loading = false;
        _refreshing = false;
        _autoFills = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && gen == _loadGen) {
          _fillViewportIfNeeded();
        }
      });
    } on MediaServerException catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = error;
      });
    }
  }

  /// 手动刷新入口:绕过缓存先显,立即重拉并写穿缓存。
  Future<void> _manualRefresh() async {
    if (_loading || _refreshing) {
      return;
    }
    await _load(preserveContent: true);
  }

  Future<void> _loadMore() async {
    if (!_paged || !_hasMore || _loading || _loadingMore || _refreshing) {
      return;
    }
    final gen = _loadGen;
    final start = _fetched;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final page = await _fetch(_activeClient(), start, ShelfGridPage.pageSize);
      if (!mounted || gen != _loadGen) {
        return;
      }
      _collectFilterDimensions(page.items);
      setState(() {
        _items = ShelfGridPage.mergeItemsById(_items, _applyFilter(page.items));
        _fetched = start + page.items.length;
        _hasMore =
            _paged &&
            page.hasMore(fetched: _fetched, pageSize: ShelfGridPage.pageSize);
        _total = widget.moviesOrSeriesOnly ? null : page.totalRecordCount;
        _loadingMore = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && gen == _loadGen) {
          _fillViewportIfNeeded();
        }
      });
    } on MediaServerException catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _pageError = error;
      });
    } finally {
      if (mounted && gen == _loadGen && _loadingMore) {
        setState(() => _loadingMore = false);
      }
    }
  }

  CatalogRequest _requestFor(
    MediaServerClient client,
    int startIndex,
    int limit,
  ) {
    final userId = client.userId ?? '';
    final sortable = client.supportsShelfSorting(widget.source);
    final effectiveOrder = _sort.supportsOrderToggle
        ? _sortOrder
        : _sort.sortOrder;
    final trimmedSearch = _searchTerm.trim();
    switch (widget.source) {
      case 'resume':
        return catalogResumeRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: sortable ? _sort.sortBy : null,
          sortOrder: sortable ? effectiveOrder : null,
        );
      case 'nextup':
        return catalogNextUpRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: sortable ? _sort.sortBy : null,
          sortOrder: sortable ? effectiveOrder : null,
        );
      case 'latest-movies':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Movie',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: sortable ? _sort.sortBy : null,
          sortOrder: sortable ? effectiveOrder : null,
        );
      case 'latest-series':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Series',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: sortable ? _sort.sortBy : null,
          sortOrder: sortable ? effectiveOrder : null,
        );
      case 'similar':
        return catalogSimilarRequest(
          userId: userId,
          itemId: widget.itemId ?? '',
          limit: limit,
          sortBy: sortable ? _sort.sortBy : null,
          sortOrder: sortable ? effectiveOrder : null,
        );
      default:
        return catalogItemsRequest(
          userId: userId,
          parentId: widget.parentId,
          searchTerm: trimmedSearch.isEmpty ? null : trimmedSearch,
          includeItemTypes: _effectiveIncludeItemTypes,
          recursive: widget.recursive,
          limit: limit,
          startIndex: startIndex,
          sortBy: sortable ? _sort.sortBy : null,
          sortOrder: sortable ? effectiveOrder : null,
          filters: _filters.watch.param == null
              ? null
              : [_filters.watch.param!],
          genres: _filters.genres.isEmpty ? null : _filters.genres,
          years: _filters.years.isEmpty ? null : _filters.years,
        );
    }
  }

  /// 经缓存层拉取:总是走网络并写穿缓存(分页追加不读缓存)。
  Future<MediaItemPage> _fetch(
    MediaServerClient client,
    int startIndex,
    int limit,
  ) async {
    final json = await _cache.fetch(
      client,
      _requestFor(client, startIndex, limit),
    );
    return parseCatalogPage(json);
  }

  String _title(AppLocalizations l10n) {
    if (widget.title.isNotEmpty) {
      return widget.title;
    }
    switch (widget.source) {
      case 'resume':
        return l10n.resumeRow;
      case 'nextup':
        return l10n.nextUpRow;
      case 'latest-movies':
        return l10n.latestMoviesRow;
      case 'latest-series':
        return l10n.latestSeriesRow;
      case 'similar':
        return l10n.similarRow;
      default:
        return '';
    }
  }

  void _selectSort(CatalogSort sort, {String? sortOrder}) {
    final nextOrder = !sort.supportsOrderToggle
        ? sort.sortOrder
        : sortOrder != null && sortOrder.isNotEmpty
        ? CatalogSort.normalizeSortOrder(sortOrder, fallback: sort)
        : sort.sortOrder;
    if (sort == _sort && nextOrder == _sortOrder) {
      return;
    }
    setState(() {
      _sortState = sort;
      _sortOrderOverride = nextOrder;
    });
    _persistSort();
    _scrollToTop();
    _load(preserveContent: true);
  }

  void _toggleSortOrder() {
    if (!_sort.supportsOrderToggle) return;
    setState(() {
      _sortOrderOverride = CatalogSort.flipSortOrder(_sortOrder);
    });
    _persistSort();
    _scrollToTop();
    _load(preserveContent: true);
  }

  void _setSearchTerm(String value) {
    final next = value.trim();
    if (next == _searchTerm) return;
    setState(() => _searchTerm = next);
    _scrollToTop();
    _load(preserveContent: true);
  }

  void _selectFilters(
    ShelfFilters filters, {
    CatalogSort? sort,
    String? sortOrder,
  }) {
    var changed = filters != _filters;
    if (sort != null && sort != _sort) {
      _sortState = sort;
      changed = true;
    }
    if (sortOrder != null && sortOrder != _sortOrder) {
      _sortOrderOverride = CatalogSort.normalizeSortOrder(
        sortOrder,
        fallback: _sort,
      );
      changed = true;
    }
    if (!changed) {
      return;
    }
    setState(() => _filters = filters);
    _persistSort();
    _scrollToTop();
    _load(preserveContent: true);
  }

  void _toggleQuickGenre(String? genre) {
    if (genre == null || genre.trim().isEmpty) {
      _selectFilters(_filters.copyWith(genres: const []));
      return;
    }
    final next = [..._filters.genres];
    if (next.contains(genre)) {
      next.remove(genre);
    } else {
      next.add(genre);
    }
    _selectFilters(_filters.copyWith(genres: next));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            title: _title(l10n),
            titleOverride: widget.titleOverride,
            showTitle: widget.showTitle,
            sort: _sort,
            sortOrder: _sortOrder,
            options: const [],
            onSort: _selectSort,
            onToggleSortOrder: _toggleSortOrder,
            showSort: false,
            onRefresh: _manualRefresh,
            refreshing: true,
            filters: _filterable ? _filters : null,
            typeFilterable: _typeFilterable,
            yearOptions: _yearOptions,
            genreOptions: _genreOptions,
            onFiltersChanged: _filterable ? _selectFilters : null,
            onToggleGenre: _filterable ? _toggleQuickGenre : null,
            searchController: _filterable ? _searchController : null,
            onSearchChanged: _filterable ? _setSearchTerm : null,
          ),
          Expanded(
            child: SkeletonPosterGrid(
              maxCrossAxisExtent: ShelfGridPage.maxCrossAxisExtentFor(
                screenWidth,
              ),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.xs,
                AppSpacing.page,
                AppSpacing.xxl,
              ),
            ),
          ),
        ],
      );
    }
    if (_error != null && _items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            title: _title(l10n),
            titleOverride: widget.titleOverride,
            showTitle: widget.showTitle,
            sort: _sort,
            sortOrder: _sortOrder,
            options: CatalogSort.optionsFor(
              _items,
              capabilities: _activeClient().capabilities,
            ),
            onSort: _selectSort,
            onToggleSortOrder: _toggleSortOrder,
            showSort: false,
            onRefresh: _manualRefresh,
            refreshing: false,
            filters: _filterable ? _filters : null,
            typeFilterable: _typeFilterable,
            yearOptions: _yearOptions,
            genreOptions: _genreOptions,
            onFiltersChanged: _filterable ? _selectFilters : null,
            onToggleGenre: _filterable ? _toggleQuickGenre : null,
            searchController: _filterable ? _searchController : null,
            onSearchChanged: _filterable ? _setSearchTerm : null,
          ),
          Expanded(
            child: AppErrorView(
              message: catalogFailureMessage(l10n, _error!),
              onRetry: _load,
            ),
          ),
        ],
      );
    }

    final options = CatalogSort.optionsFor(
      _items,
      capabilities: _activeClient().capabilities,
    );
    return Shortcuts(
      shortcuts: catalogGridArrowShortcuts,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final gridDelegate = ShelfGridPage.gridDelegateFor(
              screenWidth: screenWidth,
              availableWidth: math.max(
                1,
                constraints.maxWidth - AppSpacing.page * 2,
              ),
              episodes: _episodes,
              wide: _wideGrid,
              labelExtent: _wideGrid
                  ? MediaShelf.wideLabelExtentFor(
                      context,
                      customCard: _episodes,
                    )
                  : MediaShelf.posterLabelExtentFor(context),
            );
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.axis == Axis.vertical) {
                  HomeScrollNotification(notification.metrics.pixels > 40)
                      .dispatch(context);
                }
                return false;
              },
              child: MediaImageScrollListener(
                child: CustomScrollView(
                  controller: _scrollController,
                  scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                  slivers: [
                    SliverToBoxAdapter(
                      child: _Header(
                        title: _title(l10n),
                        titleOverride: widget.titleOverride,
                        showTitle: widget.showTitle,
                        sort: _sort,
                        sortOrder: _sortOrder,
                        options: options,
                        onSort: _selectSort,
                        onToggleSortOrder: _toggleSortOrder,
                        showSort:
                            _items.isNotEmpty &&
                            _activeClient().supportsShelfSorting(widget.source),
                        serverOrder: !_activeClient().supportsShelfSorting(
                          widget.source,
                        ),
                        onRefresh: _manualRefresh,
                        refreshing: _refreshing,
                        loadedCount: _knownCount,
                        filters: _filterable ? _filters : null,
                        typeFilterable: _typeFilterable,
                        yearOptions: _yearOptions,
                        genreOptions: _genreOptions,
                        onFiltersChanged: _filterable ? _selectFilters : null,
                        onToggleGenre: _filterable ? _toggleQuickGenre : null,
                        searchController: _filterable
                            ? _searchController
                            : null,
                        onSearchChanged: _filterable ? _setSearchTerm : null,
                      ),
                    ),
                    if (_error != null)
                      SliverToBoxAdapter(
                        child: _failureNotice(_error!, _manualRefresh),
                      ),
                    if (_pageError != null)
                      SliverToBoxAdapter(
                        child: _failureNotice(_pageError!, _loadMore),
                      ),
                    if (_items.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: AppEmptyView(message: l10n.browseEmpty),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.page,
                          AppSpacing.xs,
                          AppSpacing.page,
                          AppSpacing.xxl,
                        ),
                        sliver: SliverGrid(
                          gridDelegate: gridDelegate,
                          delegate: _ShelfChildDelegate(
                            items: _items,
                            wide: _wideGrid,
                            builder: (context, index) {
                              final item = _items[index];
                              return CatalogEnsureVisibleOnFocus(
                                child: ShelfGridPage.gridCard(
                                  context,
                                  item,
                                  wide: _wideGrid,
                                  onTap: () {
                                    final open = ShelfItemOpen.maybeOf(context);
                                    if (open != null) {
                                      open(item);
                                      return;
                                    }
                                    context.push(AppRoutes.item(item.id));
                                  },
                                  onRemoveFromResume: widget.source == 'resume'
                                      ? (entry) {
                                          unawaited(
                                            CatalogScope.of(context)
                                                .hideFromResume(entry),
                                          );
                                          setState(() {
                                            _items = [
                                              for (final current in _items)
                                                if (current.id != entry.id)
                                                  current,
                                            ];
                                          });
                                        }
                                      : null,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    if (_loadingMore)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: AppSpacing.xxl),
                          child: Center(child: CupertinoActivityIndicator()),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _failureNotice(MediaServerException error, VoidCallback retry) {
    final l10n = AppLocalizations.of(context);
    return CatalogInlineFailure(
      message: catalogFailureMessage(l10n, error),
      onRetry: retry,
      retryKey: const Key('catalog-grid-page-retry'),
    );
  }
}

/// 已有条目时的失败说明：保留列表，在区块内给出说明和重试。
class CatalogInlineFailure extends StatelessWidget {
  const CatalogInlineFailure({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryKey,
  });

  final String message;
  final VoidCallback onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.info_circle),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
          AppButton(
            key: retryKey,
            onPressed: onRetry,
            variant: AppButtonVariant.plain,
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }
}

/// 网格子项 delegate:默认 [SliverChildBuilderDelegate.shouldRebuild] 恒为
/// true,页面任何 setState(如分页 footer 出现/消失、刷新态切换)都会把
/// 整屏卡片重建一遍。条目列表未换引用、布局形态未变时跳过。
class _ShelfChildDelegate extends SliverChildBuilderDelegate {
  _ShelfChildDelegate({
    required this.items,
    required this.wide,
    required NullableIndexedWidgetBuilder builder,
  }) : super(builder, childCount: items.length, addAutomaticKeepAlives: false);

  final List<MediaItem> items;
  final bool wide;

  @override
  bool shouldRebuild(covariant _ShelfChildDelegate oldDelegate) {
    return !identical(oldDelegate.items, items) || oldDelegate.wide != wide;
  }
}

/// 叠层顶栏高度 + 页头原有上边距,让标题/排序中心落在栏外可点。
double _headerTopInset(BuildContext context) {
  var inset = AppSpacing.xl;
  if (context.findAncestorWidgetOfExactType<AppShell>() == null) {
    return inset + MediaQuery.viewPaddingOf(context).top;
  }
  final hasChrome =
      context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
  if (!hasChrome) {
    return inset + AppShell.topBarHeight;
  }
  final barHeight = kWindowChromeHeight > AppShell.topBarHeight
      ? kWindowChromeHeight
      : AppShell.topBarHeight;
  return inset + barHeight;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    this.titleOverride,
    this.showTitle = true,
    required this.sort,
    required this.sortOrder,
    required this.options,
    required this.onSort,
    required this.onToggleSortOrder,
    required this.showSort,
    this.onRefresh,
    this.refreshing = false,
    this.loadedCount,
    this.filters,
    this.typeFilterable = false,
    this.yearOptions = const [],
    this.genreOptions = const [],
    this.onFiltersChanged,
    this.onToggleGenre,
    this.searchController,
    this.onSearchChanged,
    this.serverOrder = false,
  });

  final String title;
  final Widget? titleOverride;
  final bool showTitle;
  final CatalogSort sort;
  final String sortOrder;
  final List<CatalogSort> options;
  final void Function(CatalogSort, {String? sortOrder}) onSort;
  final VoidCallback onToggleSortOrder;
  final bool showSort;
  final bool serverOrder;

  final VoidCallback? onRefresh;
  final bool refreshing;
  final int? loadedCount;

  final ShelfFilters? filters;
  final bool typeFilterable;
  final List<int> yearOptions;
  final List<String> genreOptions;
  final void Function(ShelfFilters, {CatalogSort? sort, String? sortOrder})?
  onFiltersChanged;
  final ValueChanged<String?>? onToggleGenre;
  final TextEditingController? searchController;
  final ValueChanged<String>? onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = AppUiTheme.of(context).colorScheme;
    final textTheme = AppUiTheme.of(context).textTheme;
    final heading =
        titleOverride ??
        (showTitle && title.isNotEmpty
            ? Text(
                title,
                style: textTheme.headlineMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              )
            : null);
    final isAsc = CatalogSort.normalizeSortOrder(sortOrder) == 'Ascending';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        _headerTopInset(context),
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ?heading,
                    if (loadedCount != null) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        l10n.browseLoaded(loadedCount!),
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onRefresh != null)
                AppIconButton(
                  key: gridRefreshKey,
                  tooltip: l10n.refresh,
                  color: colorScheme.onSurfaceVariant,
                  onPressed: refreshing ? null : onRefresh,
                  icon: refreshing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CupertinoActivityIndicator(),
                        )
                      : const Icon(CupertinoIcons.arrow_clockwise),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (filters != null && onFiltersChanged != null)
                _FilterBar(
                  filters: filters!,
                  sort: sort,
                  sortOrder: sortOrder,
                  typeFilterable: typeFilterable,
                  yearOptions: yearOptions,
                  genreOptions: genreOptions,
                  onChanged: onFiltersChanged!,
                ),
              if (searchController != null && onSearchChanged != null)
                SizedBox(
                  width: 200,
                  child: AppTextField(
                    key: const Key('catalog-grid-search-field'),
                    controller: searchController,
                    placeholder: l10n.searchHint,
                    onChanged: onSearchChanged,
                    prefix: const Icon(
                      AppIcons.search,
                      fill: AppIcons.filled,
                      size: 16,
                    ),
                    suffix: searchController!.text.isEmpty
                        ? null
                        : AppIconButton(
                            tooltip: l10n.libraryFilterClear,
                            onPressed: () {
                              searchController!.clear();
                              onSearchChanged!('');
                            },
                            icon: const Icon(
                              AppIcons.close,
                              fill: AppIcons.filled,
                              size: 16,
                            ),
                          ),
                  ),
                ),
              if (serverOrder) Text(l10n.providerServerOrder),
              if (showSort) ...[
                AppMenuButton<CatalogSort>(
                  key: CatalogKeys.sortBy,
                  tooltip: l10n.sortBy,
                  padding: EdgeInsets.zero,
                  style: const AppButtonStyle(hoverColor: Color(0x00000000)),
                  selected: sort,
                  onSelected: (selected) => onSort(selected),
                  items: [
                    for (final option in options)
                      AppMenuEntry<CatalogSort>(
                        key: CatalogKeys.sortOption(option.sortBy),
                        value: option,
                        child: Text(option.label(l10n)),
                      ),
                  ],
                  child: _HeaderChip(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isAsc
                                ? CupertinoIcons.sort_up
                                : CupertinoIcons.sort_down,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Text(sort.label(l10n), style: textTheme.labelLarge),
                          const SizedBox(width: AppSpacing.xxs),
                          Icon(
                            CupertinoIcons.chevron_down,
                            size: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (sort.supportsOrderToggle)
                  _HeaderChip(
                    child: AppTooltip(
                      message: isAsc
                          ? l10n.filterSortAscending
                          : l10n.filterSortDescending,
                      child: AppSurfaceAction(
                        key: const Key('catalog-grid-sort-order'),
                        borderRadius: BorderRadius.circular(999),
                        onTap: onToggleSortOrder,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Icon(
                            isAsc
                                ? CupertinoIcons.sort_up
                                : CupertinoIcons.sort_down,
                            size: 16,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
          if (filters != null &&
              onToggleGenre != null &&
              genreOptions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: OptionPill(
                      key: const Key('catalog-grid-quick-genre-all'),
                      label: l10n.libraryFilterAll,
                      selected: filters!.genres.isEmpty,
                      onPressed: () => onToggleGenre!(null),
                    ),
                  ),
                  for (final genre in genreOptions)
                    if (!filters!.genres.contains(genre))
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.xs),
                        child: OptionPill(
                          key: Key('catalog-grid-quick-genre-$genre'),
                          label: genre,
                          selected: false,
                          onPressed: () => onToggleGenre!(genre),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderChip extends StatefulWidget {
  const _HeaderChip({required this.child, this.active = false});

  final Widget child;
  final bool active;

  @override
  State<_HeaderChip> createState() => _HeaderChipState();
}

class _HeaderChipState extends State<_HeaderChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final active = widget.active;
    final rest = active
        ? scheme.primaryContainer
        : (light ? scheme.surfaceContainerLowest : scheme.surfaceContainerHigh);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.durationOf(context, AppMotion.fast),
        curve: AppMotion.standard,
        decoration: BoxDecoration(
          color: _hovered
              ? Color.alphaBlend(scheme.onSurface.withValues(alpha: .05), rest)
              : rest,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? scheme.primary
                : (light
                      ? scheme.onSurface.withValues(alpha: _hovered ? .24 : .14)
                      : scheme.outlineVariant),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: widget.child,
      ),
    );
  }
}

/// 片库头部筛选:一个「筛选」入口 + 已选项可单独去掉,排序单独放在旁边。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filters,
    required this.sort,
    required this.sortOrder,
    required this.typeFilterable,
    required this.yearOptions,
    required this.genreOptions,
    required this.onChanged,
  });

  final ShelfFilters filters;
  final CatalogSort sort;
  final String sortOrder;
  final bool typeFilterable;
  final List<int> yearOptions;
  final List<String> genreOptions;
  final void Function(ShelfFilters, {CatalogSort? sort, String? sortOrder})
  onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = AppUiTheme.of(context).colorScheme;
    final textTheme = AppUiTheme.of(context).textTheme;
    final chips = <Widget>[
      if (typeFilterable && filters.type != CatalogTypeFilter.all)
        _activeChip(
          context,
          label: filters.type.label,
          onDeleted: () =>
              onChanged(filters.copyWith(type: CatalogTypeFilter.all)),
        ),
      if (filters.watch != CatalogWatchFilter.all)
        _activeChip(
          context,
          label: filters.watch.label,
          onDeleted: () =>
              onChanged(filters.copyWith(watch: CatalogWatchFilter.all)),
        ),
      if (filters.years.isNotEmpty)
        _activeChip(
          context,
          label: filters.years.join('、'),
          onDeleted: () => onChanged(filters.copyWith(years: const [])),
        ),
      if (filters.genres.isNotEmpty)
        _activeChip(
          context,
          label: filters.genres.join('、'),
          onDeleted: () => onChanged(filters.copyWith(genres: const [])),
        ),
    ];
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _HeaderChip(
          active: filters.isNotEmpty,
          child: AppTooltip(
            message: l10n.libraryFilter,
            child: AppSurfaceAction(
              key: gridFilterMenuKey,
              borderRadius: BorderRadius.circular(999),
              onTap: () => _openPanel(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.filter,
                      fill: filters.isNotEmpty
                          ? AppIcons.filled
                          : AppIcons.outline,
                      size: 18,
                      color: filters.isNotEmpty
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      l10n.libraryFilter,
                      style: textTheme.labelLarge?.copyWith(
                        color: filters.isNotEmpty
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ...chips,
        if (filters.isNotEmpty)
          AppIconButton(
            key: gridFilterClearKey,
            tooltip: l10n.libraryFilterClear,
            onPressed: () => onChanged(const ShelfFilters()),
            icon: const Icon(AppIcons.close, fill: AppIcons.filled, size: 18),
          ),
      ],
    );
  }

  Future<void> _openPanel(BuildContext context) => showAppDialog<void>(
    context: context,
    builder: (dialogContext) => AppModalFrame(
      clipBehavior: Clip.antiAlias,
      child: LibraryFilterPanel(
        key: gridFilterPanelKey,
        capabilities:
            (ShelfClientOverride.maybeOf(context) ??
                    AuthScope.of(context).client)
                .capabilities,
        initial: filters,
        sort: sort,
        sortOrder: sortOrder,
        years: yearOptions,
        genres: genreOptions,
        loadGenres: () {
          final uri = GoRouter.maybeOf(context)
              ?.routeInformationProvider
              .value
              .uri;
          final parentId = uri?.pathSegments.firstOrNull == 'library'
              ? uri!.pathSegments.last
              : uri?.queryParameters['parentId'];
          final client =
              ShelfClientOverride.maybeOf(context) ??
              AuthScope.of(context).client;
          return client.getLibraryGenres(parentId);
        },
        typeFilterable: typeFilterable,
        onApply: (next, nextSort) => onChanged(next, sort: nextSort),
        onApplyWithOrder: (next, nextSort, nextOrder) =>
            onChanged(next, sort: nextSort, sortOrder: nextOrder),
      ),
    ),
  );

  String l10nLabel(BuildContext context) =>
      AppLocalizations.of(context).libraryFilterAll;

  Widget _activeChip(
    BuildContext context, {
    required String label,
    required VoidCallback onDeleted,
  }) {
    return RemovablePill(label: label, onDeleted: onDeleted);
  }
}

class CatalogEnsureVisibleOnFocus extends StatelessWidget {
  const CatalogEnsureVisibleOnFocus({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (!focused) {
          return;
        }
        final target = context;
        final duration = AppMotion.durationOf(target, AppMotion.fast);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!target.mounted) {
            return;
          }
          Scrollable.ensureVisible(
            target,
            alignment: 0.5,
            duration: duration,
            curve: AppMotion.standard,
          );
        });
      },
      child: child,
    );
  }
}
