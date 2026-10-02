import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/media_image/media_image.dart';

String _sortLabel(AppLocalizations l10n, String sortBy) {
  for (final sort in CatalogSort.values) {
    if (sort.sortBy == sortBy) {
      return sort.label(l10n);
    }
  }
  return CatalogSort.initial.label(l10n);
}

bool _hasCriteria(BrowseController controller) {
  return controller.type != null ||
      controller.watch != null ||
      controller.year != null ||
      controller.genre != null ||
      controller.sortBy != CatalogSort.initial.sortBy;
}

class MobileLibraryPage extends StatefulWidget {
  const MobileLibraryPage({super.key, required this.viewId});

  final String viewId;

  @override
  State<MobileLibraryPage> createState() => _MobileLibraryPageState();
}

class _MobileLibraryPageState extends State<MobileLibraryPage> {
  static const double _loadMoreThreshold = 600;

  final ScrollController _scroll = ScrollController();
  bool _nearEndLoadArmed = true;
  final Set<int> _years = {};
  final Set<String> _genres = {};
  BrowseController? _controller;
  AuthController? _auth;
  CatalogCache? _cache;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = AuthScope.of(context);
    _cache = CatalogScope.of(context).cache;
    if (_controller != null) {
      return;
    }
    _controller = _newController()..load();
  }

  @override
  void didUpdateWidget(MobileLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewId == widget.viewId) {
      return;
    }
    _controller?.removeListener(_rememberDimensions);
    _controller?.dispose();
    _years.clear();
    _genres.clear();
    _controller = _newController()..load();
  }

  BrowseController _newController() {
    final libraries = CatalogScope.of(context).libraries;
    EmbyItem? view;
    for (final library in libraries) {
      if (library.id == widget.viewId) {
        view = library;
        break;
      }
    }
    final photos = view?.collectionTypeNormalized == 'photos';
    return BrowseController(
      auth: _auth!,
      cache: _cache!,
      parentId: widget.viewId,
      includeItemTypes: photos
          ? 'Photo,PhotoAlbum'
          : switch (view?.collectionTypeNormalized) {
              'movies' => 'Movie',
              'tvshows' => 'Series',
              _ => 'Movie,Series',
            },
    )..addListener(_rememberDimensions);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    _controller?.removeListener(_rememberDimensions);
    _controller?.dispose();
    super.dispose();
  }

  void _rememberDimensions() {
    final items = _controller?.items;
    if (items == null) {
      return;
    }
    for (final item in items) {
      final year = item.productionYear;
      if (year != null) {
        _years.add(year);
      }
      for (final genre in item.genres) {
        final name = genre.trim();
        if (name.isNotEmpty) {
          _genres.add(name);
        }
      }
    }
  }

  void _maybeLoadMore() {
    final controller = _controller;
    if (controller == null || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    if (!position.hasContentDimensions) {
      return;
    }
    final nearEnd =
        position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent - _loadMoreThreshold;
    if (!nearEnd) {
      _nearEndLoadArmed = true;
      return;
    }
    if (controller.loading ||
        controller.loadingMore ||
        !controller.hasMore ||
        controller.error != null) {
      return;
    }
    if (!_nearEndLoadArmed) {
      return;
    }
    _nearEndLoadArmed = false;
    controller.load(more: true);
  }

  void _clearFilters() {
    _controller?.filter(sortBy: CatalogSort.initial.sortBy);
  }

  Future<void> _openFilters() async {
    final controller = _controller;
    if (controller == null || !mounted) {
      return;
    }
    final years = [..._years]..sort((a, b) => b.compareTo(a));
    final genres = [..._genres]..sort();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => LibraryFilterPanel(
        keyPrefix: 'phone-library',
        typeFilterable: controller.includeItemTypes == 'Movie,Series',
        initial: ShelfFilters(
          type: CatalogTypeFilter.values.firstWhere(
            (value) => value.itemType == controller.type,
            orElse: () => CatalogTypeFilter.all,
          ),
          watch: CatalogWatchFilter.values.firstWhere(
            (value) => value.param == controller.watch,
            orElse: () => CatalogWatchFilter.all,
          ),
          years: controller.years,
          genres: controller.genres,
        ),
        sort: CatalogSort.values.firstWhere(
          (value) => value.sortBy == controller.sortBy,
          orElse: () => CatalogSort.initial,
        ),
        years: years,
        genres: genres,
        loadGenres: () => _auth!.client.getLibraryGenres(widget.viewId),
        onApply: (filters, sort) => controller.filter(
          type: filters.type.itemType,
          watch: filters.watch.param,
          years: filters.years,
          genres: filters.genres,
          sortBy: (sort ?? CatalogSort.initial).sortBy,
        ),
      ),
    );
  }

  String _libraryTitle(AppLocalizations l10n) {
    for (final library in CatalogScope.of(context).libraries) {
      if (library.id != widget.viewId) {
        continue;
      }
      final name = library.name.trim();
      if (name.isNotEmpty) {
        return name;
      }
    }
    return l10n.libraries;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = _controller!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_libraryTitle(l10n), key: const Key('phone-library-title')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              key: const Key('phone-library-filter'),
              onPressed: _openFilters,
              icon: const Icon(Icons.tune_rounded, size: 20),
              label: Text(l10n.libraryFilter),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final gridWidth = constraints.maxWidth - AppSpacing.md * 2;
              return MediaImageScrollListener(
                child: RefreshIndicator(
                  onRefresh: controller.load,
                  child: CustomScrollView(
                    controller: _scroll,
                    key: PageStorageKey('library-${widget.viewId}'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                    slivers: [
                      if (controller.loading && controller.items.isEmpty)
                        const SliverPadding(
                          padding: EdgeInsets.all(AppSpacing.md),
                          sliver: SliverToBoxAdapter(child: _LibrarySkeleton()),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          sliver: SliverMainAxisGroup(
                            slivers: [
                              SliverToBoxAdapter(
                                child: _ActiveFilters(
                                  controller: controller,
                                  onClear: _clearFilters,
                                ),
                              ),
                              if (controller.loadingMore ||
                                  (controller.loading &&
                                      controller.items.isNotEmpty))
                                const SliverToBoxAdapter(
                                  child: LinearProgressIndicator(),
                                ),
                              if (controller.error != null)
                                SliverToBoxAdapter(
                                  child: MobileFailureState(
                                    message: catalogFailureMessage(
                                      l10n,
                                      controller.error!,
                                    ),
                                    onRetry: () => controller.load(
                                      more:
                                          controller.items.isNotEmpty &&
                                          controller.hasMore,
                                    ),
                                  ),
                                ),
                              if (!controller.loading &&
                                  controller.error == null &&
                                  controller.items.isEmpty)
                                SliverToBoxAdapter(
                                  child: MobileEmptyState(
                                    message: l10n.mobileEmpty,
                                    actionLabel: _hasCriteria(controller)
                                        ? l10n.libraryFilterClear
                                        : l10n.mobileRefresh,
                                    onAction: _hasCriteria(controller)
                                        ? _clearFilters
                                        : () => controller.load(),
                                  ),
                                ),
                              if (controller.items.isNotEmpty)
                                _PhonePosterSliver(
                                  items: controller.items,
                                  gridWidth: gridWidth,
                                ),
                              if (controller.hasMore &&
                                  controller.error == null)
                                SliverToBoxAdapter(
                                  child: Align(
                                    alignment: Alignment.center,
                                    child: FilledButton(
                                      key: const Key('phone-library-more'),
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                      ),
                                      onPressed:
                                          controller.loading ||
                                              controller.loadingMore
                                          ? null
                                          : () => controller.load(more: true),
                                      child: Text(l10n.mobileLoadMore),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({required this.controller, required this.onClear});

  final BrowseController controller;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (controller.sortBy != CatalogSort.initial.sortBy)
            Chip(
              key: const Key('phone-library-active-sort'),
              label: Text(_sortLabel(l10n, controller.sortBy)),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.type == 'Movie')
            Chip(
              key: const Key('phone-library-active-type'),
              label: Text(l10n.mobileMovies),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.type == 'Series')
            Chip(
              key: const Key('phone-library-active-type'),
              label: Text(l10n.mobileSeries),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.watch != null)
            Chip(
              key: const Key('phone-library-active-watch'),
              label: Text(
                CatalogWatchFilter.values
                    .firstWhere(
                      (value) => value.param == controller.watch,
                      orElse: () => CatalogWatchFilter.all,
                    )
                    .label,
              ),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.year != null)
            Chip(
              key: const Key('phone-library-active-year'),
              label: Text(controller.years.join('、')),
              visualDensity: VisualDensity.compact,
            ),
          if (controller.genre != null)
            Chip(
              key: const Key('phone-library-active-genre'),
              label: Text(controller.genres.join("、")),
              visualDensity: VisualDensity.compact,
            ),
          if (_hasCriteria(controller) && controller.items.isNotEmpty)
            TextButton(
              key: const Key('phone-library-reset'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onClear,
              child: Text(l10n.libraryFilterClear),
            ),
        ],
      ),
    );
  }
}

class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppSpacing.md;
        final columns = phoneLibraryColumnCount(constraints.maxWidth);
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < columns * 2; i++)
              SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBlock(
                      width: width,
                      height: width * 1.5,
                      animated: false,
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: phonePosterCardLabelExtent(context) - 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBlock(
                            width: width * .82,
                            height: 14,
                            animated: false,
                          ),
                          const SizedBox(height: 6),
                          SkeletonBlock(
                            width: width * .42,
                            height: 12,
                            animated: false,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Narrow phones use two readable columns; larger phones fit three.
int phoneLibraryColumnCount(double width) {
  if (width <= 360) return 2;
  if (width <= 600) {
    return 3;
  }
  return mobileGridColumnCount(width);
}

class _PhonePosterSliver extends StatelessWidget {
  const _PhonePosterSliver({required this.items, required this.gridWidth});

  final List<EmbyItem> items;
  final double gridWidth;

  @override
  Widget build(BuildContext context) {
    const spacing = AppSpacing.md;
    final columns = phoneLibraryColumnCount(gridWidth);
    final cellWidth = (gridWidth - spacing * (columns - 1)) / columns;
    final label = phonePosterCardLabelExtent(context);
    final imageWidth = catalogPosterMaxWidth(
      cellWidth,
      MediaQuery.devicePixelRatioOf(context),
    );
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: cellWidth / (cellWidth * 1.5 + label),
      ),
      delegate: _PhonePosterDelegate(items: items, imageMaxWidth: imageWidth),
    );
  }
}

class _PhonePosterDelegate extends SliverChildBuilderDelegate {
  _PhonePosterDelegate({required this.items, required this.imageMaxWidth})
    : super(
        (context, index) {
          final item = items[index];
          return PhoneGridPosterCard(
            key: ValueKey('phone-library-poster-${item.id}'),
            item: item,
            // 与首页 rail 同 ShellRoute 子树,同条目会重复注册 Hero 标签;
            // 与搜索页对齐关闭飞行,代价是片库→详情无 hero 动画(可接受)。
            hero: false,
            imageMaxWidth: imageMaxWidth,
            onTap: item.isPhotoAlbum
                ? () => context.push(
                    AppRoutes.shelfItems(
                      parentId: item.id,
                      includeItemTypes: 'Photo,PhotoAlbum',
                      title: item.name,
                      recursive: true,
                    ),
                  )
                : null,
          );
        },
        childCount: items.length,
        addAutomaticKeepAlives: false,
      );

  final List<EmbyItem> items;
  final int imageMaxWidth;

  @override
  bool shouldRebuild(covariant _PhonePosterDelegate oldDelegate) {
    return !identical(oldDelegate.items, items) ||
        oldDelegate.imageMaxWidth != imageMaxWidth;
  }
}
