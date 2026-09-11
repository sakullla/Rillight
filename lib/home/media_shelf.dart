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
  final Widget Function(BuildContext context, EmbyItem item)? itemBuilder;

  @override
  State<MediaShelf> createState() => _MediaShelfState();
}

class _MediaShelfState extends State<MediaShelf> {
  final _controller = ScrollController();
  bool _overflowing = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

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

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final scroll = resolved as PointerScrollEvent;
      final position = _controller.position;
      final delta = scroll.scrollDelta.dy != 0
          ? scroll.scrollDelta.dy
          : scroll.scrollDelta.dx;
      _controller.jumpTo(
        (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      key: widget.rowKey,
      padding: const EdgeInsets.only(bottom: 24),
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
            SizedBox(height: widget.showProgress ? 250 : 230)
          else if (widget.error != null)
            AppErrorView(
              message: catalogFailureMessage(l10n, widget.error!),
              onRetry: widget.onRetry,
            )
          else
            SizedBox(
              height: widget.showProgress ? 250 : 230,
              child: Stack(
                children: [
                  Listener(
                    onPointerSignal: _onPointerSignal,
                    child: NotificationListener<ScrollMetricsNotification>(
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
                          return widget.itemBuilder?.call(context, item) ??
                              PosterCard(
                                item: item,
                                showProgress: widget.showProgress,
                                onTap: () => widget.onTap(item),
                              );
                        },
                        separatorBuilder: (context, index) =>
                            const SizedBox(width: 12),
                        itemCount: widget.items.length,
                      ),
                    ),
                  ),
                  if (_overflowing) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _ScrollButton(
                        buttonKey: CatalogKeys.shelfScrollLeft(widget.shelfId),
                        tooltip: l10n.scrollLeft,
                        icon: Icons.chevron_left,
                        onPressed: _canScrollLeft ? () => _page(-1) : null,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _ScrollButton(
                        buttonKey: CatalogKeys.shelfScrollRight(widget.shelfId),
                        tooltip: l10n.scrollRight,
                        icon: Icons.chevron_right,
                        onPressed: _canScrollRight ? () => _page(1) : null,
                      ),
                    ),
                  ],
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
