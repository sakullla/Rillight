import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

/// hover/焦点卡片包装:鼠标悬停时放大并叠加阴影高亮,
/// 键盘焦点时显示焦点环。动画时长与曲线取自 [AppMotion]。
///
/// 纯呈现组件,不持有业务数据;点击、焦点语义经 [onTap] 透传。
class AppHoverCard extends StatefulWidget {
  const AppHoverCard({
    super.key,
    required this.child,
    this.onTap,
    this.onHighlighted,
    this.inkKey,
    this.borderRadius,
    this.hoverScale = 1.04,
    this.focusRingWidth = 2,
    this.shadowBlurRadius = 16,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 悬停或键盘焦点高亮变化时回调,供卡片揭示层使用。
  final ValueChanged<bool>? onHighlighted;

  /// 透传给内部 InkWell 的语义化 Key,供测试定位可点击区域。
  final Key? inkKey;

  /// 卡片圆角,默认 [AppRadii.md]。
  final BorderRadius? borderRadius;

  /// 悬停时的放大倍率(建议 1.03–1.05)。
  final double hoverScale;

  /// 焦点环描边宽度。
  final double focusRingWidth;

  /// 悬停/焦点时的阴影扩散半径。
  final double shadowBlurRadius;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<AppHoverCard> createState() => _AppHoverCardState();
}

class _AppHoverCardState extends State<AppHoverCard> {
  bool _hovering = false;
  bool _focused = false;
  ScrollPosition? _position;

  bool get _highlighted => _hovering || _focused;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (identical(_position, next)) {
      return;
    }
    _position?.isScrollingNotifier.removeListener(_onScrollChanged);
    _position = next;
    _position?.isScrollingNotifier.addListener(_onScrollChanged);
  }

  @override
  void dispose() {
    _position?.isScrollingNotifier.removeListener(_onScrollChanged);
    super.dispose();
  }

  void _onScrollChanged() {
    if (_position?.isScrollingNotifier.value == true && _hovering) {
      _setHovering(false);
    }
  }

  void _setHovering(bool value) {
    if (value &&
        (Scrollable.maybeOf(context)?.position.isScrollingNotifier.value ??
            false)) {
      value = false;
    }
    if (_hovering == value) {
      return;
    }
    final was = _highlighted;
    setState(() => _hovering = value);
    _notifyHighlight(was);
  }

  void _setFocused(bool value) {
    if (_focused == value) {
      return;
    }
    final was = _highlighted;
    setState(() => _focused = value);
    _notifyHighlight(was);
  }

  void _notifyHighlight(bool wasHighlighted) {
    final now = _highlighted;
    if (wasHighlighted == now) {
      return;
    }
    widget.onHighlighted?.call(now);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final radius = widget.borderRadius ?? BorderRadius.circular(AppRadii.md);
    final scrolling =
        Scrollable.maybeOf(context)?.position.isScrollingNotifier.value ??
        false;
    final highlighted = (_hovering && !scrolling) || _focused;

    final card = AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.standard,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: highlighted ? 0.5 : 0),
            blurRadius: highlighted ? widget.shadowBlurRadius : 0,
          ),
        ],
      ),
      // 焦点环走 foregroundDecoration:decoration 的 border 会被
      // Container 当作 padding 内缩子树,破坏外部固定行高。
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: _focused ? colorScheme.primary : Colors.transparent,
          width: widget.focusRingWidth,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: widget.inkKey,
          onTap: widget.onTap,
          onHover: _setHovering,
          onFocusChange: _setFocused,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          canRequestFocus: widget.onTap != null,
          borderRadius: radius,
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: widget.child,
        ),
      ),
    );
    if (widget.hoverScale == 1) {
      return card;
    }
    return AnimatedScale(
      scale: highlighted && _hovering ? widget.hoverScale : 1,
      duration: AppMotion.fast,
      curve: AppMotion.standard,
      child: card,
    );
  }
}
