import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/media_server/models.dart';

enum PhoneAxisTransitionType { horizontal, vertical, scaled }

/// 从首页带进剧集页或详情页的那张图。
///
/// 路由本身不改；页面用它在第一帧画上同一张图，避免先黑屏再换一张。
class PhoneImageHandoff {
  const PhoneImageHandoff({
    required this.item,
    required this.preferBackdrop,
    required this.maxWidth,
  });

  final MediaItem item;
  final bool preferBackdrop;
  final int maxWidth;
}

/// 手机位移和显隐。时长与曲线只取 [AppMotion]。
abstract final class PhoneMotion {
  static const int posterRequestWidth = 400;
  static const int heroRequestWidth = 800;
  static const int pageRequestWidth = 1280;

  static const playerControlsKey = Key('phone-player-controls');

  /// 路由转场时长档,统一使用 200–300ms。
  ///
  /// 经 [AppMotion.durationOf] 求值;系统减少动效时转场即时完成。
  static const Duration pageTransition = Duration(milliseconds: 250);

  /// 底部导航 tab 切换时长档,与路由转场同区间。
  static const Duration tabTransition = Duration(milliseconds: 200);

  static Object imageTag(String itemId, {required bool preferBackdrop}) {
    final kind = preferBackdrop ? 'backdrop' : 'poster';
    return 'phone-motion-$kind-$itemId';
  }

  static void openItem(
    BuildContext context,
    MediaItem item, {
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
  /// 正向沿用卡片图片，返回时也使用目的卡片图片，避免详情大图在返回时
  /// 突然换成另一种裁剪或请求宽度。
  static Widget sharedImage({
    required String itemId,
    required bool preferBackdrop,
    required Widget child,
  }) {
    return Hero(
      tag: imageTag(itemId, preferBackdrop: preferBackdrop),
      transitionOnUserGestures: true,
      flightShuttleBuilder: (context, animation, direction, from, to) {
        return ((direction == HeroFlightDirection.push
                    ? from.widget
                    : to.widget)
                as Hero)
            .child;
      },
      child: child,
    );
  }

  /// 详情页与共享图一起轻微位移。整页透明度动画会让头图与背景同时露出，
  /// 在往返时形成一帧闪白，因此页面保持不透明。
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
        if (duration == Duration.zero) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.standard,
          reverseCurve: AppMotion.exit,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.025),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  /// 父→子层级转场:shared axis Y。
  static CustomTransitionPage<T> sharedAxisPage<T>({
    required BuildContext context,
    required GoRouterState state,
    required Widget child,
    PhoneAxisTransitionType type = PhoneAxisTransitionType.vertical,
  }) {
    final duration = AppMotion.durationOf(context, pageTransition);
    return CustomTransitionPage<T>(
      key: state.pageKey,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      child: child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (duration == Duration.zero) return child;
        final primary = animation.drive(CurveTween(curve: AppMotion.standard));
        final secondary = secondaryAnimation.drive(
          CurveTween(curve: AppMotion.exit),
        );
        return FadeTransition(
          opacity: primary,
          child: FadeTransition(
            opacity: ReverseAnimation(secondary),
            child: type == PhoneAxisTransitionType.scaled
                ? ScaleTransition(
                    scale: primary.drive(Tween(begin: .96, end: 1)),
                    child: child,
                  )
                : SlideTransition(
                    position: primary.drive(
                      Tween<Offset>(
                        begin: type == PhoneAxisTransitionType.horizontal
                            ? const Offset(.04, 0)
                            : const Offset(0, .04),
                        end: Offset.zero,
                      ),
                    ),
                    child: child,
                  ),
          ),
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
        if (duration == Duration.zero) return child;
        return FadeTransition(
          opacity: animation.drive(
            CurveTween(curve: const Interval(.3, 1, curve: AppMotion.standard)),
          ),
          child: FadeTransition(
            opacity: ReverseAnimation(
              secondaryAnimation.drive(
                CurveTween(curve: const Interval(0, .3, curve: AppMotion.exit)),
              ),
            ),
            child: child,
          ),
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
      child: ExcludeSemantics(
        excluding: !visible,
        child: IgnorePointer(ignoring: !visible, child: child),
      ),
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
    return Navigator.of(context).push<T>(
      _PhonePanelRoute<T>(
        builder: builder,
        theme: AppUiTheme.of(context),
        enter: enter,
        exit: exit,
        reduced: reduced,
        isScrollControlled: isScrollControlled,
        showDragHandle: showDragHandle,
        useSafeArea: useSafeArea,
      ),
    );
  }
}

/// 底部导航 tab 切换：短距离位移，保持页面不透明。
///
/// tab 内容状态(滚动位置、搜索草稿)保留在 IndexedStack 里,这里只对入场
/// 整页做横向位移，静态内容单独缓存绘制；不复制出场页，避免 Hero tag 重复。时长经
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
    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset(0.025 * _direction, 0),
        end: Offset.zero,
      ).animate(_curve),
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// Cupertino panel route with the app's reduced-motion and dismissal policy.
class _PhonePanelRoute<T> extends PopupRoute<T> {
  _PhonePanelRoute({
    required this.builder,
    required this.theme,
    required this.enter,
    required this.exit,
    required this.reduced,
    required this.isScrollControlled,
    required this.showDragHandle,
    required this.useSafeArea,
  });
  final WidgetBuilder builder;
  final AppUiThemeData theme;
  final Duration enter, exit;
  final bool reduced, isScrollControlled, showDragHandle, useSafeArea;
  @override
  Duration get transitionDuration => enter;
  @override
  Duration get reverseTransitionDuration => exit;
  @override
  bool get barrierDismissible => true;
  @override
  Color get barrierColor => const Color(0x66000000);
  @override
  String get barrierLabel => '关闭';
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return AppUiTheme(
      data: theme,
      child: Builder(
        builder: (context) => SafeArea(
          top: useSafeArea,
          left: useSafeArea,
          right: useSafeArea,
          bottom: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.sizeOf(context).height *
                      (isScrollControlled ? 1 : 9 / 16),
                ),
                child: CupertinoPopupSurface(
                  child: ColoredBox(
                    color: theme.colorScheme.surface,
                    child: SizedBox(
                      width: double.infinity,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showDragHandle)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragEnd: (details) {
                                if ((details.primaryVelocity ?? 0) > 100) {
                                  Navigator.of(context).pop();
                                }
                              },
                              child: SizedBox(
                                height: 24,
                                width: double.infinity,
                                child: Center(
                                  child: Container(
                                    width: 36,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.outline,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Flexible(child: Builder(builder: builder)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduced) return child;
    return SlideTransition(
      position: animation
          .drive(
            CurveTween(
              curve: animation.status == AnimationStatus.reverse
                  ? AppMotion.exit
                  : AppMotion.emphasized,
            ),
          )
          .drive(Tween(begin: const Offset(0, 1), end: Offset.zero)),
      child: child,
    );
  }
}
