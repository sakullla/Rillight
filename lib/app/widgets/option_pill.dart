import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 可多选的圆角选项。宽度随文字收缩，方便在筛选里换行排列。
///
/// 选中只用一种语言表达:实底强调色 + 反色文字,不再叠勾和描边。
/// 未选在深色下是安静的抬高底,浅色下是白底细边,悬停时抬升边框与底色。
class OptionPill extends StatefulWidget {
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
  State<OptionPill> createState() => _OptionPillState();
}

class _OptionPillState extends State<OptionPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final light = scheme.brightness == Brightness.light;
    final selected = widget.selected;
    final enabled = widget.onPressed != null;
    final foreground = selected ? scheme.onPrimary : scheme.onSurface;
    final restFill = selected
        ? scheme.primary
        : (light ? scheme.surfaceContainerLowest : scheme.surfaceContainerHigh);
    final fill = _hovered && enabled
        ? Color.alphaBlend(
            (selected ? scheme.onPrimary : scheme.onSurface).withValues(
              alpha: selected ? .12 : .06,
            ),
            restFill,
          )
        : restFill;
    final borderColor = selected
        ? AppInk.transparent
        : _hovered && enabled
        ? scheme.primary.withValues(alpha: .42)
        : AppEdge.of(scheme.brightness, strong: !light);
    return Opacity(
      opacity: !enabled ? .45 : 1,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: enabled,
        child: AppSurfaceAction(
          onTap: widget.onPressed,
          onHover: (value) => setState(() => _hovered = value),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: AnimatedContainer(
            duration: AppMotion.durationOf(context, AppMotion.fast),
            curve: AppMotion.standard,
            decoration: ShapeDecoration(
              color: fill,
              shape: StadiumBorder(side: BorderSide(color: borderColor)),
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
                    widget.label,
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
class RemovablePill extends StatefulWidget {
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
  State<RemovablePill> createState() => _RemovablePillState();
}

class _RemovablePillState extends State<RemovablePill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final foreground = scheme.onPrimaryContainer;
    final tooltip = CupertinoLocalizations.of(context).clearButtonLabel;
    final compact = widget.compact;
    return Semantics(
      button: true,
      label: '${widget.label}, $tooltip',
      child: AppSurfaceAction(
        onTap: widget.onDeleted,
        onHover: (value) => setState(() => _hovered = value),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: AnimatedContainer(
          duration: AppMotion.durationOf(context, AppMotion.fast),
          decoration: ShapeDecoration(
            color: _hovered
                ? Color.alphaBlend(
                    scheme.primary.withValues(alpha: .12),
                    scheme.primaryContainer,
                  )
                : scheme.primaryContainer,
            shape: StadiumBorder(
              side: BorderSide(
                color: scheme.primary.withValues(alpha: _hovered ? .55 : .28),
              ),
            ),
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
                    widget.label,
                    style:
                        (compact
                                ? AppUiTheme.of(context).textTheme.labelSmall
                                : AppUiTheme.of(context).textTheme.labelLarge)
                            ?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w600,
                            ),
                  ),
                  SizedBox(width: compact ? 3 : 5),
                  Icon(
                    AppIcons.close,
                    fill: AppIcons.filled,
                    size: compact ? 14 : 16,
                    color: foreground.withValues(alpha: _hovered ? .95 : .72),
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
