import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/desktop_gestures.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_display_dialog.dart';
import 'package:rillight/search/search_action.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/library/aggregation_page.dart';

class HomeScrollNotification extends Notification {
  const HomeScrollNotification(this.scrolled);
  final bool scrolled;
}

/// 全局外壳:半透明顶栏叠在全幅内容上,无常驻左栏。
///
/// 已登录时 [child] 铺满窗口,顶栏 Positioned 叠在上缘,hero/backdrop 可贴到窗口顶。
/// 顶栏左侧为首页。片库不在顶栏平铺,改由首页的片库入口展示。
/// 首页右侧的「⋯」配置轮播图、继续观看、下一集、片库入口和每个片库分栏的显示与顺序。
/// 再右侧为搜索与 [SessionActions]。搜索打开不透明覆盖层,不 push `/search`
/// 页壳;覆盖层之下叠 [SearchOverlayBarrier],点击遮罩等同关闭。
/// 登录前的 /connect 页没有导航意义,不显示顶栏。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const topBarKey = Key('app-shell-top-bar');
  static const homeNavKey = Key('app-shell-home');
  static const overflowNavKey = Key('app-shell-libraries-overflow');

  /// 顶栏内容行高;有窗口铬时不低于标题按钮带。
  static const topBarHeight = 40.0;

  /// 桌面搜索覆盖层里的返回。只关闭覆盖层，不弹出底下的路由。
  static const searchBackKey = Key('search-overlay-back');

  /// 顶栏下沿溶进画面的渐变高度,避免硬分割线切开海报。
  static const topFadeHeight = 36.0;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _forwardLocations = <(String, Object?, String?)>[];
  AuthController? _auth;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_searchKey);
  }

  bool _searchKey(KeyEvent event) {
    // EditableText handles Escape before an ancestor CallbackShortcuts. Keep
    // shell dismissal available while the real overlay input owns focus.
    if (_searchOpen &&
        _searchQueryFocus.hasFocus &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _closeSearch();
      return true;
    }
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (_auth == auth) return;
    _auth?.regionAccess.removeListener(_clearHistory);
    _auth?.sources.removeSourceRevocation(_sourceRevoked);
    _auth = auth;
    auth.regionAccess.addListener(_clearHistory);
    auth.sources.addSourceRevocation(_sourceRevoked);
  }

  void _sourceRevoked(String _) => _clearHistory();
  void _clearHistory() {
    _forwardLocations.clear();
    if (mounted) setState(() => _searchOpen = false);
  }

  String? _gestureLocation;
  bool _gestureNavigation = false;

  void _back() {
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    final router = GoRouter.of(context);
    final uri = GoRouterState.of(context).uri.toString();
    if (!router.canPop() && uri == AppRoutes.home) return;
    _forwardLocations.add((
      uri,
      GoRouterState.of(context).extra,
      _auth?.session?.server.id,
    ));
    _gestureNavigation = true;
    router.canPop() ? router.pop() : router.go(AppRoutes.home);
  }

  void _forward() {
    if (_searchOpen || _forwardLocations.isEmpty) return;
    _gestureNavigation = true;
    final target = _forwardLocations.removeLast();
    // A legacy address cannot be reinterpreted under another selected server.
    if (target.$2 == null && target.$3 != _auth?.session?.server.id) return;
    GoRouter.of(context).push(target.$1, extra: target.$2);
  }

  bool _searchOpen = false;
  final FocusNode _searchQueryFocus = FocusNode();
  final FocusNode _searchButtonFocus = FocusNode();
  FocusNode? _searchReturnFocus;
  bool _contentScrolled = false;
  String _scrollPath = '';

  @override
  void dispose() {
    _auth?.regionAccess.removeListener(_clearHistory);
    _auth?.sources.removeSourceRevocation(_sourceRevoked);
    HardwareKeyboard.instance.removeHandler(_searchKey);
    _searchQueryFocus.dispose();
    _searchButtonFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    if (_searchOpen) {
      _searchQueryFocus.requestFocus();
      return;
    }
    _searchReturnFocus = _searchButtonFocus;
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchQueryFocus.requestFocus();
      }
    });
  }

  void _navigateBack() {
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(AppRoutes.home);
    }
  }

  void _closeSearch() {
    if (!_searchOpen) {
      return;
    }
    setState(() => _searchOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _searchReturnFocus;
      if (target != null && target.context != null && target.canRequestFocus) {
        target.requestFocus();
      } else {
        _searchButtonFocus.requestFocus();
      }
    });
  }

  /// 首页和详情的画面贴到窗口顶,顶栏用轻遮罩;其它页保持实心条。
  bool _immersiveTopBar(String location) {
    // The light top bar is a near-opaque surface strip. Over the home hero
    // it reads as fog on the artwork, so the light home bar is solid and the
    // hero starts with a crisp edge beneath it. Dark stays immersive.
    if (location == AppRoutes.home &&
        Theme.of(context).brightness == Brightness.light) {
      return false;
    }
    return location == AppRoutes.home || AppRoutes.isItem(location);
  }

  /// 只采纳当前路由发出的滚动;从已滚动的首页进入详情时顶栏先透出画面。
  bool _barScrolled(String location) {
    return _scrollPath == location && _contentScrolled;
  }

  @override
  Widget build(BuildContext context) {
    // 注意:ShellRoute builder 的 context 上 GoRouterState.matchedLocation
    // 是外壳自身的匹配(恒为 '/'),只有 uri 反映 push 进来的当前子路由。
    final location = GoRouterState.of(context).uri.path;
    if (location == AppRoutes.connect) {
      return Scaffold(body: widget.child);
    }

    final gestureLocation = GoRouterState.of(context).uri.toString();
    if (_gestureLocation != gestureLocation) {
      if (!_gestureNavigation) _forwardLocations.clear();
      _gestureLocation = gestureLocation;
      _gestureNavigation = false;
    }
    return DesktopNavigationGestures(
      onBack: _back,
      onForward: _forwardLocations.isEmpty ? null : _forward,
      child: SearchOverlayController(
        isOpen: _searchOpen,
        open: _openSearch,
        close: _closeSearch,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _openSearch,
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                _openSearch,
          },
          child: Focus(
            autofocus: true,
            skipTraversal: true,
            child: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  NotificationListener<HomeScrollNotification>(
                    onNotification: (notification) {
                      if (_scrollPath != location ||
                          _contentScrolled != notification.scrolled) {
                        setState(() {
                          _scrollPath = location;
                          _contentScrolled = notification.scrolled;
                        });
                      }
                      return true;
                    },
                    child: RepaintBoundary(child: widget.child),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: RepaintBoundary(
                      child: _TopBar(
                        location: location,
                        opaque:
                            !_immersiveTopBar(location) ||
                            _barScrolled(location),
                        searchFocus: _searchButtonFocus,
                        onBack: _navigateBack,
                      ),
                    ),
                  ),
                  // 遮罩在顶栏之上、覆盖层之下:压暗整个背景并拦截穿透
                  // 覆盖层非交互区域的点击,点击等同关闭;关闭后立即恢复。
                  SearchOverlayBarrier(
                    visible: _searchOpen,
                    onDismiss: _closeSearch,
                  ),
                  if (_searchOpen)
                    Positioned.fill(
                      child: Material(
                        child: SafeArea(
                          child: Column(
                            children: [
                              Padding(
                                padding: EdgeInsets.only(
                                  top: AppShell.topBarHeight,
                                  right: windowChromeTrailingInset(),
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      key: AppShell.searchBackKey,
                                      tooltip: MaterialLocalizations.of(
                                        context,
                                      ).backButtonTooltip,
                                      onPressed: _closeSearch,
                                      icon: const Icon(Icons.arrow_back),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      tooltip: MaterialLocalizations.of(
                                        context,
                                      ).closeButtonTooltip,
                                      key: SearchOverlay.closeKey,
                                      onPressed: _closeSearch,
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: SearchRouteGuard(
                                  onPop: _closeSearch,
                                  child: AggregationPage(
                                    search: true,
                                    searchFocusNode: _searchQueryFocus,
                                    searchClearsTopBar: false,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.location,
    required this.opaque,
    required this.searchFocus,
    required this.onBack,
  });

  final String location;
  final bool opaque;
  final FocusNode searchFocus;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.maybeOf(context);
    if (catalog == null) {
      return _bar(context, const []);
    }
    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) => _bar(context, catalog.libraries),
    );
  }

  Widget _bar(BuildContext context, List<EmbyItem> libraries) {
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    final leading = hasChrome ? windowChromeLeadingInset() : 0.0;
    final trailing = hasChrome ? windowChromeTrailingInset() : 0.0;
    final height = hasChrome
        ? (kWindowChromeHeight > AppShell.topBarHeight
              ? kWindowChromeHeight
              : AppShell.topBarHeight)
        : AppShell.topBarHeight;

    final canPop = GoRouter.of(context).canPop();
    final l10n = AppLocalizations.of(context);
    final library = libraries
        .where((entry) => AppRoutes.library(entry.id) == location)
        .firstOrNull;
    final title =
        library?.name ??
        (AppRoutes.isServerResume(location)
            ? l10n.resumeRow
            : switch (location) {
                AppRoutes.settings => l10n.settings,
                AppRoutes.search => l10n.search,
                AppRoutes.shelfResume => l10n.resumeRow,
                AppRoutes.shelfNextUp => l10n.nextUpRow,
                AppRoutes.shelfLatestMovies => l10n.latestMoviesRow,
                AppRoutes.shelfLatestSeries => l10n.latestSeriesRow,
                _ => l10n.details,
              });
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final scrim = light ? scheme.surface : scheme.scrim;
    final overlayHeight = height + AppShell.topFadeHeight;
    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (opaque)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
              ),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: overlayHeight,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: light
                          ? [0, height / overlayHeight, 1]
                          : AppScrim.topBarStops,
                      colors: [
                        scrim.withValues(
                          alpha: light
                              ? AppScrim.of(context, AppScrim.lightTopBar)
                              : AppScrim.of(context, AppScrim.topBar),
                        ),
                        scrim.withValues(
                          alpha: light
                              ? AppScrim.of(context, AppScrim.lightTopBar)
                              : AppScrim.of(context, AppScrim.topBarMid),
                        ),
                        scrim.withValues(alpha: 0),
                      ],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          Material(
            key: AppShell.topBarKey,
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.only(left: leading, right: trailing),
              child: Row(
                children: [
                  if (canPop ||
                      (location != AppRoutes.home &&
                          !AppRoutes.showsBrowseNav(location)))
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                      ),
                      child: ScrimIconButton(
                        key: CatalogKeys.back,
                        tooltip: !canPop
                            ? l10n.home
                            : MaterialLocalizations.of(
                                context,
                              ).backButtonTooltip,
                        onPressed: onBack,
                        icon: Icon(
                          canPop
                              ? Icons.arrow_back_rounded
                              : Icons.home_outlined,
                        ),
                      ),
                    ),
                  if (AppRoutes.showsBrowseNav(location)) ...[
                    _HomeNav(selected: location == AppRoutes.home),
                    _NavTextButton(
                      buttonKey: const Key('app-shell-aggregation'),
                      label: l10n.aggregation,
                      selected: location == AppRoutes.aggregation,
                      onPressed: () => context.go(AppRoutes.aggregation),
                    ),
                    const Spacer(),
                    IconButton(
                      key: AppShell.overflowNavKey,
                      tooltip: l10n.phoneHomeEdit,
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        unawaited(showHomeDisplayDialog(context));
                      },
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ] else ...[
                    Expanded(
                      child: AppRoutes.isItem(location)
                          ? const SizedBox.shrink()
                          : Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                    ),
                  ],
                  SizedBox(
                    height: kWindowChromeHeight,
                    child: IconTheme(
                      data: IconTheme.of(context).copyWith(size: 18),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SearchAction(focusNode: searchFocus),
                          const SessionActions(),
                          const SizedBox(width: kWindowChromeActionGap),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeNav extends StatelessWidget {
  const _HomeNav({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _NavTextButton(
      buttonKey: AppShell.homeNavKey,
      label: l10n.home,
      selected: selected,
      onPressed: () {
        if (GoRouterState.of(context).uri.path != AppRoutes.home) {
          context.go(AppRoutes.home);
        }
      },
    );
  }
}

class _NavTextButton extends StatelessWidget {
  const _NavTextButton({
    required this.buttonKey,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return TextButton(
      key: buttonKey,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: selected
            ? colorScheme.onSurface
            : colorScheme.onSurfaceVariant,
        textStyle: theme.textTheme.titleMedium?.copyWith(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label),
          const SizedBox(height: 4),
          AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            height: 2,
            width: selected ? 18 : 0,
            decoration: BoxDecoration(
              color: selected ? colorScheme.onSurface : Colors.transparent,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索子树里的 [GoRouter.pop] 改走 [onPop]，不弹出当前路由。
///
/// 桌面搜索页里的返回因此只关闭覆盖层。手机和电视把 [canPop] 设为 true，
/// 让页内返回出现，并在按下后回到首页。
class SearchRouteGuard extends StatefulWidget {
  const SearchRouteGuard({
    super.key,
    required this.onPop,
    required this.child,
    this.canPop = false,
  });

  final VoidCallback onPop;
  final bool canPop;
  final Widget child;

  @override
  State<SearchRouteGuard> createState() => _SearchRouteGuardState();
}

class _SearchRouteGuardState extends State<SearchRouteGuard> {
  late final ValueNotifier<RoutingConfig> _config;
  late final _SearchPopRouter _router;

  @override
  void initState() {
    super.initState();
    _config = ValueNotifier(
      RoutingConfig(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
    _router = _SearchPopRouter(
      host: this,
      parent: GoRouter.of(context),
      routingConfig: _config,
    );
  }

  @override
  void dispose() {
    _router.dispose();
    _config.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InheritedGoRouter(goRouter: _router, child: widget.child);
  }
}

class _SearchPopRouter extends GoRouter {
  _SearchPopRouter({
    required this.host,
    required GoRouter parent,
    required super.routingConfig,
  }) : _parent = parent,
       super.routingConfig(
         initialLocation: '/',
         overridePlatformDefaultLocation: true,
         routerNeglect: true,
       );

  final _SearchRouteGuardState host;
  final GoRouter _parent;

  @override
  bool canPop() => host.widget.canPop;

  @override
  void pop<T extends Object?>([T? result]) => host.widget.onPop();

  @override
  GoRouterState get state => _parent.state;

  @override
  void go(String location, {Object? extra}) =>
      _parent.go(location, extra: extra);

  @override
  Future<T?> push<T extends Object?>(String location, {Object? extra}) =>
      _parent.push<T>(location, extra: extra);

  @override
  void goNamed(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
    String? fragment,
  }) => _parent.goNamed(
    name,
    pathParameters: pathParameters,
    queryParameters: queryParameters,
    extra: extra,
    fragment: fragment,
  );

  @override
  Future<T?> pushNamed<T extends Object?>(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
  }) => _parent.pushNamed<T>(
    name,
    pathParameters: pathParameters,
    queryParameters: queryParameters,
    extra: extra,
  );

  @override
  Future<T?> pushReplacement<T extends Object?>(
    String location, {
    Object? extra,
  }) => _parent.pushReplacement<T>(location, extra: extra);

  @override
  Future<T?> pushReplacementNamed<T extends Object?>(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
  }) => _parent.pushReplacementNamed<T>(
    name,
    pathParameters: pathParameters,
    queryParameters: queryParameters,
    extra: extra,
  );

  @override
  Future<T?> replace<T>(String location, {Object? extra}) =>
      _parent.replace<T>(location, extra: extra);

  @override
  Future<T?> replaceNamed<T>(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
  }) => _parent.replaceNamed<T>(
    name,
    pathParameters: pathParameters,
    queryParameters: queryParameters,
    extra: extra,
  );

  @override
  void refresh() => _parent.refresh();
}
