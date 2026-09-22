import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/browse_controller.dart';

class MobileLibraryPage extends StatefulWidget {
  const MobileLibraryPage({super.key, required this.viewId});
  final String viewId;
  @override
  State<MobileLibraryPage> createState() => _MobileLibraryPageState();
}

class _MobileLibraryPageState extends State<MobileLibraryPage> {
  BrowseController? _controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) {
      _controller = BrowseController(
        auth: AuthScope.of(context),
        cache: CatalogScope.of(context).cache,
        parentId: widget.viewId,
      );
      _controller!.load();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _filter() async {
    final c = _controller!, l = AppLocalizations.of(context);
    var type = c.type, watch = c.watch, sort = c.sortBy;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.libraryFilter,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: type ?? '',
                isExpanded: true,
                decoration: InputDecoration(labelText: l.libraryFilterType),
                items: [
                  DropdownMenuItem(value: '', child: Text(l.libraryFilterAll)),
                  DropdownMenuItem(value: 'Movie', child: Text(l.mobileMovies)),
                  DropdownMenuItem(
                    value: 'Series',
                    child: Text(l.mobileSeries),
                  ),
                ],
                onChanged: (v) => setSheet(() => type = v == '' ? null : v),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: watch ?? '',
                isExpanded: true,
                decoration: InputDecoration(labelText: l.libraryFilterWatch),
                items: [
                  DropdownMenuItem(value: '', child: Text(l.libraryFilterAll)),
                  DropdownMenuItem(
                    value: 'IsPlayed',
                    child: Text(l.mobileWatched),
                  ),
                  DropdownMenuItem(
                    value: 'IsUnplayed',
                    child: Text(l.mobileUnwatched),
                  ),
                ],
                onChanged: (v) => setSheet(() => watch = v == '' ? null : v),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: sort,
                isExpanded: true,
                decoration: InputDecoration(labelText: l.mobileSort),
                items: [
                  DropdownMenuItem(
                    value: 'SortName',
                    child: Text(l.mobileNameSort),
                  ),
                  DropdownMenuItem(
                    value: 'DateCreated',
                    child: Text(l.mobileDateSort),
                  ),
                ],
                onChanged: (v) => setSheet(() => sort = v!),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  c.filter(type: type, watch: watch, sortBy: sort);
                  Navigator.pop(context);
                },
                child: Text(l.libraryFilter),
              ),
              TextButton(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = _controller!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.libraries),
        actions: [
          IconButton(
            tooltip: l.libraryFilter,
            onPressed: _filter,
            icon: const Icon(Icons.filter_list),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => RefreshIndicator(
            onRefresh: c.load,
            child: ListView(
              key: PageStorageKey('library-${widget.viewId}'),
              padding: const EdgeInsets.all(12),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (c.loading) const LinearProgressIndicator(),
                if (c.error != null)
                  MobileFailure(
                    error: c.error!,
                    retry: () => c.load(more: c.items.isNotEmpty && c.hasMore),
                  ),
                if (!c.loading && c.error == null && c.items.isEmpty)
                  Text(l.mobileEmpty),
                MobileGrid(items: c.items),
                if (c.hasMore)
                  FilledButton(
                    onPressed: c.loading ? null : () => c.load(more: true),
                    child: Text(l.mobileLoadMore),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
