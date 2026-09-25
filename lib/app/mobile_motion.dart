import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/emby_models.dart';

/// 从首页带进剧集页或详情页的那张图。
///
/// 路由本身不改；页面用它在第一帧画上同一张图，避免先黑屏再换一张。
class PhoneImageHandoff {
  const PhoneImageHandoff({
    required this.item,
    required this.preferBackdrop,
    required this.maxWidth,
  });

  final EmbyItem item;
  final bool preferBackdrop;
  final int maxWidth;
}

/// 手机位移和显隐。时长与曲线只取 [AppMotion]。
abstract final class PhoneMotion {
  static const int posterRequestWidth = 400;
  static const int heroRequestWidth = 800;
  static const int pageRequestWidth = 1280;

  static const playerControlsKey = Key('phone-player-controls');

  /// 路由转场时长档,Material Motion 校准区间 200–300ms。
  ///
  /// 经 [AppMotion.durationOf] 求值;系统减少动效时转场即时完成。
  static const Duration pageTransition = Duration(milliseconds: 250);

  /// 底部导航 tab 切换时长档,与路由转场同区间。
  static const Duration tabTransition = Duration(milliseconds: 250);

  static Object imageTag(String itemId, {required bool preferBackdrop}) {
    final kind = preferBackdrop ? 'backdrop' : 'poster';
    return 'phone-motion-$kind-$itemId';
  }

  static void openItem(
    BuildContext context,
    EmbyItem item, {
    bool preferBackdrop = false,
    int maxWidth = posterRequestWidth,
  }) {
    context.push(
      AppRoutes.item(item.id),
      extra: PhoneImageHandoff(
        item: item,
        preferBackdrop: preferBackdrop,
        maxWidth: maxWidth,
      ),
    );
  }

  /// 海报或横幅与页面顶部横幅共用一个 [Hero]。
  ///
  /// 飞行中沿用出发时的那张图。减少动效时控制器时长已经是 0，画面直接就位。
  static Widget sharedImage({
    required String itemId,
    required bool preferBackdrop,
    required Widget child,
  }) {
    return Hero(
      tag: imageTag(itemId, preferBackdrop: preferBackdrop),
      transitionOnUserGestures: true,
      flightShuttleBuilder: (context, animation, direction, from, to) {
        return (from.widget as Hero).child;
      },
      child: child,
    );
  }

  /// 详情页转场:container transform 语义,共享元素由 [sharedImage] 的 Hero
  /// 承载,页面自身淡入并轻微放大;Hero 无匹配 tag 时天然退化为 fade。
  static CustomTransitionPage<T> detailPage<T>({
    required BuildContext context,
    required GoRouterState state,
    required Widget child,
  }) {
    final duration = AppMotion.durationOf(context, pageTransition);
    return CustomTransitionPage<T>(
      key: state.pageKey,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      child: child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.standard,
          reverseCurve: AppMotion.exit,
        );
        return FadeScaleTransition(animation: curved, child: child);
      },
    );
  }

  /// 父→子层级转场:shared axis Y。
  static CustomTransitionPage<T> sharedAxisPage<T>({
    required BuildContext context,
    required GoRouterState state,
    required Widget child,
    SharedAxisTransitionType type = SharedAxisTransitionType.vertical,
  }) {
    final duration = AppMotion.durationOf(context, pageTransition);
    return CustomTransitionPage<T>(
      key: state.pageKey,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      child: child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return SharedAxisTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          transitionType: type,
          fillColor: Theme.of(context).scaffoldBackgroundColor,
          child: child,
        );
      },
    );
  }

  /// 无关页面切换(播放器、登录):fade through。
  static CustomTransitionPage<T> fadeThroughPage<T>({
    required BuildContext context,
    required GoRouterState state,
    required Widget child,
  }) {
    final duration = AppMotion.durationOf(context, pageTransition);
    return CustomTransitionPage<T>(
      key: state.pageKey,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      child: child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeThroughTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          fillColor: Theme.of(context).scaffoldBackgroundColor,
          child: child,
        );
      },
    );
  }

  /// 播放控件显隐。隐藏后不再接点击，进行中的过渡可以被下一次点按打断。
  static Widget reveal({
    required BuildContext context,
    required bool visible,
    required Widget child,
  }) {
    final duration = AppMotion.durationOf(context);
    return AnimatedOpacity(
      key: playerControlsKey,
      opacity: visible ? 1 : 0,
      duration: duration,
      curve: visible ? AppMotion.standard : AppMotion.exit,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }

  static Future<T?> showBottomPanel<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = false,
    bool showDragHandle = false,
    bool useSafeArea = false,
  }) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final enter = reduced ? Duration.zero : AppMotion.normal;
    final exit = reduced ? Duration.zero : AppMotion.fast;
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      sheetAnimationStyle: AnimationStyle(
        duration: enter,
        reverseDuration: exit,
        curve: reduced ? Curves.linear : AppMotion.emphasized,
        reverseCurve: reduced ? Curves.linear : AppMotion.exit,
      ),
      builder: builder,
    );
  }
}

/// 底部导航 tab 切换:shared axis X。
///
/// tab 内容状态(滚动位置、搜索草稿)保留在 IndexedStack 里,这里只对入场
/// 整页做横向位移加淡入,不复制出场页,避免 Hero tag 重复。时长经
/// [AppMotion.durationOf] 求值,减少动效时即时就位。
class PhoneTabTransition extends StatefulWidget {
  const PhoneTabTransition({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  State<PhoneTabTransition> createState() => _PhoneTabTransitionState();
}

class _PhoneTabTransitionState extends State<PhoneTabTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    // 首次入场不播放,避免登录后首页整体滑入。
    _controller = AnimationController(
      vsync: this,
      duration: PhoneMotion.tabTransition,
      value: 1,
    );
    _curve = CurvedAnimation(parent: _controller, curve: AppMotion.standard);
  }

  @override
  void didUpdateWidget(PhoneTabTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      _direction = widget.index > oldWidget.index ? 1 : -1;
      _controller
        ..duration = AppMotion.durationOf(context, PhoneMotion.tabTransition)
        ..forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _controller.isAnimating) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0.06 * _direction, 0),
          end: Offset.zero,
        ).animate(_curve),
        child: widget.child,
      ),
    );
  }
}
