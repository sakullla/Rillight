import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_sort.dart';
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

  /// 每页条数:分页加载,避免一次拉全库导致卡顿。similar 只取这一页。
  static const int pageSize = 60;

  /// 滚动距底部不足该像素时预取下一页。
  static const double loadMoreThreshold = 600;

  /// 海报网格列宽上限,随 [AppBreakpoints] 缩放:紧凑 180、中等 200、宽松 220。
  static double maxCrossAxisExtentFor(double screenWidth) {
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
    double labelExtent = 38.0,
  }) {
    const spacing = AppSpacing.md;
    // PosterCard 非 wide 布局文字行占位:xs 间距 + 标题行,
    // 与 MediaShelf 行高口径一致。横图分集/继续观看用 16:9。
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
      childAspectRatio: cellWidth / (imageHeight + labelExtent),
    );
  }

  /// 网格卡片:宽度取自单元格约束,顶部对齐,多余高度留在底部。
  static Widget gridCard(
    BuildContext context,
    EmbyItem item, {
    required VoidCallback onTap,
    ValueChanged<EmbyItem>? onRemoveFromResume,
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
                    showProgress: wide && onRemoveFromResume != null,
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
  static List<EmbyItem> mergeItemsById(
    Iterable<EmbyItem> existing,
    Iterable<EmbyItem> incoming,
  ) {
    final merged = List<EmbyItem>.of(existing);
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
    );
  }

  @override
  State<ShelfGridPage> createState() => _ShelfGridPageState();
}

class _ShelfGridPageState extends State<ShelfGridPage> {
  List<EmbyItem> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _refreshing = false;
  bool _hasMore = false;
  EmbyException? _error;
  EmbyException? _pageError;
  late CatalogSort _sort = _defaultSort;

  /// 片库组合筛选:类型/年份/流派/已看,与排序叠加生效。
  ShelfFilters _filters = const ShelfFilters();

  /// 筛选取值维度:从已加载条目聚合,只增不减,翻页/筛选后取值稳定。
  final Set<int> _knownYears = {};
  final Set<String> _knownGenres = {};

  CatalogCache? _scopeCache;

  /// 目录缓存:无 CatalogScope 时用无会话实例降级直连。
  CatalogCache get _cache =>
      _scopeCache ??= CatalogScope.maybeOf(context)?.cache ?? CatalogCache();

  CatalogSort get _defaultSort => widget.includeItemTypes == 'Episode'
      ? CatalogSort.indexNumber
      : CatalogSort.initial;

  bool get _episodes => widget.includeItemTypes == 'Episode';
  bool get _wideGrid =>
      _episodes || widget.source == 'resume' || widget.source == 'nextup';
  final ScrollController _scrollController = ScrollController();
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

  void _collectFilterDimensions(List<EmbyItem> items) {
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
    super.dispose();
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
      _sort = _defaultSort;
      _filters = const ShelfFilters();
      _knownYears.clear();
      _knownGenres.clear();
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
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

  List<EmbyItem> _applyFilter(List<EmbyItem> items) {
    if (!widget.moviesOrSeriesOnly) {
      return items;
    }
    return items.where((item) => item.isMovieOrSeries).toList();
  }

  Future<void> _load({bool preserveContent = false}) async {
    final gen = ++_loadGen;
    // 切排序/手动刷新保留已有内容增量刷新,不清空整页骨架屏重来。
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
        _fetched = 0;
        _autoFills = 0;
      }
    });
    final client = AuthScope.of(context).client;
    if (!preserveContent) {
      // 先显:命中缓存立即渲染,后台重拉完成后无感更新。
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
        _loading = false;
        _refreshing = false;
        _autoFills = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && gen == _loadGen) {
          _fillViewportIfNeeded();
        }
      });
    } on EmbyException catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _loading = false;
        _refreshing = false;
        // 先显缓存内容时保留显示,可经手动刷新重试;否则展示错误。
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
      final page = await _fetch(
        AuthScope.of(context).client,
        start,
        ShelfGridPage.pageSize,
      );
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
        _loadingMore = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && gen == _loadGen) {
          _fillViewportIfNeeded();
        }
      });
    } on EmbyException catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      // 分页追加失败不打断已有内容,保留重试机会(再次滚动到底部重试)。
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

  CatalogRequest _requestFor(EmbyClient client, int startIndex, int limit) {
    final userId = client.userId ?? '';
    switch (widget.source) {
      case 'resume':
        return catalogResumeRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'nextup':
        return catalogNextUpRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'latest-movies':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Movie',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'latest-series':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Series',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'similar':
        return catalogSimilarRequest(
          userId: userId,
          itemId: widget.itemId ?? '',
          limit: limit,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      default:
        return catalogItemsRequest(
          userId: userId,
          parentId: widget.parentId,
          includeItemTypes: _effectiveIncludeItemTypes,
          recursive: widget.recursive,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
          filters: _filters.watch.param == null
              ? null
              : [_filters.watch.param!],
          genres: _filters.genres.isEmpty ? null : _filters.genres,
          years: _filters.years.isEmpty ? null : _filters.years,
        );
    }
  }

  /// 经缓存层拉取:总是走网络并写穿缓存(分页追加不读缓存)。
  Future<EmbyItemPage> _fetch(
    EmbyClient client,
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

  void _selectSort(CatalogSort sort) {
    if (sort == _sort) {
      return;
    }
    setState(() => _sort = sort);
    // 在已有内容上增量刷新,不出现整页骨架屏重来。
    _load(preserveContent: true);
  }

  void _selectFilters(ShelfFilters filters) {
    if (filters == _filters) {
      return;
    }
    setState(() => _filters = filters);
    // 与切排序一致:保留已有内容增量刷新,不整页骨架屏重来。
    _load(preserveContent: true);
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
            options: const [],
            onSort: _selectSort,
            showSort: false,
            onRefresh: _manualRefresh,
            refreshing: true,
            filters: _filterable ? _filters : null,
            typeFilterable: _typeFilterable,
            yearOptions: _yearOptions,
            genreOptions: _genreOptions,
            onFiltersChanged: _filterable ? _selectFilters : null,
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
            options: CatalogSort.optionsFor(_items),
            onSort: _selectSort,
            showSort: false,
            onRefresh: _manualRefresh,
            refreshing: false,
            filters: _filterable ? _filters : null,
            typeFilterable: _typeFilterable,
            yearOptions: _yearOptions,
            genreOptions: _genreOptions,
            onFiltersChanged: _filterable ? _selectFilters : null,
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

    final options = CatalogSort.optionsFor(_items);
    return Shortcuts(
      shortcuts: catalogGridArrowShortcuts,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        // 列数只依赖页面盒约束宽度,用 box LayoutBuilder 在滚动视图外算一次。
        // 不能用 SliverLayoutBuilder:SliverConstraints 含 scrollOffset,
        // 每滚一帧都不同,会让 SliverGrid 连同整屏卡片每帧重建。
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
                  : MediaShelf.posterLabelExtentFor(
                      context,
                      showProgress: false,
                    ),
            );
            return MediaImageScrollListener(
              child: CustomScrollView(
                controller: _scrollController,
                // 预构建半屏即可,快滑时少把屏幕外海报提前打进磁盘/解码。
                scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                slivers: [
                  SliverToBoxAdapter(
                    child: _Header(
                      title: _title(l10n),
                      titleOverride: widget.titleOverride,
                      showTitle: widget.showTitle,
                      sort: _sort,
                      options: options,
                      onSort: _selectSort,
                      showSort: _items.isNotEmpty,
                      onRefresh: _manualRefresh,
                      refreshing: _refreshing,
                      loadedCount: _items.length,
                      filters: _filterable ? _filters : null,
                      typeFilterable: _typeFilterable,
                      yearOptions: _yearOptions,
                      genreOptions: _genreOptions,
                      onFiltersChanged: _filterable ? _selectFilters : null,
                    ),
                  ),
                  if (_error != null)
                    SliverToBoxAdapter(
                      child: _failureNotice(_error!, _manualRefresh),
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
                                onTap: () =>
                                    context.push(AppRoutes.item(item.id)),
                                onRemoveFromResume: widget.source == 'resume'
                                    ? (entry) {
                                        unawaited(
                                          CatalogScope.of(
                                            context,
                                          ).hideFromResume(entry),
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
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  if (_pageError != null)
                    SliverToBoxAdapter(
                      child: _failureNotice(_pageError!, _loadMore),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _failureNotice(EmbyException error, VoidCallback retry) {
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
          const Icon(Icons.info_outline),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
          TextButton(
            key: retryKey,
            onPressed: onRetry,
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

  final List<EmbyItem> items;
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
    return inset;
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
    required this.options,
    required this.onSort,
    required this.showSort,
    this.onRefresh,
    this.refreshing = false,
    this.loadedCount,
    this.filters,
    this.typeFilterable = false,
    this.yearOptions = const [],
    this.genreOptions = const [],
    this.onFiltersChanged,
  });

  final String title;
  final Widget? titleOverride;
  final bool showTitle;
  final CatalogSort sort;
  final List<CatalogSort> options;
  final ValueChanged<CatalogSort> onSort;
  final bool showSort;

  /// 手动刷新入口:绕过缓存立即重拉。null 时不显示刷新按钮。
  final VoidCallback? onRefresh;
  final bool refreshing;
  final int? loadedCount;

  /// 当前筛选状态;null 时不显示筛选控件(非片库来源)。
  final ShelfFilters? filters;

  /// 电影+剧集混合网格才提供类型筛选。
  final bool typeFilterable;

  /// 年份/流派可选值(从已加载条目聚合)。
  final List<int> yearOptions;
  final List<String> genreOptions;
  final ValueChanged<ShelfFilters>? onFiltersChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
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
          ?heading,
          if (loadedCount != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              l10n.browseLoaded(loadedCount!),
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (onRefresh != null) ...[
                IconButton(
                  key: gridRefreshKey,
                  tooltip: l10n.retry,
                  visualDensity: VisualDensity.compact,
                  onPressed: refreshing ? null : onRefresh,
                  icon: refreshing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (filters != null && onFiltersChanged != null) ...[
                _FilterBar(
                  filters: filters!,
                  typeFilterable: typeFilterable,
                  yearOptions: yearOptions,
                  genreOptions: genreOptions,
                  onChanged: onFiltersChanged!,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (showSort) ...[
                PopupMenuButton<CatalogSort>(
                  key: CatalogKeys.sortBy,
                  tooltip: l10n.sortBy,
                  initialValue: sort,
                  onSelected: onSort,
                  itemBuilder: (context) => [
                    for (final option in options)
                      CheckedPopupMenuItem<CatalogSort>(
                        key: CatalogKeys.sortOption(option.sortBy),
                        value: option,
                        checked: option == sort,
                        child: Text(option.label(l10n)),
                      ),
                  ],
                  child: _HeaderChip(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.sort,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Text(sort.label(l10n), style: textTheme.labelLarge),
                          const SizedBox(width: AppSpacing.xxs),
                          Icon(
                            Icons.arrow_drop_down,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadii.md),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 片库头部筛选:一个「筛选」入口 + 已选项可单独去掉,排序单独放在旁边。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filters,
    required this.typeFilterable,
    required this.yearOptions,
    required this.genreOptions,
    required this.onChanged,
  });

  static const _all = 'all';

  final ShelfFilters filters;
  final bool typeFilterable;
  final List<int> yearOptions;
  final List<String> genreOptions;
  final ValueChanged<ShelfFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
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
          label: '${filters.years.first}',
          onDeleted: () => onChanged(filters.copyWith(years: const [])),
        ),
      if (filters.genres.isNotEmpty)
        _activeChip(
          context,
          label: filters.genres.first,
          onDeleted: () => onChanged(filters.copyWith(genres: const [])),
        ),
    ];
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _HeaderChip(
          child: Tooltip(
            message: l10n.libraryFilter,
            child: InkWell(
              key: gridFilterMenuKey,
              borderRadius: BorderRadius.circular(AppRadii.md),
              onTap: () => _openPanel(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.filter_list_rounded,
                      size: 18,
                      color: filters.isNotEmpty
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(l10n.libraryFilter, style: textTheme.labelLarge),
                  ],
                ),
              ),
            ),
          ),
        ),
        ...chips,
        if (filters.isNotEmpty)
          IconButton(
            key: gridFilterClearKey,
            tooltip: l10n.libraryFilterClear,
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged(const ShelfFilters()),
            icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
          ),
      ],
    );
  }

  Future<void> _openPanel(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 草稿:面板内选择仅暂存,点击「确定」才生效;取消/点遮罩丢弃。
    var draft = filters;
    await showDialog<void>(
      context: context,
      barrierColor: scheme.scrim.withValues(
        alpha: AppScrim.of(context, AppScrim.barrier),
      ),
      builder: (dialogContext) {
        Widget dimensionChips({
          required String dimension,
          required String label,
          required List<(String, String)> options,
          required String selected,
          required ValueChanged<String> onSelected,
        }) {
          return Column(
            key: gridFilterKey(dimension),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: theme.textTheme.labelLarge),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final (value, optionLabel) in options)
                    ChoiceChip(
                      key: gridFilterOption(dimension, value),
                      label: Text(optionLabel),
                      selected: value == selected,
                      onSelected: (_) => onSelected(value),
                    ),
                ],
              ),
            ],
          );
        }

        return StatefulBuilder(
          builder: (dialogContext, setPanelState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Material(
                  key: gridFilterPanelKey,
                  color: scheme.surfaceContainerHigh,
                  elevation: 12,
                  shadowColor: Colors.black.withValues(alpha: 0.45),
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.xl),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: AppGlass.edgeLight),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.md,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10n.libraryFilter,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (typeFilterable) ...[
                          dimensionChips(
                            dimension: 'type',
                            label: l10n.libraryFilterType,
                            options: [
                              for (final option in CatalogTypeFilter.values)
                                (
                                  option.itemType ?? _all,
                                  option == CatalogTypeFilter.all
                                      ? l10n.libraryFilterAll
                                      : option.label,
                                ),
                            ],
                            selected: draft.type.itemType ?? _all,
                            onSelected: (value) => setPanelState(() {
                              draft = draft.copyWith(
                                type: value == 'Movie'
                                    ? CatalogTypeFilter.movie
                                    : value == 'Series'
                                    ? CatalogTypeFilter.series
                                    : CatalogTypeFilter.all,
                              );
                            }),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                        dimensionChips(
                          dimension: 'watch',
                          label: l10n.libraryFilterWatch,
                          options: [
                            for (final option in CatalogWatchFilter.values)
                              (
                                option.param ?? _all,
                                option == CatalogWatchFilter.all
                                    ? l10n.libraryFilterAll
                                    : option.label,
                              ),
                          ],
                          selected: draft.watch.param ?? _all,
                          onSelected: (value) => setPanelState(() {
                            draft = draft.copyWith(
                              watch: value == 'IsUnplayed'
                                  ? CatalogWatchFilter.unplayed
                                  : value == 'IsPlayed'
                                  ? CatalogWatchFilter.played
                                  : CatalogWatchFilter.all,
                            );
                          }),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        dimensionChips(
                          dimension: 'year',
                          label: l10n.libraryFilterYear,
                          options: [
                            (_all, l10n.libraryFilterAll),
                            for (final year in yearOptions) ('$year', '$year'),
                          ],
                          selected: draft.years.isEmpty
                              ? _all
                              : '${draft.years.first}',
                          onSelected: (value) => setPanelState(() {
                            draft = draft.copyWith(
                              years: value == _all
                                  ? const []
                                  : [int.parse(value)],
                            );
                          }),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        dimensionChips(
                          dimension: 'genre',
                          label: l10n.libraryFilterGenre,
                          options: [
                            (_all, l10n.libraryFilterAll),
                            for (final genre in genreOptions) (genre, genre),
                          ],
                          selected: draft.genres.isEmpty
                              ? _all
                              : draft.genres.first,
                          onSelected: (value) => setPanelState(() {
                            draft = draft.copyWith(
                              genres: value == _all ? const [] : [value],
                            );
                          }),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Wrap(
                            spacing: AppSpacing.xs,
                            children: [
                              if (draft.isNotEmpty)
                                TextButton(
                                  onPressed: () => setPanelState(
                                    () => draft = const ShelfFilters(),
                                  ),
                                  child: Text(l10n.libraryFilterClear),
                                ),
                              TextButton(
                                onPressed: () => Navigator.pop(dialogContext),
                                child: Text(l10n.libraryFilterCancel),
                              ),
                              TextButton(
                                onPressed: () {
                                  onChanged(draft);
                                  Navigator.pop(dialogContext);
                                },
                                child: Text(
                                  MaterialLocalizations.of(
                                    dialogContext,
                                  ).okButtonLabel,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  String l10nLabel(BuildContext context) =>
      AppLocalizations.of(context).libraryFilterAll;

  Widget _activeChip(
    BuildContext context, {
    required String label,
    required VoidCallback onDeleted,
  }) {
    return InputChip(
      visualDensity: VisualDensity.compact,
      label: Text(label),
      onDeleted: onDeleted,
      deleteIcon: const Icon(Icons.close_rounded, size: 16),
    );
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
