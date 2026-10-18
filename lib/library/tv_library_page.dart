import 'dart:async';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/library/library_filter_panel.dart';
import 'package:rillight/media_image/media_image.dart';

class TvLibraryPage extends StatefulWidget {
  const TvLibraryPage({
    super.key,
    required this.viewId,
    this.initialGenre,
    this.initialType,
  });
  final String viewId;
  final String? initialGenre;
  final String? initialType;
  @override
  State<TvLibraryPage> createState() => _TvLibraryPageState();
}

class _TvLibraryPageState extends State<TvLibraryPage> {
  BrowseController? _controller;
  final _focus = TvReturnFocus();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _knownGenres = <String>{};
  bool _genresRequested = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
  }

  void _onFocus() {
    if (!mounted) return;
    _focus.syncOwned(this);
  }

  void _prefetchGenres(BrowseController c) {
    if (_genresRequested) return;
    _genresRequested = true;
    unawaited(() async {
      try {
        final result = await c.auth.client.getLibraryGenres(widget.viewId);
        if (mounted && result.isNotEmpty) {
          setState(() => _knownGenres.addAll(result));
        }
      } catch (_) {}
    }());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= () {
      final controller = BrowseController(
        auth: AuthScope.of(context),
        cache: CatalogScope.of(context).cache,
        parentId: widget.viewId,
        includeItemTypes:
            widget.initialType ??
            switch (CatalogScope.of(context).libraries
                .where((item) => item.id == widget.viewId)
                .firstOrNull
                ?.collectionTypeNormalized) {
              'movies' => 'Movie',
              'tvshows' => 'Series',
              _ => 'Movie,Series',
            },
      );
      final genre = widget.initialGenre;
      if (genre != null && genre.isNotEmpty) {
        controller.genre = genre;
        controller.genres = [genre];
      }
      _prefetchGenres(controller);
      controller.load();
      return controller;
    }();
    _focus.noteRoute(
      ModalRoute.of(context)?.isCurrent ?? true,
      () => _focus.allowRestore(this),
    );
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _focus.dispose();
    _searchController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _filter() async {
    final c = _controller!;
    final mergedGenres = {
      ..._knownGenres,
      ...c.items.expand((item) => item.genres),
    }.toList()..sort();
    await showAppDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AppModalFrame(
        clipBehavior: Clip.antiAlias,
        child: LibraryFilterPanel(
          television: true,
          capabilities: c.auth.client.capabilities,
          typeFilterable: c.includeItemTypes == 'Movie,Series',
          keyPrefix: 'tv-library',
          initial: ShelfFilters(
            type: CatalogTypeFilter.values.firstWhere(
              (v) => v.itemType == c.type,
              orElse: () => CatalogTypeFilter.all,
            ),
            watch: CatalogWatchFilter.values.firstWhere(
              (v) => v.param == c.watch,
              orElse: () => CatalogWatchFilter.all,
            ),
            years: c.years,
            genres: c.genres,
          ),
          sort: c.currentSort,
          sortOrder: c.sortOrder,
          years: c.items
              .map((item) => item.productionYear)
              .whereType<int>()
              .toSet()
              .toList(),
          genres: mergedGenres,
          loadGenres: () async {
            final res = await AuthScope.of(context).client
                .getLibraryGenres(widget.viewId);
            if (mounted && res.isNotEmpty) {
              setState(() => _knownGenres.addAll(res));
            }
            return res;
          },
          onApply: (filters, sort) => c.filter(
            type: filters.type.itemType,
            watch: filters.watch.param,
            years: filters.years,
            genres: filters.genres,
            sortBy: (sort ?? c.defaultSort).sortBy,
          ),
          onApplyWithOrder: (filters, sort, sortOrder) => c.filter(
            type: filters.type.itemType,
            watch: filters.watch.param,
            years: filters.years,
            genres: filters.genres,
            sortBy: (sort ?? c.defaultSort).sortBy,
            sortOrder: sortOrder,
          ),
        ),
      ),
    );
  }

  Future<void> _pickSort(BrowseController c) async {
    final l = AppLocalizations.of(context);
    final options = CatalogSort.optionsFor(
      c.items,
      capabilities: c.auth.client.capabilities,
    );
    await showAppDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) => AppDialog(
        title: Text(l.sortBy),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final option in options)
              TvAction(
                key: Key('tv-library-quick-sort-${option.sortBy}'),
                autofocus: option == c.currentSort,
                pill: true,
                selected: option == c.currentSort,
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  c.selectSort(option);
                },
                child: Text(option.label(l)),
              ),
          ],
        ),
        actions: [
          TvAction(
            pill: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.libraryFilterCancel),
          ),
        ],
      ),
    );
  }

  void _clearAll(BrowseController c) {
    _searchController.clear();
    c.filter(
      type: null,
      watch: null,
      year: null,
      genre: null,
      years: const [],
      genres: const [],
      sortBy: c.defaultSort.sortBy,
      sortOrder: c.defaultSort.sortOrder,
      searchTerm: '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!, l = AppLocalizations.of(context);
    final library = CatalogScope.of(context).libraries
        .where((item) => item.id == widget.viewId)
        .firstOrNull;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        _focus.retain(c.items.map((item) => item.id));
        for (final item in c.items) {
          _knownGenres.addAll(item.genres);
        }
        final genreList = [..._knownGenres]..sort();
        final s = TvDesign.scaleOf(context);
        final padding = TvFrame.contentPadding(context);
        final active = _hasActiveFilters(c);
        final activeCount = _activeFilterDimensionCount(c);
        final isAsc =
            CatalogSort.normalizeSortOrder(c.sortOrder) == 'Ascending';
        final filterSummary = _filterSummary(c, l);
        return TvFrame(
          title: library?.name ?? l.libraries,
          subtitle: filterSummary.isEmpty ? null : filterSummary,
          actions: [
            SizedBox(
              width: 190 * s,
              child: TvInput(
                key: const Key('tv-library-search'),
                pill: true,
                label: l.searchHint,
                controller: _searchController,
                leading: const Icon(AppIcons.search, fill: AppIcons.filled),
                onSubmitted: () => c.setSearchTerm(_searchController.text),
              ),
            ),
            TvAction(
              key: const Key('tv-library-quick-sort'),
              pill: true,
              leading: Icon(
                isAsc ? CupertinoIcons.sort_up : CupertinoIcons.sort_down,
              ),
              onPressed: () => _pickSort(c),
              child: Text(c.currentSort.label(l)),
            ),
            if (c.currentSort.supportsOrderToggle)
              TvAction(
                key: const Key('tv-library-sort-order'),
                pill: true,
                leading: Icon(
                  isAsc ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down,
                ),
                onPressed: c.toggleSortOrder,
                child: Text(
                  isAsc ? l.filterSortAscending : l.filterSortDescending,
                ),
              ),
            TvAction(
              key: const Key('tv-library-filter'),
              autofocus: true,
              pill: true,
              selected: active,
              leading: Icon(
                AppIcons.filter,
                fill: active ? AppIcons.filled : AppIcons.outline,
              ),
              onPressed: _filter,
              child: Text(
                activeCount > 0
                    ? '${l.libraryFilter} ($activeCount)'
                    : l.libraryFilter,
              ),
            ),
            if (active)
              TvAction(
                key: const Key('tv-library-clear'),
                pill: true,
                leading: const Icon(AppIcons.close, fill: AppIcons.filled),
                onPressed: () => _clearAll(c),
                child: Text(l.libraryFilterClear),
              ),
          ],
          child: LayoutBuilder(
            builder: (context, constraints) {
              final metrics = TvGrid.metricsFor(
                context,
                constraints.maxWidth - padding.horizontal,
              );
              return MediaImageScrollListener(
                child: CustomScrollView(
                  key: PageStorageKey('tv-library-${widget.viewId}'),
                  scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                  slivers: [
                    if (genreList.isNotEmpty)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          padding.left,
                          0,
                          padding.right,
                          8 * s,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: SizedBox(
                            height: 44 * s,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                Padding(
                                  padding: EdgeInsets.only(right: 8 * s),
                                  child: TvAction(
                                    key: const Key(
                                      'tv-library-quick-genre-all',
                                    ),
                                    pill: true,
                                    selected:
                                        c.genres.isEmpty && c.genre == null,
                                    onPressed: () => c.toggleGenre(null),
                                    child: Text(l.libraryFilterAll),
                                  ),
                                ),
                                for (final genre in genreList)
                                  Padding(
                                    padding: EdgeInsets.only(right: 8 * s),
                                    child: TvAction(
                                      key: Key('tv-library-quick-genre-$genre'),
                                      pill: true,
                                      selected:
                                          c.genres.contains(genre) ||
                                          c.genre == genre,
                                      onPressed: () => c.toggleGenre(genre),
                                      child: Text(genre),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (c.loadingMore || c.loading)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          padding.left,
                          0,
                          padding.right,
                          8 * s,
                        ),
                        sliver: const SliverToBoxAdapter(
                          child: AppLoadingBar(),
                        ),
                      ),
                    if (c.error != null)
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: padding.left),
                        sliver: SliverToBoxAdapter(
                          child: TvFailure(
                            error: c.error!,
                            retry: () =>
                                c.load(more: c.items.isNotEmpty && c.hasMore),
                          ),
                        ),
                      ),
                    if (!c.loading && c.error == null && c.items.isEmpty)
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 240 * s,
                          child: TvEmptyState(message: l.mobileEmpty),
                        ),
                      ),
                    if (c.items.isNotEmpty)
                      SliverPadding(
                        // 上下留出聚焦放大的空间,首行焦点环不被裁切。
                        padding: EdgeInsets.fromLTRB(
                          padding.left,
                          10 * s,
                          padding.right,
                          0,
                        ),
                        sliver: _posterGrid(
                          c.items,
                          metrics,
                          _focus,
                          onNearBottom: () {
                            if (c.hasMore && !c.loading && !c.loadingMore) {
                              c.load(more: true);
                            }
                          },
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        padding.left,
                        20 * s,
                        padding.right,
                        padding.bottom,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            if (c.hasMore) ...[
                              TvAction(
                                key: const Key('tv-library-more'),
                                pill: true,
                                leading: const Icon(
                                  CupertinoIcons.chevron_down,
                                ),
                                onPressed: c.loading || c.loadingMore
                                    ? null
                                    : () => c.load(more: true),
                                child: Text(l.mobileLoadMore),
                              ),
                              SizedBox(width: 10 * s),
                            ],
                            TvAction(
                              key: const Key('tv-library-refresh'),
                              pill: true,
                              leading: const Icon(
                                CupertinoIcons.arrow_clockwise,
                              ),
                              onPressed: c.load,
                              child: Text(l.mobileRefresh),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

Widget _posterGrid(
  List<MediaItem> items,
  TvGridMetrics metrics,
  TvReturnFocus focus, {
  VoidCallback? onNearBottom,
}) {
  return SliverGrid(
    key: const Key('tv-library-grid'),
    gridDelegate: metrics.delegate,
    delegate: SliverChildBuilderDelegate(
      (context, index) {
        final item = items[index];
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (focused) {
            if (focused &&
                onNearBottom != null &&
                index >= items.length - metrics.columns * 2) {
              onNearBottom();
            }
          },
          child: TvPoster(
            key: ValueKey(item.id),
            item: item,
            imageMaxWidth: metrics.imageMaxWidth,
            focusNode: focus.nodeFor(item.id),
          ),
        );
      },
      childCount: items.length,
      addAutomaticKeepAlives: false,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = items.indexWhere((item) => item.id == key.value);
        return index < 0 ? null : index;
      },
    ),
  );
}

bool _hasActiveFilters(BrowseController c) =>
    c.type != null ||
    c.watch != null ||
    c.genre != null ||
    c.years.isNotEmpty ||
    c.genres.isNotEmpty ||
    c.searchTerm.isNotEmpty ||
    c.sortBy != c.defaultSort.sortBy ||
    CatalogSort.normalizeSortOrder(c.sortOrder) !=
        CatalogSort.normalizeSortOrder(c.defaultSort.sortOrder);

int _activeFilterDimensionCount(BrowseController c) =>
    (c.type == null ? 0 : 1) +
    (c.watch == null ? 0 : 1) +
    (c.years.isEmpty && c.year == null ? 0 : 1) +
    (c.genres.isEmpty && c.genre == null ? 0 : 1) +
    (c.searchTerm.isEmpty ? 0 : 1);

String _filterSummary(BrowseController c, AppLocalizations l) {
  final watch = CatalogWatchFilter.values.firstWhere(
    (v) => v.param == c.watch,
    orElse: () => CatalogWatchFilter.all,
  );
  final type = CatalogTypeFilter.values.firstWhere(
    (v) => v.itemType == c.type,
    orElse: () => CatalogTypeFilter.all,
  );
  final parts = <String>[
    if (c.totalCount != null) l.browseLoaded(c.totalCount!),
    if (type != CatalogTypeFilter.all) type.label,
    if (watch != CatalogWatchFilter.all) watch.label,
    ...c.genres,
    if (c.genre != null && !c.genres.contains(c.genre)) c.genre!,
    ...c.years.map((year) => '$year'),
    if (c.searchTerm.isNotEmpty) '“${c.searchTerm}”',
  ];
  return parts.join(' · ');
}

/// 页面 State 存活期间记住最后聚焦的条目 id。
///
/// 路由重新成为当前页时请求该项。条目已不在或不能聚焦时不抢焦点,
/// 交给 [TvFocusRegion] 落到最近的可见目标。壳内被排除焦点的栏不恢复。
class TvReturnFocus {
  final _nodes = <String, FocusNode>{};
  String? lastId;
  var restore = false;
  var _pendingRestore = false;
  bool? _routeCurrent;
  Set<String> _alive = const {};
  var _disposed = false;
  var _pruneQueued = false;

  FocusNode nodeFor(String id) {
    return _nodes.putIfAbsent(id, () {
      final node = FocusNode(debugLabel: 'tv-return-$id');
      node.addListener(() {
        if (node.hasFocus) lastId = id;
      });
      return node;
    });
  }

  void retain(Iterable<String> ids) {
    _alive = Set<String>.of(ids);
    if (_disposed || _pruneQueued) return;
    if (_nodes.keys.every(_alive.contains)) return;
    _pruneQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pruneQueued = false;
      if (_disposed) return;
      for (final id in _nodes.keys.toList()) {
        if (_alive.contains(id)) continue;
        _nodes.remove(id)?.dispose();
      }
    });
  }

  void syncOwned(State<StatefulWidget> owner) {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      return;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return;
    for (final entry in _nodes.entries) {
      if (!identical(entry.value, primary)) continue;
      lastId = entry.key;
      restore = true;
      return;
    }
    final focusContext = primary.context;
    if (focusContext != null &&
        focusContext.mounted &&
        _owns(focusContext, owner)) {
      restore = false;
    }
  }

  void noteRoute(bool current, bool Function() canRestore) {
    final previous = _routeCurrent;
    _routeCurrent = current;
    if (previous == true && !current) _pendingRestore = restore;
    if (!(previous == false && current && _pendingRestore)) return;
    _pendingRestore = false;
    final id = lastId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply(id, canRestore));
  }

  bool allowRestore(State<StatefulWidget> owner) {
    if (_disposed || !owner.mounted) return false;
    final context = owner.context;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    var allowed = true;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is ExcludeFocus && widget.excluding) {
        allowed = false;
        return false;
      }
      return true;
    });
    return allowed;
  }

  void _apply(String? id, bool Function() canRestore) {
    if (_disposed || id == null || !canRestore()) return;
    // 先消化离开期间挂起的 autofocus,再改回到记住的条目。
    FocusManager.instance.applyFocusChangesIfNeeded();
    final node = _nodes[id];
    if (node == null ||
        node.context?.mounted != true ||
        !node.canRequestFocus ||
        node.hasFocus) {
      return;
    }
    node.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
  }

  void dispose() {
    _disposed = true;
    final pending = _nodes.values.toList();
    _nodes.clear();
    for (final node in pending) {
      node.dispose();
    }
  }

  static bool _owns(BuildContext focusContext, State<StatefulWidget> owner) {
    var owns = false;
    focusContext.visitAncestorElements((element) {
      if (element is StatefulElement && identical(element.state, owner)) {
        owns = true;
        return false;
      }
      return true;
    });
    return owns;
  }
}
