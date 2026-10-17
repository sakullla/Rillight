import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/ui/app_icons.dart';

enum PhoneDestination {
  home,
  aggregation,
  search;

  /// Old index 1 was the removed library hub. Persist semantic IDs from now on.
  static PhoneDestination restore(Object? value) => switch (value) {
    'aggregation' || 2 => aggregation,
    'search' || 3 => search,
    _ => home,
  };
}

/// 悬浮导航盖住内容时，滚动区底部要留出系统手势条、间距、导航本身和溶入带。
/// 贴底时沿用 Scaffold 已经算进 [MediaQuery.padding] 的高度。
double phoneScrollClearance(BuildContext context) {
  if (!PhoneNavStyle.floatingOf(context)) {
    return MediaQuery.paddingOf(context).bottom;
  }
  return MediaQuery.viewPaddingOf(context).bottom +
      AppMobileNav.floatMargin +
      AppMobileNav.barHeight +
      AppMobileNav.fadeHeight;
}

/// 手机底部三个目的地:首页、聚合、搜索。悬浮时离开窗口边缘并盖在内容上；贴底时铺满宽度。
class PhoneBottomNav extends StatelessWidget {
  const PhoneBottomNav({
    super.key,
    required this.index,
    required this.onSelected,
    required this.floating,
  });

  final int index;
  final ValueChanged<int> onSelected;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final radius = floating
        ? BorderRadius.circular(AppMobileNav.floatRadius)
        : BorderRadius.zero;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    Widget bar = LiquidGlassBackdrop(
      enabled: false,
      child: LiquidGlass(
        kind: floating ? LiquidGlassKind.panel : LiquidGlassKind.bar,
        borderRadius: radius,
        tint: 1,
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: floating,
          child: CupertinoTabBar(
            activeColor: AppUiTheme.of(context).colorScheme.primary,
            inactiveColor: AppUiTheme.of(context).colorScheme.onSurfaceVariant,
            height: floating
                ? AppMobileNav.floatingHeight
                : AppMobileNav.dockedHeight,
            backgroundColor: const Color(0x00000000),
            currentIndex: index,
            onTap: onSelected,
            iconSize: 24,
            border: null,
            items: [
              BottomNavigationBarItem(
                icon: const Icon(AppIcons.home, fill: AppIcons.outline),
                activeIcon: const Icon(AppIcons.home, fill: AppIcons.filled),
                label: l.home,
              ),
              BottomNavigationBarItem(
                icon: const Icon(AppIcons.aggregation, fill: AppIcons.outline),
                activeIcon: const Icon(
                  AppIcons.aggregation,
                  fill: AppIcons.filled,
                ),
                label: l.aggregation,
              ),
              BottomNavigationBarItem(
                icon: const Icon(AppIcons.search, fill: AppIcons.outline),
                activeIcon: const Icon(AppIcons.search, fill: AppIcons.filled),
                label: l.search,
              ),
            ],
          ),
        ),
      ),
    );
    if (floating) {
      bar = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x52000000),
              blurRadius: 20,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: bar,
      );
    }
    final padded = Padding(
      padding: floating
          ? EdgeInsets.fromLTRB(
              AppMobileNav.floatMargin,
              0,
              AppMobileNav.floatMargin,
              bottom + AppMobileNav.floatMargin,
            )
          : EdgeInsets.zero,
      child: bar,
    );
    if (!floating) {
      return padded;
    }
    final surface = AppUiTheme.of(context).colorScheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.35, 1],
          colors: [
            surface.withValues(alpha: 0),
            surface.withValues(alpha: 0.48),
            surface.withValues(alpha: 0.86),
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const IgnorePointer(
            child: SizedBox(
              height: AppMobileNav.fadeHeight,
              width: double.infinity,
            ),
          ),
          padded,
        ],
      ),
    );
  }
}
