import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 可多选的圆角选项。宽度随文字收缩，方便在筛选里换行排列。
///
/// 选中只用一种语言表达:实底强调色 + 反色文字,不再叠勾和描边。
/// 未选在深色下是安静的抬高底,浅色下是白底细边。
class OptionPill extends StatelessWidget {
  const OptionPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final light = scheme.brightness == Brightness.light;
    final foreground = selected ? scheme.onPrimary : scheme.onSurface;
    return Opacity(
      opacity: onPressed == null ? .45 : 1,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: onPressed != null,
        child: AppSurfaceAction(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: AnimatedContainer(
            duration: AppMotion.durationOf(context, AppMotion.fast),
            curve: AppMotion.standard,
            decoration: ShapeDecoration(
              color: selected
                  ? scheme.primary
                  : (light
                        ? scheme.surfaceContainerLowest
                        : scheme.surfaceContainerHigh),
              shape: StadiumBorder(
                side: BorderSide(
                  color: selected
                      ? AppInk.transparent
                      : AppEdge.of(scheme.brightness, strong: !light),
                ),
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: 48,
                minHeight: AppControlHeight.md,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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

/// 已选项。点整颗胶囊即可去掉，关闭图标只作提示。
class RemovablePill extends StatelessWidget {
  const RemovablePill({
    super.key,
    required this.label,
    required this.onDeleted,
    this.compact = false,
  });

  final String label;
  final VoidCallback onDeleted;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final foreground = scheme.onPrimaryContainer;
    final tooltip = CupertinoLocalizations.of(context).clearButtonLabel;
    return Semantics(
      button: true,
      label: '$label, $tooltip',
      child: AppSurfaceAction(
        onTap: onDeleted,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: scheme.primaryContainer,
            shape: const StadiumBorder(),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: compact ? 28 : AppControlHeight.sm + 4,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 10 : 12,
                compact ? 4 : 6,
                compact ? 6 : 8,
                compact ? 4 : 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style:
                        (compact
                                ? AppUiTheme.of(context).textTheme.labelSmall
                                : AppUiTheme.of(context).textTheme.labelLarge)
                            ?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w500,
                            ),
                  ),
                  SizedBox(width: compact ? 2 : 4),
                  Icon(
                    AppIcons.close,
                    fill: AppIcons.filled,
                    size: compact ? 14 : 16,
                    color: foreground.withValues(alpha: .72),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
