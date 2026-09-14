import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_hover_card.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/library_nav_prefs.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/media_image/media_image.dart';

/// 首页片库入口,只作内容行;进库主路径是顶栏库名.
class LibraryTiles extends StatelessWidget {
  const LibraryTiles({super.key, required this.libraries});

  final List<EmbyItem> libraries;

  @override
  Widget build(BuildContext context) {
    final nav = LibraryNavScope.maybeOf(context);
    return ListenableBuilder(
      listenable: nav ?? _SilentListenable(),
      builder: (context, _) {
        final items = _visibleLibraries(libraries, nav);
        if (items.isEmpty) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        final tileWidth = MediaShelf.wideCardWidthFor(
          MediaQuery.sizeOf(context).width,
        );
        return MediaShelf(
          rowKey: CatalogKeys.librariesMenu,
          shelfId: 'libraries',
          title: l10n.libraries,
          items: items,
          wide: true,
          extent: tileWidth * 9 / 16 + AppSpacing.xs,
          onTap: (library) => context.push(AppRoutes.library(library.id)),
          itemBuilder: (context, library) {
            return _LibraryCard(library: library, width: tileWidth);
          },
        );
      },
    );
  }
}

List<EmbyItem> _visibleLibraries(
  List<EmbyItem> libraries,
  LibraryNavController? nav,
) {
  if (nav == null || !nav.customized) {
    return libraries;
  }
  return nav.layout(libraries, maxPinned: 1 << 20).pinned;
}

class _SilentListenable extends ChangeNotifier {}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.library, required this.width});

  final EmbyItem library;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final height = width * 9 / 16;
    return SizedBox(
      width: width,
      height: height,
      child: AppHoverCard(
        inkKey: CatalogKeys.library(library.id),
        onTap: () => context.push(AppRoutes.library(library.id)),
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: ColoredBox(
            color: colorScheme.surfaceContainerHigh,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MediaImage(
                  item: library,
                  width: width,
                  height: height,
                  preferBackdrop: true,
                  maxWidth: 480,
                ),
                // 底部压暗托住库名;alpha 取 AppScrim 文字带起点并尊重减少动效。
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.4, 1],
                      colors: [
                        colorScheme.scrim.withValues(alpha: 0),
                        colorScheme.scrim.withValues(
                          alpha: AppScrim.of(context, AppScrim.textStart),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Text(
                      library.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
