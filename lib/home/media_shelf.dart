import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';
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
    this.scrollPageOnFocus = true,
    this.fitWholeCards = false,
    this.cardBuilder,
    this.bottomSpacing = AppSpacing.xxl,
  });

  final String shelfId;
  final Key? rowKey;
  final String title;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onTap;
  final bool loading;
  final MediaServerException? error;
  final VoidCallback? onRetry;
  final VoidCallback? onMore;
  final bool showProgress;
  final bool wide;
  final double? extent;
  final Widget Function(BuildContext context, MediaItem item)? itemBuilder;
  final ValueChanged<MediaItem>? onRemoveFromResume;
  final Widget? headerAction;

  /// 首次布局及该值变化时把对应条目滚到行中央(集详情的"本季分集"条
  /// 打开第 10 集时不该停在第 1 集)。卡片节距按默认卡宽 + [cardGap] 估算,
  /// 自定义 [itemBuilder] 需使用同档卡宽。
  final String? focusItemId;

  /// 焦点落在卡片上时，是否连同页面一起滚到卡片居中。
  /// 本季分集已经在详情页里，点集只该滚这一行，不该把下面的演职员和相册带跑。
  final bool scrollPageOnFocus;

  /// 宽卡行按可用宽度取整数张卡:卡宽在默认档上下伸缩,使一页正好容纳
  /// 整数张卡;翻页、定位与滚动停稳都对齐到整卡,首尾不露半张。
  final bool fitWholeCards;

  /// 需要知道实际卡宽的自定义卡片([fitWholeCards] 时卡宽随行宽变化)。
  /// 优先于 [itemBuilder]。
  final Widget Function(BuildContext context, MediaItem item, double width)?
  cardBuilder;

  /// 行下方到下一分区的间距。
  final double bottomSpacing;

  /// 内容超出时,静止右缘至少切进下一张卡片的宽度。
  static const double peek = AppSpacing.page;

  /// 第一条可见货架在海报下方占用的高度:标题、间距和一张宽卡。
  static double heroClearanceFor(BuildContext context, double screenWidth) {
    final title = lineHeightOf(
      context,
      AppUiTheme.of(context).textTheme.titleLarge,
    );
    final image = wideCardWidthFor(screenWidth) * 9 / 16;
    final labels = wideLabelExtentFor(context, customCard: false);
    return title + AppSpacing.sm + (image + labels) * hoverScale;
  }

  /// [fitWholeCards] 行的几何:页边距之间放下整数张卡,张数取最接近默认卡宽
  /// [nominal] 的值,卡宽随之伸缩。
  static ({int count, double width}) wholeCardLayout({
    required double maxWidth,
    required double nominal,
  }) {
    final span = maxWidth - AppSpacing.page * 2;
    if (!span.isFinite || span <= 0 || nominal <= 0) {
      return (count: 1, width: nominal);
    }
    var count = ((span + cardGap) / (nominal + cardGap)).round();
    if (count < 1) count = 1;
    return (count: count, width: (span - cardGap * (count - 1)) / count);
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
      strutStyle: StrutStyle.fromTextStyle(
        style ?? const TextStyle(),
        forceStrutHeight: true,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height.ceilToDouble();
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
    final textTheme = AppUiTheme.of(context).textTheme;
    final title = lineHeightOf(context, textTheme.titleSmall);
    if (customCard) {
      return AppSpacing.xs + title;
    }
    return AppSpacing.xxs + title + lineHeightOf(context, textTheme.bodySmall);
  }

  /// 竖版海报行的标签高度:xs 间距 + 一行标题 + 2px + 一行年份/评分副信息。
  /// 续播进度画在封面上，不另占标题行。
  static double posterLabelExtentFor(BuildContext context) {
    final textTheme = AppUiTheme.of(context).textTheme;
    return AppSpacing.xs +
        lineHeightOf(context, textTheme.titleSmall) +
        2 +
        lineHeightOf(context, textTheme.labelSmall);
  }

  @override
  State<MediaShelf> createState() => _MediaShelfState();
}

class _MediaShelfState extends State<MediaShelf> {
  final _controller = ScrollController();
  bool _overflowing = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  /// 上一次布局的卡宽与一页张数;[MediaShelf.fitWholeCards] 时随行宽变化。
  double? _cardWidth;
  int _pageCards = 1;

  bool get _whole => widget.fitWholeCards && widget.wide;

  bool get _customCard =>
      widget.cardBuilder != null || widget.itemBuilder != null;

  double _defaultCardWidth() {
    final screenWidth = MediaQuery.sizeOf(context).width;
    return widget.wide
        ? MediaShelf.wideCardWidthFor(screenWidth)
        : MediaShelf.posterWidthFor(screenWidth);
  }

  double _rowHeightFor(double cardWidth) {
    if (widget.extent != null) {
      return widget.extent!;
    }
    final cardHeight = widget.wide
        ? cardWidth * 9 / 16 +
              MediaShelf.wideLabelExtentFor(context, customCard: _customCard)
        : cardWidth * 1.5 + MediaShelf.posterLabelExtentFor(context);
    // 整卡行的分集卡不做悬停放大,不必为放大留余量。
    final scale = _whole && _customCard ? 1.0 : MediaShelf.hoverScale;
    return (cardHeight * scale).ceilToDouble();
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
    final cardWidth = _cardWidth ?? _defaultCardWidth();
    final pitch = cardWidth + MediaShelf.cardGap;
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final double target;
    if (_whole) {
      // 整卡行:滚到目标所在的那一页,页首对齐整卡。
      target = ((index ~/ _pageCards) * _pageCards * pitch).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    } else {
      final cardStart = AppSpacing.page + index * pitch;
      target = (cardStart - (position.viewportDimension - cardWidth) / 2).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    }
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
      position.pointerScroll(dy);
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
    final double target;
    if (_whole) {
      final pitch = (_cardWidth ?? _defaultCardWidth()) + MediaShelf.cardGap;
      final page = (position.pixels / pitch).round() + direction * _pageCards;
      target = (page * pitch).clamp(0.0, position.maxScrollExtent);
    } else {
      final delta = position.viewportDimension * 0.9 * direction;
      target = (position.pixels + delta).clamp(0.0, position.maxScrollExtent);
    }
    _controller.animateTo(
      target,
      duration: AppMotion.durationOf(context, AppMotion.normal),
      curve: Curves.easeOut,
    );
  }

  /// 整卡行在拖动、滚轮或焦点滚动停下后对齐到最近的整卡,不停在半张卡上。
  bool _snapToWholeCard(ScrollEndNotification notification) {
    if (!_whole || notification.depth != 0) return false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      if (!position.hasContentDimensions ||
          position.isScrollingNotifier.value) {
        return;
      }
      final pitch = (_cardWidth ?? _defaultCardWidth()) + MediaShelf.cardGap;
      if (pitch <= 0) return;
      final target = ((position.pixels / pitch).round() * pitch).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() > 0.5) {
        _controller.animateTo(
          target,
          duration: AppMotion.durationOf(context, AppMotion.fast),
          curve: AppMotion.standard,
        );
      }
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    return Padding(
      key: widget.rowKey,
      // 分区之间默认留 32(AppSpacing.xxl)。
      padding: EdgeInsets.only(bottom: widget.bottomSpacing),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 分区标题用 titleMedium(手机/桌面同一档),标题与内容间距见下方 12。
                    style: AppUiTheme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (widget.headerAction != null) widget.headerAction!,
                if (widget.onMore != null && widget.error == null)
                  // 「更多」是次要入口:文字加箭头,不铺底色,悬停才出现底面。
                  AppButton(
                    key: CatalogKeys.shelfMore(widget.shelfId),
                    onPressed: widget.onMore,
                    style: AppButtonStyle(
                      foregroundColor: AppUiTheme.of(context)
                          .colorScheme
                          .onSurfaceVariant,
                      textStyle: AppUiTheme.of(context).textTheme.labelLarge,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm,
                        6,
                        AppSpacing.xs,
                        6,
                      ),
                      shape: const StadiumBorder(),
                    ),
                    variant: AppButtonVariant.plain,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(l10n.more),
                        const SizedBox(width: 2),
                        const Icon(CupertinoIcons.chevron_right, size: 14),
                      ],
                    ),
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
                    AppButton(
                      onPressed: widget.onRetry,
                      variant: AppButtonVariant.plain,
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
                var cardWidth = _defaultCardWidth();
                if (_whole) {
                  final layout = MediaShelf.wholeCardLayout(
                    maxWidth: constraints.maxWidth,
                    nominal: cardWidth,
                  );
                  cardWidth = layout.width;
                  _pageCards = layout.count;
                }
                _cardWidth = cardWidth;
                final viewWidth = _whole
                    ? constraints.maxWidth
                    : MediaShelf.restingViewportWidth(
                        maxWidth: constraints.maxWidth,
                        cardWidth: cardWidth,
                        itemCount: widget.items.length,
                      );
                final rowHeight = _rowHeightFor(cardWidth);
                final hoverInset = widget.wide
                    ? 0.0
                    : rowHeight * (1 - 1 / MediaShelf.hoverScale) / 2;
                return SizedBox(
                  height: rowHeight,
                  width: viewWidth,
                  child: Stack(
                    children: [
                      NotificationListener<ScrollMetricsNotification>(
                        onNotification: (notification) {
                          _updateScrollButtons();
                          return false;
                        },
                        child: NotificationListener<ScrollEndNotification>(
                          onNotification: _snapToWholeCard,
                          child: FocusTraversalGroup(
                            policy: ReadingOrderTraversalPolicy(),
                            child: ScrollConfiguration(
                              behavior: const _ShelfScrollBehavior(),
                              child: Listener(
                                onPointerSignal: _onVerticalWheelToParent,
                                // 整卡行把视口收进页边距:相邻页的卡片在边距里被裁掉,
                                // 不会从右缘露出一条。
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: _whole
                                        ? AppSpacing.page -
                                              MediaShelf.hoverGutter
                                        : 0,
                                  ),
                                  child: MediaImageScrollListener(
                                    child: ListView.separated(
                                      key: PageStorageKey(
                                        'shelf-${widget.shelfId}',
                                      ),
                                      controller: _controller,
                                      scrollCacheExtent:
                                          const ScrollCacheExtent.viewport(0.5),
                                      // 首张卡片外缘仍落在 AppSpacing.page 竖线上。
                                      padding: EdgeInsets.symmetric(
                                        horizontal: _whole
                                            ? 0
                                            : AppSpacing.page -
                                                  MediaShelf.hoverGutter,
                                        vertical: hoverInset,
                                      ),
                                      scrollDirection: Axis.horizontal,
                                      itemBuilder: (context, index) {
                                        final item = widget.items[index];
                                        final child =
                                            widget.cardBuilder?.call(
                                              context,
                                              item,
                                              cardWidth,
                                            ) ??
                                            widget.itemBuilder?.call(
                                              context,
                                              item,
                                            ) ??
                                            PosterCard(
                                              item: item,
                                              showProgress: widget.showProgress,
                                              wide: widget.wide,
                                              width: cardWidth,
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
                                            alignment: Alignment.topCenter,
                                            child: Listener(
                                              onPointerSignal:
                                                  _onVerticalWheelToParent,
                                              child: Shortcuts(
                                                shortcuts:
                                                    _kShelfArrowShortcuts,
                                                child: _EnsureVisibleOnFocus(
                                                  scrollPage:
                                                      widget.scrollPageOnFocus,
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
                              child: _ScrollButton(
                                buttonKey: CatalogKeys.shelfScrollRight(
                                  widget.shelfId,
                                ),
                                tooltip: l10n.scrollRight,
                                icon: CupertinoIcons.chevron_right,
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

class _EnsureVisibleOnFocus extends StatefulWidget {
  const _EnsureVisibleOnFocus({required this.child, required this.scrollPage});

  final Widget child;
  final bool scrollPage;

  @override
  State<_EnsureVisibleOnFocus> createState() => _EnsureVisibleOnFocusState();
}

class _EnsureVisibleOnFocusState extends State<_EnsureVisibleOnFocus> {
  int _focusRevision = 0;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        _focused = focused;
        final revision = ++_focusRevision;
        if (!focused) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focused || revision != _focusRevision) return;
          final duration = AppMotion.durationOf(context, AppMotion.fast);
          if (!widget.scrollPage) {
            final scrollable = Scrollable.maybeOf(context);
            final object = context.findRenderObject();
            if (scrollable == null || object is! RenderObject) return;
            scrollable.position.ensureVisible(
              object,
              alignment: 0.5,
              duration: duration,
              curve: AppMotion.standard,
            );
            return;
          }
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: duration,
            curve: AppMotion.standard,
          );
        });
      },
      child: widget.child,
    );
  }
}

class _ShelfScrollBehavior extends AppScrollBehavior {
  const _ShelfScrollBehavior();
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
        paperInLight: true,
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        size: ScrimIconButtonSize.large,
      ),
    );
  }
}
