import 'package:flutter/material.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/shelf_grid_page.dart';

/// 库网格下钻页,页头展示库名与当前筛选结果。
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
      key: ValueKey(viewId),
      source: 'items',
      parentId: viewId,
      includeItemTypes: 'Movie,Series',
      recursive: true,
      title: current?.name ?? '',
      showTitle: true,
    );
  }
}
