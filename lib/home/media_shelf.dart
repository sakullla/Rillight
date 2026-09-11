import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/poster_card.dart';

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
    if (widget.wide) {
      return 148;
    }
    return widget.showProgress ? 250 : 230;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateScrollButtons();
      }
    });
  }

  @override
  void didUpdateWidget(MediaShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.items, widget.items) ||
        oldWidget.loading != widget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateScrollButtons();
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
    return Padding(
      key: widget.rowKey,
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (widget.onMore != null)
                  TextButton(
                    key: CatalogKeys.shelfMore(widget.shelfId),
                    onPressed: widget.onMore,
                    child: Text(l10n.more),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (widget.loading)
            SizedBox(height: _rowHeight)
          else if (widget.error != null)
            AppErrorView(
              message: catalogFailureMessage(l10n, widget.error!),
              onRetry: widget.onRetry,
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
                    child: ListView.separated(
                      controller: _controller,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      scrollDirection: Axis.horizontal,
                      itemBuilder: (context, index) {
                        final item = widget.items[index];
                        final child =
                            widget.itemBuilder?.call(context, item) ??
                            PosterCard(
                              item: item,
                              showProgress: widget.showProgress,
                              wide: widget.wide,
                              width: widget.wide ? 220 : 120,
                              onTap: () => widget.onTap(item),
                            );
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Listener(
                            onPointerSignal: _onVerticalWheelToParent,
                            child: child,
                          ),
                        );
                      },
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 12),
                      itemCount: widget.items.length,
                    ),
                  ),
                  if (_canScrollLeft)
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
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
                  if (_canScrollRight)
                    Positioned(
                      right: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
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
                ],
              ),
            ),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        child: IconButton(
          key: buttonKey,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
  }
}
