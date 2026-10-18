import 'dart:async';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/option_pill.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/media_image/media_image.dart';

bool _hasCriteria(BrowseController controller) {
  return controller.type != null ||
      controller.watch != null ||
      controller.year != null ||
      controller.genre != null ||
      controller.years.isNotEmpty ||
      controller.genres.isNotEmpty ||
      controller.searchTerm.isNotEmpty ||
      controller.sortBy != controller.defaultSort.sortBy ||
      controller.sortOrder != controller.defaultSort.sortOrder;
}

int _activeFilterDimensionCount(BrowseController controller) {
  var count = 0;
  if (controller.type != null) count++;
  if (controller.watch != null) count++;
  if (controller.years.isNotEmpty || controller.year != null) count++;
  if (controller.genres.isNotEmpty || controller.genre != null) count++;
  if (controller.searchTerm.isNotEmpty) count++;
  return count;
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
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _searchVisible = false;
  bool _nearEndLoadArmed = true;
  final Set<int> _years = {};
  final Set<String> _genres = {};
  bool _genresRequested = false;
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
    _prefetchLibraryGenres();
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
    _genresRequested = false;
    _searchController.clear();
    _searchVisible = false;
    _controller = _newController()..load();
    _prefetchLibraryGenres();
  }

  void _prefetchLibraryGenres() {
    if (_genresRequested || _auth == null) return;
    _genresRequested = true;
    unawaited(() async {
      try {
        final result = await _auth!.client.getLibraryGenres(widget.viewId);
        if (mounted && result.isNotEmpty) {
          setState(() => _genres.addAll(result));
        }
      } catch (_) {}
    }());
  }

  BrowseController _newController() {
    final libraries = CatalogScope.of(context).libraries;
    MediaItem? view;
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
    _searchController.dispose();
    _searchFocusNode.dispose();
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

  void _scrollToTop() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
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
    final controller = _controller;
    if (controller != null) {
      _searchController.clear();
      setState(() => _searchVisible = false);
      _scrollToTop();
      controller.filter(
        sortBy: controller.defaultSort.sortBy,
        sortOrder: controller.defaultSort.sortOrder,
        searchTerm: '',
      );
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible && _searchController.text.isNotEmpty) {
        _searchController.clear();
        _scrollToTop();
        _controller?.setSearchTerm('');
      } else if (_searchVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocusNode.requestFocus();
        });
      }
    });
  }

  Future<void> _openFilters() async {
    final controller = _controller;
    if (controller == null || !mounted) {
      return;
    }
    final years = [..._years]..sort((a, b) => b.compareTo(a));
    final genres = [..._genres]..sort();
    await showAppModalSheet<void>(
      context: context,
      builder: (context) => LibraryFilterPanel(
        keyPrefix: 'phone-library',
        capabilities: controller.auth.client.capabilities,
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
          orElse: () => controller.defaultSort,
        ),
        sortOrder: controller.sortOrder,
        years: years,
        genres: genres,
        loadGenres: () => _auth!.client.getLibraryGenres(widget.viewId),
        onApply: (filters, sort) {
          _scrollToTop();
          controller.filter(
            type: filters.type.itemType,
            watch: filters.watch.param,
            years: filters.years,
            genres: filters.genres,
            sortBy: (sort ?? controller.defaultSort).sortBy,
          );
        },
        onApplyWithOrder: (filters, sort, sortOrder) {
          _scrollToTop();
          controller.filter(
            type: filters.type.itemType,
            watch: filters.watch.param,
            years: filters.years,
            genres: filters.genres,
            sortBy: (sort ?? controller.defaultSort).sortBy,
            sortOrder: sortOrder,
          );
        },
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = _hasCriteria(controller);
        final activeDims = _activeFilterDimensionCount(controller);
        final total = controller.totalCount;
        final genreList = [..._genres]..sort();
        final filterLabel = activeDims > 0
            ? '${l10n.libraryFilter} $activeDims'
            : l10n.libraryFilter;
        return CupertinoPageScaffold(
          navigationBar: PhoneTopBar(
            title: Text(
              _libraryTitle(l10n),
              key: const Key('phone-library-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIconButton(
                  key: const Key('phone-library-search-toggle'),
                  tooltip: l10n.search,
                  onPressed: _toggleSearch,
                  icon: Icon(
                    AppIcons.search,
                    fill: (_searchVisible || controller.searchTerm.isNotEmpty)
                        ? AppIcons.filled
                        : AppIcons.outline,
                    size: 18,
                    color: (_searchVisible || controller.searchTerm.isNotEmpty)
                        ? scheme.primary
                        : scheme.onSurface,
                  ),
                ),
                const SizedBox(width: 4),
                AppButton.icon(
                  key: const Key('phone-library-filter'),
                  onPressed: _openFilters,
                  style: AppButtonStyle(
                    backgroundColor: active
                        ? scheme.primary
                        : const Color(0x00000000),
                    foregroundColor: active
                        ? scheme.onPrimary
                        : scheme.onSurface,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(48, 44),
                    shape: const StadiumBorder(),
                    textStyle: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  icon: Icon(
                    AppIcons.filter,
                    fill: active ? AppIcons.filled : AppIcons.outline,
                    size: 17,
                  ),
                  label: Text(filterLabel),
                  variant: AppButtonVariant.tinted,
                ),
              ],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gridWidth = constraints.maxWidth - AppSpacing.md * 2;
              return MediaImageScrollListener(
                child: AppRefresh(
                  onRefresh: controller.load,
                  child: CustomScrollView(
                    controller: _scroll,
                    key: PageStorageKey('library-${widget.viewId}'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                    slivers: [
                      SliverToBoxAdapter(
                        child: _PhoneQuickHeader(
                          controller: controller,
                          total: total,
                          genres: genreList,
                          searchVisible:
                              _searchVisible ||
                              controller.searchTerm.isNotEmpty,
                          searchController: _searchController,
                          searchFocusNode: _searchFocusNode,
                          onSearchChanged: (value) {
                            _scrollToTop();
                            controller.setSearchTerm(value);
                          },
                          onClear: _clearFilters,
                          onSortSelected: (sort) {
                            _scrollToTop();
                            controller.selectSort(sort);
                          },
                          onToggleSortOrder: () {
                            _scrollToTop();
                            controller.toggleSortOrder();
                          },
                          onToggleGenre: (genre) {
                            _scrollToTop();
                            controller.toggleGenre(genre);
                          },
                        ),
                      ),
                      if (controller.loading && controller.items.isEmpty)
                        const SliverPadding(
                          padding: EdgeInsets.all(AppSpacing.md),
                          sliver: SliverToBoxAdapter(child: _LibrarySkeleton()),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.md,
                            AppSpacing.xs,
                            AppSpacing.md,
                            AppSpacing.md +
                                MediaQuery.paddingOf(context).bottom,
                          ),
                          sliver: SliverMainAxisGroup(
                            slivers: [
                              if (controller.loadingMore ||
                                  (controller.loading &&
                                      controller.items.isNotEmpty))
                                const SliverToBoxAdapter(
                                  child: AppLoadingBar(),
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
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      top: AppSpacing.md,
                                    ),
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: AppButton(
                                        key: const Key('phone-library-more'),
                                        style: const AppButtonStyle(
                                          minimumSize: Size(48, 48),
                                        ),
                                        onPressed:
                                            controller.loading ||
                                                controller.loadingMore
                                            ? null
                                            : () => controller.load(more: true),
                                        variant: AppButtonVariant.tinted,
                                        child: Text(l10n.mobileLoadMore),
                                      ),
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
        );
      },
    );
  }
}

class _PhoneQuickHeader extends StatelessWidget {
  const _PhoneQuickHeader({
    required this.controller,
    required this.total,
    required this.genres,
    required this.searchVisible,
    required this.searchController,
    required this.searchFocusNode,
    required this.onSearchChanged,
    required this.onClear,
    required this.onSortSelected,
    required this.onToggleSortOrder,
    required this.onToggleGenre,
  });

  final BrowseController controller;
  final int? total;
  final List<String> genres;
  final bool searchVisible;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClear;
  final ValueChanged<CatalogSort> onSortSelected;
  final VoidCallback onToggleSortOrder;
  final ValueChanged<String?> onToggleGenre;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final sortOptions = CatalogSort.optionsFor(
      controller.items,
      capabilities: controller.auth.client.capabilities,
    );
    final currentSort = controller.currentSort;
    final isAsc =
        CatalogSort.normalizeSortOrder(controller.sortOrder) == 'Ascending';
    final hasActive = _hasCriteria(controller);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            4,
          ),
          child: Row(
            children: [
              if (total != null && total! > 0)
                Expanded(
                  child: Text(
                    l10n.browseLoaded(total!),
                    key: const Key('phone-library-count'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                )
              else
                const Spacer(),
              AppMenuButton<CatalogSort>(
                key: const Key('phone-library-quick-sort'),
                tooltip: l10n.sortBy,
                padding: EdgeInsets.zero,
                selected: currentSort,
                onSelected: onSortSelected,
                items: [
                  for (final option in sortOptions)
                    AppMenuEntry<CatalogSort>(
                      value: option,
                      child: Text(option.label(l10n)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.sort_down,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        currentSort.label(l10n),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (currentSort.supportsOrderToggle)
                AppIconButton(
                  key: const Key('phone-library-sort-order'),
                  tooltip: isAsc
                      ? l10n.filterSortAscending
                      : l10n.filterSortDescending,
                  onPressed: onToggleSortOrder,
                  icon: Icon(
                    isAsc ? CupertinoIcons.sort_up : CupertinoIcons.sort_down,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              if (hasActive && controller.items.isNotEmpty)
                AppButton(
                  key: const Key('phone-library-reset'),
                  style: const AppButtonStyle(
                    minimumSize: Size(44, 32),
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  onPressed: onClear,
                  variant: AppButtonVariant.plain,
                  child: Text(l10n.libraryFilterClear),
                ),
            ],
          ),
        ),
        if (searchVisible)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              6,
            ),
            child: AppTextField(
              key: const Key('phone-library-search-field'),
              controller: searchController,
              focusNode: searchFocusNode,
              placeholder: l10n.searchHint,
              onChanged: onSearchChanged,
              prefix: const Icon(AppIcons.search, fill: AppIcons.filled),
              suffix: searchController.text.isEmpty
                  ? null
                  : AppIconButton(
                      tooltip: l10n.libraryFilterClear,
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                      icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                    ),
            ),
          ),
        _ActiveAndGenreQuickBar(
          controller: controller,
          genres: genres,
          onClear: onClear,
          onToggleGenre: onToggleGenre,
        ),
      ],
    );
  }
}

class _ActiveAndGenreQuickBar extends StatelessWidget {
  const _ActiveAndGenreQuickBar({
    required this.controller,
    required this.genres,
    required this.onClear,
    required this.onToggleGenre,
  });

  final BrowseController controller;
  final List<String> genres;
  final VoidCallback onClear;
  final ValueChanged<String?> onToggleGenre;

  Widget _chip(BuildContext context, {required Key key, required String text}) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: Container(
        key: key,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          maxLines: 1,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasActive = _hasCriteria(controller);
    if (!hasActive && genres.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 4, AppSpacing.md, 8),
        children: [
          if (controller.type == 'Movie')
            _chip(
              context,
              key: const Key('phone-library-active-type'),
              text: l10n.mobileMovies,
            ),
          if (controller.type == 'Series')
            _chip(
              context,
              key: const Key('phone-library-active-type'),
              text: l10n.mobileSeries,
            ),
          if (controller.watch != null)
            _chip(
              context,
              key: const Key('phone-library-active-watch'),
              text: CatalogWatchFilter.values
                  .firstWhere(
                    (value) => value.param == controller.watch,
                    orElse: () => CatalogWatchFilter.all,
                  )
                  .label,
            ),
          if (controller.year != null || controller.years.isNotEmpty)
            _chip(
              context,
              key: const Key('phone-library-active-year'),
              text: controller.years.join('、'),
            ),
          if (controller.genre != null || controller.genres.isNotEmpty)
            _chip(
              context,
              key: const Key('phone-library-active-genre'),
              text: controller.genres.join('、'),
            ),
          if (genres.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: OptionPill(
                key: const Key('phone-library-quick-genre-all'),
                label: l10n.libraryFilterAll,
                selected: controller.genres.isEmpty && controller.genre == null,
                onPressed: () => onToggleGenre(null),
              ),
            ),
            for (final genre in genres)
              if (!controller.genres.contains(genre) &&
                  controller.genre != genre)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.xs),
                  child: OptionPill(
                    key: Key('phone-library-quick-genre-$genre'),
                    label: genre,
                    selected: false,
                    onPressed: () => onToggleGenre(genre),
                  ),
                ),
          ],
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
        const spacing = AppSpacing.sm;
        final columns = phoneLibraryColumnCount(
          constraints.maxWidth,
          textScale: MediaQuery.textScalerOf(context).scale(16) / 16,
        );
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
                      height: phoneLibraryPosterLabelExtent(context) - 6,
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

/// Standard portrait phones (360dp–430dp, textScale < 1.35) use 3 dense columns;
/// wider screens use 4–6 columns; extreme text scaling (>= 1.35) degrades to 2.
int phoneLibraryColumnCount(double width, {double textScale = 1}) {
  if (textScale >= 1.35) {
    return ((width + AppSpacing.sm) / (128 * textScale.clamp(1.0, 2.0)))
        .floor()
        .clamp(1, 6);
  }
  final effectiveWidth = width + AppSpacing.md * 2;
  if (effectiveWidth < 340) return 2;
  if (effectiveWidth <= 460) return 3;
  if (effectiveWidth <= 640) return 4;
  if (effectiveWidth <= 840) return 5;
  return 6;
}

class _PhonePosterSliver extends StatelessWidget {
  const _PhonePosterSliver({required this.items, required this.gridWidth});

  final List<MediaItem> items;
  final double gridWidth;

  @override
  Widget build(BuildContext context) {
    const spacing = AppSpacing.sm;
    final columns = phoneLibraryColumnCount(
      gridWidth,
      textScale: MediaQuery.textScalerOf(context).scale(16) / 16,
    );
    final cellWidth = (gridWidth - spacing * (columns - 1)) / columns;
    final label = phoneLibraryPosterLabelExtent(context);
    final imageWidth = catalogPosterMaxWidth(
      cellWidth,
      MediaQuery.devicePixelRatioOf(context),
    );
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: AppSpacing.sm,
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
            hero: false,
            imageMaxWidth: imageMaxWidth,
            titleMaxLines: 1,
            seasonCountCaption: false,
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

  final List<MediaItem> items;
  final int imageMaxWidth;

  @override
  bool shouldRebuild(covariant _PhonePosterDelegate oldDelegate) {
    return !identical(oldDelegate.items, items) ||
        oldDelegate.imageMaxWidth != imageMaxWidth;
  }
}
