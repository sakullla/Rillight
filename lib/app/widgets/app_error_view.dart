import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/ui/app_icons.dart';

class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool compact;

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
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppUiTheme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: colorScheme.onSurface, height: 1.45),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  onPressed: onRetry,
                  variant: AppButtonVariant.filled,
                  child: Text(l10n.retry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
