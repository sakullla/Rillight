import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'theme.dart';

enum AppButtonVariant { plain, filled, tinted, outlined }

/// One focus owner for pointer, keyboard and remote activation. Cupertino's
/// button supplies pointer feedback; the outer focus also handles select/space.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.child,
    this.onPressed,
    this.variant = AppButtonVariant.plain,
    this.focusNode,
    this.autofocus = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.color,
    this.foregroundColor,
    this.semanticLabel,
    this.onFocusChange,
    this.minimumSize = const Size(44, 44),
  });
  final Widget child;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final FocusNode? focusNode;
  final bool autofocus;
  final EdgeInsetsGeometry padding;
  final Color? color, foregroundColor;
  final String? semanticLabel;
  final ValueChanged<bool>? onFocusChange;
  final Size minimumSize;
  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _focused = false, _hovered = false;
  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final enabled = widget.onPressed != null;
    final filled = widget.variant == AppButtonVariant.filled;
    final background =
        widget.color ??
        switch (widget.variant) {
          AppButtonVariant.filled => colors.primary,
          AppButtonVariant.tinted => colors.primaryContainer,
          _ => const Color(0x00000000),
        };
    final foreground = enabled
        ? widget.foregroundColor ?? (filled ? colors.onPrimary : colors.primary)
        : colors.onSurfaceVariant.withValues(alpha: .5);
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onFocusChange: (value) {
        setState(() => _focused = value);
        widget.onFocusChange?.call(value);
      },
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.semanticLabel,
        child: AnimatedContainer(
          duration: AppMotion.durationOf(context, AppMotion.fast),
          decoration: BoxDecoration(
            color: !enabled && filled
                ? colors.surfaceContainerHigh
                : background,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              width: _focused ? 2 : 1,
              color: _focused
                  ? colors.primary
                  : widget.variant == AppButtonVariant.outlined
                  ? colors.outline
                  : _hovered
                  ? colors.outlineVariant
                  : const Color(0x00000000),
            ),
          ),
          child: ExcludeFocus(
            child: CupertinoButton(
              padding: widget.padding,
              minimumSize: widget.minimumSize,
              onPressed: widget.onPressed,
              child: IconTheme(
                data: IconThemeData(color: foreground, size: 20),
                child: DefaultTextStyle(
                  style: theme.textTheme.labelLarge!.copyWith(
                    color: foreground,
                  ),
                  textAlign: TextAlign.center,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    this.color,
    this.size = 20,
    this.padding = const EdgeInsets.all(10),
  });
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? color;
  final double size;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final button = AppButton(
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      padding: padding,
      foregroundColor: color,
      semanticLabel: tooltip,
      child: IconTheme.merge(
        data: IconThemeData(size: size),
        child: icon,
      ),
    );
    return tooltip == null
        ? button
        : AppTooltip(message: tooltip!, child: button);
  }
}

/// Tooltip uses the overlay rather than a Material ancestor.
class AppTooltip extends StatefulWidget {
  const AppTooltip({super.key, required this.message, required this.child});
  final String message;
  final Widget child;
  @override
  State<AppTooltip> createState() => _AppTooltipState();
}

class _AppTooltipState extends State<AppTooltip> {
  final _portal = OverlayPortalController();
  final _anchor = GlobalKey();
  @override
  Widget build(BuildContext context) => MouseRegion(
    key: _anchor,
    onEnter: (_) => _portal.show(),
    onExit: (_) => _portal.hide(),
    child: OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        final colors = AppUiTheme.of(context).colorScheme;
        final anchor = _anchor.currentContext!.findRenderObject()! as RenderBox;
        final overlay =
            Overlay.of(context).context.findRenderObject()! as RenderBox;
        final rect =
            anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
        return Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _TooltipLayout(rect),
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 280),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colors.inverseSurface,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  widget.message,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: widget.child,
    ),
  );
}

class _TooltipLayout extends SingleChildLayoutDelegate {
  _TooltipLayout(this.anchor);
  final Rect anchor;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: (constraints.maxWidth - 16).clamp(0, 280));
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = (anchor.center.dx - childSize.width / 2).clamp(
      8.0,
      (size.width - childSize.width - 8).clamp(8.0, double.infinity),
    );
    final below = anchor.bottom + 6;
    final y = below + childSize.height < size.height - 8
        ? below
        : (anchor.top - childSize.height - 6).clamp(8.0, double.infinity);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_TooltipLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}

/// A Cupertino input backed by FormField so validate/save/reset keep their
/// existing contracts. Labels and errors remain visible outside the input.
class AppTextField extends FormField<String> {
  AppTextField({
    super.key,
    this.controller,
    String? initialValue,
    String? label,
    String? placeholder,
    Widget? prefix,
    Widget? suffix,
    FocusNode? focusNode,
    bool autofocus = false,
    bool obscureText = false,
    super.enabled = true,
    bool readOnly = false,
    int? maxLines = 1,
    int? minLines,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
    VoidCallback? onTap,
    List<TextInputFormatter>? inputFormatters,
    TextStyle? style,
    EdgeInsetsGeometry padding = const EdgeInsets.all(12),
    AutovalidateMode autovalidateMode = AutovalidateMode.disabled,
    super.validator,
    super.onSaved,
    Iterable<String>? autofillHints,
    bool autocorrect = true,
    bool enableSuggestions = true,
  }) : assert(controller == null || initialValue == null),
       super(
         initialValue: controller?.text ?? initialValue ?? '',
         autovalidateMode: autovalidateMode,
         builder: (field) {
           final colors = AppUiTheme.of(field.context).colorScheme;
           return Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             mainAxisSize: MainAxisSize.min,
             children: [
               if (label != null)
                 Padding(
                   padding: const EdgeInsets.only(bottom: 6),
                   child: Text(label),
                 ),
               CupertinoTextField(
                 controller: (field as _AppTextFieldState)._controller,
                 focusNode: focusNode,
                 autofocus: autofocus,
                 obscureText: obscureText,
                 enabled: enabled,
                 readOnly: readOnly,
                 maxLines: maxLines,
                 minLines: minLines,
                 keyboardType: keyboardType,
                 textInputAction: textInputAction,
                 inputFormatters: inputFormatters,
                 autofillHints: autofillHints,
                 autocorrect: autocorrect,
                 enableSuggestions: enableSuggestions,
                 placeholder: placeholder,
                 prefix: prefix,
                 suffix: suffix,
                 padding: padding,
                 style: style ?? TextStyle(color: colors.onSurface),
                 decoration: BoxDecoration(
                   color: colors.surfaceContainerLowest,
                   borderRadius: BorderRadius.circular(AppRadii.sm),
                   border: Border.all(
                     color: field.hasError ? colors.error : colors.outline,
                   ),
                 ),
                 onChanged: (value) {
                   field.didChange(value);
                   onChanged?.call(value);
                 },
                 onSubmitted: onSubmitted,
                 onTap: onTap,
               ),
               if (field.errorText != null)
                 Padding(
                   padding: const EdgeInsets.only(top: 6),
                   child: Semantics(
                     liveRegion: true,
                     child: Text(
                       field.errorText!,
                       style: TextStyle(color: colors.error, fontSize: 13),
                     ),
                   ),
                 ),
             ],
           );
         },
       );

  final TextEditingController? controller;

  @override
  FormFieldState<String> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends FormFieldState<String> {
  TextEditingController? _owned;
  AppTextField get _field => widget as AppTextField;
  TextEditingController get _controller => _field.controller ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (_field.controller == null) {
      _owned = TextEditingController(text: widget.initialValue);
    }
    _controller.addListener(_sync);
  }

  void _sync() {
    if (_controller.text != value) didChange(_controller.text);
  }

  @override
  void didUpdateWidget(covariant AppTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_field.controller == oldWidget.controller) return;
    final oldController = oldWidget.controller ?? _owned!;
    final previousValue = oldController.value;
    oldController.removeListener(_sync);
    _owned?.dispose();
    _owned = _field.controller == null
        ? TextEditingController.fromValue(previousValue)
        : null;
    _controller.addListener(_sync);
    setValue(_controller.text);
  }

  @override
  void reset() {
    _controller.text = widget.initialValue ?? '';
    super.reset();
  }

  @override
  void dispose() {
    _controller.removeListener(_sync);
    _owned?.dispose();
    super.dispose();
  }
}

class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onSelected,
    this.focusNode,
    this.avatar,
  });
  final Widget label;
  final Widget? avatar;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: AppButton(
        focusNode: focusNode,
        onPressed: onSelected == null ? null : () => onSelected!(!selected),
        color: selected ? colors.primaryContainer : colors.surfaceContainerHigh,
        foregroundColor: selected
            ? colors.onPrimaryContainer
            : colors.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (avatar != null) ...[avatar!, const SizedBox(width: 6)],
            label,
          ],
        ),
      ),
    );
  }
}

class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.selected = false,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 10,
    ),
  });
  final Widget? leading, subtitle, trailing;
  final Widget title;
  final VoidCallback? onTap;
  final bool enabled, selected;
  final EdgeInsetsGeometry contentPadding;
  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final content = Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle(style: theme.textTheme.bodyLarge!, child: title),
              if (subtitle != null)
                DefaultTextStyle(
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  child: subtitle!,
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
    return Semantics(
      selected: selected,
      enabled: enabled,
      child: onTap == null
          ? Padding(padding: contentPadding, child: content)
          : AppButton(
              onPressed: enabled ? onTap : null,
              padding: contentPadding,
              color: selected ? theme.colorScheme.primaryContainer : null,
              foregroundColor: theme.colorScheme.onSurface,
              child: content,
            ),
    );
  }
}

class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    this.onChanged,
  });
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => AppListTile(
    title: title,
    subtitle: subtitle,
    trailing: CupertinoSwitch(value: value, onChanged: onChanged),
  );
}

class AppDivider extends StatelessWidget {
  const AppDivider({
    super.key,
    this.height = 16,
    this.thickness = 1,
    this.indent = 0,
    this.endIndent = 0,
    this.color,
  });
  final double height, thickness, indent, endIndent;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Center(
      child: Container(
        height: thickness,
        margin: EdgeInsetsDirectional.only(start: indent, end: endIndent),
        color: color ?? AppUiTheme.of(context).dividerColor,
      ),
    ),
  );
}

class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.value,
    this.color,
    this.backgroundColor,
    this.height = 4,
  });
  final double value, height;
  final Color? color, backgroundColor;
  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    return Semantics(
      value: '${(value.clamp(0, 1) * 100).round()}%',
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: ColoredBox(
            color: backgroundColor ?? colors.surfaceContainerHighest,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                widthFactor: value.clamp(0, 1),
                child: ColoredBox(
                  color: color ?? colors.primary,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
