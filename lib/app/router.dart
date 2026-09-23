import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/home/catalog_shell.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/search/search_page.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_window_host.dart';

import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/player/tv_player_page.dart';

export 'package:rillight/app/routes.dart';

GoRouter createAppRouter({
  required AuthController auth,
  PresentationEnvironment environment = PresentationEnvironment.desktop,
}) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    observers: [_ConnectFlowObserver(auth)],
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
      if (!environment.isDesktop && !environment.isTv) ...[
        GoRoute(
          path: AppRoutes.connect,
          name: AppRoutes.connect,
          builder: (context, state) => AndroidConnectPage(
            addingAnother: state.uri.queryParameters['add'] == '1',
          ),
        ),
        ShellRoute(
          builder: (context, state, child) => CatalogShell(
            key: ValueKey(
              '${auth.session?.server.id}|${auth.session?.userId}|${auth.session?.server.activeLine?.id}',
            ),
            auth: auth,
            child: child,
          ),
          routes: [
            // Keep detail and playback on one Navigator: an underlying shell
            // route otherwise remains current for Android predictive back.
            GoRoute(
              path: '/play/:itemId',
              builder: (context, state) {
                final request = state.extra as PlayerOpenRequest?;
                return MobilePlayerPage(
                  itemId: state.pathParameters['itemId']!,
                  mediaSourceId: request?.mediaSourceId,
                  autoResume: request?.autoResume ?? true,
                  audioStreamIndex: request?.audioStreamIndex,
                  subtitleStreamIndex: request?.subtitleStreamIndex,
                );
              },
            ),
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const MobileShell(),
            ),
            GoRoute(
              path: AppRoutes.mine,
              builder: (context, state) => const PhoneMinePage(),
            ),
            GoRoute(
              path: '/library/:viewId',
              builder: (context, state) =>
                  MobileLibraryPage(viewId: state.pathParameters['viewId']!),
            ),
            GoRoute(
              path: '/item/:itemId',
              builder: (context, state) => MobileDetailPage(
                itemId: state.pathParameters['itemId']!,
                initialSeasonId: state.uri.queryParameters['season'],
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              builder: (context, state) => PhoneShelfPage.fromState(state),
            ),
          ],
        ),
      ],
      if (environment.isTv) ...[
        GoRoute(
          path: AppRoutes.connect,
          name: AppRoutes.connect,
          builder: (context, state) => TvConnectPage(
            addingAnother: state.uri.queryParameters['add'] == '1',
          ),
        ),
        ShellRoute(
          builder: (context, state, child) => CatalogShell(
            key: ValueKey(
              '${auth.session?.server.id}|${auth.session?.userId}|${auth.session?.server.activeLine?.id}',
            ),
            auth: auth,
            child: child,
          ),
          routes: [
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const TvShell(),
            ),
            GoRoute(
              path: '/library/:viewId',
              builder: (context, state) =>
                  TvLibraryPage(viewId: state.pathParameters['viewId']!),
            ),
            GoRoute(
              path: '/item/:itemId',
              builder: (context, state) => TvDetailPage(
                itemId: state.pathParameters['itemId']!,
                initialSeasonId: state.uri.queryParameters['season'],
              ),
            ),
            GoRoute(
              path: '/play/:itemId',
              builder: (context, state) {
                final request = state.extra as PlayerOpenRequest?;
                return TvPlayerPage(
                  itemId: state.pathParameters['itemId']!,
                  mediaSourceId: request?.mediaSourceId,
                  autoResume: request?.autoResume ?? true,
                );
              },
            ),
          ],
        ),
      ],
      if (environment.isDesktop)
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
