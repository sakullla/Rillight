import 'package:flutter/material.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/app/theme.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/desktop_scroll.dart';
import 'package:rillight/app/mobile_motion.dart';
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
import 'package:rillight/home/phone_home_edit_page.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/search/search_page.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_window_host.dart';

import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/home/tv_shelf_page.dart';
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
          pageBuilder: (context, state) => PhoneMotion.fadeThroughPage(
            context: context,
            state: state,
            child: AndroidConnectPage(
              addingAnother: state.uri.queryParameters['add'] == '1',
            ),
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
              pageBuilder: (context, state) {
                final request = state.extra as PlayerOpenRequest?;
                return PhoneMotion.fadeThroughPage(
                  context: context,
                  state: state,
                  child: Theme(
                    data: AppTheme.dark(),
                    child: MobilePlayerPage(
                      sourceRequest: request,
                      itemId: state.pathParameters['itemId']!,
                      mediaSourceId: request?.mediaSourceId,
                      autoResume: request?.autoResume ?? true,
                      audioStreamIndex: request?.audioStreamIndex,
                      subtitleStreamIndex: request?.subtitleStreamIndex,
                    ),
                  ),
                );
              },
            ),
            GoRoute(
              path: AppRoutes.home,
              pageBuilder: (context, state) => PhoneMotion.fadeThroughPage(
                context: context,
                state: state,
                child: const MobileShell(),
              ),
            ),
            GoRoute(
              path: AppRoutes.mine,
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: const PhoneMinePage(),
              ),
            ),
            GoRoute(
              path: AppRoutes.homeEdit,
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: const PhoneHomeEditPage(),
              ),
            ),
            GoRoute(
              path: '/library/:viewId',
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: MobileLibraryPage(
                  viewId: state.pathParameters['viewId']!,
                ),
              ),
            ),
            GoRoute(
              path: '/item/:itemId',
              pageBuilder: (context, state) => PhoneMotion.detailPage(
                context: context,
                state: state,
                child: _sourceDetail(
                  auth,
                  state,
                  MobileDetailPage(
                    key: ValueKey(state.uri.toString()),
                    itemId: state.pathParameters['itemId']!,
                    initialSeasonId: state.uri.queryParameters['season'],
                    initialEpisodeId: state.uri.queryParameters['episode'],
                  ),
                ),
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: PhoneShelfPage.fromState(state),
              ),
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
              path: '/shelf/:source',
              builder: (context, state) {
                final source = state.pathParameters['source'] ?? '';
                if (TvShelfPage.handles(source)) {
                  return TvShelfPage.fromState(state);
                }
                final query = state.uri.queryParameters;
                return TvLibraryPage(
                  viewId: query['parentId'] ?? '',
                  initialGenre: query['genre'],
                  initialType: query['includeItemTypes'],
                );
              },
            ),
            GoRoute(
              path: '/item/:itemId',
              builder: (context, state) => _sourceDetail(
                auth,
                state,
                TvDetailPage(
                  key: ValueKey(state.uri.toString()),
                  itemId: state.pathParameters['itemId']!,
                  initialSeasonId: state.uri.queryParameters['season'],
                ),
              ),
            ),
            GoRoute(
              path: '/play/:itemId',
              builder: (context, state) {
                final request = state.extra as PlayerOpenRequest?;
                return Theme(
                  data: AppTheme.dark(),
                  child: TvPlayerPage(
                    sourceRequest: request,
                    itemId: state.pathParameters['itemId']!,
                    mediaSourceId: request?.mediaSourceId,
                    autoResume: request?.autoResume ?? true,
                  ),
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
              pageBuilder: (context, state) =>
                  _desktopPage(state, const ConnectPage()),
            ),
            GoRoute(
              path: AppRoutes.home,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const HomePage()),
            ),
            GoRoute(
              path: '/library/:viewId',
              pageBuilder: (context, state) => _desktopPage(
                state,
                LibraryPage(viewId: state.pathParameters['viewId'] ?? ''),
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              pageBuilder: (context, state) =>
                  _desktopPage(state, ShelfGridPage.fromState(state)),
            ),
            GoRoute(
              path: '/item/:itemId',
              pageBuilder: (context, state) => _desktopPage(
                state,
                _sourceDetail(
                  auth,
                  state,
                  ItemDetailPage(
                    itemId: state.pathParameters['itemId'] ?? '',
                    initialSeasonId: state.uri.queryParameters['season'],
                  ),
                ),
              ),
            ),
            GoRoute(
              path: AppRoutes.search,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const SearchPage()),
            ),
            GoRoute(
              path: AppRoutes.settings,
              pageBuilder: (context, state) => _desktopPage(
                state,
                SettingsPage(
                  settingsStore: PlayerScope.of(context).settingsStore,
                ),
              ),
            ),
          ],
        ),
    ],
  );
}

Widget _sourceDetail(AuthController auth, GoRouterState state, Widget child) {
  final command = state.extra is PlayerHostOpenItemCommand
      ? state.extra as PlayerHostOpenItemCommand
      : null;
  return SourceDetailGate(
    key: ValueKey((
      state.uri.toString(),
      command?.source,
      command?.regionGeneration,
    )),
    auth: auth,
    itemId: state.pathParameters['itemId']!,
    command: command,
    child: child,
  );
}

// Desktop navigation replaces the page directly. Mobile-style full-page
// fade/zoom transitions composite two poster trees on every animation frame,
// competing with scrolling and image uploads on shared-memory GPUs.
NoTransitionPage<void> _desktopPage(GoRouterState state, Widget child) =>
    NoTransitionPage<void>(
      key: state.pageKey,
      name: state.name ?? state.matchedLocation,
      arguments: state.extra,
      child: DesktopScrollScope(child: child),
    );

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
