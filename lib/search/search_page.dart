import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/poster_card.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();
  List<EmbyItem> _items = const [];
  bool _loading = false;
  bool _searched = false;
  EmbyException? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _submit([String? raw]) async {
    final term = (raw ?? _query.text).trim();
    if (term.isEmpty) {
      setState(() {
        _searched = false;
        _items = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final items = await AuthScope.of(context).client.searchByName(term);
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items.where((item) => item.isMovieOrSeries).toList();
        _loading = false;
      });
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _items = const [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: CatalogKeys.searchField,
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: l10n.search,
                    hintText: l10n.searchHint,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (value) => _submit(value),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: CatalogKeys.searchSubmit,
                onPressed: _loading ? null : () => _submit(),
                child: Text(l10n.search),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildBody(l10n)),
        ],
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const SizedBox.expand();
    }
    if (_error != null) {
      return AppErrorView(
        message: searchFailureMessage(l10n, _error!),
        onRetry: _submit,
      );
    }
    if (!_searched) {
      return Center(child: Text(l10n.searchEmptyQuery));
    }
    if (_items.isEmpty) {
      return Center(
        key: CatalogKeys.searchNoResults,
        child: Text(l10n.searchNoResults),
      );
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.52,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return PosterCard(
          item: item,
          onTap: () => context.push(AppRoutes.item(item.id)),
        );
      },
    );
  }
}
