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
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_sort.dart';

const Map<ShortcutActivator, Intent> _kGridArrowShortcuts = {
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
  }) {
    const spacing = AppSpacing.md;
    // PosterCard 非 wide 布局文字行占位:xs 间距 + 标题行,
    // 与 MediaShelf 行高口径一致。横图分集/继续观看用 16:9。
    const labelExtent = 38.0;
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
  bool _hasMore = false;
  EmbyException? _error;
  late CatalogSort _sort = _defaultSort;

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
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      _load();
    }
  }

  void _maybeLoadMore() {
    if (!_paged || !_hasMore || _loading || _loadingMore) {
      return;
    }
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >=
        position.maxScrollExtent - ShelfGridPage.loadMoreThreshold) {
      _loadMore();
    }
  }

  void _fillViewportIfNeeded() {
    if (!_paged || !_hasMore || _loading || _loadingMore) {
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

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _items = const [];
      _hasMore = false;
      _fetched = 0;
      _autoFills = 0;
    });
    try {
      final page = await _fetch(
        AuthScope.of(context).client,
        0,
        ShelfGridPage.pageSize,
      );
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _items = _applyFilter(page.items);
        _fetched = page.items.length;
        _hasMore =
            _paged &&
            page.hasMore(fetched: _fetched, pageSize: ShelfGridPage.pageSize);
        _loading = false;
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
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final gen = _loadGen;
    final start = _fetched;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetch(
        AuthScope.of(context).client,
        start,
        ShelfGridPage.pageSize,
      );
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _items = [..._items, ..._applyFilter(page.items)];
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
    } on EmbyException {
      if (!mounted || gen != _loadGen) {
        return;
      }
      // 分页追加失败不打断已有内容,保留重试机会(再次滚动到底部重试)。
      setState(() => _loadingMore = false);
    }
  }

  Future<EmbyItemPage> _fetch(EmbyClient client, int startIndex, int limit) {
    switch (widget.source) {
      case 'resume':
        return client.queryResumeItems(
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'nextup':
        return client.queryNextUp(
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'latest-movies':
        return client.queryItems(
          includeItemTypes: 'Movie',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'latest-series':
        return client.queryItems(
          includeItemTypes: 'Series',
          recursive: true,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'similar':
        final itemId = widget.itemId ?? '';
        return client.querySimilar(
          itemId,
          limit: limit,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      default:
        return client.queryItems(
          parentId: widget.parentId,
          includeItemTypes: widget.includeItemTypes,
          recursive: widget.recursive,
          limit: limit,
          startIndex: startIndex,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
    }
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
    _load();
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
    if (_error != null) {
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
      shortcuts: _kGridArrowShortcuts,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: CustomScrollView(
          controller: _scrollController,
          scrollCacheExtent: const ScrollCacheExtent.pixels(400),
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
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.xs,
                AppSpacing.page,
                AppSpacing.xxl,
              ),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  return SliverGrid(
                    gridDelegate: ShelfGridPage.gridDelegateFor(
                      screenWidth: screenWidth,
                      availableWidth: constraints.crossAxisExtent,
                      episodes: _episodes,
                      wide: _wideGrid,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = _items[index];
                        return _EnsureVisibleOnFocus(
                          child: ShelfGridPage.gridCard(
                            context,
                            item,
                            wide: _wideGrid,
                            onTap: () => context.push(AppRoutes.item(item.id)),
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
                                          if (current.id != entry.id) current,
                                      ];
                                    });
                                  }
                                : null,
                          ),
                        );
                      },
                      childCount: _items.length,
                      addAutomaticKeepAlives: false,
                    ),
                  );
                },
              ),
            ),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.xxl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
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
  });

  final String title;
  final Widget? titleOverride;
  final bool showTitle;
  final CatalogSort sort;
  final List<CatalogSort> options;
  final ValueChanged<CatalogSort> onSort;
  final bool showSort;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final heading =
        titleOverride ??
        (showTitle && title.isNotEmpty
            ? Text(title, style: textTheme.headlineSmall)
            : null);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        _headerTopInset(context),
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          if (showSort) ...[
            PopupMenuButton<CatalogSort>(
              key: CatalogKeys.sortBy,
              tooltip: l10n.sortBy,
              color: colorScheme.surface.withValues(alpha: 0.96),
              surfaceTintColor: Colors.transparent,
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
              child: LiquidGlass(
                kind: LiquidGlassKind.pill,
                borderRadius: BorderRadius.circular(AppRadii.md),
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
            if (heading != null) const SizedBox(width: AppSpacing.md),
          ],
          if (heading != null) Expanded(child: heading),
        ],
      ),
    );
  }
}

class _EnsureVisibleOnFocus extends StatelessWidget {
  const _EnsureVisibleOnFocus({required this.child});

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
