import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/ui/app_icons.dart';

class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    required this.message,
    this.title,
    this.onRetry,
    this.compact = false,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String message;

  /// 可选的加粗标题,用于区分离线与服务器故障。
  final String? title;
  final VoidCallback? onRetry;
  final bool compact;

  /// 主操作文案与回调;未设置时沿用 [onRetry] 和“重试”。
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  /// 次操作(文字按钮),例如切换服务器。
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = AppUiTheme.of(context).colorScheme;

    if (compact) {
      return Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              AppIcons.error,
              fill: AppIcons.filled,
              color: colorScheme.error,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppUiTheme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final primary = onPrimary ?? onRetry;
    final hasPrimary = primary != null;
    final textTheme = AppUiTheme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colorScheme.error.withValues(alpha: 0.35),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Icon(
                    AppIcons.error,
                    fill: AppIcons.filled,
                    size: 30,
                    color: colorScheme.onErrorContainer,
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
                  color: colorScheme.onSurface,
                  height: 1.45,
                ),
              ),
              if (hasPrimary) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  onPressed: primary,
                  variant: AppButtonVariant.filled,
                  child: Text(primaryLabel ?? l10n.retry),
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
