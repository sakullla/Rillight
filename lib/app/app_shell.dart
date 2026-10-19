import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/desktop_gestures.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/browse_menu_button.dart';
import 'package:rillight/app/widgets/desktop_back_button.dart';
import 'package:rillight/app/widgets/top_bar_backdrop.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_display_dialog.dart';
import 'package:rillight/search/search_action.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/app/ui/app_icons.dart';

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

  /// 非浏览页面顶栏的「浏览」菜单入口。
  static const browseMenuKey = BrowseMenuButton.buttonKey;

  /// 顶栏「浏览」显示文字的最小窗口宽度;更窄只显示图标,
  /// 让搜索与账户在 1024 宽度下仍能同排。
  static const browseLabelMinWidth = 1200.0;

  /// 顶栏内容行高;有窗口铬时不低于标题按钮带。
  ///
  /// 有系统标题按钮时,导航、编辑首页、搜索、设置和账号收进同一条
  /// 标题按钮带,垂直中心与最小化/最大化/关闭重合。没有标题按钮时,
  /// 这些控件在本高度内共用一条中线。
  static const topBarHeight = 56.0;

  /// 顶栏下沿溶进画面的渐变高度,避免硬分割线切开海报。
  static const topFadeHeight = TopBarBackdrop.fadeHeight;

  /// 窗口不窄于此宽度时,顶栏搜索入口展开为带提示与快捷键的胶囊。
  static const searchPillMinWidth = 900.0;

  static const librariesNavKey = Key('app-shell-libraries');
  static Key libraryNavEntryKey(String id) => Key('app-shell-library-$id');

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
    _auth?.serverAccess.removeListener(_clearHistory);
    _auth?.sources.removeSourceRevocation(_sourceRevoked);
    _auth = auth;
    auth.serverAccess.addListener(_clearHistory);
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
  (String, bool)? _pendingScroll;
  bool _scrollUpdateScheduled = false;

  @override
  void dispose() {
    _auth?.serverAccess.removeListener(_clearHistory);
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
        AppUiTheme.of(context).brightness == Brightness.light) {
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
      return CupertinoPageScaffold(child: widget.child);
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
            child: CupertinoPageScaffold(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NotificationListener<HomeScrollNotification>(
                    onNotification: (notification) {
                      _pendingScroll = (location, notification.scrolled);
                      if (!_scrollUpdateScheduled) {
                        _scrollUpdateScheduled = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _scrollUpdateScheduled = false;
                          final next = _pendingScroll;
                          _pendingScroll = null;
                          if (!mounted ||
                              next == null ||
                              GoRouterState.of(context).uri.path != next.$1) {
                            return;
                          }
                          if (_scrollPath != next.$1 ||
                              _contentScrolled != next.$2) {
                            setState(() {
                              _scrollPath = next.$1;
                              _contentScrolled = next.$2;
                            });
                          }
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
                        scrolled: _barScrolled(location),
                        searchFocus: _searchButtonFocus,
                        onBack: _navigateBack,
                      ),
                    ),
                  ),

                  SearchOverlayBarrier(
                    visible: _searchOpen,
                    onDismiss: _closeSearch,
                  ),
                  if (_searchOpen)
                    Positioned.fill(
                      // 搜索面淡入并下落几像素,不再生硬地盖在 hero 上。
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: AppMotion.durationOf(
                          context,
                          AppMotion.normal,
                        ),
                        curve: AppMotion.emphasized,
                        builder: (context, t, child) => Opacity(
                          opacity: t,
                          child: Transform.translate(
                            offset: Offset(0, (1 - t) * -8),
                            child: child,
                          ),
                        ),
                        child: ColoredBox(
                          // 实色阅读面连同顶栏一起盖住:搜索行占据顶栏位置,
                          // 结果之下不再透出首页画面。
                          color: AppUiTheme.of(context).scaffoldBackgroundColor,
                          child: SafeArea(
                            child: SearchRouteGuard(
                              onPop: _closeSearch,
                              child: AggregationPage(
                                search: true,
                                searchFocusNode: _searchQueryFocus,
                                searchClearsTopBar: false,
                                onCloseSearch: _closeSearch,
                              ),
                            ),
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
    required this.scrolled,
    required this.searchFocus,
    required this.onBack,
  });

  final String location;
  final bool opaque;

  /// 当前页内容已滚到顶栏下方:显示细分隔线,片库页把页内大标题收进顶栏。
  final bool scrolled;
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

  Widget _bar(BuildContext context, List<MediaItem> libraries) {
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    final captionBand = hasChrome && windowChromeShowsCaptionButtons;
    final leading = hasChrome ? windowChromeLeadingInset() : 0.0;
    final trailing = hasChrome ? windowChromeTrailingInset() : 0.0;
    final height = hasChrome
        ? (kWindowChromeHeight > AppShell.topBarHeight
              ? kWindowChromeHeight
              : AppShell.topBarHeight)
        : AppShell.topBarHeight;

    // 下拉菜单也是一条路由。用导航器的 canPop 会把菜单当成页面，
    // 首页一点「媒体库」，左边就多出「返回」，按钮还被挤开。
    final canPop = _shellPageCanPop(context);
    final l10n = AppLocalizations.of(context);
    final library = libraries
        .where((entry) => AppRoutes.library(entry.id) == location)
        .firstOrNull;
    final personName = AppRoutes.isPerson(location)
        ? (GoRouterState.of(context).uri.queryParameters['name']?.trim() ?? '')
        : '';
    final title =
        library?.name ??
        (personName.isNotEmpty
            ? personName
            : AppRoutes.isServerResume(location)
            ? (GoRouterState.of(context).uri.queryParameters['section'] ==
                      'favorites'
                  ? l10n.filterFavorite
                  : l10n.resumeRow)
            : switch (location) {
                AppRoutes.settings => l10n.settings,
                AppRoutes.search => l10n.search,
                AppRoutes.shelfResume => l10n.resumeRow,
                AppRoutes.shelfNextUp => l10n.nextUpRow,
                AppRoutes.shelfLatestMovies => l10n.latestMoviesRow,
                AppRoutes.shelfLatestSeries => l10n.latestSeriesRow,
                _ => l10n.details,
              });
    final scheme = AppUiTheme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final item = AppRoutes.isItem(location);
    // 片库与货架页自带大标题:未滚动时顶栏不重复,滚过标题后再收进顶栏。
    final pageHasHeading = _pageHasHeading(location);
    final showTitle = !item && (!pageHasHeading || scrolled);
    // 宽窗口用带提示文字的搜索胶囊,窄窗口退回图标。
    final wideSearch =
        MediaQuery.sizeOf(context).width >= AppShell.searchPillMinWidth;
    final showBrowseMenu = !AppRoutes.showsBrowseNav(location);
    final showBrowseLabel =
        MediaQuery.sizeOf(context).width >= AppShell.browseLabelMinWidth;
    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 近实底 surface 带加下沿淡出:白海报上的文字与图标不再依赖
          // 图片明暗。沉浸页多一层模糊,滚动后的详情也不再铺黑色薄层。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: TopBarBackdrop(height: height, blur: !opaque),
          ),
          Container(
            decoration: BoxDecoration(),
            key: AppShell.topBarKey,
            child: Padding(
              padding: EdgeInsets.only(
                left: leading + AppSpacing.sm,
                right: trailing,
              ),
              child: Align(
                alignment: captionBand ? Alignment.topCenter : Alignment.center,
                child: SizedBox(
                  height: captionBand ? kWindowChromeHeight : null,
                  child: Row(
                    children: [
                      if (canPop ||
                          (location != AppRoutes.home &&
                              !AppRoutes.showsBrowseNav(location)))
                        Padding(
                          padding: const EdgeInsets.only(
                            left: AppSpacing.page - AppSpacing.sm,
                            right: AppSpacing.sm,
                          ),
                          child: DesktopBackButton(
                            overArtwork: !opaque,
                            tooltip: !canPop ? l10n.home : l10n.mobileBack,
                            onPressed: onBack,
                            icon: canPop ? AppIcons.back : AppIcons.home,
                            label: canPop ? l10n.mobileBack : l10n.home,
                          ),
                        ),
                      if (AppRoutes.showsBrowseNav(location)) ...[
                        _HomeNav(selected: location == AppRoutes.home),
                        const SizedBox(width: AppSpacing.xxs),
                        _NavTextButton(
                          buttonKey: const Key('app-shell-aggregation'),
                          label: l10n.aggregation,
                          icon: AppIcons.aggregation,
                          selected: location == AppRoutes.aggregation,
                          onPressed: () => context.go(AppRoutes.aggregation),
                        ),
                        if (libraries.isNotEmpty) ...[
                          const SizedBox(width: AppSpacing.xxs),
                          _LibrariesNav(libraries: libraries),
                        ],
                        const Spacer(),
                        AppIconButton(
                          key: AppShell.overflowNavKey,
                          tooltip: l10n.phoneHomeEdit,
                          padding: EdgeInsets.zero,
                          constraints: kTitleBarIconConstraints,
                          size: 20,
                          onPressed: () {
                            unawaited(showHomeDisplayDialog(context));
                          },
                          icon: const Icon(
                            AppIcons.tune,
                            fill: AppIcons.filled,
                          ),
                        ),
                      ] else ...[
                        Expanded(
                          child: item
                              ? const SizedBox.shrink()
                              : AnimatedOpacity(
                                  opacity: showTitle ? 1 : 0,
                                  duration: AppMotion.durationOf(
                                    context,
                                    AppMotion.fast,
                                  ),
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppUiTheme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                        ),
                      ],
                      IconTheme(
                        data: IconTheme.of(context).copyWith(size: 20),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showBrowseMenu) ...[
                              BrowseMenuButton(
                                key: AppShell.browseMenuKey,
                                libraries: libraries,
                                currentLocation: location,
                                showLabel: showBrowseLabel,
                              ),
                              const SizedBox(width: AppSpacing.xxs),
                            ],
                            if (wideSearch)
                              const SizedBox(width: AppSpacing.xs),
                            SearchAction(
                              focusNode: searchFocus,
                              expanded: wideSearch,
                              overArtwork: !opaque && !light,
                            ),
                            if (wideSearch)
                              const SizedBox(width: AppSpacing.xs),
                            const SessionActions(),
                            const SizedBox(width: kWindowChromeActionGap),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶栏「返回」只看页面栈。对话框和锚定菜单是无页面路由，不算可返回的一页。
bool _shellPageCanPop(BuildContext context) {
  final delegate = GoRouter.of(context).routerDelegate;
  if (_navigatorHasPageStack(delegate.navigatorKey.currentState)) {
    return true;
  }
  return _shellMatchHasPageStack(delegate.currentConfiguration.matches);
}

bool _navigatorHasPageStack(NavigatorState? navigator) {
  final pages = navigator?.widget.pages;
  return pages != null && pages.length > 1;
}

bool _shellMatchHasPageStack(List<RouteMatchBase> matches) {
  for (final match in matches) {
    if (match is ShellRouteMatch &&
        (_navigatorHasPageStack(match.navigatorKey.currentState) ||
            _shellMatchHasPageStack(match.matches))) {
      return true;
    }
  }
  return false;
}

bool _pageHasHeading(String location) =>
    location.startsWith('/library/') ||
    location.startsWith('/shelf/') ||
    location.startsWith('/server/') ||
    AppRoutes.isPerson(location);

class _HomeNav extends StatelessWidget {
  const _HomeNav({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _NavTextButton(
      buttonKey: AppShell.homeNavKey,
      label: l10n.home,
      icon: AppIcons.home,
      selected: selected,
      onPressed: () {
        if (GoRouterState.of(context).uri.path != AppRoutes.home) {
          context.go(AppRoutes.home);
        }
      },
    );
  }
}

/// 顶栏「媒体库」:点开下拉列出全部片库,直接跳转,不必先回首页找入口。
class _LibrariesNav extends StatelessWidget {
  const _LibrariesNav({required this.libraries});

  final List<MediaItem> libraries;

  static IconData _iconFor(MediaItem library) =>
      switch (library.collectionTypeNormalized) {
        'movies' => AppIcons.movie,
        'tvshows' => AppIcons.series,
        'photos' => AppIcons.photoLibrary,
        'music' => AppIcons.music,
        'boxsets' => AppIcons.boxSet,
        _ => AppIcons.library,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Builder(
      builder: (context) => _NavTextButton(
        buttonKey: AppShell.librariesNavKey,
        label: l10n.libraries,
        icon: AppIcons.library,
        selected: false,
        trailing: AppIcons.chevronDown,
        onPressed: () async {
          final box = context.findRenderObject()! as RenderBox;
          final origin = box.localToGlobal(Offset(0, box.size.height));
          final picked = await showAppMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(origin.dx, origin.dy, 0, 0),
            constraints: const BoxConstraints(maxWidth: 280),
            items: [
              for (final library in libraries)
                AppMenuEntry(
                  key: AppShell.libraryNavEntryKey(library.id),
                  value: library.id,
                  child: Row(
                    children: [
                      Icon(
                        _iconFor(library),
                        size: 18,
                        fill: AppIcons.filled,
                        color: AppUiTheme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          library.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.start,
                          style: AppUiTheme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: AppUiTheme.of(context)
                                    .colorScheme
                                    .onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
          if (picked != null && context.mounted) {
            context.push(AppRoutes.library(picked));
          }
        },
      ),
    );
  }
}

class _NavTextButton extends StatelessWidget {
  const _NavTextButton({
    required this.buttonKey,
    required this.label,
    this.icon,
    this.trailing,
    required this.selected,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final IconData? icon;
  final IconData? trailing;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colorScheme = theme.colorScheme;
    final fg = selected ? colorScheme.onSurface : colorScheme.onSurfaceVariant;
    final light = colorScheme.brightness == Brightness.light;
    return AppButton(
      key: buttonKey,
      onPressed: onPressed,
      style: AppButtonStyle(
        foregroundColor: fg,
        // 选中底由内部 pill 表达,选中项悬停不再叠一层;未选中项悬停给一层
        // 极浅的底面,作为唯一的可点反馈。
        hoverColor: selected
            ? const Color(0x00000000)
            : colorScheme.onSurface.withValues(alpha: 0.05),
        textStyle: theme.textTheme.titleMedium?.copyWith(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        minimumSize: const Size(44, kWindowChromeHeight),
      ),
      variant: AppButtonVariant.plain,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        // 浅色顶栏是纸面:选中项用白色药丸加细边与轻影,像分段控件一样
        // 浮起来;深色保持抬高一档的表面色。
        decoration: BoxDecoration(
          color: selected
              ? (light
                    ? colorScheme.surfaceContainerLowest
                    : colorScheme.surfaceContainerHigh)
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: selected && light
              ? Border.all(color: colorScheme.outlineVariant)
              : null,
          boxShadow: selected && light
              ? const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 6,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 18,
                fill: selected ? AppIcons.filled : AppIcons.outline,
                color: selected ? colorScheme.primary : fg,
              ),
              const SizedBox(width: 6),
            ],
            Text(label),
            if (trailing != null) ...[
              const SizedBox(width: 2),
              Icon(trailing, size: 18, color: fg),
            ],
          ],
        ),
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
    required this._parent,
    required super.routingConfig,
  }) : super.routingConfig(
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
