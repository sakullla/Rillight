import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/home/catalog_shell.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/search/search_page.dart';

export 'package:rillight/app/routes.dart';

GoRouter createAppRouter({required AuthController auth}) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: auth,
    redirect: (context, state) {
      final loggedIn = auth.isLoggedIn;
      final onConnect = state.matchedLocation == AppRoutes.connect;
      if (!loggedIn && !onConnect) {
        return AppRoutes.connect;
      }
      if (loggedIn && onConnect && state.uri.queryParameters['add'] != '1') {
        return AppRoutes.home;
      }
      return null;
    },
    routes: [
      ShellRoute(
        observers: [_ConnectFlowObserver(auth)],
        builder: (context, state, child) {
          return CatalogShell(
            auth: auth,
            child: AppShell(child: child),
          );
        },
        routes: [
          GoRoute(
            path: AppRoutes.connect,
            builder: (context, state) => const ConnectPage(),
          ),
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const HomePage(),
          ),
          GoRoute(
            path: '/library/:viewId',
            builder: (context, state) =>
                LibraryPage(viewId: state.pathParameters['viewId'] ?? ''),
          ),
          GoRoute(
            path: '/shelf/:source',
            builder: (context, state) => ShelfGridPage.fromState(state),
          ),
          GoRoute(
            path: '/item/:itemId',
            builder: (context, state) => ItemDetailPage(
              itemId: state.pathParameters['itemId'] ?? '',
              initialSeasonId: state.uri.queryParameters['season'],
            ),
          ),
          GoRoute(
            path: AppRoutes.search,
            builder: (context, state) => const SearchPage(),
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const SettingsPage(),
          ),
        ],
      ),
    ],
  );
}

/// Navigator removals end a connection flow; refreshes and widget rebuilds do not.
class _ConnectFlowObserver extends NavigatorObserver {
  _ConnectFlowObserver(this.auth);

  final AuthController auth;

  void _endFlow(Route<dynamic> route) {
    if (route.settings.name == AppRoutes.connect) {
      auth.connectDraft = null;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _endFlow(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _endFlow(route);
  }
}
