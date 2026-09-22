import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
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
      builder: (context, _) => ListView(
        key: const PageStorageKey('tv-search'),
        children: [
          TvInput(
            label: l.search,
            controller: _text,
            onSubmitted: () => c.submit(_text.text),
          ),
          TvAction(
            onPressed: () => c.submit(_text.text),
            child: Text(l.search),
          ),
          if (c.loading) const LinearProgressIndicator(),
          if (c.error != null)
            TvFailure(error: c.error!, retry: () => c.submit(_text.text)),
          if (c.searched && !c.loading && c.error == null && c.items.isEmpty)
            Text(l.mobileEmpty),
          TvGrid(key: const Key('tv-search-grid'), items: c.items),
          if (c.pageError != null)
            TvFailure(error: c.pageError!, retry: c.loadMore),
          if (c.hasMore)
            TvAction(
              key: const Key('tv-search-more'),
              onPressed: c.loadingMore ? null : c.loadMore,
              child: Text(l.mobileLoadMore),
            ),
        ],
      ),
    );
  }
}
