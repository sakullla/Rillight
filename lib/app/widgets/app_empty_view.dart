import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 空状态视图:图标 + 标题 + 文案,可选主/次操作,风格与 [AppErrorView] 对齐。
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.message,
    this.title,
    this.icon = AppIcons.empty,
    this.actionLabel,
    this.onAction,
    this.action,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String message;

  /// 可选的加粗标题,用于区分空库的不同原因。
  final String? title;
  final IconData icon;

  /// 可选主操作文案;[onAction] 为空时不渲染按钮。
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 自定义主操作。设置后不再使用 [actionLabel]。
  final Widget? action;

  /// 主操作(填充按钮),优先于 [actionLabel]/[action]。
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  /// 次操作(文字按钮)。
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = AppUiTheme.of(context).colorScheme;
    final textTheme = AppUiTheme.of(context).textTheme;
    final hasPrimary = primaryLabel != null && onPrimary != null;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colorScheme.surfaceContainerHighest,
                      colorScheme.surfaceContainerHigh,
                    ],
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Icon(
                    icon,
                    fill: AppIcons.filled,
                    size: 30,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (title != null) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              if (hasPrimary) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  onPressed: onPrimary,
                  variant: AppButtonVariant.filled,
                  child: Text(primaryLabel!),
                ),
              ] else if (action != null) ...[
                const SizedBox(height: AppSpacing.md),
                action!,
              ] else if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  onPressed: onAction,
                  variant: AppButtonVariant.outlined,
                  child: Text(actionLabel!),
                ),
              ],
              if (secondaryLabel != null && onSecondary != null) ...[
                const SizedBox(height: AppSpacing.xs),
                AppButton(
                  onPressed: onSecondary,
                  variant: AppButtonVariant.plain,
                  child: Text(secondaryLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
