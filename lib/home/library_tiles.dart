import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_hover_card.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/media_image/media_image.dart';

/// 桌面和电视首页的片库入口。是否出现、排在哪一行，由首页区块决定。
///
/// 跟手机端一样只占一行：宽窗口大约五张再露出下一张，其余横滑。
/// 鼠标左键可拖。竖向滚轮留给页面，不在这一行里被吃掉。
class LibraryTiles extends StatelessWidget {
  const LibraryTiles({
    super.key,
    required this.libraries,
    this.headerAction,
    this.cardBuilder,
  });

  final List<EmbyItem> libraries;
  final Widget? headerAction;

  /// 电视端换成可聚焦的卡片。缺省是指针悬停卡。
  final Widget Function(
    BuildContext context,
    EmbyItem library,
    double width,
    double height,
  )?
  cardBuilder;

  @override
  Widget build(BuildContext context) {
    if (libraries.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = MediaQuery.sizeOf(context).width;
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : screen;
        final cardWidth = _libraryCardWidth(screen, maxWidth);
        final cardHeight = cardWidth * 9 / 16;
        final hoverInset = cardHeight * (MediaShelf.hoverScale - 1) / 2;
        return Padding(
          key: CatalogKeys.librariesMenu,
          padding: const EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.page,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.libraries,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    ?headerAction,
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                height: cardHeight + hoverInset * 2,
                child: ScrollConfiguration(
                  behavior: const _LibraryRailScrollBehavior(),
                  child: ListView.separated(
                    // Without its own storage key this rail inherits the
                    // page's key and restores the vertical offset as an X offset.
                    key: const PageStorageKey('home-library-tiles-scroll'),
                    primary: false,
                    scrollDirection: Axis.horizontal,
                    scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.page,
                      vertical: hoverInset,
                    ),
                    itemCount: libraries.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final library = libraries[index];
                      return cardBuilder?.call(
                            context,
                            library,
                            cardWidth,
                            cardHeight,
                          ) ??
                          _LibraryCard(
                            library: library,
                            width: cardWidth,
                            height: cardHeight,
                          );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 宽窗口一屏大约五张完整卡，再露出下一张。窄窗口不低于货架宽卡。
double _libraryCardWidth(double screenWidth, double maxWidth) {
  final wide = MediaShelf.wideCardWidthFor(screenWidth);
  final inner = maxWidth - AppSpacing.page * 2;
  if (inner <= wide) {
    return wide;
  }
  const gap = AppSpacing.sm;
  final across = (inner - gap * 5) / 5.25;
  return across > wide ? across : wide;
}

/// 片库行允许鼠标拖动。不拦截滚轮，竖向滚动仍由首页接管。
class _LibraryRailScrollBehavior extends MaterialScrollBehavior {
  const _LibraryRailScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.invertedStylus,
  };
}

class LibraryCardFace extends StatelessWidget {
  const LibraryCardFace({
    super.key,
    required this.library,
    required this.width,
    required this.height,
  });

  final EmbyItem library;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ClipRRect(
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
              fit: BoxFit.cover,
            ),
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
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    required this.library,
    required this.width,
    required this.height,
  });

  final EmbyItem library;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: AppHoverCard(
        inkKey: CatalogKeys.library(library.id),
        onTap: () => context.push(AppRoutes.library(library.id)),
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: LibraryCardFace(library: library, width: width, height: height),
      ),
    );
  }
}
