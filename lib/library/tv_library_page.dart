import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/browse_controller.dart';
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
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= () {
      final controller = BrowseController(
        auth: AuthScope.of(context),
        cache: CatalogScope.of(context).cache,
        parentId: widget.viewId,
        includeItemTypes: widget.initialType ?? 'Movie,Series',
      );
      final genre = widget.initialGenre;
      if (genre != null && genre.isNotEmpty) {
        controller.genre = genre;
      }
      controller.load();
      return controller;
    }();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _filter() async {
    final c = _controller!, l = AppLocalizations.of(context);
    var type = c.type, watch = c.watch, sort = c.sortBy;
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l.libraryFilter),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l.libraryFilterType),
                  for (final choice in [
                    (null, l.libraryFilterAll),
                    ('Movie', l.mobileMovies),
                    ('Series', l.mobileSeries),
                  ])
                    TvAction(
                      autofocus: choice.$1 == null,
                      selected: type == choice.$1,
                      onPressed: () => update(() => type = choice.$1),
                      child: Text(choice.$2),
                    ),
                  Text(l.libraryFilterWatch),
                  for (final choice in [
                    (null, l.libraryFilterAll),
                    ('IsPlayed', l.mobileWatched),
                    ('IsUnplayed', l.mobileUnwatched),
                  ])
                    TvAction(
                      selected: watch == choice.$1,
                      onPressed: () => update(() => watch = choice.$1),
                      child: Text(choice.$2),
                    ),
                  Text(l.mobileSort),
                  for (final choice in [
                    ('SortName', l.mobileNameSort),
                    ('DateCreated', l.mobileDateSort),
                  ])
                    TvAction(
                      selected: sort == choice.$1,
                      onPressed: () => update(() => sort = choice.$1),
                      child: Text(choice.$2),
                    ),
                  TvAction(
                    onPressed: () {
                      c.filter(type: type, watch: watch, sortBy: sort);
                      Navigator.pop(context);
                    },
                    child: Text(l.libraryFilter),
                  ),
                  TvAction(
                    onPressed: () {
                      c.filter(sortBy: 'SortName');
                      Navigator.pop(context);
                    },
                    child: Text(l.libraryFilterClear),
                  ),
                ],
              ),
            ),
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
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final metrics = TvGrid.metricsFor(context, constraints.maxWidth);
            return MediaImageScrollListener(
              child: CustomScrollView(
                key: PageStorageKey('tv-library-${widget.viewId}'),
                scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                slivers: [
                  SliverToBoxAdapter(
                    child: TvAction(
                      key: const Key('tv-library-filter'),
                      autofocus: true,
                      onPressed: _filter,
                      child: Text(l.libraryFilter),
                    ),
                  ),
                  if (c.loadingMore || (c.loading && c.items.isNotEmpty))
                    const SliverToBoxAdapter(child: LinearProgressIndicator()),
                  if (c.loading && c.items.isEmpty)
                    const SliverToBoxAdapter(child: LinearProgressIndicator()),
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
                    TvPosterSliver(
                      key: const Key('tv-library-grid'),
                      items: c.items,
                      metrics: metrics,
                    ),
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
        ),
      ),
    );
  }
}
