import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/media_image/media_image.dart';

/// Repairs a removed remote target only on the visible route. Offstage panes
/// cannot receive focus; a surviving nearby target or navigation remains usable.
class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({super.key, required this.child});
  final Widget child;
  @override
  State<TvFocusRegion> createState() => _TvFocusRegionState();
}

class _TvFocusRegionState extends State<TvFocusRegion> {
  final _nodes = <FocusNode>{};
  Rect? _lastRect;
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_schedule);
  }

  void selected(FocusNode node) {
    if (node.context != null) _lastRect = node.rect;
  }

  void remove(FocusNode node) {
    if (node.hasFocus && node.context != null) _lastRect = node.rect;
    _nodes.remove(node);
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          _lastRect == null) {
        return;
      }
      if (_nodes.any((node) => node.hasFocus)) return;
      final current = FocusManager.instance.primaryFocus;
      // Preserve an intentional non-button input target.
      if (current != null &&
          current is! FocusScopeNode &&
          current.context != null &&
          current.context!.findAncestorWidgetOfExactType<EditableText>() !=
              null) {
        return;
      }
      final candidates = _nodes
          .where(
            (node) =>
                node.context?.mounted == true &&
                node.canRequestFocus &&
                !node.skipTraversal,
          )
          .toList();
      candidates.sort(
        (a, b) => (a.rect.center - _lastRect!.center).distanceSquared.compareTo(
          (b.rect.center - _lastRect!.center).distanceSquared,
        ),
      );
      if (candidates.isNotEmpty) {
        candidates.first.requestFocus();
        FocusManager.instance.applyFocusChangesIfNeeded();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _TvFocusRegistry(owner: this, child: widget.child);
}

class _TvFocusRegistry extends InheritedWidget {
  const _TvFocusRegistry({required this.owner, required super.child});
  final _TvFocusRegionState owner;
  @override
  bool updateShouldNotify(_TvFocusRegistry oldWidget) =>
      owner != oldWidget.owner;
}

/// A stable, visible remote target. Its node survives rebuilds and route pushes.
class TvAction extends StatefulWidget {
  const TvAction({
    super.key,
    required this.child,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
    this.emphasized = false,
  });
  final Widget child;
  final FutureOr<void> Function()? onPressed;
  final bool autofocus, selected, emphasized;
  final FocusNode? focusNode;
  @override
  State<TvAction> createState() => _TvActionState();
}

class _TvActionState extends State<TvAction>
    with AutomaticKeepAliveClientMixin {
  final _ownedNode = FocusNode();
  bool get _focused => _node.hasFocus;
  _TvFocusRegionState? _region;
  bool _activating = false;
  FocusNode get _node => widget.focusNode ?? _ownedNode;
  @override
  void initState() {
    super.initState();
    _node.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    updateKeepAlive();
    if (_node.hasFocus) {
      _region?.selected(_node);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _node.hasFocus) {
          Scrollable.ensureVisible(
            context,
            alignment: .5,
            duration: const Duration(milliseconds: 120),
          );
        }
      });
    }
  }

  @override
  bool get wantKeepAlive => _focused;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final region = context
        .dependOnInheritedWidgetOfExactType<_TvFocusRegistry>()
        ?.owner;
    if (!identical(region, _region)) {
      _region?.remove(_node);
      _region = region;
      _region?._nodes.add(_node);
    }
  }

  Future<void> _activate() async {
    if (widget.onPressed == null || _activating) return;
    _activating = true;
    try {
      await widget.onPressed!();
    } finally {
      _activating = false;
      if (mounted && _node.canRequestFocus) _node.requestFocus();
    }
  }

  @override
  void dispose() {
    _region?.remove(_node);
    _node.removeListener(_changed);
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final fill = widget.emphasized
        ? (_focused ? scheme.primary : scheme.primaryContainer)
        : _focused
        ? const Color(0xff315d8c)
        : widget.selected
        ? const Color(0xff253a50)
        : const Color(0xff20252d);
    final foreground = widget.emphasized
        ? (_focused ? scheme.onPrimary : scheme.onPrimaryContainer)
        : null;
    return ExcludeFocus(
      excluding: widget.onPressed == null,
      child: FocusableActionDetector(
        focusNode: _node,
        autofocus: widget.autofocus,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
              ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              unawaited(_activate());
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          enabled: widget.onPressed != null,
          focused: _focused,
          selected: widget.selected,
          child: GestureDetector(
            onTap: widget.onPressed == null ? null : _activate,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              margin: const EdgeInsets.all(4),
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(minHeight: 48),
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(
                  color: _focused ? Colors.white : Colors.transparent,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Opacity(
                opacity: widget.onPressed == null ? .4 : 1,
                child: foreground == null
                    ? widget.child
                    : IconTheme(
                        data: IconThemeData(color: foreground),
                        child: DefaultTextStyle.merge(
                          style: TextStyle(color: foreground),
                          child: widget.child,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TvFrame extends StatelessWidget {
  const TvFrame({
    super.key,
    required this.title,
    required this.child,
    this.back = true,
  });
  final String title;
  final Widget child;
  final bool back;
  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      dialogTheme: const DialogThemeData(
        backgroundColor: Color(0xff151a22),
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: Theme.of(context).textTheme.apply(fontSizeFactor: 1.15),
    ),
    child: TvFocusRegion(
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (back)
                        TvAction(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Icon(Icons.arrow_back),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.headlineSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class TvFailure extends StatelessWidget {
  const TvFailure({super.key, required this.error, required this.retry});
  final EmbyException error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(embyFailureMessage(AppLocalizations.of(context), error)),
      TvAction(
        autofocus: true,
        onPressed: retry,
        child: Text(AppLocalizations.of(context).retry),
      ),
    ],
  );
}

class TvPoster extends StatelessWidget {
  const TvPoster({
    super.key,
    required this.item,
    this.autofocus = false,
    this.imageMaxWidth = 280,
  });
  final EmbyItem item;
  final bool autofocus;
  final int imageMaxWidth;
  @override
  Widget build(BuildContext context) => TvAction(
    autofocus: autofocus,
    onPressed: () => context.push(AppRoutes.item(item.id)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: RepaintBoundary(
            child: MediaImage(item: item, maxWidth: imageMaxWidth),
          ),
        ),
        const SizedBox(height: 8),
        Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    ),
  );
}

class TvGrid extends StatelessWidget {
  const TvGrid({super.key, required this.items});
  final List<EmbyItem> items;

  static int columnCount(double width) => (width / 180).floor().clamp(2, 6);

  static TvGridMetrics metricsFor(BuildContext context, double width) {
    final columns = columnCount(width);
    final cell = width / columns;
    final title = MediaShelf.lineHeightOf(
      context,
      Theme.of(context).textTheme.bodyMedium,
    );
    return TvGridMetrics(
      columns: columns,
      imageMaxWidth: catalogPosterMaxWidth(
        cell,
        MediaQuery.devicePixelRatioOf(context),
      ),
      childAspectRatio: cell / (cell * 1.35 + 8 + title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = metricsFor(context, MediaQuery.sizeOf(context).width);
    return TvPosterSliver(items: items, metrics: metrics);
  }
}

class TvGridMetrics {
  const TvGridMetrics({
    required this.columns,
    required this.imageMaxWidth,
    required this.childAspectRatio,
  });

  final int columns;
  final int imageMaxWidth;
  final double childAspectRatio;
}

/// 只构建视口内的海报。列数在滚动视图外算好，避免每滚一帧重建整屏。
class TvPosterSliver extends StatelessWidget {
  const TvPosterSliver({super.key, required this.items, required this.metrics});

  final List<EmbyItem> items;
  final TvGridMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: metrics.columns,
        childAspectRatio: metrics.childAspectRatio,
      ),
      delegate: _TvPosterDelegate(items: items, metrics: metrics),
    );
  }
}

class _TvPosterDelegate extends SliverChildBuilderDelegate {
  _TvPosterDelegate({required this.items, required TvGridMetrics metrics})
    : super(
        (context, index) => TvPoster(
          key: ValueKey(items[index].id),
          item: items[index],
          imageMaxWidth: metrics.imageMaxWidth,
        ),
        childCount: items.length,
        addAutomaticKeepAlives: false,
      );

  final List<EmbyItem> items;

  @override
  bool shouldRebuild(covariant _TvPosterDelegate oldDelegate) {
    return !identical(oldDelegate.items, items);
  }
}

/// Keep navigation keys out of EditableText until the user deliberately edits.
class TvInput extends StatelessWidget {
  const TvInput({
    super.key,
    required this.label,
    required this.controller,
    this.autofocus = false,
    this.secret = false,
    this.onSubmitted,
  });
  final String label;
  final TextEditingController controller;
  final bool autofocus, secret;
  final VoidCallback? onSubmitted;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) => TvAction(
      autofocus: autofocus,
      onPressed: () async {
        await showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (context) => AlertDialog(
            title: Text(label),
            content: SizedBox(
              width: 600,
              child: TextField(
                key: const Key('tv-input-editor'),
                controller: controller,
                autofocus: true,
                obscureText: secret,
                autocorrect: false,
                enableSuggestions: !secret,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => Navigator.pop(context),
              ),
            ),
            actions: [
              TvAction(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context).mobileBack),
              ),
            ],
          ),
        );
        onSubmitted?.call();
      },
      child: Text(
        '$label  ${secret ? '•' * value.text.length : value.text}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}
