import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';

/// Tells server flows how the hosting panel sizes them.
///
/// The desktop panel hugs its content (a two-server list or the unlock step
/// must not float in a mostly empty 800px card); the phone page fills the
/// safe viewport.
class ServerPanelScope extends InheritedWidget {
  const ServerPanelScope({
    super.key,
    required this.shrinkWrap,
    required this.compact,
    required super.child,
  });

  /// Body sizes to its content up to the panel's maximum height.
  final bool shrinkWrap;

  /// Narrow (phone) presentation: tighter padding, back arrow navigation.
  final bool compact;

  static ServerPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ServerPanelScope>();

  @override
  bool updateShouldNotify(ServerPanelScope oldWidget) =>
      shrinkWrap != oldWidget.shrinkWrap || compact != oldWidget.compact;
}

/// A single scrollable body and a persistent header; child steps replace the
/// body rather than creating another modal route above the current form.
class ServerFlowFrame extends StatefulWidget {
  const ServerFlowFrame({
    super.key,
    required this.title,
    required this.onBack,
    required this.child,
    this.action,
    this.backLabel,
    this.subtitle,
    this.scroll = true,
    this.dismissible = false,
    this.footer,
  });
  final String title;
  final String? backLabel;
  final String? subtitle;
  final VoidCallback onBack;
  final Widget child;
  final Widget? action;
  final bool scroll;

  /// Root of a desktop panel: closes with an ✕ on the trailing edge instead of
  /// a back arrow. Phone keeps the back arrow (system back owns closing).
  final bool dismissible;

  /// Pinned below the body; keeps the primary action reachable above long
  /// content and the on-screen keyboard.
  final Widget? footer;
  @override
  State<ServerFlowFrame> createState() => _ServerFlowFrameState();
}

class _ServerFlowFrameState extends State<ServerFlowFrame> {
  final scrollController = ScrollController();
  bool scrolled = false;

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final next = notification.metrics.pixels > 2;
    if (next != scrolled) setState(() => scrolled = next);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final scope = ServerPanelScope.maybeOf(context);
    final shrink = scope?.shrinkWrap ?? false;
    final compact = scope?.compact ?? false;
    final closeAtEnd = widget.dismissible && !compact;
    final pad = compact ? 16.0 : 22.0;
    final backButton = AppIconButton(
      key: const Key('server-flow-back'),
      tooltip:
          widget.backLabel ?? (closeAtEnd ? l.serversDismiss : l.serversBack),
      onPressed: widget.onBack,
      minimumSize: const Size(44, 44),
      icon: Icon(closeAtEnd ? AppIcons.close : AppIcons.back, size: 22),
    );
    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        closeAtEnd ? pad : 8,
        compact ? 8 : 14,
        closeAtEnd ? 12 : pad - 6,
        compact ? 8 : 12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (!closeAtEnd) ...[backButton, const SizedBox(width: 4)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.3,
                    fontSize: compact ? 20 : 22,
                  ),
                ),
                if (widget.subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.action != null) ...[
            const SizedBox(width: 10),
            widget.action!,
          ],
          if (closeAtEnd) ...[const SizedBox(width: 6), backButton],
        ],
      ),
    );
    Widget body = widget.scroll
        ? CupertinoScrollbar(
            controller: scrollController,
            child: SingleChildScrollView(
              controller: scrollController,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(pad, 6, pad, pad + 4),
              child: widget.child,
            ),
          )
        : widget.child;
    body = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: body,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onBack,
      },
      child: FocusScope(
        key: ValueKey(widget.title),
        autofocus: true,
        child: FocusTraversalGroup(
          child: Column(
            mainAxisSize: shrink ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              AnimatedOpacity(
                opacity: scrolled ? 1 : 0,
                duration: AppMotion.fast,
                child: AppDivider(
                  height: 1,
                  thickness: .6,
                  color: colors.outlineVariant,
                ),
              ),
              if (shrink) Flexible(child: body) else Expanded(child: body),
              if (widget.footer != null)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: .7),
                        width: .6,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(pad, 12, pad, 14),
                    child: widget.footer,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
