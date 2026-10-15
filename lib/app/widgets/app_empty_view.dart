import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 空状态视图:图标 + 文案,可选主操作,风格与 [AppErrorView] 对齐。
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.message,
    this.icon = AppIcons.empty,
    this.actionLabel,
    this.onAction,
    this.action,
  });

  final String message;
  final IconData icon;

  /// 可选主操作文案;[onAction] 为空时不渲染按钮。
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 自定义主操作。设置后不再使用 [actionLabel]。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colorScheme = AppUiTheme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Icon(
                  icon,
                  fill: AppIcons.filled,
                  size: 28,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppUiTheme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            if (action != null) ...[
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
          ],
        ),
      ),
    );
  }
}
