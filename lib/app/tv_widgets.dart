import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
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
  });
  final Widget child;
  final FutureOr<void> Function()? onPressed;
  final bool autofocus, selected;
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
                color: _focused
                    ? const Color(0xff315d8c)
                    : widget.selected
                    ? const Color(0xff253a50)
                    : const Color(0xff20252d),
                border: Border.all(
                  color: _focused ? Colors.white : Colors.transparent,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Opacity(
                opacity: widget.onPressed == null ? .4 : 1,
                child: widget.child,
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
            padding: const EdgeInsets.all(28),
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
  const TvPoster({super.key, required this.item, this.autofocus = false});
  final EmbyItem item;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => TvAction(
    autofocus: autofocus,
    onPressed: () => context.push(AppRoutes.item(item.id)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: MediaImage(item: item, maxWidth: 400)),
        const SizedBox(height: 8),
        Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    ),
  );
}

class TvGrid extends StatelessWidget {
  const TvGrid({super.key, required this.items});
  final List<EmbyItem> items;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final columns = (size.maxWidth / 180).floor().clamp(2, 6);
      final width = size.maxWidth / columns;
      return Wrap(
        children: [
          for (final item in items)
            SizedBox(
              key: ValueKey(item.id),
              width: width,
              height: width * 1.35 + 76,
              child: TvPoster(item: item),
            ),
        ],
      );
    },
  );
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
