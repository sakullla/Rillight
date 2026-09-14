import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/poster_card.dart';

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
    this.focusedId,
    this.focusNonce = 0,
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
  final String? focusedId;
  final int focusNonce;

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
        _updateScrollButtons();
        _scrollToFocused();
      }
    });
  }

  @override
  void didUpdateWidget(MediaShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focusChanged =
        oldWidget.focusedId != widget.focusedId ||
        oldWidget.focusNonce != widget.focusNonce ||
        oldWidget.items != widget.items;
    if (!listEquals(oldWidget.items, widget.items) ||
        oldWidget.loading != widget.loading ||
        focusChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateScrollButtons();
          if (focusChanged) {
            _scrollToFocused();
          }
        }
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

  void _scrollToFocused() {
    final id = widget.focusedId;
    if (id == null || id.isEmpty || !_controller.hasClients) {
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
    const gap = MediaShelf.cardGap;
    const pad = AppSpacing.page;
    final position = _controller.position;
    if (position.maxScrollExtent <= 0 && index > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToFocused();
        }
      });
      return;
    }
    final itemStart = pad + index * (cardWidth + gap);
    final target = (itemStart - (position.viewportDimension - cardWidth) / 2)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _controller.jumpTo(target);
    _updateScrollButtons();
  }

  void _page(int direction) {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
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
          if (widget.loading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: SkeletonShelfRow(
                posterWidth: widget.wide
                    ? MediaShelf.wideCardWidthFor(screenWidth)
                    : MediaShelf.posterWidthFor(screenWidth),
                posterAspectRatio: widget.wide ? 16 / 9 : 2 / 3,
              ),
            )
          else if (widget.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: widget.onRetry == null
                  ? SkeletonShelfRow(
                      posterWidth: widget.wide
                          ? MediaShelf.wideCardWidthFor(screenWidth)
                          : MediaShelf.posterWidthFor(screenWidth),
                      posterAspectRatio: widget.wide ? 16 / 9 : 2 / 3,
                    )
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: widget.onRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(l10n.retry),
                      ),
                    ),
            )
          else
            SizedBox(
              height: _rowHeight,
              child: Stack(
                children: [
                  NotificationListener<ScrollMetricsNotification>(
                    onNotification: (notification) {
                      _updateScrollButtons();
                      return false;
                    },
                    child: FocusTraversalGroup(
                      policy: ReadingOrderTraversalPolicy(),
                      child: Listener(
                        onPointerSignal: _onVerticalWheelToParent,
                        child: ListView.separated(
                          controller: _controller,
                          scrollCacheExtent: const ScrollCacheExtent.viewport(
                            1,
                          ),
                          // 首张卡片外缘仍落在 AppSpacing.page 竖线上。
                          padding: const EdgeInsets.symmetric(
                            horizontal:
                                AppSpacing.page - MediaShelf.hoverGutter,
                          ),
                          scrollDirection: Axis.horizontal,
                          itemBuilder: (context, index) {
                            final item = widget.items[index];
                            final child =
                                widget.itemBuilder?.call(context, item) ??
                                PosterCard(
                                  item: item,
                                  showProgress: widget.showProgress,
                                  wide: widget.wide,
                                  width: widget.wide
                                      ? MediaShelf.wideCardWidthFor(screenWidth)
                                      : MediaShelf.posterWidthFor(screenWidth),
                                  onTap: () => widget.onTap(item),
                                  onRemoveFromResume: widget.onRemoveFromResume,
                                );
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: MediaShelf.hoverGutter,
                              ),
                              child: Align(
                                alignment: Alignment.center,
                                child: Listener(
                                  onPointerSignal: _onVerticalWheelToParent,
                                  child: Shortcuts(
                                    shortcuts: _kShelfArrowShortcuts,
                                    child: _EnsureVisibleOnFocus(child: child),
                                  ),
                                ),
                              ),
                            );
                          },
                          separatorBuilder: (context, index) => const SizedBox(
                            width:
                                MediaShelf.cardGap - 2 * MediaShelf.hoverGutter,
                          ),
                          itemCount: widget.items.length,
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
