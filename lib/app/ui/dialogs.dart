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
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 24,
    ),
  });
  final Widget? title;
  final Widget content;
  final List<Widget> actions;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final EdgeInsets insetPadding;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          insetPadding.left,
          insetPadding.top,
          insetPadding.right,
          insetPadding.bottom + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: DecoratedBox(
              decoration: overlaySurfaceDecoration(theme),
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

/// A bounded modal viewport for pages that own their scrolling and footer.
class AppModalFrame extends StatelessWidget {
  const AppModalFrame({
    super.key,
    required this.child,
    this.backgroundColor,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 24,
      vertical: 24,
    ),
    this.clipBehavior = Clip.antiAlias,
  });
  final Widget child;
  final Color? backgroundColor;
  final EdgeInsets insetPadding;
  final Clip clipBehavior;
  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    return SafeArea(
      child: Padding(
        padding:
            insetPadding +
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Center(
          child: Container(
            clipBehavior: clipBehavior,
            decoration: overlaySurfaceDecoration(theme, color: backgroundColor),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 对话框、浮层面板共用的表面:浮层圆角、发丝亮边与两层投影。
///
/// 深色主题的亮边让面板从压暗的页面里浮出来,不靠加亮底色。
BoxDecoration overlaySurfaceDecoration(
  AppUiThemeData theme, {
  Color? color,
  BorderRadius? borderRadius,
}) => BoxDecoration(
  color: color ?? theme.colorScheme.surfaceContainerLow,
  borderRadius: borderRadius ?? BorderRadius.circular(AppRadii.overlay),
  border: Border.all(color: AppEdge.of(theme.brightness, strong: true)),
  boxShadow: AppShadow.overlay(theme.brightness),
);

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
            child: MediaQuery.removeViewInsets(
              context: context,
              removeBottom: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadii.overlay),
                  ),
                  // 圆角边框要求四边同色;底边贴在屏幕外,看到的只有顶缘亮边。
                  border: Border.all(
                    color: AppEdge.of(theme.brightness, strong: true),
                  ),
                  boxShadow: AppShadow.overlay(theme.brightness),
                ),
                child: Builder(builder: builder),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AppMenuEntry<T> {
  const AppMenuEntry({
    this.key,
    required this.value,
    required this.child,
    this.enabled = true,
    this.destructive = false,
  });
  final T value;
  final Key? key;
  final Widget child;
  final bool enabled, destructive;
}

Future<T?> showAppMenu<T>({
  required BuildContext context,
  required List<AppMenuEntry<T>> items,
  T? selected,
  String? title,
  RelativeRect? position,
  BoxConstraints? constraints,
}) => showAppDialog<T>(
  context: context,
  builder: (context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final anchored = position != null;
    final content = Column(
      key: const Key('app-menu-content'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in items)
          AppButton(
            key: entry.key,
            autofocus:
                entry.enabled &&
                (entry.value == selected ||
                    selected == null && identical(entry, items.first)),
            onPressed: entry.enabled
                ? () => Navigator.of(context).pop(entry.value)
                : null,
            // 锚定菜单是一列左对齐的条目:正文用墨色,当前项用强调色浅底和勾,
            // 不再整列染成蓝色链接。
            color: anchored && entry.value == selected
                ? scheme.primaryContainer
                : null,
            foregroundColor: entry.destructive
                ? scheme.error
                : anchored
                ? (entry.value == selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface)
                : null,
            padding: anchored
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: DefaultTextStyle.merge(
              textAlign: anchored ? TextAlign.start : null,
              style: anchored && entry.value == selected
                  ? const TextStyle(fontWeight: FontWeight.w600)
                  : null,
              child: Row(
                children: [
                  Expanded(child: entry.child),
                  if (entry.value == selected)
                    Icon(
                      CupertinoIcons.check_mark,
                      size: 16,
                      color: anchored ? scheme.primary : null,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
    if (position != null) {
      return Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: CustomSingleChildLayout(
          delegate: _AppMenuLayout(position, constraints),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppUiTheme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              border: Border.all(
                color: AppUiTheme.of(context).colorScheme.outlineVariant,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppUiTheme.of(context).colorScheme.scrim.withValues(
                    alpha: AppUiTheme.of(context).brightness == Brightness.dark
                        ? 0.42
                        : 0.16,
                  ),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(6),
              child: content,
            ),
          ),
        ),
      );
    }
    return AppDialog(
      maxWidth: constraints?.maxWidth ?? 400,
      title: title == null ? null : Text(title),
      content: content,
      actions: [
        AppButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  },
);

class _AppMenuLayout extends SingleChildLayoutDelegate {
  _AppMenuLayout(this.position, this.constraints);
  final RelativeRect position;
  final BoxConstraints? constraints;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints parent) {
    final width = (constraints?.maxWidth ?? 360).clamp(
      0.0,
      (parent.maxWidth - 16).clamp(0.0, double.infinity),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: (parent.maxHeight - 16).clamp(0, double.infinity),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    position.left.clamp(
      8.0,
      (size.width - childSize.width - 8).clamp(8.0, double.infinity),
    ),
    position.top.clamp(
      8.0,
      (size.height - childSize.height - 8).clamp(8.0, double.infinity),
    ),
  );
  @override
  bool shouldRelayout(_AppMenuLayout oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.constraints != constraints;
}

class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.items,
    required this.child,
    this.onSelected,
    this.selected,
    this.title,
    this.tooltip,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.style,
  });
  final List<AppMenuEntry<T>> items;
  final Widget child;
  final ValueChanged<T>? onSelected;
  final T? selected;
  final String? title, tooltip;

  /// 触发钮内边距。子组件自带胶囊外形时传 [EdgeInsets.zero],
  /// 避免胶囊外再套一圈按钮底面。
  final EdgeInsetsGeometry padding;
  final AppButtonStyle? style;
  @override
  Widget build(BuildContext context) {
    final button = AppButton(
      semanticLabel: tooltip,
      padding: padding,
      style: style,
      onPressed: onSelected == null
          ? null
          : () async {
              final box = context.findRenderObject()! as RenderBox;
              final origin = box.localToGlobal(Offset(0, box.size.height));
              final result = await showAppMenu<T>(
                context: context,
                items: items,
                selected: selected,
                title: title,
                position: RelativeRect.fromLTRB(origin.dx, origin.dy, 0, 0),
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
VoidCallback showAppNotice(
  BuildContext context,
  String message, {
  Key? key,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) => AppNoticeHost.of(context).show(
  message,
  key: key,
  actionLabel: actionLabel,
  onAction: onAction,
  duration: duration,
);

/// Capture before closing a route so feedback can survive its disposal.
/// The root overlay and theme do not depend on the outgoing route's context.
class AppNoticeHost {
  AppNoticeHost.navigator(NavigatorState navigator, AppUiThemeData theme)
    : _overlay = navigator.overlay!,
      _theme = theme;
  AppNoticeHost.of(BuildContext context)
    : _overlay = Overlay.of(context, rootOverlay: true),
      _theme = AppUiTheme.of(context);

  final OverlayState _overlay;
  final AppUiThemeData _theme;

  VoidCallback show(
    String message, {
    Key? key,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!_overlay.mounted) return () {};
    final noticeKey = GlobalKey<_NoticeState>();
    var removed = false;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _Notice(
        key: noticeKey,
        theme: _theme,
        message: message,
        messageKey: key,
        actionLabel: actionLabel,
        onAction: onAction,
        duration: duration,
        dismiss: () {
          if (removed) return;
          removed = true;
          entry.remove();
          entry.dispose();
        },
      ),
    );
    _overlay.insert(entry);
    return () {
      if (removed) return;
      final notice = noticeKey.currentState;
      if (notice != null) {
        notice._dismiss();
      } else {
        removed = true;
        entry.remove();
        entry.dispose();
      }
    };
  }
}

class _Notice extends StatefulWidget {
  const _Notice({
    super.key,
    required this.theme,
    required this.message,
    this.messageKey,
    this.actionLabel,
    this.onAction,
    required this.duration,
    required this.dismiss,
  });
  final AppUiThemeData theme;
  final String message;
  final Key? messageKey;
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
    key: const Key('app-notice'),
    left: 16,
    right: 16,
    bottom: 20 + MediaQuery.paddingOf(context).bottom,
    child: AppUiTheme(
      data: widget.theme,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              border: Border.all(
                color: widget.theme.colorScheme.outlineVariant,
              ),
              boxShadow: [
                BoxShadow(
                  color: widget.theme.colorScheme.scrim.withValues(alpha: 0.28),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        widget.message,
                        key: widget.messageKey,
                        style: widget.theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
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
                    icon: const Icon(CupertinoIcons.xmark, size: 16),
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
