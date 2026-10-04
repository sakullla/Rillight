import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/catalog_filter_button.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/search/search_controller.dart' as search;

class TvSearchPage extends StatefulWidget {
  const TvSearchPage({super.key});
  @override
  State<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends State<TvSearchPage> {
  final _text = TextEditingController();
  final _focus = TvReturnFocus();
  search.SearchController? _controller;

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
    _controller ??= search.SearchController(
      auth: AuthScope.of(context),
      cache: CatalogScope.of(context).cache,
    );
    _focus.noteRoute(
      ModalRoute.of(context)?.isCurrent ?? true,
      () => _focus.allowRestore(this),
    );
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!, l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        _focus.retain(c.items.map((item) => item.id));
        return LayoutBuilder(
          builder: (context, constraints) {
            final metrics = TvGrid.metricsFor(context, constraints.maxWidth);
            return MediaImageScrollListener(
              child: CustomScrollView(
                key: const PageStorageKey('tv-search'),
                scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                slivers: [
                  SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Expanded(
                          child: TvInput(
                            label: l.search,
                            controller: _text,
                            pill: true,
                            leading: const Icon(Icons.search_rounded, size: 20),
                            onSubmitted: () => c.submit(_text.text),
                          ),
                        ),
                        TvAction(
                          pill: true,
                          leading: const Icon(Icons.tune_rounded, size: 20),
                          onPressed: () => showCatalogWatchFilter(
                            context,
                            watch: c.watch,
                            onChanged: c.setWatch,
                          ),
                          child: Text(l.libraryFilter),
                        ),
                      ],
                    ),
                  ),
                  if (c.watch != null)
                    SliverToBoxAdapter(
                      child: CatalogWatchChip(
                        watch: c.watch!,
                        onClear: () => c.setWatch(null),
                      ),
                    ),
                  if (c.refreshingFirstPage)
                    const SliverToBoxAdapter(
                      child: LinearProgressIndicator(
                        key: Key('tv-search-refreshing'),
                      ),
                    ),
                  if (c.error != null)
                    SliverToBoxAdapter(
                      key: Key(
                        c.items.isNotEmpty
                            ? 'tv-search-refresh-failure'
                            : 'tv-search-failure',
                      ),
                      child: TvFailure(
                        error: c.error!,
                        retry: () => c.submit(c.term),
                      ),
                    ),
                  if (c.searched &&
                      !c.refreshingFirstPage &&
                      c.error == null &&
                      c.items.isEmpty)
                    SliverToBoxAdapter(child: Text(l.mobileEmpty)),
                  if (c.items.isNotEmpty) _posterGrid(c.items, metrics, _focus),
                  if (c.pageError != null)
                    SliverToBoxAdapter(
                      child: TvFailure(error: c.pageError!, retry: c.loadMore),
                    ),
                  if (c.hasMore && c.liveFirstPageReady)
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
        );
      },
    );
  }
}

Widget _posterGrid(
  List<EmbyItem> items,
  TvGridMetrics metrics,
  TvReturnFocus focus,
) {
  return SliverGrid(
    key: const Key('tv-search-grid'),
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
