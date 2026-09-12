import 'package:flutter/material.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/shelf_grid_page.dart';

/// 库网格下钻页。换库由顶栏库名承担,页内不再放切换器。
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
      moviesOrSeriesOnly: true,
    );
  }
}
