import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/search/search_action.dart';

/// 全局外壳:侧边导航 + 内容区,无全局 AppBar。
///
/// 侧栏承载 首页/媒体库/搜索 导航,会话菜单([SessionActions])与收起按钮
/// 固定在侧栏底部;收起后侧栏隐藏,内容区左上角悬浮展开按钮。
/// 内容区直接渲染 [child],页面自管滚动与顶部。
/// 登录前的 /connect 页没有导航意义,不显示侧栏。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  /// 收起/展开导航按钮的测试 Key。
  static const railToggle = Key('app-shell-rail-toggle');

  static const _libraryPrefix = '/library';

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    // 注意:ShellRoute builder 的 context 上 GoRouterState.matchedLocation
    // 是外壳自身的匹配(恒为 '/'),只有 uri 反映 push 进来的当前子路由。
    final location = GoRouterState.of(context).uri.path;
    if (location == AppRoutes.connect) {
      return Scaffold(body: widget.child);
    }

    final l10n = AppLocalizations.of(context);
    final extended = MediaQuery.sizeOf(context).width >= AppBreakpoints.large;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            children: [
              if (!_collapsed) ...[
                NavigationRail(
                  extended: extended,
                  labelType: NavigationRailLabelType.none,
                  selectedIndex: _selectedIndex(location),
                  onDestinationSelected: (index) =>
                      _onDestination(context, index),
                  destinations: [
                    NavigationRailDestination(
                      icon: const Icon(Icons.home_outlined),
                      selectedIcon: const Icon(Icons.home),
                      label: Text(l10n.home),
                    ),
                    NavigationRailDestination(
                      icon: const Icon(Icons.video_library_outlined),
                      selectedIcon: const Icon(Icons.video_library),
                      label: Text(l10n.libraries),
                    ),
                    NavigationRailDestination(
                      icon: const SearchAction(),
                      label: Text(l10n.search),
                    ),
                  ],
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: AppShell.railToggle,
                        tooltip: l10n.collapseNav,
                        onPressed: () => setState(() => _collapsed = true),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      const SessionActions(),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
              ],
              Expanded(child: widget.child),
            ],
          ),
          if (_collapsed)
            Positioned(
              left: AppSpacing.sm,
              top: AppSpacing.sm,
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.scrim.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: IconButton(
                  key: AppShell.railToggle,
                  tooltip: l10n.expandNav,
                  onPressed: () => setState(() => _collapsed = false),
                  icon: const Icon(Icons.menu),
                ),
              ),
            ),
        ],
      ),
    );
  }

  int? _selectedIndex(String location) {
    if (location == AppRoutes.home) {
      return 0;
    }
    if (location.startsWith(AppShell._libraryPrefix)) {
      return 1;
    }
    if (location == AppRoutes.search) {
      return 2;
    }
    return null;
  }

  void _onDestination(BuildContext context, int index) {
    switch (index) {
      case 0:
        context.go(AppRoutes.home);
      case 1:
        _openLibrary(context);
      case 2:
        openSearch(context);
    }
  }

  void _openLibrary(BuildContext context) {
    if (GoRouterState.of(
      context,
    ).uri.path.startsWith(AppShell._libraryPrefix)) {
      return;
    }
    final libraries = CatalogScope.maybeOf(context)?.libraries;
    if (libraries == null || libraries.isEmpty) {
      context.go(AppRoutes.home);
      return;
    }
    context.push(AppRoutes.library(libraries.first.id));
  }
}
