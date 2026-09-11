import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/poster_card.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.viewId});

  final String viewId;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<EmbyItem> _items = const [];
  bool _loading = true;
  EmbyException? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewId != widget.viewId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await AuthScope.of(context).client.getItems(
        parentId: widget.viewId,
        recursive: false,
        sortBy: 'SortName',
        sortOrder: 'Ascending',
      );
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
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final libraries = CatalogScope.maybeOf(context)?.libraries ?? const [];
    EmbyItem? view;
    for (final library in libraries) {
      if (library.id == widget.viewId) {
        view = library;
        break;
      }
    }

    if (_loading) {
      return const SizedBox.expand();
    }
    if (_error != null) {
      return AppErrorView(
        message: catalogFailureMessage(l10n, _error!),
        onRetry: _load,
      );
    }

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(
              view?.name ?? '',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              childAspectRatio: 0.52,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final item = _items[index];
              return PosterCard(
                item: item,
                onTap: () => context.push(AppRoutes.item(item.id)),
              );
            }, childCount: _items.length),
          ),
        ),
      ],
    );
  }
}
