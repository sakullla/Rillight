import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/catalog_filter_button.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/media_image/media_image.dart';

/// 手机货架。查询与桌面 shelf 的默认排序、分页一致，画面用海报网格。
class PhoneShelfPage extends StatefulWidget {
  const PhoneShelfPage({
    super.key,
    required this.source,
    this.parentId,
    this.includeItemTypes,
    this.itemId,
    this.title = '',
    this.recursive = false,
    this.genre,
  });

  final String source;
  final String? parentId;
  final String? includeItemTypes;
  final String? itemId;
  final String title;
  final bool recursive;
  final String? genre;

  /// 与桌面货架每页条数相同。
  static const pageSize = 60;

  /// 360–412dp 固定 3 列。更宽时增列，单张不会大到一屏只剩两张。
  static int columnCountFor(double width) {
    if (width <= 412) {
      return 3;
    }
    return (width / 130).floor().clamp(3, 6);
  }

  static const loadMoreKey = Key('phone-shelf-load-more');

  factory PhoneShelfPage.fromState(GoRouterState state) {
    final query = state.uri.queryParameters;
    return PhoneShelfPage(
      source: state.pathParameters['source'] ?? '',
      parentId: query['parentId'],
      includeItemTypes: query['includeItemTypes'],
      itemId: query['itemId'],
      title: query['title'] ?? '',
      recursive: query['recursive'] == '1',
      genre: query['genre'],
    );
  }

  @override
  State<PhoneShelfPage> createState() => _PhoneShelfPageState();
}

class _PhoneShelfPageState extends State<PhoneShelfPage> {
  List<EmbyItem> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;

  /// 已有条目上的筛选刷新。飞行期间禁止加载更多。
  bool _refreshing = false;
  bool _hasMore = false;
  EmbyException? _error;
  EmbyException? _pageError;

  /// 筛选刷新失败时保留原列表；重试重拉第 0 页，而不是分页追加。
  EmbyException? _refreshError;
  int _fetched = 0;
  int _loadGen = 0;
  CatalogCache? _fallbackCache;
  AuthController? _auth;
  Object? _identity;

  Object _identityOf(AuthController auth) =>
      (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (identical(auth, _auth)) return;
    _auth?.removeListener(_onAuth);
    _auth = auth;
    _identity = _identityOf(auth);
    auth.addListener(_onAuth);
  }

  void _onAuth() {
    final auth = _auth;
    if (auth == null) return;
    final next = _identityOf(auth);
    if (next == _identity) return;
    _identity = next;
    _loadGen++;
    setState(() {
      _items = const [];
      _fetched = 0;
      _hasMore = false;
      _error = _pageError = _refreshError = null;
    });
    if (auth.isLoggedIn) unawaited(_load());
  }

  @override
  void dispose() {
    _loadGen++;
    _auth?.removeListener(_onAuth);
    super.dispose();
  }

  /// `Filters` 的已看状态。null 表示全部。
  String? _watch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_load());
      }
    });
  }

  @override
  void didUpdateWidget(PhoneShelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.parentId != widget.parentId ||
        oldWidget.includeItemTypes != widget.includeItemTypes ||
        oldWidget.itemId != widget.itemId ||
        oldWidget.recursive != widget.recursive) {
      unawaited(_load());
    }
  }

  CatalogCache get _cache {
    return CatalogScope.maybeOf(context)?.cache ??
        (_fallbackCache ??= CatalogCache());
  }

  String _title(AppLocalizations l10n) {
    if (widget.title.isNotEmpty) {
      return widget.title;
    }
    return switch (widget.source) {
      'resume' => l10n.resumeRow,
      'nextup' => l10n.nextUpRow,
      'latest-movies' => l10n.latestMoviesRow,
      'latest-series' => l10n.latestSeriesRow,
      'similar' => l10n.similarRow,
      _ => '',
    };
  }

  List<String>? get _filters =>
      _watch == null || !_filterable ? null : [_watch!];

  CatalogRequest _request(EmbyClient client, int startIndex, int limit) {
    final userId = client.userId ?? '';
    final sort = CatalogSort.initial;
    final filters = _filters;
    switch (widget.source) {
      case 'resume':
        return catalogResumeRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
      case 'nextup':
        return catalogNextUpRequest(
          userId: userId,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
      case 'latest-movies':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Movie',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
          filters: filters,
        );
      case 'latest-series':
        return catalogItemsRequest(
          userId: userId,
          includeItemTypes: 'Series',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
          filters: filters,
        );
      case 'similar':
        return catalogSimilarRequest(
          userId: userId,
          itemId: widget.itemId?.trim() ?? '',
          limit: limit,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
        );
      default:
        return catalogItemsRequest(
          userId: userId,
          parentId: widget.parentId,
          includeItemTypes: widget.includeItemTypes,
          recursive: widget.recursive,
          limit: limit,
          startIndex: startIndex,
          sortBy: sort.sortBy,
          sortOrder: sort.sortOrder,
          filters: filters,
          genres: widget.genre == null ? null : [widget.genre!],
        );
    }
  }

  void _selectWatch(String? watch) {
    if (watch == _watch) {
      return;
    }
    setState(() => _watch = watch);
    unawaited(_load(keepVisible: true));
  }

  /// similar 接口不支持 StartIndex，只取这一页。
  bool get _paged => widget.source != 'similar';

  /// /Items 支持 Filters。继续观看、下一集和相似项的接口不支持。
  bool get _filterable {
    return switch (widget.source) {
      'resume' || 'nextup' || 'similar' => false,
      _ => true,
    };
  }

  Future<EmbyItemPage> _fetch(int startIndex) async {
    final similarId = widget.itemId?.trim() ?? '';
    if (widget.source == 'similar' && similarId.isEmpty) {
      return const EmbyItemPage(items: []);
    }
    final client = AuthScope.of(context).client;
    final json = await _cache.fetch(
      client,
      _request(client, startIndex, PhoneShelfPage.pageSize),
    );
    return parseCatalogPage(json);
  }

  Future<void> _load({bool keepVisible = false}) async {
    final gen = ++_loadGen;
    final identity = _identity;
    final keep = keepVisible && _items.isNotEmpty;
    final client = AuthScope.of(context).client;
    final request = _request(client, 0, PhoneShelfPage.pageSize);
    final network = _fetch(0);
    unawaited(network.then<void>((_) {}, onError: (Object _) {}));
    bool owns() => mounted && gen == _loadGen && identity == _identity;
    setState(() {
      _loading = !keep;
      _loadingMore = false;
      _refreshing = keep;
      _error = null;
      _pageError = null;
      _refreshError = null;
      if (!keep) {
        _items = const [];
        _hasMore = false;
        _fetched = 0;
      }
    });
    if (!keep) {
      unawaited(() async {
        try {
          final hit = await _cache.lookupWhenReady(request);
          if (!owns() ||
              hit == null ||
              (_items.isNotEmpty || (!_loading && _error == null))) {
            return;
          }
          final cached = parseCatalogPage(hit.json);
          if (cached.items.isEmpty) return;
          setState(() {
            _items = cached.items;
            _fetched = cached.items.length;
            _hasMore = _continues(cached, _fetched, grew: true);
            _refreshError = _error;
            _error = null;
            _loading = false;
            _refreshing = _refreshError == null;
          });
        } catch (_) {
          // A damaged disk row never blocks or replaces the live request.
        }
      }());
    }
    try {
      final page = await network;
      if (!owns()) {
        return;
      }
      setState(() {
        _items = page.items;
        _fetched = page.items.length;
        _hasMore = _continues(page, _fetched, grew: true);
        _loading = false;
        _refreshing = false;
      });
    } catch (error) {
      if (!owns()) {
        return;
      }
      setState(() {
        _loading = false;
        _refreshing = false;
        if (keep) {
          _refreshError = _asEmby(error);
        } else {
          _error = _asEmby(error);
        }
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore ||
        _loading ||
        _loadingMore ||
        _refreshing ||
        _refreshError != null) {
      return;
    }
    final gen = _loadGen;
    final identity = _identity;
    final start = _fetched;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final page = await _fetch(start);
      if (!mounted || gen != _loadGen || identity != _identity) {
        return;
      }
      final before = _items.length;
      final merged = _merge(_items, page.items);
      setState(() {
        _items = merged;
        _fetched = start + page.items.length;
        _hasMore = _continues(page, _fetched, grew: merged.length > before);
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || gen != _loadGen || identity != _identity) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _pageError = _asEmby(error);
      });
    }
  }

  EmbyException _asEmby(Object error) {
    if (error is EmbyException) {
      return error;
    }
    return EmbyException(EmbyFailureKind.unknown, cause: error);
  }

  /// 这一页没铺满，或和已有条目完全重复时，不再请求下一页。
  bool _continues(EmbyItemPage page, int fetched, {required bool grew}) {
    if (!_paged || !grew || page.items.length < PhoneShelfPage.pageSize) {
      return false;
    }
    return page.hasMore(fetched: fetched, pageSize: PhoneShelfPage.pageSize);
  }

  List<EmbyItem> _merge(List<EmbyItem> existing, List<EmbyItem> incoming) {
    final merged = [...existing];
    final seen = {for (final item in merged) item.id};
    for (final item in incoming) {
      if (seen.add(item.id)) {
        merged.add(item);
      }
    }
    return merged;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = _title(l10n);
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_filterable)
            CatalogFilterButton(
              watch: _watch,
              onChanged: _selectWatch,
              buttonKey: const Key('phone-shelf-filter'),
            ),
        ],
      ),
      body: _body(l10n),
    );
  }

  Widget _body(AppLocalizations l10n) {
    final content = _content(l10n);
    if (!_filterable || _watch == null) {
      return content;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogWatchChip(watch: _watch!, onClear: () => _selectWatch(null)),
        Expanded(child: content),
      ],
    );
  }

  Widget _content(AppLocalizations l10n) {
    if (_loading && _items.isEmpty) {
      return const _ShelfGridSkeleton();
    }
    if (_error != null && _items.isEmpty) {
      return MobileFailureState(
        message: catalogFailureMessage(l10n, _error!),
        onRetry: () => unawaited(_load()),
      );
    }
    if (_items.isEmpty) {
      return MobileEmptyState(message: l10n.mobileEmpty);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final metrics = _shelfGridMetrics(constraints.maxWidth, scale);
        if (metrics.tileWidth <= 0 || metrics.tileHeight <= 0) {
          return const SizedBox.shrink();
        }
        final imageWidth = catalogPosterMaxWidth(
          metrics.tileWidth,
          MediaQuery.devicePixelRatioOf(context),
        );
        return MediaImageScrollListener(
          child: CustomScrollView(
            key: PageStorageKey(
              'phone-shelf-${widget.source}|${widget.parentId}|'
              '${widget.itemId}|${widget.genre}|${widget.recursive}|$_watch',
            ),
            scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
            slivers: [
              if (_refreshing)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (_refreshError != null)
                SliverToBoxAdapter(
                  child: MobileFailureState(
                    message: catalogFailureMessage(l10n, _refreshError!),
                    onRetry: () => unawaited(_load(keepVisible: true)),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.all(AppSpacing.md),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: metrics.columns,
                    mainAxisSpacing: metrics.spacing,
                    crossAxisSpacing: metrics.spacing,
                    childAspectRatio: metrics.tileWidth / metrics.tileHeight,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = _items[index];
                      return MobilePoster(
                        key: ValueKey(item.id),
                        item: item,
                        imageMaxWidth: imageWidth,
                      );
                    },
                    childCount: _items.length,
                    addAutomaticKeepAlives: false,
                    findChildIndexCallback: (key) {
                      if (key is! ValueKey<String>) {
                        return null;
                      }
                      final index = _items.indexWhere(
                        (item) => item.id == key.value,
                      );
                      return index < 0 ? null : index;
                    },
                  ),
                ),
              ),
              if (_pageError != null)
                SliverToBoxAdapter(
                  child: MobileFailureState(
                    message: catalogFailureMessage(l10n, _pageError!),
                    onRetry: () => unawaited(_loadMore()),
                  ),
                )
              else if (_hasMore && _refreshError == null)
                SliverToBoxAdapter(
                  child: Center(
                    child: TextButton(
                      key: PhoneShelfPage.loadMoreKey,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed:
                          _loadingMore || _refreshing || _refreshError != null
                          ? null
                          : () => unawaited(_loadMore()),
                      child: Text(l10n.episodesLoadMore),
                    ),
                  ),
                ),
              if (_loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 页边距算在宽度里面。占位和成品共用列数、间距和格子高宽比。
class _ShelfGridMetrics {
  const _ShelfGridMetrics({
    required this.columns,
    required this.spacing,
    required this.tileWidth,
    required this.tileHeight,
  });

  final int columns;
  final double spacing;
  final double tileWidth;
  final double tileHeight;
}

_ShelfGridMetrics _shelfGridMetrics(double outerWidth, double textScale) {
  const spacing = AppSpacing.sm;
  final columns = PhoneShelfPage.columnCountFor(outerWidth);
  final content = math.max(0.0, outerWidth - AppSpacing.md * 2);
  final gaps = spacing * math.max(0, columns - 1);
  final tileWidth = columns <= 0 || content <= gaps
      ? 0.0
      : (content - gaps) / columns;
  return _ShelfGridMetrics(
    columns: columns,
    spacing: spacing,
    tileWidth: tileWidth,
    tileHeight: tileWidth * 1.5 + 32 * textScale,
  );
}

class _ShelfGridSkeleton extends StatelessWidget {
  const _ShelfGridSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final metrics = _shelfGridMetrics(constraints.maxWidth, scale);
        if (metrics.columns <= 0 ||
            metrics.tileWidth <= 0 ||
            metrics.tileHeight <= 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: metrics.columns,
              mainAxisSpacing: metrics.spacing,
              crossAxisSpacing: metrics.spacing,
              childAspectRatio: metrics.tileWidth / metrics.tileHeight,
            ),
            itemCount: metrics.columns * 3,
            itemBuilder: (context, index) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AspectRatio(
                    aspectRatio: 2 / 3,
                    child: SkeletonBlock(animated: false),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SkeletonBlock(
                    width: metrics.tileWidth * 0.72,
                    height: 14,
                    animated: false,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
