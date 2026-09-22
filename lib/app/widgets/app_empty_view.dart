import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

/// 空状态视图:图标 + 文案,可选主操作,风格与 [AppErrorView] 对齐。
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
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
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: AppSpacing.huge,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              action!,
            ] else if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
