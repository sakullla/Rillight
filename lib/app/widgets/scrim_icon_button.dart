import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

/// [ScrimIconButton] 的两档尺寸:40 常规(图标 20)、48 大号(图标 24)。
enum ScrimIconButtonSize {
  regular(dimension: 40, iconSize: 20),
  large(dimension: 48, iconSize: 24);

  const ScrimIconButtonSize({required this.dimension, required this.iconSize});

  final double dimension;
  final double iconSize;
}

/// 铺在海报/剧照上的圆形图标按钮:实色 scrim 底衬 + `onSurface` 图标 +
/// 1px 白色细边。不含 [BackdropFilter],在任意亮度的底图上对比度稳定。
///
/// 用于顶栏返回钮、hero 翻页钮、货架/章节滚动钮与详情操作圆钮。
/// [onPressed] 为空时呈禁用态(图标降 alpha,底衬保留)。
class ScrimIconButton extends StatelessWidget {
  const ScrimIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = ScrimIconButtonSize.regular,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final ScrimIconButtonSize size;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final backing = scheme.scrim.withValues(
      alpha: AppScrim.resolve(AppScrim.control, reduce: reduce),
    );
    final dimension = size.dimension;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      icon: icon,
      iconSize: size.iconSize,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: dimension, height: dimension),
      style: IconButton.styleFrom(
        backgroundColor: backing,
        disabledBackgroundColor: backing,
        foregroundColor: scheme.onSurface,
        disabledForegroundColor: scheme.onSurface.withValues(
          alpha: AppScrim.controlDisabledIcon,
        ),
        side: BorderSide(
          color: Colors.white.withValues(alpha: AppGlass.edgeLight),
        ),
        shape: const CircleBorder(),
        fixedSize: Size.square(dimension),
        minimumSize: Size.square(dimension),
        maximumSize: Size.square(dimension),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
