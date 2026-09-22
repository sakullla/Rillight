import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/library_nav_dialog.dart';
import 'package:rillight/home/library_nav_prefs.dart';
import 'package:rillight/search/search_action.dart';
import 'package:rillight/search/search_overlay.dart';

class HomeScrollNotification extends Notification {
  const HomeScrollNotification(this.scrolled);
  final bool scrolled;
}

/// 全局外壳:半透明顶栏叠在全幅内容上,无常驻左栏。
///
/// 已登录时 [child] 铺满窗口,顶栏 Positioned 叠在上缘,hero/backdrop 可贴到窗口顶。
/// 顶栏左侧为首页与 [CatalogScope.libraries] 各库名,放不下的库进入溢出;
/// 右侧为搜索与 [SessionActions]。搜索打开不透明覆盖层,不 push `/search`
/// 页壳;覆盖层之下叠 [SearchOverlayBarrier],点击遮罩等同关闭。
/// 登录前的 /connect 页没有导航意义,不显示顶栏。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const topBarKey = Key('app-shell-top-bar');
  static const homeNavKey = Key('app-shell-home');
  static const overflowNavKey = Key('app-shell-libraries-overflow');
  static const customizeNavKey = Key('app-shell-customize-nav');
  static const customizeNavValue = '__customize_nav__';
  static const moreLibrariesKey = Key('app-shell-more-libraries');
  static const moreLibrariesValue = '__more_libraries__';

  /// 未自定义时顶栏默认展示的库名数,多出的进溢出。
  static const maxVisibleLibraries = 5;

  /// 自定义导航最多勾选的库数;顶栏放不下的仍进 ⋯。
  static const maxPinnedLibraries = 20;

  /// ⋯ 菜单一次列出的库名数,多出的进「更多」。
  static const maxOverflowMenuLibraries = 5;

  static Key libraryNavKey(String id) => Key('app-shell-library-$id');

  /// 顶栏内容行高;有窗口铬时不低于标题按钮带。
  static const topBarHeight = 56.0;

  /// 顶栏下沿溶进画面的渐变高度,避免硬分割线切开海报。
  static const topFadeHeight = 36.0;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _searchOpen = false;
  final FocusNode _searchQueryFocus = FocusNode();
  final FocusNode _searchButtonFocus = FocusNode();
  FocusNode? _searchReturnFocus;
  bool _contentScrolled = false;
  String _scrollPath = '';

  @override
  void dispose() {
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

    return SearchOverlayController(
      isOpen: _searchOpen,
      open: _openSearch,
      close: _closeSearch,
      child: CallbackShortcuts(
        bindings: {
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
                  child: widget.child,
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _TopBar(
                    location: location,
                    opaque:
                        !_immersiveTopBar(location) || _barScrolled(location),
                    searchFocus: _searchButtonFocus,
                  ),
                ),
                // 遮罩在顶栏之上、覆盖层之下:压暗整个背景并拦截穿透
                // 覆盖层非交互区域的点击,点击等同关闭;关闭后立即恢复。
                SearchOverlayBarrier(
                  visible: _searchOpen,
                  onDismiss: _closeSearch,
                ),
                if (_searchOpen)
                  SearchOverlay(
                    queryFocusNode: _searchQueryFocus,
                    onClose: _closeSearch,
                  ),
              ],
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
  });

  final String location;
  final bool opaque;
  final FocusNode searchFocus;

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
        switch (location) {
          AppRoutes.settings => l10n.settings,
          AppRoutes.search => l10n.search,
          AppRoutes.shelfResume => l10n.resumeRow,
          AppRoutes.shelfNextUp => l10n.nextUpRow,
          AppRoutes.shelfLatestMovies => l10n.latestMoviesRow,
          AppRoutes.shelfLatestSeries => l10n.latestSeriesRow,
          _ => l10n.details,
        };
    final scrim = Theme.of(context).colorScheme.scrim;
    final overlayHeight = height + AppShell.topFadeHeight;
    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
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
                    stops: AppScrim.topBarStops,
                    colors: [
                      scrim.withValues(
                        alpha: opaque
                            ? 0.98
                            : AppScrim.of(context, AppScrim.topBar),
                      ),
                      scrim.withValues(
                        alpha: opaque
                            ? 0.94
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
                  if (canPop || location != AppRoutes.home)
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
                        onPressed: () =>
                            canPop ? context.pop() : context.go(AppRoutes.home),
                        icon: Icon(
                          canPop
                              ? Icons.arrow_back_rounded
                              : Icons.home_outlined,
                        ),
                      ),
                    ),
                  if (AppRoutes.showsBrowseNav(location)) ...[
                    _HomeNav(selected: location == AppRoutes.home),
                    Expanded(
                      child: _LibraryNav(
                        libraries: libraries,
                        location: location,
                      ),
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

class _LibraryNav extends StatelessWidget {
  const _LibraryNav({required this.libraries, required this.location});

  final List<EmbyItem> libraries;
  final String location;

  static const _overflowWidth = 48.0;

  @override
  Widget build(BuildContext context) {
    if (libraries.isEmpty) {
      return const SizedBox.shrink();
    }
    final nav = LibraryNavScope.maybeOf(context);
    return ListenableBuilder(
      listenable: nav ?? _IgnoredListenable(),
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final arranged = (nav ?? LibraryNavController()).layout(
              libraries,
              maxPinned: (nav?.customized ?? false)
                  ? AppShell.maxPinnedLibraries
                  : AppShell.maxVisibleLibraries,
            );
            var visible = arranged.pinned;
            var overflow = arranged.overflow;
            final style = Theme.of(context).textTheme.titleMedium;
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : double.infinity;
            while (visible.isNotEmpty) {
              var total = _overflowWidth;
              for (final library in visible) {
                total += _navLabelWidth(context, library.name, style);
              }
              if (total <= maxWidth) {
                break;
              }
              overflow = [visible.last, ...overflow];
              visible = visible.sublist(0, visible.length - 1);
            }
            // ⋯ 只列顶栏放不下的库,一次最多 5 条,避免和已显示的重复、菜单过长。
            final menuShown =
                overflow.length <= AppShell.maxOverflowMenuLibraries
                ? overflow
                : overflow.take(AppShell.maxOverflowMenuLibraries).toList();
            final menuRest =
                overflow.length <= AppShell.maxOverflowMenuLibraries
                ? const <EmbyItem>[]
                : overflow.sublist(AppShell.maxOverflowMenuLibraries);
            return Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final library in visible)
                          _NavTextButton(
                            buttonKey: AppShell.libraryNavKey(library.id),
                            label: library.name,
                            selected: location == AppRoutes.library(library.id),
                            onPressed: () {
                              if (GoRouterState.of(context).uri.path !=
                                  AppRoutes.library(library.id)) {
                                context.push(AppRoutes.library(library.id));
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  key: AppShell.overflowNavKey,
                  tooltip: AppLocalizations.of(context).libraries,
                  constraints: const BoxConstraints(
                    minWidth: 168,
                    maxWidth: 280,
                    maxHeight: 360,
                  ),
                  padding: EdgeInsets.zero,
                  splashRadius: 18,
                  iconSize: 18,
                  iconColor: Theme.of(context).colorScheme.onSurface,
                  style: IconButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(40, kWindowChromeHeight),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (id) {
                    if (id == AppShell.customizeNavValue) {
                      if (nav != null) {
                        unawaited(
                          showLibraryNavDialog(
                            context: context,
                            libraries: libraries,
                            nav: nav,
                            maxPinned: AppShell.maxPinnedLibraries,
                          ),
                        );
                      }
                      return;
                    }
                    if (id == AppShell.moreLibrariesValue) {
                      unawaited(() async {
                        final picked = await showMoreLibrariesDialog(
                          context: context,
                          libraries: menuRest,
                        );
                        if (picked == null || !context.mounted) {
                          return;
                        }
                        if (GoRouterState.of(context).uri.path !=
                            AppRoutes.library(picked)) {
                          context.push(AppRoutes.library(picked));
                        }
                      }());
                      return;
                    }
                    if (GoRouterState.of(context).uri.path !=
                        AppRoutes.library(id)) {
                      context.push(AppRoutes.library(id));
                    }
                  },
                  itemBuilder: (context) => [
                    for (final library in menuShown)
                      PopupMenuItem(
                        value: library.id,
                        child: Text(library.name),
                      ),
                    if (menuRest.isNotEmpty)
                      PopupMenuItem(
                        key: AppShell.moreLibrariesKey,
                        value: AppShell.moreLibrariesValue,
                        child: Text(AppLocalizations.of(context).more),
                      ),
                    if (menuShown.isNotEmpty) const PopupMenuDivider(),
                    PopupMenuItem(
                      key: AppShell.customizeNavKey,
                      value: AppShell.customizeNavValue,
                      child: Text(AppLocalizations.of(context).customizeNav),
                    ),
                  ],
                ),
              ],
            );
          },
        );
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

double _navLabelWidth(BuildContext context, String label, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width + AppSpacing.xl + AppSpacing.md;
  painter.dispose();
  return width;
}

class _IgnoredListenable extends ChangeNotifier {}
