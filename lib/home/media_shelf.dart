import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_image/media_image.dart';

const Map<ShortcutActivator, Intent> _kShelfArrowShortcuts = {
  SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
    TraversalDirection.left,
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
    TraversalDirection.right,
  ),
  SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
    TraversalDirection.up,
  ),
  SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
    TraversalDirection.down,
  ),
};

class MediaShelf extends StatefulWidget {
  const MediaShelf({
    super.key,
    required this.shelfId,
    required this.title,
    required this.items,
    required this.onTap,
    this.rowKey,
    this.loading = false,
    this.error,
    this.onRetry,
    this.onMore,
    this.showProgress = false,
    this.wide = false,
    this.extent,
    this.itemBuilder,
    this.onRemoveFromResume,
    this.headerAction,
    this.focusItemId,
  });

  final String shelfId;
  final Key? rowKey;
  final String title;
  final List<EmbyItem> items;
  final ValueChanged<EmbyItem> onTap;
  final bool loading;
  final EmbyException? error;
  final VoidCallback? onRetry;
  final VoidCallback? onMore;
  final bool showProgress;
  final bool wide;
  final double? extent;
  final Widget Function(BuildContext context, EmbyItem item)? itemBuilder;
  final ValueChanged<EmbyItem>? onRemoveFromResume;
  final Widget? headerAction;

  /// 首次布局及该值变化时把对应条目滚到行中央(集详情的"本季分集"条
  /// 打开第 10 集时不该停在第 1 集)。卡片节距按默认卡宽 + [cardGap] 估算,
  /// 自定义 [itemBuilder] 需使用同档卡宽。
  final String? focusItemId;

  /// 内容超出时,静止右缘至少切进下一张卡片的宽度。
  static const double peek = AppSpacing.page;

  /// 第一条可见货架在海报下方占用的高度:标题、间距和一张宽卡。
  static double heroClearanceFor(BuildContext context, double screenWidth) {
    final title = lineHeightOf(
      context,
      Theme.of(context).textTheme.titleMedium,
    );
    final image = wideCardWidthFor(screenWidth) * 9 / 16;
    final labels = wideLabelExtentFor(context, customCard: false);
    return title + AppSpacing.sm + (image + labels) * hoverScale;
  }

  /// 未超出时返回 [maxWidth]。超出时把静止可见宽度收到下一张卡片内部。
  static double restingViewportWidth({
    required double maxWidth,
    required double cardWidth,
    required int itemCount,
  }) {
    if (itemCount <= 0 ||
        cardWidth <= 0 ||
        !maxWidth.isFinite ||
        maxWidth <= 0) {
      return maxWidth;
    }
    final lastCardRight =
        AppSpacing.page + itemCount * cardWidth + (itemCount - 1) * cardGap;
    if (lastCardRight <= maxWidth + 0.5) {
      return maxWidth;
    }
    final span = maxWidth - AppSpacing.page;
    final pitch = cardWidth + cardGap;
    if (span <= 0 || pitch <= 0) {
      return maxWidth;
    }
    var remainder = span % pitch;
    if (remainder == 0) {
      remainder = pitch;
    }
    if (remainder < cardWidth) {
      return maxWidth;
    }
    final minPeek = cardWidth / 2 < peek ? cardWidth / 2 : peek;
    final clipped = maxWidth - ((remainder - cardWidth) + minPeek);
    if (clipped <= AppSpacing.page + minPeek) {
      return maxWidth;
    }
    return clipped;
  }

  /// 竖版海报卡宽,随 [AppBreakpoints] 缩放。
  static double posterWidthFor(double screenWidth) {
    if (screenWidth < AppBreakpoints.compact) {
      return 128;
    }
    if (screenWidth < AppBreakpoints.large) {
      return 148;
    }
    return 168;
  }

  /// 宽版(16:9)卡宽,随 [AppBreakpoints] 缩放;库卡复用同一档宽。
  static double wideCardWidthFor(double screenWidth) {
    if (screenWidth < AppBreakpoints.compact) {
      return 232;
    }
    if (screenWidth < AppBreakpoints.large) {
      return 264;
    }
    return 296;
  }

  /// 卡片间视觉间距;子项两侧各留 [hoverGutter] 吸收 hover 放大,
  /// 分隔条只补剩余部分,卡片节距仍为卡宽 + [cardGap]。
  static const double cardGap = AppSpacing.sm;
  static const double hoverGutter = AppSpacing.xxs;

  /// `PosterCard` 默认 hover 放大倍数;行高按卡片实际高度乘此倍数,
  /// 只为放大溢出留余量,不再为标签多留空白。
  static const double hoverScale = 1.04;

  /// 单行文字的实际排版高度(随字体与文字缩放变化)。
  static double lineHeightOf(BuildContext context, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: 'Ag', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// 宽卡(16:9)行的标签高度:自定义 [itemBuilder] 视为 `EpisodeThumbCard`
  /// (xs 间距 + 一行 titleSmall);默认 `PosterCard(wide)` 为
  /// xxs 间距 + 剧名 titleSmall + S1E2 副标题 bodySmall。
  static double wideLabelExtentFor(
    BuildContext context, {
    required bool customCard,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final title = lineHeightOf(context, textTheme.titleSmall);
    if (customCard) {
      return AppSpacing.xs + title;
    }
    return AppSpacing.xxs + title + lineHeightOf(context, textTheme.bodySmall);
  }

  /// 竖版海报行的标签高度:xs 间距 + 标题 titleSmall,
  /// [showProgress] 时再加一行进度 bodySmall。
  static double posterLabelExtentFor(
    BuildContext context, {
    required bool showProgress,
  }) {
    final textTheme = Theme.of(context).textTheme;
    var extent = AppSpacing.xs + lineHeightOf(context, textTheme.titleSmall);
    if (showProgress) {
      extent += lineHeightOf(context, textTheme.bodySmall);
    }
    return extent;
  }

  @override
  State<MediaShelf> createState() => _MediaShelfState();
}

class _MediaShelfState extends State<MediaShelf> {
  final _controller = ScrollController();
  bool _overflowing = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  double get _rowHeight {
    if (widget.extent != null) {
      return widget.extent!;
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardHeight = widget.wide
        ? MediaShelf.wideCardWidthFor(screenWidth) * 9 / 16 +
              MediaShelf.wideLabelExtentFor(
                context,
                customCard: widget.itemBuilder != null,
              )
        : MediaShelf.posterWidthFor(screenWidth) * 1.5 +
              MediaShelf.posterLabelExtentFor(
                context,
                showProgress: widget.showProgress,
              );
    return (cardHeight * MediaShelf.hoverScale).ceilToDouble();
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _revealFocusItem();
        _updateScrollButtons();
      }
    });
  }

  @override
  void didUpdateWidget(MediaShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focusChanged = oldWidget.focusItemId != widget.focusItemId;
    if (focusChanged ||
        !listEquals(oldWidget.items, widget.items) ||
        oldWidget.loading != widget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (focusChanged) {
            _revealFocusItem();
          }
          _updateScrollButtons();
        }
      });
    }
  }

  /// 把 [MediaShelf.focusItemId] 对应的卡片滚到行中央;列表惰性构建,
  /// 目标可能尚未挂载,所以按卡片节距直接算偏移而不用 ensureVisible。
  void _revealFocusItem() {
    final id = widget.focusItemId;
    if (id == null || !_controller.hasClients) {
      return;
    }
    final index = widget.items.indexWhere((item) => item.id == id);
    if (index < 0) {
      return;
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardWidth = widget.wide
        ? MediaShelf.wideCardWidthFor(screenWidth)
        : MediaShelf.posterWidthFor(screenWidth);
    final pitch = cardWidth + MediaShelf.cardGap;
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final cardStart = AppSpacing.page + index * pitch;
    final target = (cardStart - (position.viewportDimension - cardWidth) / 2)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() > 0.5) {
      _controller.jumpTo(target);
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
      if (_overflowing || _canScrollLeft || _canScrollRight) {
        setState(() {
          _overflowing = false;
          _canScrollLeft = false;
          _canScrollRight = false;
        });
      }
      return;
    }
    final position = _controller.position;
    // Offstage 首页重建时 ScrollPosition 已 attach,但尚未完成布局。
    if (!position.hasContentDimensions || !position.hasPixels) {
      return;
    }
    final overflowing = position.maxScrollExtent > 0.5;
    final canLeft = overflowing && position.pixels > 0.5;
    final canRight =
        overflowing && position.pixels < position.maxScrollExtent - 0.5;
    if (overflowing != _overflowing ||
        canLeft != _canScrollLeft ||
        canRight != _canScrollRight) {
      setState(() {
        _overflowing = overflowing;
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  void _onVerticalWheelToParent(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    if (event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) {
      return;
    }
    final vertical = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (vertical == null) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final dy = (resolved as PointerScrollEvent).scrollDelta.dy;
      final position = vertical.position;
      position.jumpTo(
        (position.pixels + dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void _page(int direction) {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final delta = position.viewportDimension * 0.9 * direction;
    _controller.animateTo(
      (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    return Padding(
      key: widget.rowKey,
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (widget.headerAction != null) widget.headerAction!,
                if (widget.onMore != null && widget.error == null)
                  TextButton(
                    key: CatalogKeys.shelfMore(widget.shelfId),
                    onPressed: widget.onMore,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant,
                      textStyle: Theme.of(context).textTheme.labelLarge,
                    ),
                    child: Text(l10n.more),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (widget.error != null && widget.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      catalogFailureMessage(l10n, widget.error!),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.onRetry != null)
                    TextButton(
                      onPressed: widget.onRetry,
                      child: Text(l10n.retry),
                    ),
                ],
              ),
            ),
          if (widget.loading && widget.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: SkeletonShelfRow(
                posterWidth: widget.wide
                    ? MediaShelf.wideCardWidthFor(screenWidth)
                    : MediaShelf.posterWidthFor(screenWidth),
                posterAspectRatio: widget.wide ? 16 / 9 : 2 / 3,
              ),
            )
          else if (widget.error != null && widget.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: widget.onRetry == null
                  ? SkeletonShelfRow(
                      posterWidth: widget.wide
                          ? MediaShelf.wideCardWidthFor(screenWidth)
                          : MediaShelf.posterWidthFor(screenWidth),
                      posterAspectRatio: widget.wide ? 16 / 9 : 2 / 3,
                    )
                  : AppErrorView(
                      message: catalogFailureMessage(l10n, widget.error!),
                      onRetry: widget.onRetry,
                    ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = widget.wide
                    ? MediaShelf.wideCardWidthFor(screenWidth)
                    : MediaShelf.posterWidthFor(screenWidth);
                final viewWidth = MediaShelf.restingViewportWidth(
                  maxWidth: constraints.maxWidth,
                  cardWidth: cardWidth,
                  itemCount: widget.items.length,
                );
                return SizedBox(
                  height: _rowHeight,
                  width: viewWidth,
                  child: Stack(
                    children: [
                      NotificationListener<ScrollMetricsNotification>(
                        onNotification: (notification) {
                          _updateScrollButtons();
                          return false;
                        },
                        child: FocusTraversalGroup(
                          policy: ReadingOrderTraversalPolicy(),
                          child: ScrollConfiguration(
                            behavior: const _ShelfScrollBehavior(),
                            child: Listener(
                              onPointerSignal: _onVerticalWheelToParent,
                              child: MediaImageScrollListener(
                                child: ListView.separated(
                                  key: PageStorageKey(
                                    'shelf-${widget.shelfId}',
                                  ),
                                  controller: _controller,
                                  scrollCacheExtent:
                                      const ScrollCacheExtent.viewport(0.5),
                                  // 首张卡片外缘仍落在 AppSpacing.page 竖线上。
                                  padding: const EdgeInsets.symmetric(
                                    horizontal:
                                        AppSpacing.page -
                                        MediaShelf.hoverGutter,
                                  ),
                                  scrollDirection: Axis.horizontal,
                                  itemBuilder: (context, index) {
                                    final item = widget.items[index];
                                    final child =
                                        widget.itemBuilder?.call(
                                          context,
                                          item,
                                        ) ??
                                        PosterCard(
                                          item: item,
                                          showProgress: widget.showProgress,
                                          wide: widget.wide,
                                          width: widget.wide
                                              ? MediaShelf.wideCardWidthFor(
                                                  screenWidth,
                                                )
                                              : MediaShelf.posterWidthFor(
                                                  screenWidth,
                                                ),
                                          onTap: () => widget.onTap(item),
                                          onRemoveFromResume:
                                              widget.onRemoveFromResume !=
                                                      null &&
                                                  item.canResume
                                              ? widget.onRemoveFromResume
                                              : null,
                                        );
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: MediaShelf.hoverGutter,
                                      ),
                                      child: Align(
                                        alignment: Alignment.center,
                                        child: Listener(
                                          onPointerSignal:
                                              _onVerticalWheelToParent,
                                          child: Shortcuts(
                                            shortcuts: _kShelfArrowShortcuts,
                                            child: _EnsureVisibleOnFocus(
                                              child: child,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                  separatorBuilder: (context, index) =>
                                      const SizedBox(
                                        width:
                                            MediaShelf.cardGap -
                                            2 * MediaShelf.hoverGutter,
                                      ),
                                  itemCount: widget.items.length,
                                ),
                              ),
                            ),
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
                              child: _ScrollButton(
                                buttonKey: CatalogKeys.shelfScrollLeft(
                                  widget.shelfId,
                                ),
                                tooltip: l10n.scrollLeft,
                                icon: Icons.chevron_left,
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
                              child: _ScrollButton(
                                buttonKey: CatalogKeys.shelfScrollRight(
                                  widget.shelfId,
                                ),
                                tooltip: l10n.scrollRight,
                                icon: Icons.chevron_right,
                                onPressed: () => _page(1),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _EnsureVisibleOnFocus extends StatelessWidget {
  const _EnsureVisibleOnFocus({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (!focused) {
          return;
        }
        final target = context;
        final duration = AppMotion.durationOf(target, AppMotion.fast);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!target.mounted) {
            return;
          }
          Scrollable.ensureVisible(
            target,
            alignment: 0.5,
            duration: duration,
            curve: AppMotion.standard,
          );
        });
      },
      child: child,
    );
  }
}

class _ShelfScrollBehavior extends MaterialScrollBehavior {
  const _ShelfScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.invertedStylus,
  };
}

class _ScrollButton extends StatelessWidget {
  const _ScrollButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: ScrimIconButton(
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }
}
