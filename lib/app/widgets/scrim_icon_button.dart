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

/// 铺在海报/剧照上的圆形图标按钮:实色 scrim 底衬 + 白色图标 + 1px 细边。
/// 不含 [BackdropFilter],在任意亮度的底图上对比度稳定。底衬永远是黑色
/// scrim(两种主题下 [ColorScheme.scrim] 均为黑),图标因此固定用白色,
/// 与叠图白字一致;不随主题 onSurface 走,浅色主题下深色图标会不可读。
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
    final highContrast = MediaQuery.highContrastOf(context);
    final backing = scheme.scrim.withValues(
      alpha: AppScrim.resolve(AppScrim.control, highContrast: highContrast),
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
        // 白色图标叠黑色 scrim:与叠图白字同规则,不随主题亮度换色。
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white.withValues(
          alpha: AppScrim.controlDisabledIcon,
        ),
        side: BorderSide(
          color: scheme.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: AppGlass.edgeLight)
              : Colors.black.withValues(alpha: AppGlass.edgeLight),
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
