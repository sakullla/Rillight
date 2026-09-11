import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/media_image/media_image.dart';

class LibraryTiles extends StatelessWidget {
  const LibraryTiles({super.key, required this.libraries});

  final List<EmbyItem> libraries;

  @override
  Widget build(BuildContext context) {
    if (libraries.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return MediaShelf(
      rowKey: CatalogKeys.librariesMenu,
      shelfId: 'libraries',
      title: l10n.libraries,
      items: libraries,
      wide: true,
      extent: 110,
      onTap: (library) => context.push(AppRoutes.library(library.id)),
      itemBuilder: (context, library) {
        return _LibraryCard(library: library);
      },
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.library});

  final EmbyItem library;

  @override
  Widget build(BuildContext context) {
    const width = 196.0;
    const height = 110.0;
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: CatalogKeys.library(library.id),
        onTap: () => context.push(AppRoutes.library(library.id)),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              MediaImage(
                item: library,
                width: width,
                height: height,
                preferBackdrop: true,
                maxWidth: 400,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    library.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
