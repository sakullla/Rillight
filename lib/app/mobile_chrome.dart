import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/skeleton.dart';

/// 手机上的加载、空、失败三种画面。
///
/// 颜色和字号跟随当前 [AppTheme]，出现过渡使用 [AppMotion]。
/// 可点操作的最小尺寸为 48dp。
const Size _minHit = Size(AppSpacing.huge, AppSpacing.huge);

enum MobileLoadingVariant { home, libraries, row }

/// 内容形状的加载占位：首页是横幅加海报行，片库是列表条。
class MobileLoadingPlaceholder extends StatelessWidget {
  const MobileLoadingPlaceholder.home({super.key})
    : variant = MobileLoadingVariant.home;

  const MobileLoadingPlaceholder.libraries({super.key})
    : variant = MobileLoadingVariant.libraries;

  const MobileLoadingPlaceholder.row({super.key})
    : variant = MobileLoadingVariant.row;

  static const Key homeKey = Key('mobile-home-loading');
  static const Key librariesKey = Key('mobile-libraries-loading');

  final MobileLoadingVariant variant;

  @override
  Widget build(BuildContext context) {
    final animate = AppMotion.durationOf(context) != Duration.zero;
    final shaped = switch (variant) {
      MobileLoadingVariant.home => _HomeLoading(animate: animate),
      MobileLoadingVariant.libraries => _LibrariesLoading(animate: animate),
      MobileLoadingVariant.row => _RowLoading(animate: animate),
    };
    final keyed = switch (variant) {
      MobileLoadingVariant.home => KeyedSubtree(key: homeKey, child: shaped),
      MobileLoadingVariant.libraries => KeyedSubtree(
        key: librariesKey,
        child: shaped,
      ),
      MobileLoadingVariant.row => shaped,
    };
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: AppMotion.durationOf(context, AppMotion.fast),
      curve: AppMotion.standard,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: keyed,
    );
  }
}

class _HomeLoading extends StatelessWidget {
  const _HomeLoading({required this.animate});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return SkeletonBlock(
              width: width,
              height: width * 9 / 16,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              animated: animate,
            );
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        SkeletonBlock(width: 128, height: 18, animated: animate),
        const SizedBox(height: AppSpacing.sm),
        _PosterLoading(animate: animate),
        const SizedBox(height: AppSpacing.lg),
        SkeletonBlock(width: 96, height: 18, animated: animate),
        const SizedBox(height: AppSpacing.sm),
        _PosterLoading(animate: animate),
      ],
    );
  }
}

class _LibrariesLoading extends StatelessWidget {
  const _LibrariesLoading({required this.animate});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              children: [
                SkeletonBlock(
                  width: AppSpacing.huge,
                  height: AppSpacing.huge,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  animated: animate,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(child: SkeletonBlock(height: 16, animated: animate)),
              ],
            ),
          ),
      ],
    );
  }
}

class _RowLoading extends StatelessWidget {
  const _RowLoading({required this.animate});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    return _PosterLoading(animate: animate);
  }
}

class _PosterLoading extends StatelessWidget {
  const _PosterLoading({required this.animate});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    const posterWidth = 148.0;
    const aspect = 2 / 3;
    final posterHeight = posterWidth / aspect;
    return SizedBox(
      height: posterHeight + AppSpacing.xs + AppSpacing.sm,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 3,
        separatorBuilder: (context, index) =>
            const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(
                width: posterWidth,
                height: posterHeight,
                animated: animate,
              ),
              const SizedBox(height: AppSpacing.xs),
              SkeletonBlock(
                width: posterWidth * 0.75,
                height: AppSpacing.sm,
                animated: animate,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 没有内容：一句话，外加刷新这一种下一步。
class MobileEmptyState extends StatelessWidget {
  const MobileEmptyState({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  static const Key stateKey = Key('mobile-empty-state');
  static const Key actionKey = Key('mobile-empty-action');

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final action = actionLabel != null && onAction != null
        ? OutlinedButton(
            key: actionKey,
            style: OutlinedButton.styleFrom(minimumSize: _minHit),
            onPressed: onAction,
            child: Text(actionLabel!),
          )
        : null;
    return Semantics(
      key: stateKey,
      container: true,
      liveRegion: true,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: Column(
            children: [
              Icon(
                Icons.movie_outlined,
                size: AppSpacing.huge,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (action != null) ...[
                const SizedBox(height: AppSpacing.md),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 请求失败：另一句话，并给出重试。
class MobileFailureState extends StatelessWidget {
  const MobileFailureState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  static const Key stateKey = Key('mobile-failure-state');
  static const Key retryKey = Key('mobile-failure-retry');

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: stateKey,
      container: true,
      liveRegion: true,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: Column(
            children: [
              Icon(
                Icons.error_outline,
                size: AppSpacing.huge,
                color: scheme.error,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                key: retryKey,
                style: FilledButton.styleFrom(minimumSize: _minHit),
                onPressed: onRetry,
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
