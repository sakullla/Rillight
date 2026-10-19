import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/app/ui/app_icons.dart';

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

/// 顶栏取色。已经是手机主题时沿用当前主题，否则按明暗用 phoneLight 或 phoneDark。
AppUiThemeData phoneChromeTheme(BuildContext context) {
  final theme = AppUiTheme.of(context);
  if (theme.phone) return theme;
  return theme.brightness == Brightness.dark
      ? AppUiTheme.phoneDark()
      : AppUiTheme.phoneLight();
}

/// 手机顶栏。壳层、登录、我的、服务器管理、附加详情和演职员页共用这一条。
///
/// 返回、标题和右侧操作都画在这里。颜色来自 [phoneChromeTheme]：浅色是
/// [AppUiTheme.phoneLight]，深色是 [AppUiTheme.phoneDark]。
class PhoneTopBar extends StatelessWidget
    implements ObstructingPreferredSizeWidget {
  const PhoneTopBar({
    super.key,
    this.title,
    this.leading,
    this.trailing,
    this.backgroundColor,
    this.foregroundColor,
    this.automaticallyImplyLeading = true,
    this.centerTitle = false,
    this.includeSafeTop = true,
    this.height = bodyHeight,
    this.border,
    this.child,
  });

  /// 壳层叠在内容上。子组件放服务器胶囊、页面名和我的入口。
  const PhoneTopBar.shell({
    super.key,
    required this.backgroundColor,
    required this.child,
    this.foregroundColor,
    this.height = bodyHeight,
  }) : title = null,
       leading = null,
       trailing = null,
       automaticallyImplyLeading = false,
       centerTitle = false,
       includeSafeTop = true,
       border = null;

  /// 不含状态栏的顶栏高度。可点的返回钮沿用 44dp 图标按钮。
  static const bodyHeight = 44.0;

  static const backKey = Key('phone-top-bar-back');
  static const backgroundKey = Key('phone-top-bar-background');

  final Widget? title;
  final Widget? leading;
  final Widget? trailing;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool automaticallyImplyLeading;
  final bool centerTitle;
  final bool includeSafeTop;
  final double height;
  final Border? border;

  /// 壳层自定义内容。设置后不再排返回和标题。
  final Widget? child;

  Color _background(BuildContext context) =>
      backgroundColor ?? phoneChromeTheme(context).scaffoldBackgroundColor;

  @override
  bool shouldFullyObstruct(BuildContext context) => _background(context).a >= 1;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final phone = phoneChromeTheme(context);
    final background = _background(context);
    final foreground = foregroundColor ?? phone.colorScheme.onSurface;
    final top = includeSafeTop ? MediaQuery.paddingOf(context).top : 0.0;
    final titleStyle = (phone.textTheme.titleMedium ?? const TextStyle())
        .copyWith(color: foreground, fontWeight: FontWeight.w700);
    return ColoredBox(
      key: backgroundKey,
      color: background,
      child: DecoratedBox(
        decoration: BoxDecoration(border: border),
        child: Padding(
          padding: EdgeInsets.only(top: top),
          child: SizedBox(
            height: height,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: IconTheme(
                data: IconThemeData(color: foreground),
                child: DefaultTextStyle(
                  style: titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: _content(context, foreground),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Color foreground) {
    final custom = child;
    if (custom != null) return custom;
    final resolvedLeading = _leading(context, foreground);
    final titleWidget = title;
    return Row(
      children: [
        ?resolvedLeading,
        Expanded(
          child: titleWidget == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: EdgeInsets.only(
                    left: resolvedLeading == null
                        ? AppSpacing.md
                        : AppSpacing.xs,
                    right: AppSpacing.xs,
                  ),
                  child: Align(
                    alignment: centerTitle
                        ? Alignment.center
                        : Alignment.centerLeft,
                    child: titleWidget,
                  ),
                ),
        ),
        if (trailing != null)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: trailing,
          ),
      ],
    );
  }

  Widget? _leading(BuildContext context, Color foreground) {
    if (leading != null) return leading;
    if (!automaticallyImplyLeading) return null;
    final route = ModalRoute.of(context);
    if (route?.canPop != true) return null;
    return AppIconButton(
      key: backKey,
      tooltip: AppLocalizations.of(context).mobileBack,
      color: foreground,
      onPressed: () => Navigator.maybePop(context),
      icon: const Icon(AppIcons.back, fill: AppIcons.filled),
    );
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

/// 没有内容：标题、原因，外加主/次下一步。
class MobileEmptyState extends StatelessWidget {
  const MobileEmptyState({
    super.key,
    required this.message,
    this.title,
    this.actionLabel,
    this.onAction,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  static const Key stateKey = Key('mobile-empty-state');
  static const Key actionKey = Key('mobile-empty-action');

  final String message;

  /// 可选的加粗标题,用于区分空库的不同原因。
  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 主操作(填充按钮),优先于 [actionLabel]。
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  /// 次操作(文字按钮)。
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final textTheme = AppUiTheme.of(context).textTheme;
    final hasPrimary = primaryLabel != null && onPrimary != null;
    final action = hasPrimary
        ? AppButton(
            key: actionKey,
            style: AppButtonStyle(minimumSize: _minHit),
            onPressed: onPrimary,
            variant: AppButtonVariant.filled,
            child: Text(primaryLabel!),
          )
        : actionLabel != null && onAction != null
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
                    AppIcons.movie,
                    fill: AppIcons.filled,
                    size: 28,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (title != null) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: AppSpacing.md),
                action,
              ],
              if (secondaryLabel != null && onSecondary != null) ...[
                const SizedBox(height: AppSpacing.xs),
                AppButton(
                  key: const Key('mobile-empty-secondary'),
                  style: AppButtonStyle(minimumSize: _minHit),
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

/// 请求失败：标题、原因、重试，以及可选的切换入口。
class MobileFailureState extends StatelessWidget {
  const MobileFailureState({
    super.key,
    required this.message,
    required this.onRetry,
    this.title,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  static const Key stateKey = Key('mobile-failure-state');
  static const Key retryKey = Key('mobile-failure-retry');
  static const Key secondaryKey = Key('mobile-failure-secondary');

  final String message;
  final VoidCallback onRetry;

  /// 可选的加粗标题,用于区分设备离线与服务器离线。
  final String? title;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    final textTheme = AppUiTheme.of(context).textTheme;
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
                    AppIcons.error,
                    fill: AppIcons.filled,
                    size: 28,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (title != null) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                key: retryKey,
                style: AppButtonStyle(minimumSize: _minHit),
                onPressed: onPrimary ?? onRetry,
                variant: AppButtonVariant.filled,
                child: Text(primaryLabel ?? l10n.retry),
              ),
              if (secondaryLabel != null && onSecondary != null) ...[
                const SizedBox(height: AppSpacing.xs),
                AppButton(
                  key: secondaryKey,
                  style: AppButtonStyle(minimumSize: _minHit),
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
