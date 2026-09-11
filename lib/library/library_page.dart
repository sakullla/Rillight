import 'package:flutter/material.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/shelf_grid_page.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key, required this.viewId});

  final String viewId;

  @override
  Widget build(BuildContext context) {
    final libraries = CatalogScope.maybeOf(context)?.libraries ?? const [];
    String title = '';
    for (final library in libraries) {
      if (library.id == viewId) {
        title = library.name;
        break;
      }
    }
    return ShelfGridPage(
      source: 'items',
      parentId: viewId,
      title: title,
      moviesOrSeriesOnly: true,
    );
  }
}
