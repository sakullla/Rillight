import 'dart:async';
import 'package:flutter/material.dart' hide SearchController;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/search/search_controller.dart';

class MobileSearchPage extends StatefulWidget {
  const MobileSearchPage({super.key});
  @override
  State<MobileSearchPage> createState() => _MobileSearchPageState();
}

class _MobileSearchPageState extends State<MobileSearchPage> {
  final _text = TextEditingController();
  SearchController? _controller;
  Timer? _debounce;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= SearchController(
      auth: AuthScope.of(context),
      cache: CatalogScope.of(context).cache,
    );
  }

  void _submit() {
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    _controller!.submit(_text.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller?.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = _controller!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            key: const Key('mobile-search-field'),
            controller: _text,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            onChanged: (value) {
              _debounce?.cancel();
              _debounce = Timer(
                const Duration(milliseconds: 350),
                () => c.submit(value),
              );
            },
            decoration: InputDecoration(
              hintText: l.searchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: l.search,
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => RefreshIndicator(
              onRefresh: () => c.submit(_text.text),
              child: ListView(
                key: const PageStorageKey('mobile-search-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  if (c.loading) const LinearProgressIndicator(),
                  if (c.error != null)
                    MobileFailure(error: c.error!, retry: _submit),
                  if (!c.searched)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(l.searchEmptyQuery),
                    ),
                  if (c.searched &&
                      !c.loading &&
                      c.error == null &&
                      c.items.isEmpty)
                    Text(l.searchNoResults),
                  MobileGrid(items: c.items),
                  if (c.pageError != null)
                    MobileFailure(error: c.pageError!, retry: c.loadMore),
                  if (c.hasMore)
                    FilledButton(
                      onPressed: c.loadingMore ? null : c.loadMore,
                      child: Text(l.mobileLoadMore),
                    ),
                  if (c.loadingMore) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
