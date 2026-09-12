import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/search/search_action.dart';
import 'package:rillight/search/search_overlay.dart';

/// 全局外壳:半透明顶栏叠在全幅内容上,无常驻左栏。
///
/// 已登录时 [child] 铺满窗口,顶栏 Positioned 叠在上缘,hero/backdrop 可贴到窗口顶。
/// 顶栏左侧为首页与 [CatalogScope.libraries] 各库名,放不下的库进入溢出;
/// 右侧为搜索与 [SessionActions]。搜索打开覆盖层,不 push `/search` 页壳。
/// 登录前的 /connect 页没有导航意义,不显示顶栏。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const topBarKey = Key('app-shell-top-bar');
  static const homeNavKey = Key('app-shell-home');
  static const overflowNavKey = Key('app-shell-libraries-overflow');

  static Key libraryNavKey(String id) => Key('app-shell-library-$id');

  /// 顶栏内容行高;有窗口铬时不低于标题按钮带。
  static const topBarHeight = 48.0;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _searchOpen = false;
  final FocusNode _searchQueryFocus = FocusNode();

  @override
  void dispose() {
    _searchQueryFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    if (_searchOpen) {
      _searchQueryFocus.requestFocus();
      return;
    }
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
                widget.child,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _TopBar(location: location),
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
  const _TopBar({required this.location});

  final String location;

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
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      key: AppShell.topBarKey,
      color: colorScheme.surface.withValues(alpha: 0.72),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(left: leading, right: trailing),
          child: Row(
            children: [
              _HomeNav(selected: location == AppRoutes.home),
              Expanded(
                child: _LibraryNav(libraries: libraries, location: location),
              ),
              const SearchAction(),
              const SessionActions(),
            ],
          ),
        ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = Theme.of(context).textTheme.titleSmall;
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        final widths = [
          for (final library in libraries)
            _navLabelWidth(context, library.name, style),
        ];
        var visibleCount = libraries.length;
        while (visibleCount > 0) {
          var total = 0.0;
          for (var i = 0; i < visibleCount; i++) {
            total += widths[i];
          }
          if (visibleCount < libraries.length) {
            total += _overflowWidth;
          }
          if (total <= maxWidth) {
            break;
          }
          visibleCount--;
        }
        final visible = libraries.take(visibleCount).toList();
        final overflow = libraries.skip(visibleCount).toList();
        return Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
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
                              context.go(AppRoutes.library(library.id));
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (overflow.isNotEmpty)
              PopupMenuButton<String>(
                key: AppShell.overflowNavKey,
                tooltip: AppLocalizations.of(context).libraries,
                onSelected: (id) {
                  if (GoRouterState.of(context).uri.path !=
                      AppRoutes.library(id)) {
                    context.go(AppRoutes.library(id));
                  }
                },
                itemBuilder: (context) => [
                  for (final library in overflow)
                    PopupMenuItem(value: library.id, child: Text(library.name)),
                ],
                icon: const Icon(Icons.more_horiz),
              ),
          ],
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
        textStyle: theme.textTheme.titleSmall?.copyWith(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label),
    );
  }
}

double _navLabelWidth(BuildContext context, String label, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: Directionality.of(context),
    maxLines: 1,
  )..layout();
  return painter.width + AppSpacing.xl + AppSpacing.md;
}
