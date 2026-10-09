import 'package:flutter/material.dart';

/// 可多选的圆角选项。宽度随文字收缩，方便在筛选里换行排列。
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
    final scheme = Theme.of(context).colorScheme;
    final foreground = scheme.onSurface;
    return Opacity(
      opacity: onPressed == null ? .45 : 1,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: onPressed != null,
        child: Material(
          color: selected
              ? scheme.surfaceBright
              : scheme.surfaceContainerHighest,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      Icon(Icons.check_rounded, size: 16, color: foreground),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
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
    final scheme = Theme.of(context).colorScheme;
    final foreground = scheme.onSurface;
    final tooltip = MaterialLocalizations.of(context).deleteButtonTooltip;
    return Semantics(
      button: true,
      label: '$label, $tooltip',
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onDeleted,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: compact ? 28 : 36),
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
                                ? Theme.of(context).textTheme.labelSmall
                                : Theme.of(context).textTheme.labelLarge)
                            ?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w500,
                            ),
                  ),
                  SizedBox(width: compact ? 2 : 4),
                  Icon(
                    Icons.close_rounded,
                    size: compact ? 14 : 16,
                    color: scheme.onSurfaceVariant,
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
