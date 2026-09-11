import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/home/catalog_shell.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/search/search_action.dart';
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
      if (loggedIn && onConnect) {
        return AppRoutes.home;
      }
      return null;
    },
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return CatalogShell(
            auth: auth,
            child: AppShell(
              actions: const [
                SearchAction(),
                LibrariesAction(),
                SessionActions(),
              ],
              child: child,
            ),
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
            builder: (context, state) =>
                ItemDetailPage(itemId: state.pathParameters['itemId'] ?? ''),
          ),
          GoRoute(
            path: AppRoutes.search,
            builder: (context, state) => const SearchPage(),
          ),
        ],
      ),
      GoRoute(
        path: '/play/:itemId',
        builder: (context, state) => PlayerPage(
          itemId: state.pathParameters['itemId'] ?? '',
          autoResume: state.uri.queryParameters['resume'] == '1',
        ),
      ),
    ],
  );
}
