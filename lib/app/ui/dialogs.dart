import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'controls.dart';
import 'theme.dart';

/// Scrollable form/dialog surface, bounded by the viewport and keyboard.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    this.title,
    required this.content,
    this.actions = const [],
    this.maxWidth = 520,
    this.padding = const EdgeInsets.all(24),
  });
  final Widget? title;
  final Widget content;
  final List<Widget> actions;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          24,
          16,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.xl),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.scrim.withValues(alpha: .2),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: padding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (title != null) ...[
                        Semantics(
                          namesRoute: true,
                          header: true,
                          child: DefaultTextStyle(
                            style: theme.textTheme.titleLarge!,
                            child: title!,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      content,
                      if (actions.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: actions,
                        ),
                      ],
                    ],
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

/// Captures local artwork/TV theme across the navigator boundary. Escape/back
/// cancels with null, just like a barrier tap; an explicit result commits.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final theme = AppUiTheme.of(context);
  return showCupertinoDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: '关闭对话框',
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    builder: (context) => AppUiTheme(
      data: theme,
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          if (barrierDismissible)
            const SingleActivator(LogicalKeyboardKey.escape):
                const DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                Navigator.of(context).pop();
                return null;
              },
            ),
          },
          child: FocusTraversalGroup(child: Builder(builder: builder)),
        ),
      ),
    ),
  );
}

Future<T?> showAppModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) {
  final theme = AppUiTheme.of(context);
  return showCupertinoModalPopup<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    builder: (context) => AppUiTheme(
      data: theme,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .9,
          ),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Builder(builder: builder),
          ),
        ),
      ),
    ),
  );
}

class AppMenuEntry<T> {
  const AppMenuEntry({
    required this.value,
    required this.child,
    this.enabled = true,
    this.destructive = false,
  });
  final T value;
  final Widget child;
  final bool enabled, destructive;
}

Future<T?> showAppMenu<T>({
  required BuildContext context,
  required List<AppMenuEntry<T>> items,
  T? selected,
  String? title,
}) => showAppDialog<T>(
  context: context,
  builder: (context) => AppDialog(
    maxWidth: 400,
    title: title == null ? null : Text(title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in items)
          AppButton(
            autofocus:
                entry.enabled &&
                (entry.value == selected ||
                    selected == null && identical(entry, items.first)),
            onPressed: entry.enabled
                ? () => Navigator.of(context).pop(entry.value)
                : null,
            foregroundColor: entry.destructive
                ? AppUiTheme.of(context).colorScheme.error
                : null,
            child: Row(
              children: [
                Expanded(child: entry.child),
                if (entry.value == selected)
                  const Icon(CupertinoIcons.check_mark, size: 18),
              ],
            ),
          ),
      ],
    ),
    actions: [
      AppButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
    ],
  ),
);

class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.items,
    required this.child,
    this.onSelected,
    this.selected,
    this.title,
    this.tooltip,
  });
  final List<AppMenuEntry<T>> items;
  final Widget child;
  final ValueChanged<T>? onSelected;
  final T? selected;
  final String? title, tooltip;
  @override
  Widget build(BuildContext context) {
    final button = AppButton(
      semanticLabel: tooltip,
      onPressed: onSelected == null
          ? null
          : () async {
              final result = await showAppMenu<T>(
                context: context,
                items: items,
                selected: selected,
                title: title,
              );
              if (result != null) onSelected?.call(result);
            },
      child: child,
    );
    return tooltip == null
        ? button
        : AppTooltip(message: tooltip!, child: button);
  }
}

class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.items,
    this.value,
    this.onChanged,
    this.hint,
    this.label,
  });
  final List<AppMenuEntry<T>> items;
  final T? value;
  final ValueChanged<T>? onChanged;
  final Widget? hint;
  final String? label;
  @override
  Widget build(BuildContext context) => AppMenuButton<T>(
    items: items,
    selected: value,
    onSelected: onChanged,
    title: label,
    tooltip: label,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child:
              items.where((entry) => entry.value == value).firstOrNull?.child ??
              hint ??
              const SizedBox(),
        ),
        const SizedBox(width: 8),
        const Icon(CupertinoIcons.chevron_down, size: 14),
      ],
    ),
  );
}

/// App-local transient feedback. Disposal cancels the timer and removes the
/// entry, including when the navigation tree disappears before the timeout.
void showAppNotice(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final theme = AppUiTheme.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _Notice(
      theme: theme,
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
      dismiss: () {
        entry.remove();
        entry.dispose();
      },
    ),
  );
  overlay.insert(entry);
}

class _Notice extends StatefulWidget {
  const _Notice({
    required this.theme,
    required this.message,
    this.actionLabel,
    this.onAction,
    required this.duration,
    required this.dismiss,
  });
  final AppUiThemeData theme;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback dismiss;
  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> {
  Timer? _timer;
  bool _closed = false;
  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    widget.dismiss();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
    left: 16,
    right: 16,
    bottom: 16 + MediaQuery.paddingOf(context).bottom,
    child: AppUiTheme(
      data: widget.theme,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: widget.theme.colorScheme.outline),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(widget.message),
                    ),
                  ),
                  if (widget.actionLabel != null)
                    AppButton(
                      onPressed: () {
                        _dismiss();
                        widget.onAction?.call();
                      },
                      child: Text(widget.actionLabel!),
                    ),
                  AppIconButton(
                    tooltip: '关闭提示',
                    icon: const Icon(CupertinoIcons.xmark),
                    onPressed: _dismiss,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
