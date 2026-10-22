import 'package:cupertino_ui/cupertino_ui.dart';

import '../theme/tokens.dart';
import 'app_icons.dart';
import 'controls.dart';
import 'theme.dart';

/// 动作按钮的三档层级。每个视图只放一个 [primary]。
enum AppActionTier {
  /// accent 实底,带图标和文字:播放、连接、添加服务器这类视图主操作。
  primary,

  /// 安静表面 + 发丝边,带图标和文字;可带切换态(已收藏、已看)。
  secondary,

  /// 纯文字:更多、取消。
  tertiary,
}

/// 三档动作按钮的唯一规格来源。焦点、键盘、悬停与 TV 焦点反相全部来自
/// [AppButton];这里只决定尺寸、底色和切换态。
///
/// - 同一平台的主/次按钮等高:桌面按钮面 40,手机 44,圆角为胶囊;触控区
///   始终不低于 44。
/// - 文字不省略:放不下时最多折成两行,按钮随之变高,由外层 Wrap 整组折行。
/// - [active] 非空时按钮是开关:激活为 primaryContainer 实底、primary 边和
///   填充图标,并输出 Semantics `toggled`。
/// - 只有图标的按钮用 [AppActionButton.icon],必须提供 tooltip,同时作为
///   语义 label。
class AppActionButton extends StatelessWidget {
  const AppActionButton({
    super.key,
    required String this.label,
    this.icon,
    this.trailingIcon,
    this.tier = AppActionTier.secondary,
    this.active,
    this.onPressed,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.semanticLabel,
    this.maxWidth,
  }) : _iconOnly = false;

  /// 纯图标按钮,只用于工具栏、卡片角标与顶栏这类惯例位置。
  const AppActionButton.icon({
    super.key,
    required IconData this.icon,
    required String this.tooltip,
    this.active,
    this.onPressed,
    this.focusNode,
    this.autofocus = false,
  }) : label = null,
       trailingIcon = null,
       tier = AppActionTier.secondary,
       semanticLabel = null,
       maxWidth = null,
       _iconOnly = true;

  final String? label;
  final IconData? icon;

  /// 尾随图标(下拉箭头等)。第三级按钮不画图标。
  final IconData? trailingIcon;
  final AppActionTier tier;

  /// 切换态。null 表示普通按钮;true/false 表示开关的当前状态。
  final bool? active;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool autofocus;

  /// 悬停提示。纯图标按钮必填,同时作为语义 label。
  final String? tooltip;
  final String? semanticLabel;

  /// 按钮最大宽度;超出时文字折行。缺省时由父约束决定。
  final double? maxWidth;
  final bool _iconOnly;

  /// 桌面按钮面高度。
  static const double desktopExtent = 40;

  /// 手机按钮面高度(与最小触控区相同)。
  static const double phoneExtent = 44;

  /// 当前平台主/次按钮的按钮面高度。
  static double extentOf(BuildContext context) =>
      AppUiTheme.of(context).phone ? phoneExtent : desktopExtent;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final on = active == true;
    final extent = extentOf(context);

    if (_iconOnly) {
      return Semantics(
        toggled: active,
        child: AppIconButton(
          icon: Icon(icon, fill: on ? AppIcons.filled : AppIcons.outline),
          tooltip: tooltip,
          onPressed: onPressed,
          focusNode: focusNode,
          autofocus: autofocus,
          selected: on,
        ),
      );
    }

    final quiet = colors.surfaceContainerHigh.withValues(
      alpha: colors.brightness == Brightness.light ? .72 : .56,
    );
    final style = switch (tier) {
      AppActionTier.primary => AppButtonStyle(
        faceExtent: extent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      ),
      AppActionTier.secondary => AppButtonStyle(
        faceExtent: extent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        backgroundColor: on ? colors.primaryContainer : quiet,
        foregroundColor: on ? colors.onPrimaryContainer : colors.onSurface,
        side: on
            ? BorderSide(
                color: colors.primary,
                width: AppSelectionDecoration.borderWidth,
              )
            : BorderSide(color: AppEdge.of(colors.brightness, strong: true)),
        textStyle: theme.textTheme.labelLarge!.copyWith(
          fontWeight: on ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      AppActionTier.tertiary => AppButtonStyle(
        faceExtent: extent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    };
    final text = Text(
      label!,
      softWrap: true,
      maxLines: 2,
      overflow: TextOverflow.clip,
    );
    final showIcons = tier != AppActionTier.tertiary;
    final leading = showIcons && icon != null
        ? Icon(icon, size: 18, fill: on ? AppIcons.filled : AppIcons.outline)
        : null;
    final trailing = showIcons && trailingIcon != null
        ? Icon(trailingIcon, size: 14)
        : null;
    final content = leading == null && trailing == null
        ? text
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 8)],
              Flexible(child: text),
              if (trailing != null) ...[const SizedBox(width: 6), trailing],
            ],
          );
    Widget button = AppButton(
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      variant: switch (tier) {
        AppActionTier.primary => AppButtonVariant.filled,
        AppActionTier.secondary => AppButtonVariant.outlined,
        AppActionTier.tertiary => AppButtonVariant.plain,
      },
      semanticLabel: semanticLabel ?? tooltip,
      style: style,
      child: content,
    );
    if (maxWidth != null) {
      button = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: button,
      );
    }
    if (active != null) button = Semantics(toggled: active, child: button);
    return tooltip == null
        ? button
        : AppTooltip(message: tooltip!, child: button);
  }
}
