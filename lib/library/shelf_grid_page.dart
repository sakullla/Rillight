import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/shelf_sort.dart';

class ShelfGridPage extends StatefulWidget {
  const ShelfGridPage({
    super.key,
    required this.source,
    this.parentId,
    this.includeItemTypes,
    this.itemId,
    this.title = '',
    this.recursive = false,
    this.moviesOrSeriesOnly = false,
  });

  final String source;
  final String? parentId;
  final String? includeItemTypes;
  final String? itemId;
  final String title;
  final bool recursive;
  final bool moviesOrSeriesOnly;

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

  /// 网格 delegate:列数由可用宽度与列宽上限推导,单元格被卡片精确填满;
  /// 宽高比吸收 PosterCard 竖版海报(2:3)与标题行高,避免溢出。
  static SliverGridDelegate gridDelegateFor({
    required double screenWidth,
    required double availableWidth,
  }) {
    const spacing = AppSpacing.md;
    // PosterCard 非 wide 布局文字行占位:xs 间距 + 标题行,
    // 与 MediaShelf 行高口径一致。
    const labelExtent = 30.0;
    final count = math.max(
      1,
      (availableWidth / maxCrossAxisExtentFor(screenWidth)).ceil(),
    );
    final cellWidth = (availableWidth - (count - 1) * spacing) / count;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: count,
      mainAxisSpacing: spacing,
      crossAxisSpacing: spacing,
      childAspectRatio: cellWidth / (cellWidth * 1.5 + labelExtent),
    );
  }

  /// 网格卡片:宽度取自单元格约束,顶部对齐,多余高度留在底部。
  static Widget gridCard(
    BuildContext context,
    EmbyItem item, {
    required VoidCallback onTap,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Align(
          alignment: Alignment.topCenter,
          child: PosterCard(
            item: item,
            width: constraints.maxWidth,
            onTap: onTap,
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
  EmbyException? _error;
  CatalogSort _sort = CatalogSort.initial;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
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
      _sort = CatalogSort.initial;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _fetch(AuthScope.of(context).client);
      if (!mounted) {
        return;
      }
      var visible = items;
      if (widget.moviesOrSeriesOnly) {
        visible = items.where((item) => item.isMovieOrSeries).toList();
      }
      setState(() {
        _items = visible;
        _loading = false;
      });
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<List<EmbyItem>> _fetch(EmbyClient client) {
    switch (widget.source) {
      case 'resume':
        return client.getResumeItems(
          limit: 200,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'nextup':
        return client.getNextUp(
          limit: 200,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'latest-movies':
        return client.getItems(
          includeItemTypes: 'Movie',
          recursive: true,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'latest-series':
        return client.getItems(
          includeItemTypes: 'Series',
          recursive: true,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      case 'similar':
        final itemId = widget.itemId ?? '';
        return client.getSimilar(
          itemId,
          sortBy: _sort.sortBy,
          sortOrder: _sort.sortOrder,
        );
      default:
        return client.getItems(
          parentId: widget.parentId,
          includeItemTypes: widget.includeItemTypes,
          recursive: widget.recursive,
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
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
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
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Header(
            title: _title(l10n),
            sort: _sort,
            options: options,
            onSort: _selectSort,
            showSort: _items.isNotEmpty,
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.xxl,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              return SliverGrid(
                gridDelegate: ShelfGridPage.gridDelegateFor(
                  screenWidth: screenWidth,
                  availableWidth: constraints.crossAxisExtent,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = _items[index];
                  return ShelfGridPage.gridCard(
                    context,
                    item,
                    onTap: () => context.push(AppRoutes.item(item.id)),
                  );
                }, childCount: _items.length),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.sort,
    required this.options,
    required this.onSort,
    required this.showSort,
  });

  final String title;
  final CatalogSort sort;
  final List<CatalogSort> options;
  final ValueChanged<CatalogSort> onSort;
  final bool showSort;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xl,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(child: Text(title, style: textTheme.headlineMedium)),
          if (showSort)
            PopupMenuButton<CatalogSort>(
              key: CatalogKeys.sortBy,
              tooltip: l10n.sortBy,
              initialValue: sort,
              onSelected: onSort,
              itemBuilder: (context) => [
                for (final option in options)
                  PopupMenuItem(
                    value: option,
                    child: Text(
                      option.label(l10n),
                      key: CatalogKeys.sortOption(option.sortBy),
                    ),
                  ),
              ],
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
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
      ),
    );
  }
}
