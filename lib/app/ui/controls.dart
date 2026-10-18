import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'theme.dart';

enum AppButtonVariant { plain, filled, tinted, outlined }

/// One corner radius per emphasis level, shared by desktop, phone and TV.
/// 有底色或描边的按钮是胶囊;纯文本/图标按钮保持圆角矩形,悬停底色更收敛。
double _buttonRadius(AppButtonVariant variant) => switch (variant) {
  AppButtonVariant.plain => AppRadii.md,
  AppButtonVariant.filled => AppRadii.pill,
  AppButtonVariant.tinted => AppRadii.pill,
  AppButtonVariant.outlined => AppRadii.pill,
};

const _tvFocusScale = 1.04;
const _tvPressScale = 0.96;

/// 指针/触控按下时的轻微回弹。TV 另有焦点缩放档。
const _pressScale = 0.97;

/// Laid-out hit box on each axis. Style sizes and icon constraints can ask
/// for less; they cannot shrink the control below this.
const _minHitExtent = 44.0;

double _hitExtent(double value) =>
    value.isFinite && value < _minHitExtent ? _minHitExtent : value;

Size _hitSize(Size size) =>
    Size(_hitExtent(size.width), _hitExtent(size.height));

/// Exact size is the larger of the requested fixed size and the minimum,
/// then raised to [_minHitExtent] on each axis.
Size _fixedHitSize(Size fixed, Size minimum) {
  final resolved = _hitSize(fixed);
  final floor = _hitSize(minimum);
  return Size(
    resolved.width < floor.width ? floor.width : resolved.width,
    resolved.height < floor.height ? floor.height : resolved.height,
  );
}

BoxConstraints _hitConstraints(BoxConstraints constraints) {
  final minWidth = _hitExtent(constraints.minWidth);
  final minHeight = _hitExtent(constraints.minHeight);
  return BoxConstraints(
    minWidth: minWidth,
    maxWidth: constraints.maxWidth < minWidth ? minWidth : constraints.maxWidth,
    minHeight: minHeight,
    maxHeight: constraints.maxHeight < minHeight
        ? minHeight
        : constraints.maxHeight,
  );
}

/// Reusable app action appearance, independent of a design library's states.
class AppButtonStyle {
  const AppButtonStyle({
    this.padding,
    this.minimumSize,
    this.fixedSize,
    this.foregroundColor,
    this.backgroundColor,
    this.disabledForegroundColor,
    this.hoverColor,
    this.side,
    this.shape,
    this.textStyle,
    this.boxShadow,
  });
  final EdgeInsetsGeometry? padding;
  final Size? minimumSize, fixedSize;
  final Color? foregroundColor,
      backgroundColor,
      disabledForegroundColor,
      hoverColor;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final TextStyle? textStyle;

  /// 投影:仅实底主按钮(如播放 CTA)需要,从画面里浮出来。描边/纯文本按钮
  /// 保持平面,浮层投影由 [AppShadow] 提供。
  final List<BoxShadow>? boxShadow;
}

/// Selectable read-only text with an owned controller that follows its value.
class AppSelectableText extends StatefulWidget {
  const AppSelectableText(this.data, {super.key, this.style});
  final String data;
  final TextStyle? style;
  @override
  State<AppSelectableText> createState() => _AppSelectableTextState();
}

class _AppSelectableTextState extends State<AppSelectableText> {
  late final _controller = TextEditingController(text: widget.data);
  @override
  void didUpdateWidget(AppSelectableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _controller.text = widget.data;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoTextField(
    controller: _controller,
    style: widget.style,
    readOnly: true,
    maxLines: null,
    decoration: null,
    padding: EdgeInsets.zero,
  );
}

/// One focus owner for pointer, keyboard and remote activation. Cupertino's
/// button supplies pointer feedback; the outer focus also handles select/space.
///
/// Hover, keyboard focus, pressed, disabled and selected each differ from the
/// resting face. Television focus changes the fill and the scale.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.child,
    this.onPressed,
    this.variant = AppButtonVariant.plain,
    this.selected = false,
    this.focusNode,
    this.autofocus = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.color,
    this.foregroundColor,
    this.semanticLabel,
    this.onFocusChange,
    this.minimumSize = const Size(_minHitExtent, _minHitExtent),
    this.style,
  });
  AppButton.icon({
    super.key,
    required Widget icon,
    required Widget label,
    this.onPressed,
    this.variant = AppButtonVariant.plain,
    this.selected = false,
    this.focusNode,
    this.autofocus = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.color,
    this.foregroundColor,
    this.semanticLabel,
    this.onFocusChange,
    this.minimumSize = const Size(_minHitExtent, _minHitExtent),
    this.style,
  }) : child = Row(
         mainAxisSize: MainAxisSize.min,
         children: [
           icon,
           const SizedBox(width: 8),
           Flexible(child: label),
         ],
       );
  final Widget child;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;

  /// Selected emphasis. Independent of hover, focus, pressed and disabled.
  final bool selected;
  final FocusNode? focusNode;
  final bool autofocus;
  final EdgeInsetsGeometry padding;
  final Color? color, foregroundColor;
  final String? semanticLabel;
  final ValueChanged<bool>? onFocusChange;
  final Size minimumSize;
  final AppButtonStyle? style;
  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _focused = false,
      _hovered = false,
      _pointerDown = false,
      _keyDown = false;
  bool get _pressed => _pointerDown || _keyDown;
  static final _activateKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
  };

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  @override
  void didUpdateWidget(AppButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onPressed == null && (_pointerDown || _keyDown)) {
      _pointerDown = false;
      _keyDown = false;
    }
  }

  bool _handleKey(KeyEvent event) {
    if (!_focused ||
        widget.onPressed == null ||
        !_activateKeys.contains(event.logicalKey)) {
      return false;
    }
    final down = event is! KeyUpEvent;
    if (_keyDown != down) setState(() => _keyDown = down);
    return false;
  }

  void _setPointer(bool value) {
    if (widget.onPressed == null || _pointerDown == value) return;
    setState(() => _pointerDown = value);
  }

  _ButtonFace _face(AppUiThemeData theme) {
    final colors = theme.colorScheme;
    final enabled = widget.onPressed != null;
    final customFill = widget.color ?? widget.style?.backgroundColor;
    final resting =
        customFill ??
        switch (widget.variant) {
          AppButtonVariant.filled => colors.primary,
          AppButtonVariant.tinted => colors.primaryContainer,
          AppButtonVariant.plain ||
          AppButtonVariant.outlined => const Color(0x00000000),
        };
    final tvFocus = theme.tv && _focused && enabled;
    var fill = resting;
    var scale = 1.0;
    var side =
        widget.style?.side ??
        BorderSide(
          color: widget.variant == AppButtonVariant.outlined
              ? colors.outline
              : const Color(0x00000000),
        );

    if (!enabled) {
      if (widget.variant == AppButtonVariant.filled) {
        fill = colors.surfaceContainerHigh;
      }
      if (widget.variant == AppButtonVariant.outlined &&
          widget.style?.side == null) {
        side = BorderSide(color: colors.outline.withValues(alpha: .38));
      }
    } else if (tvFocus && !_pressed) {
      fill = colors.inverseSurface;
      scale = _tvFocusScale;
      side = BorderSide(color: colors.primary, width: 2);
    } else if (_pressed) {
      fill = theme.tv && _focused
          ? Color.alphaBlend(
              colors.scrim.withValues(alpha: .16),
              colors.inverseSurface,
            )
          : _stateFill(colors, resting, customFill != null, _PressKind.pressed);
      scale = theme.tv
          ? (_focused ? _tvPressScale : 1)
          : (widget.variant == AppButtonVariant.plain ? 1 : _pressScale);
      // 按下只压暗底色;键盘焦点保留焦点环,不再叠一圈强调色边。
      if (_focused) side = BorderSide(color: colors.primary, width: 2);
    } else if (_focused) {
      if (customFill == null) {
        fill = _stateFill(colors, resting, false, _PressKind.focus);
      }
      side = BorderSide(color: colors.primary, width: 2);
    } else if (widget.selected) {
      if (customFill == null) fill = colors.secondaryContainer;
      if (widget.style?.side == null) {
        side = BorderSide(color: colors.secondary, width: 2);
      }
    } else if (_hovered) {
      // 悬停只换底色,不额外加边框,平面按钮更干净。
      fill =
          widget.style?.hoverColor ??
          _stateFill(colors, resting, customFill != null, _PressKind.hover);
    }

    // 品牌主按钮:未自定义底色的实底按钮铺品牌渐变(主色向次强调色偏移,
    // 与图标的粉紫渐变同源),并带同色光晕。
    // TV 焦点是反相实底,禁用态是中性底,两者都不走渐变。
    final brand =
        widget.variant == AppButtonVariant.filled &&
        enabled &&
        customFill == null &&
        !tvFocus;
    return _ButtonFace(
      fill: fill,
      gradient: brand
          ? LinearGradient(
              colors: [fill, Color.lerp(fill, colors.secondary, .55)!],
            )
          : null,
      foreground: _foreground(colors, enabled, tvFocus),
      side: side,
      radius: _buttonRadius(widget.variant),
      scale: scale,
      shadow:
          widget.style?.boxShadow ??
          (brand && !_pressed
              ? AppShadow.glow(colors.primary, theme.brightness)
              : null),
    );
  }

  Color _stateFill(
    AppColorScheme colors,
    Color resting,
    bool custom,
    _PressKind kind,
  ) {
    if (!custom &&
        (widget.variant == AppButtonVariant.plain ||
            widget.variant == AppButtonVariant.outlined)) {
      return switch (kind) {
        _PressKind.hover => colors.surfaceContainerHigh,
        _PressKind.focus => colors.surfaceContainerHighest,
        _PressKind.pressed => colors.surfaceBright,
      };
    }
    final base = resting.a == 0 ? colors.surfaceContainerHighest : resting;
    final (ink, amount) = switch (kind) {
      _PressKind.hover => (colors.onSurface, .1),
      _PressKind.focus => (
        widget.variant == AppButtonVariant.filled
            ? colors.onSurface
            : colors.primary,
        .22,
      ),
      _PressKind.pressed => (colors.scrim, .16),
    };
    return Color.alphaBlend(ink.withValues(alpha: amount), base);
  }

  Color _foreground(AppColorScheme colors, bool enabled, bool tvFocus) {
    if (tvFocus) return colors.onInverseSurface;
    if (!enabled) {
      return widget.style?.disabledForegroundColor ??
          colors.onSurfaceVariant.withValues(alpha: .5);
    }
    final explicit = widget.foregroundColor ?? widget.style?.foregroundColor;
    if (explicit != null) return explicit;
    if (widget.selected &&
        widget.color == null &&
        widget.style?.backgroundColor == null) {
      return colors.onSecondaryContainer;
    }
    return widget.variant == AppButtonVariant.filled
        ? colors.onPrimary
        : colors.primary;
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final enabled = widget.onPressed != null;
    final face = _face(theme);
    final minimumSize = _hitSize(
      widget.style?.minimumSize ?? widget.minimumSize,
    );
    final fixedSize = widget.style?.fixedSize;
    final duration = AppMotion.durationOf(context, AppMotion.fast);
    final shape =
        (widget.style?.shape ??
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(face.radius),
                ))
            .copyWith(side: face.side);
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onFocusChange: (value) {
        setState(() {
          _focused = value;
          if (!value) _keyDown = false;
        });
        widget.onFocusChange?.call(value);
      },
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      shortcuts: const <ShortcutActivator, Intent>{
        _KeyPhaseActivator(LogicalKeyboardKey.enter, up: false):
            DoNothingIntent(),
        _KeyPhaseActivator(LogicalKeyboardKey.space, up: false):
            DoNothingIntent(),
        _KeyPhaseActivator(LogicalKeyboardKey.select, up: false):
            DoNothingIntent(),
        _KeyPhaseActivator(LogicalKeyboardKey.enter, up: true):
            ActivateIntent(),
        _KeyPhaseActivator(LogicalKeyboardKey.space, up: true):
            ActivateIntent(),
        _KeyPhaseActivator(LogicalKeyboardKey.select, up: true):
            ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        DoNothingIntent: DoNothingAction(),
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
        selected: widget.selected ? true : null,
        label: widget.semanticLabel,
        child: Listener(
          onPointerDown: (_) => _setPointer(true),
          onPointerUp: (_) => _setPointer(false),
          onPointerCancel: (_) => _setPointer(false),
          child: AnimatedScale(
            scale: face.scale,
            duration: duration,
            alignment: Alignment.center,
            child: AnimatedContainer(
              duration: duration,
              constraints: fixedSize == null
                  ? null
                  : BoxConstraints.tight(_fixedHitSize(fixedSize, minimumSize)),
              decoration: ShapeDecoration(
                color: face.gradient == null ? face.fill : null,
                gradient: face.gradient,
                shape: shape,
                shadows: face.shadow,
              ),
              child: ExcludeFocus(
                child: CupertinoButton(
                  padding: widget.style?.padding ?? widget.padding,
                  minimumSize: minimumSize,
                  onPressed: widget.onPressed,
                  child: IconTheme(
                    data: IconThemeData(color: face.foreground, size: 20),
                    child: DefaultTextStyle(
                      style:
                          (widget.style?.textStyle ??
                                  (widget.variant == AppButtonVariant.filled
                                      // 实底主按钮的字压在饱和色上,需要半粗才立得住。
                                      ? theme.textTheme.labelLarge!.copyWith(
                                          fontWeight: FontWeight.w600,
                                        )
                                      : theme.textTheme.labelLarge!))
                              .copyWith(color: face.foreground),
                      textAlign: TextAlign.center,
                      child: widget.child,
                    ),
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

enum _PressKind { hover, focus, pressed }

/// Key-down is the pressed face only. The action runs on release, and the
/// down event is consumed so an ancestor shortcut does not run it early.
class _KeyPhaseActivator extends SingleActivator {
  const _KeyPhaseActivator(super.trigger, {required this.up});

  final bool up;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    final matched = up ? event is KeyUpEvent : event is KeyDownEvent;
    return matched && event.logicalKey == trigger;
  }
}

class _ButtonFace {
  const _ButtonFace({
    required this.fill,
    required this.foreground,
    required this.side,
    required this.radius,
    required this.scale,
    this.gradient,
    this.shadow,
  });
  final Color fill, foreground;
  final Gradient? gradient;
  final BorderSide side;
  final double radius, scale;
  final List<BoxShadow>? shadow;
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
    this.minimumSize = const Size(_minHitExtent, _minHitExtent),
    this.backgroundColor,
    this.style,
    this.constraints,
    this.selected = false,
  });
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? color;
  final double size;
  final EdgeInsetsGeometry padding;
  final Size minimumSize;
  final Color? backgroundColor;
  final AppButtonStyle? style;
  final BoxConstraints? constraints;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    // 纯图标按钮默认用中性墨色:工具栏一排图标若都染强调色,页面会显得杂乱。
    // 强调色留给主要操作与选中态;调用方显式传色时仍按调用方。
    final neutral =
        color == null &&
            style?.foregroundColor == null &&
            !selected &&
            !AppUiTheme.of(context).tv
        ? AppUiTheme.of(context).colorScheme.onSurfaceVariant
        : color;
    final button = AppButton(
      onPressed: onPressed,
      selected: selected,
      focusNode: focusNode,
      autofocus: autofocus,
      padding: padding,
      foregroundColor: neutral,
      color: backgroundColor,
      style: style,
      minimumSize: minimumSize,
      semanticLabel: tooltip,
      child: IconTheme.merge(
        data: IconThemeData(size: size),
        child: icon,
      ),
    );
    final bounded = constraints == null
        ? button
        : ConstrainedBox(
            constraints: _hitConstraints(constraints!),
            child: button,
          );
    return tooltip == null
        ? bounded
        : AppTooltip(message: tooltip!, child: bounded);
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
  Timer? _timer;
  void _showTouch() {
    _timer?.cancel();
    _portal.show();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) _portal.hide();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

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
        // 深色主题用深色 tooltip:白盒压在暗画面上同样"莫名其妙"。
        final dark = colors.brightness == Brightness.dark;
        final background = dark
            ? colors.surfaceContainerHighest
            : colors.inverseSurface;
        final foreground = dark ? colors.onSurface : colors.onInverseSurface;
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
                  color: background,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: AppShadow.overlay(colors.brightness),
                ),
                child: Text(
                  widget.message,
                  style: TextStyle(fontSize: 12, color: foreground),
                ),
              ),
            ),
          ),
        );
      },
      child: GestureDetector(onLongPress: _showTouch, child: widget.child),
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
    String? helperText,
    String? errorText,
    Widget? prefix,
    Widget? suffix,
    this.focusNode,
    bool autofocus = false,
    bool obscureText = false,
    super.enabled = true,
    bool readOnly = false,
    int? maxLines = 1,
    int? minLines,
    int? maxLength,
    EdgeInsets scrollPadding = const EdgeInsets.all(20),
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
    VoidCallback? onTap,
    VoidCallback? onEditingComplete,
    List<TextInputFormatter>? inputFormatters,
    TextStyle? style,
    EdgeInsetsGeometry padding = const EdgeInsets.all(12),
    AutovalidateMode autovalidateMode = AutovalidateMode.disabled,
    super.validator,
    super.onSaved,
    Iterable<String>? autofillHints,
    bool autocorrect = true,
    bool enableSuggestions = true,
    bool enableInteractiveSelection = true,
  }) : assert(controller == null || initialValue == null),
       super(
         initialValue: controller?.text ?? initialValue ?? '',
         autovalidateMode: autovalidateMode,
         builder: (field) {
           final state = field as _AppTextFieldState;
           final theme = AppUiTheme.of(field.context);
           final colors = theme.colorScheme;
           final focused = state._hasFocus;
           final borderColor = field.hasError
               ? colors.error
               : focused
               ? colors.primary
               : colors.outlineVariant;
           return Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             mainAxisSize: MainAxisSize.min,
             children: [
               if (label != null)
                 Padding(
                   padding: const EdgeInsets.only(bottom: 6),
                   child: Text(
                     label,
                     style: theme.textTheme.labelMedium?.copyWith(
                       color: focused
                           ? colors.primary
                           : colors.onSurfaceVariant,
                     ),
                   ),
                 ),
               CupertinoTextField(
                 controller: state._controller,
                 focusNode: state._effectiveFocusNode,
                 autofocus: autofocus,
                 obscureText: obscureText,
                 enabled: enabled,
                 readOnly: readOnly,
                 maxLines: maxLines,
                 minLines: minLines,
                 maxLength: maxLength,
                 scrollPadding: scrollPadding,
                 keyboardType: keyboardType,
                 textInputAction: textInputAction,
                 inputFormatters: inputFormatters,
                 autofillHints: autofillHints,
                 autocorrect: autocorrect,
                 enableSuggestions: enableSuggestions,
                 enableInteractiveSelection: enableInteractiveSelection,
                 placeholder: placeholder,
                 placeholderStyle: TextStyle(
                   color: colors.onSurfaceVariant.withValues(alpha: 0.62),
                 ),
                 prefix: prefix == null
                     ? null
                     : Padding(
                         padding: const EdgeInsets.only(left: 12),
                         child: IconTheme.merge(
                           data: IconThemeData(
                             color: focused
                                 ? colors.primary
                                 : colors.onSurfaceVariant,
                             size: 18,
                           ),
                           child: prefix,
                         ),
                       ),
                 suffix: suffix == null
                     ? null
                     : Padding(
                         padding: const EdgeInsets.only(right: 4),
                         child: suffix,
                       ),
                 padding: padding,
                 style: style ?? TextStyle(color: colors.onSurface),
                 decoration: BoxDecoration(
                   color: colors.surfaceContainerLowest,
                   borderRadius: BorderRadius.circular(AppRadii.md),
                   border: Border.all(
                     color: borderColor,
                     width: focused || field.hasError ? 1.5 : 1,
                   ),
                   boxShadow: focused
                       ? [
                           BoxShadow(
                             color:
                                 (field.hasError
                                         ? colors.error
                                         : colors.primary)
                                     .withValues(alpha: 0.14),
                             blurRadius: 10,
                           ),
                         ]
                       : null,
                 ),
                 onChanged: (value) {
                   field.didChange(value);
                   onChanged?.call(value);
                 },
                 onSubmitted: onSubmitted,
                 onTap: onTap,
                 onEditingComplete: onEditingComplete,
               ),
               if (helperText != null)
                 Padding(
                   padding: const EdgeInsets.only(top: 6),
                   child: Text(
                     helperText,
                     style: TextStyle(
                       color: colors.onSurfaceVariant,
                       fontSize: 13,
                     ),
                   ),
                 ),
               if (field.errorText != null || errorText != null)
                 Padding(
                   padding: const EdgeInsets.only(top: 6),
                   child: Semantics(
                     liveRegion: true,
                     child: Text(
                       field.errorText ?? errorText!,
                       style: TextStyle(color: colors.error, fontSize: 13),
                     ),
                   ),
                 ),
             ],
           );
         },
       );

  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  FormFieldState<String> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends FormFieldState<String> {
  TextEditingController? _owned;
  FocusNode? _ownedFocus;
  AppTextField get _field => widget as AppTextField;
  TextEditingController get _controller => _field.controller ?? _owned!;
  FocusNode get _effectiveFocusNode =>
      _field.focusNode ?? (_ownedFocus ??= FocusNode());
  bool get _hasFocus => _effectiveFocusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    if (_field.controller == null) {
      _owned = TextEditingController(text: widget.initialValue);
    }
    _controller.addListener(_sync);
    _effectiveFocusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _sync() {
    if (_controller.text != value) didChange(_controller.text);
  }

  @override
  void didUpdateWidget(covariant AppTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_field.focusNode != oldWidget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocus)?.removeListener(_onFocusChanged);
      if (_field.focusNode != null) {
        _ownedFocus?.dispose();
        _ownedFocus = null;
      }
      _effectiveFocusNode.addListener(_onFocusChanged);
    }
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
    (_field.focusNode ?? _ownedFocus)?.removeListener(_onFocusChanged);
    _ownedFocus?.dispose();
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
    // 选中只用实底强调色表达,不叠描边;未选是安静的中性底。
    return Semantics(
      selected: selected,
      child: AppButton(
        focusNode: focusNode,
        onPressed: onSelected == null ? null : () => onSelected!(!selected),
        variant: AppButtonVariant.tinted,
        color: selected ? colors.primary : colors.surfaceContainerHigh,
        foregroundColor: selected ? colors.onPrimary : colors.onSurface,
        style: const AppButtonStyle(side: BorderSide(color: Color(0x00000000))),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
    this.minTileHeight = 44,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 10,
    ),
    this.autofocus = false,
  });
  final Widget? leading, subtitle, trailing;
  final Widget title;
  final VoidCallback? onTap;
  final bool enabled, selected;
  final double minTileHeight;
  final bool autofocus;
  final EdgeInsetsGeometry contentPadding;
  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minTileHeight),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DefaultTextStyle(
                  style: theme.textTheme.bodyLarge!,
                  child: title,
                ),
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
      ),
    );
    return Semantics(
      selected: selected,
      enabled: enabled,
      child: onTap == null
          ? Padding(padding: contentPadding, child: content)
          : AppSurfaceAction(
              autofocus: autofocus,
              onTap: enabled ? onTap : null,
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: contentPadding,
                decoration: BoxDecoration(
                  color: selected ? theme.colorScheme.primaryContainer : null,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: theme.colorScheme.onSurface),
                  child: content,
                ),
              ),
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
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 10,
    ),
  });
  final EdgeInsetsGeometry contentPadding;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => AppListTile(
    contentPadding: contentPadding,
    title: title,
    subtitle: subtitle,
    enabled: onChanged != null,
    onTap: onChanged == null ? null : () => onChanged!(!value),
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

/// Clickable content keeps its original layout and typography; one focus node
/// owns mouse, keyboard and remote activation.
class AppSurfaceAction extends StatefulWidget {
  const AppSurfaceAction({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.borderRadius,
    this.mouseCursor,
    this.onDoubleTap,
  });
  final Widget child;
  final VoidCallback? onTap, onLongPress, onDoubleTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final ValueChanged<bool>? onHover, onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus, canRequestFocus;
  final BorderRadius? borderRadius;
  final MouseCursor? mouseCursor;
  @override
  State<AppSurfaceAction> createState() => _AppSurfaceActionState();
}

class _AppSurfaceActionState extends State<AppSurfaceAction> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: enabled && widget.canRequestFocus,
      onFocusChange: (value) {
        setState(() => _focused = value);
        widget.onFocusChange?.call(value);
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: MouseRegion(
        cursor:
            widget.mouseCursor ??
            (enabled ? SystemMouseCursors.click : SystemMouseCursors.basic),
        onEnter: (_) => widget.onHover?.call(true),
        onExit: (_) => widget.onHover?.call(false),
        child: Semantics(
          button: true,
          enabled: enabled,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onDoubleTap: widget.onDoubleTap,
            onSecondaryTapDown: widget.onSecondaryTapDown,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: widget.borderRadius,
                border: _focused
                    ? Border.all(
                        color: AppUiTheme.of(context).colorScheme.primary,
                        width: 2,
                      )
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class AppLoadingBar extends StatelessWidget {
  const AppLoadingBar({
    super.key,
    this.value,
    this.color,
    this.backgroundColor,
    this.minHeight = 4,
    this.borderRadius,
  });
  final double? value;
  final double minHeight;
  final Color? color, backgroundColor;
  final BorderRadiusGeometry? borderRadius;
  @override
  Widget build(BuildContext context) => value == null
      ? SizedBox(
          height: minHeight < 16 ? 16 : minHeight,
          child: Center(
            child: CupertinoActivityIndicator(radius: 7, color: color),
          ),
        )
      : AppProgressBar(
          value: value!,
          height: minHeight,
          color: color,
          backgroundColor: backgroundColor,
        );
}

class AppDisclosure extends StatefulWidget {
  const AppDisclosure({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.children = const [],
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.tilePadding = const EdgeInsets.all(12),
    this.childrenPadding = EdgeInsets.zero,
    this.backgroundColor,
  });
  final Widget title;
  final Widget? subtitle, leading, trailing;
  final List<Widget> children;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final EdgeInsetsGeometry tilePadding, childrenPadding;
  final Color? backgroundColor;
  @override
  State<AppDisclosure> createState() => _AppDisclosureState();
}

class _AppDisclosureState extends State<AppDisclosure> {
  late bool _expanded = widget.initiallyExpanded;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: widget.backgroundColor ?? const Color(0x00000000),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          expanded: _expanded,
          child: AppListTile(
            title: widget.title,
            subtitle: widget.subtitle,
            leading: widget.leading,
            contentPadding: widget.tilePadding,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.trailing != null) widget.trailing!,
                Icon(
                  _expanded
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  size: 16,
                ),
              ],
            ),
            onTap: () {
              setState(() => _expanded = !_expanded);
              widget.onExpansionChanged?.call(_expanded);
            },
          ),
        ),
        if (_expanded)
          Padding(
            padding: widget.childrenPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: widget.children,
            ),
          ),
      ],
    ),
  );
}

/// Pull-to-refresh for existing list and grid scroll trees. Keeps their scroll
/// controller and viewport mounted while a Cupertino activity indicator runs.
///
/// The indicator is a floating disc that follows the finger, shows how far
/// the pull is from the trigger point and spins while [onRefresh] runs.
/// Android uses clamping physics, so the content itself does not move; the
/// disc is the only feedback and therefore must never hide under a
/// transparent status bar or top bar. Full-bleed pages pass [edgeOffset]
/// (status bar plus any overlaid bar) so it appears below them.
class AppRefresh extends StatefulWidget {
  const AppRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.edgeOffset = 0,
  });
  final Future<void> Function() onRefresh;
  final Widget child;

  /// Distance from the top of this widget to the first visible content row.
  final double edgeOffset;

  /// Pull distance that triggers a refresh on release.
  static const triggerDistance = 72.0;
  static const _maxPull = 132.0;
  static const _discSize = 40.0;

  /// Floating indicator disc, for tests and captures.
  static const indicatorKey = Key('app-refresh-indicator');

  @override
  State<AppRefresh> createState() => _AppRefreshState();
}

class _AppRefreshState extends State<AppRefresh> {
  double _pull = 0;
  bool _busy = false;
  bool _armed = false;

  void _setPull(double value) {
    final next = value.clamp(0.0, AppRefresh._maxPull);
    final armed = next >= AppRefresh.triggerDistance;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _pull = next;
      _armed = armed;
    });
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _pull = 0;
          _armed = false;
        });
      }
    }
  }

  bool _notify(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical || _busy) return false;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        n.overscroll < 0) {
      // Clamping physics: resist a little so the disc trails the finger.
      _setPull(_pull - n.overscroll * .7);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        n.metrics.pixels < n.metrics.minScrollExtent) {
      _setPull(n.metrics.minScrollExtent - n.metrics.pixels);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        _pull > 0 &&
        (n.scrollDelta ?? 0) > 0) {
      _setPull(_pull - n.scrollDelta!);
    } else if (n is ScrollEndNotification) {
      if (_pull >= AppRefresh.triggerDistance) {
        _refresh();
      } else if (_pull != 0) {
        setState(() {
          _pull = 0;
          _armed = false;
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final progress = _busy
        ? 1.0
        : (_pull / AppRefresh.triggerDistance).clamp(0.0, 1.0);
    // Busy: rest just below the content edge. Pulling: slide in with the
    // finger from above the edge.
    final travel = _busy
        ? AppSpacing.md
        : _pull * .55 - AppRefresh._discSize * .5;
    final visible = _busy || _pull > 0;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _notify,
          child: widget.child,
        ),
        if (visible)
          Positioned(
            top: widget.edgeOffset + travel,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Opacity(
                  opacity: _busy ? 1 : (.35 + progress * .65),
                  child: Container(
                    key: AppRefresh.indicatorKey,
                    width: AppRefresh._discSize,
                    height: AppRefresh._discSize,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: .6),
                        width: .5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF000000).withValues(alpha: .22),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: _busy
                        ? CupertinoActivityIndicator(
                            color: scheme.primary,
                            radius: 9,
                          )
                        : _RefreshDial(
                            progress: progress,
                            armed: _armed,
                            color: scheme.primary,
                            track: scheme.outlineVariant,
                          ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Arc that fills toward the trigger point, with an arrow that flips once the
/// release would refresh.
class _RefreshDial extends StatelessWidget {
  const _RefreshDial({
    required this.progress,
    required this.armed,
    required this.color,
    required this.track,
  });
  final double progress;
  final bool armed;
  final Color color;
  final Color track;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: CustomPaint(
      painter: _RefreshArcPainter(
        progress: progress,
        color: color,
        track: track,
      ),
      child: Center(
        child: AnimatedRotation(
          turns: armed ? .5 : 0,
          duration: AppMotion.durationOf(context, AppMotion.fast),
          child: Icon(
            CupertinoIcons.arrow_down,
            size: 12,
            color: armed ? color : track,
          ),
        ),
      ),
    ),
  );
}

class _RefreshArcPainter extends CustomPainter {
  const _RefreshArcPainter({
    required this.progress,
    required this.color,
    required this.track,
  });
  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect.deflate(1.1),
      0,
      6.2832,
      false,
      stroke..color = track.withValues(alpha: .45),
    );
    if (progress > 0) {
      canvas.drawArc(
        rect.deflate(1.1),
        -1.5708,
        6.2832 * progress,
        false,
        stroke..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RefreshArcPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}
