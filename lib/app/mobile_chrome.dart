import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/home/phone_hero.dart';

/// 手机滚动不使用 Android 拉伸回弹，避免下拉刷新和上拉时把横幅、卡片拉变形。
class PhoneScrollBehavior extends MaterialScrollBehavior {
  const PhoneScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

/// 手机上的加载、空、失败三种画面。
///
/// 颜色和字号跟随当前 [AppTheme]，出现过渡使用 [AppMotion]。
/// 可点操作的最小尺寸为 48dp。
const Size _minHit = Size(AppSpacing.huge, AppSpacing.huge);

enum MobileLoadingVariant { home, libraries, row }

/// 内容形状的加载占位：首页是横幅加海报行，片库是列表条。
class MobileLoadingPlaceholder extends StatelessWidget {
  const MobileLoadingPlaceholder.home({super.key})
    : variant = MobileLoadingVariant.home,
      wide = false;

  const MobileLoadingPlaceholder.libraries({super.key})
    : variant = MobileLoadingVariant.libraries,
      wide = false;

  const MobileLoadingPlaceholder.row({super.key, this.wide = false})
    : variant = MobileLoadingVariant.row;

  static const Key homeKey = Key('mobile-home-loading');
  static const Key librariesKey = Key('mobile-libraries-loading');

  final MobileLoadingVariant variant;

  /// 行内占位跟随成品：继续观看和下一集是 16:9，海报行是 2:3。
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final animate = AppMotion.durationOf(context) != Duration.zero;
    final shaped = switch (variant) {
      MobileLoadingVariant.home => _HomeLoading(animate: animate),
      MobileLoadingVariant.libraries => _LibrariesLoading(animate: animate),
      MobileLoadingVariant.row => _RailLoading(animate: animate, wide: wide),
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

class _SectionSkeleton extends StatelessWidget {
  const _SectionSkeleton({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final animate = AppMotion.durationOf(context) != Duration.zero;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBlock(width: 96, height: 16, animated: animate),
        const SizedBox(height: AppSpacing.sm),
        _RailLoading(animate: animate, wide: wide),
      ],
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
            final viewport = MediaQuery.sizeOf(context).height;
            final top = MediaQuery.viewPaddingOf(context).top + 56;
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final posterHeight = PhoneHero.posterHeightFor(
              width,
              viewportHeight: viewport,
            );
            final posterWidth = posterHeight * 2 / 3;
            // 与成品同形:居中 2:3 海报、两侧露出邻卡、下方标题/元信息/按钮。
            return SizedBox(
              height:
                  top +
                  PhoneHero.contentHeightFor(
                    width,
                    textScale: scale,
                    viewportHeight: viewport,
                  ),
              child: Padding(
                padding: EdgeInsets.only(top: top + PhoneHero.topGap),
                child: Column(
                  children: [
                    SizedBox(
                      height: posterHeight,
                      child: ClipRect(
                        child: OverflowBox(
                          maxWidth: double.infinity,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              for (var i = 0; i < 3; i++) ...[
                                if (i > 0)
                                  const SizedBox(
                                    width: PhoneHero.posterSpacing,
                                  ),
                                SkeletonBlock(
                                  width: i == 1
                                      ? posterWidth
                                      : posterWidth * .88,
                                  height: i == 1
                                      ? posterHeight
                                      : posterHeight * .88,
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.lg,
                                  ),
                                  animated: animate,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: PhoneHero.posterGap),
                    SkeletonBlock(
                      width: 72,
                      height: 12 * scale,
                      animated: animate,
                    ),
                    const SizedBox(height: 10),
                    SkeletonBlock(
                      width: (width - 48) * .62,
                      height: 24 * scale,
                      animated: animate,
                    ),
                    const SizedBox(height: 10),
                    SkeletonBlock(
                      width: (width - 48) * .42,
                      height: 14 * scale,
                      animated: animate,
                    ),
                    const SizedBox(height: PhoneHero.actionsGap),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: PhoneHero.sidePadding,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: SkeletonBlock(
                              height: PhoneHero.actionsHeight,
                              borderRadius: BorderRadius.circular(24),
                              animated: animate,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: SkeletonBlock(
                              height: PhoneHero.actionsHeight,
                              borderRadius: BorderRadius.circular(24),
                              animated: animate,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: AppSpacing.xl),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: _SectionSkeleton(wide: true),
        ),
        const SizedBox(height: AppSpacing.xl),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: _SectionSkeleton(wide: false),
        ),
      ],
    );
  }
}

class _LibrariesLoading extends StatelessWidget {
  const _LibrariesLoading({required this.animate});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = (constraints.maxWidth - AppSpacing.md) / 2;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (var i = 0; i < 4; i++)
              SizedBox(
                width: cell,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBlock(
                      width: cell,
                      height: cell * 9 / 16,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      animated: animate,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    SkeletonBlock(
                      width: cell * 0.62,
                      height: 14,
                      animated: animate,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 海报卡宽：一屏两张完整 2:3，再露出下一张。页边距 16，间距 8。
double phoneHomePosterCardWidth(double screenWidth) {
  final available = screenWidth - AppSpacing.md * 2;
  return (available - AppSpacing.xs * 2) / 2.2;
}

/// 横卡宽：一屏一张完整 16:9，再露出下一张。页边距 16，间距 8。
double phoneHomeWideCardWidth(double screenWidth) {
  final available = screenWidth - AppSpacing.md * 2;
  return (available - AppSpacing.xs) / 1.3;
}

/// Shared geometry keeps loading and resolved rails on the same baseline.
double phoneHomeRailHeight(BuildContext context, {required bool wide}) {
  final screen = MediaQuery.sizeOf(context).width;
  final width = wide
      ? phoneHomeWideCardWidth(screen)
      : phoneHomePosterCardWidth(screen);
  if (!wide) return width * 1.5 + phonePosterCardLabelExtent(context) + 2;
  final theme = Theme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  final title = scaler.scale(theme.bodyMedium?.fontSize ?? 14) * 1.2;
  final meta = scaler.scale(theme.labelSmall?.fontSize ?? 12) * 1.2;
  return width * 9 / 16 +
      16 +
      phoneHomeWideBadgeHeight(context) +
      title * 2 +
      meta +
      4;
}

double phoneHomeWideBadgeHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(12) * 1.2 + 4;

class _RailLoading extends StatelessWidget {
  const _RailLoading({required this.animate, required this.wide});

  final bool animate;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final cardWidth = wide
        ? phoneHomeWideCardWidth(screen)
        : phoneHomePosterCardWidth(screen);
    final imageHeight = wide ? cardWidth * 9 / 16 : cardWidth * 1.5;
    return SizedBox(
      height: phoneHomeRailHeight(context, wide: wide),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: wide ? 2 : 4,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: SizedBox(
              width: cardWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBlock(
                    width: cardWidth,
                    height: imageHeight,
                    animated: animate,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SkeletonBlock(
                    width: cardWidth * 0.72,
                    height: 14,
                    animated: animate,
                  ),
                ],
              ),
            ),
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
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Icon(
                    Icons.movie_outlined,
                    size: 28,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
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
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 28,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
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
