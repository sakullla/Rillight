import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/shelf_grid_page.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key, required this.viewId});

  final String viewId;

  @override
  Widget build(BuildContext context) {
    final libraries = CatalogScope.maybeOf(context)?.libraries ?? const [];
    EmbyItem? current;
    for (final library in libraries) {
      if (library.id == viewId) {
        current = library;
        break;
      }
    }
    return ShelfGridPage(
      source: 'items',
      parentId: viewId,
      title: current?.name ?? '',
      titleOverride: libraries.length > 1 && current != null
          ? _LibrarySwitcher(current: current, libraries: libraries)
          : null,
      moviesOrSeriesOnly: true,
    );
  }
}

/// 库页头部的媒体库切换器:当前库名 + 下拉菜单列出全部库。
class _LibrarySwitcher extends StatelessWidget {
  const _LibrarySwitcher({required this.current, required this.libraries});

  final EmbyItem current;
  final List<EmbyItem> libraries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return PopupMenuButton<String>(
      key: CatalogKeys.librarySwitcher,
      tooltip: l10n.switchLibrary,
      initialValue: current.id,
      onSelected: (id) {
        if (id != current.id) {
          context.go(AppRoutes.library(id));
        }
      },
      itemBuilder: (context) => [
        for (final library in libraries)
          PopupMenuItem(
            value: library.id,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: library.id == current.id
                      ? Icon(Icons.check, size: 18, color: colorScheme.primary)
                      : null,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(library.name),
              ],
            ),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              current.name,
              style: textTheme.headlineMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.xxs),
          Icon(Icons.arrow_drop_down, color: colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
