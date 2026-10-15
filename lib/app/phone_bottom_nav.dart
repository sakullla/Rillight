import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';

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

/// 手机底部四个目的地:首页、媒体库、聚合、搜索。悬浮时离开窗口边缘并盖在内容上；贴底时铺满宽度。
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
            iconSize: 26,
            items: [
              BottomNavigationBarItem(
                icon: const Icon(CupertinoIcons.house),
                activeIcon: const Icon(CupertinoIcons.house_fill),
                label: l.home,
              ),
              BottomNavigationBarItem(
                icon: const Icon(CupertinoIcons.play_rectangle),
                activeIcon: const Icon(CupertinoIcons.play_rectangle_fill),
                label: l.libraries,
              ),
              BottomNavigationBarItem(
                icon: const Icon(CupertinoIcons.square_stack_3d_up),
                activeIcon: const Icon(CupertinoIcons.square_stack_3d_up_fill),
                label: l.aggregation,
              ),
              BottomNavigationBarItem(
                icon: const Icon(CupertinoIcons.search),
                activeIcon: const Icon(CupertinoIcons.search),
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
              color: Color(0x47000000),
              blurRadius: 12,
              offset: Offset(0, 4),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IgnorePointer(
          child: SizedBox(
            height: AppMobileNav.fadeHeight,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    surface.withValues(alpha: 0),
                    surface.withValues(alpha: 0.72),
                  ],
                ),
              ),
            ),
          ),
        ),
        ColoredBox(color: surface.withValues(alpha: 0.72), child: padded),
      ],
    );
  }
}
