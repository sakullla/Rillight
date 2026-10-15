import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/home/phone_hero.dart';

/// 手机滚动不使用 Android 拉伸回弹，避免下拉刷新和上拉时把横幅、卡片拉变形。
class PhoneScrollBehavior extends ScrollBehavior {
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
/// 颜色和字号跟随当前 [AppUiTheme]，出现过渡使用 [AppMotion]。
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
        SkeletonBlock(width: 112, height: 20, animated: animate),
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
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final height = PhoneHero.heightFor(width, viewportHeight: viewport);
            final page = AppUiTheme.of(context).scaffoldBackgroundColor;
            // 与成品同形:整屏宽的头图块,片名、元信息和按钮压在下缘。
            return SizedBox(
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SkeletonBlock(
                    borderRadius: BorderRadius.zero,
                    animated: animate,
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [.4, 1],
                        colors: [page.withValues(alpha: 0), page],
                      ),
                    ),
                  ),
                  Positioned(
                    left: PhoneHero.sidePadding,
                    right: PhoneHero.sidePadding,
                    bottom: PhoneHero.dotsHeight,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SkeletonBlock(
                          width: 68,
                          height: 11 * scale,
                          animated: animate,
                        ),
                        const SizedBox(height: 8),
                        SkeletonBlock(
                          width: (width - 40) * .62,
                          height: 30 * scale,
                          animated: animate,
                        ),
                        const SizedBox(height: 10),
                        SkeletonBlock(
                          width: (width - 40) * .44,
                          height: 12 * scale,
                          animated: animate,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Row(
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
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: _SectionSkeleton(wide: true),
        ),
        const SizedBox(height: 28),
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

//// 海报卡宽：一屏两张半到三张完整 2:3，再露出下一张。页边距 16，间距 12。
double phoneHomePosterCardWidth(double screenWidth) {
  final available = screenWidth - AppSpacing.md * 2;
  return ((available - AppSpacing.sm * 2) / 2.7).clamp(104.0, 168.0);
}

/// 横卡宽：一屏一张完整 16:9，再露出下一张。页边距 16，间距 12。
double phoneHomeWideCardWidth(double screenWidth) {
  final available = screenWidth - AppSpacing.md * 2;
  return ((available - AppSpacing.sm) / 1.22).clamp(220.0, 420.0);
}

/// 片库磁贴宽：一屏两张多。
double phoneHomeLibraryCardWidth(double screenWidth) {
  final available = screenWidth - AppSpacing.md * 2;
  return ((available - AppSpacing.sm) / 1.8).clamp(160.0, 300.0);
}

/// Shared geometry keeps loading and resolved rails on the same baseline.
double phoneHomeRailHeight(BuildContext context, {required bool wide}) {
  final screen = MediaQuery.sizeOf(context).width;
  final width = wide
      ? phoneHomeWideCardWidth(screen)
      : phoneHomePosterCardWidth(screen);
  if (!wide) return width * 1.5 + phonePosterCardLabelExtent(context) + 2;
  final theme = AppUiTheme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  final title = scaler.scale(theme.bodyMedium?.fontSize ?? 14) * 1.25;
  final meta = scaler.scale(theme.labelSmall?.fontSize ?? 12) * 1.25;
  return width * 9 / 16 + 8 + title + 2 + meta + 6;
}

double phoneHomeWideBadgeHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(11) * 1.25 + 4;

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
            padding: const EdgeInsets.only(right: AppSpacing.sm),
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
    final scheme = AppUiTheme.of(context).colorScheme;
    final action = actionLabel != null && onAction != null
        ? AppButton(
            key: actionKey,
            style: AppButtonStyle(minimumSize: _minHit),
            onPressed: onAction,
            variant: AppButtonVariant.outlined,
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
                    CupertinoIcons.film,
                    size: 28,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppUiTheme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
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
    final scheme = AppUiTheme.of(context).colorScheme;
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
                    CupertinoIcons.exclamationmark_circle,
                    size: 28,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppUiTheme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                key: retryKey,
                style: AppButtonStyle(minimumSize: _minHit),
                onPressed: onRetry,
                variant: AppButtonVariant.filled,
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
