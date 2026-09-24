import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/catalog_filter_button.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/search/search_controller.dart' as search;

class TvSearchPage extends StatefulWidget {
  const TvSearchPage({super.key});
  @override
  State<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends State<TvSearchPage> {
  final _text = TextEditingController();
  search.SearchController? _controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= search.SearchController(
      auth: AuthScope.of(context),
      cache: CatalogScope.of(context).cache,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!, l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final metrics = TvGrid.metricsFor(context, constraints.maxWidth);
          return MediaImageScrollListener(
            child: CustomScrollView(
              key: const PageStorageKey('tv-search'),
              scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
              slivers: [
                SliverToBoxAdapter(
                  child: TvInput(
                    label: l.search,
                    controller: _text,
                    onSubmitted: () => c.submit(_text.text),
                  ),
                ),
                SliverToBoxAdapter(
                  child: TvAction(
                    onPressed: () => c.submit(_text.text),
                    child: Text(l.search),
                  ),
                ),
                SliverToBoxAdapter(
                  child: TvAction(
                    onPressed: () => showCatalogWatchFilter(
                      context,
                      watch: c.watch,
                      onChanged: c.setWatch,
                    ),
                    child: Text(l.libraryFilter),
                  ),
                ),
                if (c.watch != null)
                  SliverToBoxAdapter(
                    child: CatalogWatchChip(
                      watch: c.watch!,
                      onClear: () => c.setWatch(null),
                    ),
                  ),
                if (c.loading)
                  const SliverToBoxAdapter(child: LinearProgressIndicator()),
                if (c.error != null)
                  SliverToBoxAdapter(
                    child: TvFailure(
                      error: c.error!,
                      retry: () => c.submit(_text.text),
                    ),
                  ),
                if (c.searched &&
                    !c.loading &&
                    c.error == null &&
                    c.items.isEmpty)
                  SliverToBoxAdapter(child: Text(l.mobileEmpty)),
                if (c.items.isNotEmpty)
                  TvPosterSliver(
                    key: const Key('tv-search-grid'),
                    items: c.items,
                    metrics: metrics,
                  ),
                if (c.pageError != null)
                  SliverToBoxAdapter(
                    child: TvFailure(error: c.pageError!, retry: c.loadMore),
                  ),
                if (c.hasMore)
                  SliverToBoxAdapter(
                    child: TvAction(
                      key: const Key('tv-search-more'),
                      onPressed: c.loadingMore ? null : c.loadMore,
                      child: Text(l.mobileLoadMore),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
