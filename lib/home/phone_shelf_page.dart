import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
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
  bool _hasMore = false;
  EmbyException? _error;
  EmbyException? _pageError;
  int _fetched = 0;
  int _loadGen = 0;
  CatalogCache? _fallbackCache;

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
    unawaited(_load());
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

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _pageError = null;
      _items = const [];
      _hasMore = false;
      _fetched = 0;
    });
    try {
      final page = await _fetch(0);
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _items = page.items;
        _fetched = page.items.length;
        _hasMore = _continues(page, _fetched, grew: true);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _loading = false;
        _error = _asEmby(error);
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loading || _loadingMore) {
      return;
    }
    final gen = _loadGen;
    final start = _fetched;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final page = await _fetch(start);
      if (!mounted || gen != _loadGen) {
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
      if (!mounted || gen != _loadGen) {
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
        final columns = PhoneShelfPage.columnCountFor(constraints.maxWidth);
        final tileWidth = constraints.maxWidth / columns;
        final tileHeight = tileWidth * 1.5 + 32 * scale;
        final imageWidth = catalogPosterMaxWidth(
          tileWidth,
          MediaQuery.devicePixelRatioOf(context),
        );
        return MediaImageScrollListener(
          child: CustomScrollView(
            scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(AppSpacing.md),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: AppSpacing.sm,
                    crossAxisSpacing: AppSpacing.sm,
                    childAspectRatio: tileWidth / tileHeight,
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
              else if (_hasMore)
                SliverToBoxAdapter(
                  child: Center(
                    child: TextButton(
                      key: PhoneShelfPage.loadMoreKey,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: _loadingMore
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

class _ShelfGridSkeleton extends StatelessWidget {
  const _ShelfGridSkeleton();

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppSpacing.sm;
        final columns = PhoneShelfPage.columnCountFor(constraints.maxWidth);
        final tile = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (var i = 0; i < columns * 3; i++)
                SizedBox(
                  width: tile,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBlock(
                        width: tile,
                        height: tile * 1.5,
                        animated: animate,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      SkeletonBlock(
                        width: tile * 0.72,
                        height: 14,
                        animated: animate,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
