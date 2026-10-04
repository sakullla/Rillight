import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
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

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
  }

  void _onFocus() {
    if (!mounted) return;
    _focus.syncOwned(this);
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
      }
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
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _filter() async {
    final c = _controller!;
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: LibraryFilterPanel(
          television: true,
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
          sort: CatalogSort.values.firstWhere(
            (s) => s.sortBy == c.sortBy,
            orElse: () => CatalogSort.initial,
          ),
          years: c.items
              .map((item) => item.productionYear)
              .whereType<int>()
              .toSet()
              .toList(),
          genres: c.items.expand((item) => item.genres).toSet().toList(),
          loadGenres: () =>
              AuthScope.of(context).client.getLibraryGenres(widget.viewId),
          onApply: (filters, sort) => c.filter(
            type: filters.type.itemType,
            watch: filters.watch.param,
            years: filters.years,
            genres: filters.genres,
            sortBy: (sort ?? CatalogSort.initial).sortBy,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!, l = AppLocalizations.of(context);
    return TvFrame(
      title: l.libraries,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          _focus.retain(c.items.map((item) => item.id));
          return LayoutBuilder(
            builder: (context, constraints) {
              final metrics = TvGrid.metricsFor(context, constraints.maxWidth);
              return MediaImageScrollListener(
                child: CustomScrollView(
                  key: PageStorageKey('tv-library-${widget.viewId}'),
                  scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Row(
                        children: [
                          TvAction(
                            key: const Key('tv-library-filter'),
                            autofocus: true,
                            pill: true,
                            leading: const Icon(Icons.tune_rounded, size: 20),
                            onPressed: _filter,
                            child: Text(l.libraryFilter),
                          ),
                          if (_hasActiveFilters(c)) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: TvAction(
                                pill: true,
                                onPressed: _filter,
                                child: Text(
                                  _filterSummary(c),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (c.loadingMore || (c.loading && c.items.isNotEmpty))
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(),
                      ),
                    if (c.loading && c.items.isEmpty)
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(),
                      ),
                    if (c.error != null)
                      SliverToBoxAdapter(
                        child: TvFailure(
                          error: c.error!,
                          retry: () =>
                              c.load(more: c.items.isNotEmpty && c.hasMore),
                        ),
                      ),
                    if (!c.loading && c.error == null && c.items.isEmpty)
                      SliverToBoxAdapter(child: Text(l.mobileEmpty)),
                    if (c.items.isNotEmpty)
                      _posterGrid(c.items, metrics, _focus),
                    if (c.hasMore)
                      SliverToBoxAdapter(
                        child: TvAction(
                          key: const Key('tv-library-more'),
                          onPressed: c.loading || c.loadingMore
                              ? null
                              : () => c.load(more: true),
                          child: Text(l.mobileLoadMore),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: TvAction(
                        key: const Key('tv-library-refresh'),
                        onPressed: c.load,
                        child: Text(l.mobileRefresh),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

Widget _posterGrid(
  List<EmbyItem> items,
  TvGridMetrics metrics,
  TvReturnFocus focus,
) {
  return SliverGrid(
    key: const Key('tv-library-grid'),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: metrics.columns,
      childAspectRatio: metrics.childAspectRatio,
    ),
    delegate: SliverChildBuilderDelegate(
      (context, index) {
        final item = items[index];
        return TvPoster(
          key: ValueKey(item.id),
          item: item,
          imageMaxWidth: metrics.imageMaxWidth,
          focusNode: focus.nodeFor(item.id),
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
    c.sortBy != CatalogSort.initial.sortBy;

String _filterSummary(BrowseController c) {
  final watch = CatalogWatchFilter.values.firstWhere(
    (v) => v.param == c.watch,
    orElse: () => CatalogWatchFilter.all,
  );
  final type = CatalogTypeFilter.values.firstWhere(
    (v) => v.itemType == c.type,
    orElse: () => CatalogTypeFilter.all,
  );
  return [
    if (type != CatalogTypeFilter.all) type.label,
    if (watch != CatalogWatchFilter.all) watch.label,
    ...c.genres,
    if (c.genre != null) c.genre!,
    ...c.years.map((year) => '$year'),
  ].join(' · ');
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
