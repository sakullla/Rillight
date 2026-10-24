import 'dart:ui' show ImageFilter;

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/desktop_performance_host.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_hover_card.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/media_image/media_image.dart';

/// 桌面和电视首页的片库入口。是否出现、排在哪一行，由首页区块决定。
///
/// 卡片与聚合页媒体库同一档 16:9 横卡宽，一行放不下时横滑，并露出左右按钮。
/// 鼠标左键可拖。竖向滚轮留给页面，不在这一行里被吃掉。
class LibraryTiles extends StatefulWidget {
  const LibraryTiles({
    super.key,
    required this.libraries,
    this.headerAction,
    this.cardBuilder,
  });

  final List<MediaItem> libraries;
  final Widget? headerAction;

  /// 电视端换成可聚焦的卡片。缺省是指针悬停卡。
  final Widget Function(
    BuildContext context,
    MediaItem library,
    double width,
    double height,
  )?
  cardBuilder;

  @override
  State<LibraryTiles> createState() => _LibraryTilesState();
}

class _LibraryTilesState extends State<LibraryTiles> {
  static const _shelfId = 'libraries';

  final _controller = ScrollController();
  var _canScrollLeft = false;
  var _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateScrollButtons();
    });
  }

  @override
  void didUpdateWidget(LibraryTiles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraries.length != widget.libraries.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateScrollButtons();
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_updateScrollButtons);
    _controller.dispose();
    super.dispose();
  }

  void _updateScrollButtons() {
    if (!_controller.hasClients) {
      if (_canScrollLeft || _canScrollRight) {
        setState(() {
          _canScrollLeft = false;
          _canScrollRight = false;
        });
      }
      return;
    }
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasPixels) {
      return;
    }
    final canLeft = position.maxScrollExtent > 0.5 && position.pixels > 0.5;
    final canRight =
        position.maxScrollExtent > 0.5 &&
        position.pixels < position.maxScrollExtent - 0.5;
    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final delta = position.viewportDimension * 0.9 * direction;
    _controller.animateTo(
      (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
      duration: AppMotion.durationOf(context, AppMotion.normal),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final libraries = widget.libraries;
    if (libraries.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final cardWidth = MediaShelf.wideCardWidthFor(
      MediaQuery.sizeOf(context).width,
    );
    final cardHeight = cardWidth * 9 / 16;
    final hoverInset = cardHeight * (MediaShelf.hoverScale - 1) / 2;
    return Padding(
      key: CatalogKeys.librariesMenu,
      padding: const EdgeInsets.only(
        top: AppSpacing.sm,
        bottom: AppSpacing.xxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.libraries,
                    style: AppUiTheme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?widget.headerAction,
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: cardHeight + hoverInset * 2,
            child: Stack(
              children: [
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: (notification) {
                    _updateScrollButtons();
                    return false;
                  },
                  child: ScrollConfiguration(
                    behavior: const _LibraryRailScrollBehavior(),
                    child: ListView.separated(
                      // Without its own storage key this rail inherits the
                      // page's key and restores the vertical offset as an X offset.
                      key: const PageStorageKey('home-library-tiles-scroll'),
                      controller: _controller,
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
                        return widget.cardBuilder?.call(
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
                if (_canScrollLeft)
                  Positioned(
                    left: AppSpacing.xs,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: ExcludeFocus(
                        child: _LibraryScrollButton(
                          buttonKey: CatalogKeys.shelfScrollLeft(_shelfId),
                          tooltip: l10n.scrollLeft,
                          icon: CupertinoIcons.chevron_left,
                          onPressed: () => _page(-1),
                        ),
                      ),
                    ),
                  ),
                if (_canScrollRight)
                  Positioned(
                    right: AppSpacing.xs,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: ExcludeFocus(
                        child: _LibraryScrollButton(
                          buttonKey: CatalogKeys.shelfScrollRight(_shelfId),
                          tooltip: l10n.scrollRight,
                          icon: CupertinoIcons.chevron_right,
                          onPressed: () => _page(1),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryScrollButton extends StatelessWidget {
  const _LibraryScrollButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: ScrimIconButton(
        paperInLight: true,
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }
}

/// 片库行允许鼠标拖动。不拦截滚轮，竖向滚动仍由首页接管。
class _LibraryRailScrollBehavior extends AppScrollBehavior {
  const _LibraryRailScrollBehavior();
}

class LibraryCardFace extends StatelessWidget {
  const LibraryCardFace({
    super.key,
    required this.library,
    required this.width,
    required this.height,
  });

  final MediaItem library;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colorScheme = theme.colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card),
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
                  stops: const [0.45, 1],
                  colors: [
                    colorScheme.scrim.withValues(alpha: 0),
                    colorScheme.scrim.withValues(
                      alpha: AppScrim.of(context, AppScrim.bottomMid),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Align(
                alignment: Alignment.bottomLeft,
                // 玻璃铭牌:名字浮在毛玻璃片上,比裸白字更精致,亮图上也可读。
                child: _LibraryNameBadge(
                  name: library.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppInk.white,
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

/// The badge is small, but every visible library tile used to create a
/// separate backdrop blur layer while the row was moving. Reuse the desktop
/// performance signal so sustained raster pressure turns this into a solid
/// badge along with the other optional effects.
class _LibraryNameBadge extends StatelessWidget {
  const _LibraryNameBadge({required this.name, required this.style});

  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final content = ColoredBox(
      color: AppInk.black.withValues(alpha: 0.32),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.start,
          style: style,
        ),
      ),
    );
    final body = DesktopPerformanceHost.systemReducedMotionOf(context)
        ? content
        : BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: content,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: body,
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    required this.library,
    required this.width,
    required this.height,
  });

  final MediaItem library;
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
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: LibraryCardFace(library: library, width: width, height: height),
      ),
    );
  }
}
