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
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/home/catalog_shell.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/item_detail_page.dart';

import 'package:rillight/home/phone_home_edit_page.dart';

import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/aggregation/query/aggregation_query.dart'
    show QueryMode;
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';

import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_window_host.dart';
import 'source_route_extra_codec.dart';

import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/library/tv_detail_page.dart';

import 'package:rillight/player/tv_player_page.dart';

export 'package:rillight/app/routes.dart';

GoRouter createAppRouter({
  required AuthController auth,
  PresentationEnvironment environment = PresentationEnvironment.desktop,
}) {
  late final GoRouter router;
  router = GoRouter(
    initialLocation: AppRoutes.home,
    extraCodec: const SourceRouteExtraCodec(),
    observers: [_ConnectFlowObserver(auth)],
    refreshListenable: Listenable.merge([auth, auth.regionAccess]),
    redirect: (context, state) {
      final loggedIn = auth.isLoggedIn;
      final onConnect = state.matchedLocation == AppRoutes.connect;
      var authorizedPlayer = false;
      var playerState = state;
      final committed = router.routerDelegate.currentConfiguration;
      if (committed.isNotEmpty &&
          committed.uri == state.uri &&
          router.state.uri.path.startsWith('/play/')) {
        // A pushed player has its own match/extra. Refreshing selected Auth
        // reparses the base detail URI, not that independent top route.
        playerState = router.state;
      }
      final request = playerState.extra;
      final runtime = context
          .getInheritedWidgetOfExactType<PlayerScope>()
          ?.bindings
          .runtime;
      final mountedPlayer =
          runtime?.hasMountedPlayer(playerState.pageKey) == true;
      if (playerState.uri.path.startsWith('/play/') && mountedPlayer) {
        // Immutable extra is startup intent, not ownership after switching.
        // Only this mounted controller's actual runtime lease counts.
        authorizedPlayer =
            runtime!.mountedPlayerOrigin(playerState.pageKey)?.permit.isValid ==
            true;
      } else if (playerState.uri.path.startsWith('/play/') &&
          request is PlayerOpenRequest &&
          request.source != null &&
          request.source!.itemId == request.itemId &&
          request.libraryId != null &&
          request.libraryId!.isNotEmpty) {
        try {
          // Selected Auth owns catalog chrome, not an independent actual-source
          // player. Losing B must not destroy A's still-authorized playback.
          // Runtime still proves item ancestry; unknown/legacy routes get no
          // exception to login and revoked A permits cannot use this path.
          final permit = auth.sources.permit(
            request.source!.account,
            libraryId: request.libraryId,
          );
          authorizedPlayer =
              permit.isValid &&
              (request.source!.account.region != AccessRegion.private ||
                  request.regionGeneration == permit.regionGeneration);
        } catch (_) {
          // Invalid account/scope is not an alternate authentication fallback.
        }
      }
      if (!loggedIn && !onConnect && !authorizedPlayer) {
        return AppRoutes.connect;
      }
      if (playerState.uri.path.startsWith('/play/') &&
          request is PlayerOpenRequest &&
          request.source != null &&
          !authorizedPlayer) {
        return environment.isDesktop ? AppRoutes.aggregation : AppRoutes.home;
      }
      if (loggedIn && onConnect && state.uri.queryParameters['add'] != '1') {
        return AppRoutes.home;
      }
      final command = state.extra;
      if (!authorizedPlayer &&
          command is PlayerHostOpenItemCommand &&
          command.source != null &&
          (AppRoutes.isItem(state.uri.path) ||
              state.uri.path.startsWith('/shelf/'))) {
        try {
          final permit = auth.sources.permit(
            command.source!.account,
            libraryId: command.libraryId,
          );
          if (!permit.isValid ||
              command.regionGeneration != permit.regionGeneration) {
            return environment.isDesktop
                ? AppRoutes.aggregation
                : AppRoutes.home;
          }
        } catch (_) {
          return environment.isDesktop ? AppRoutes.aggregation : AppRoutes.home;
        }
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
            // The catalog invalidates selected-session data itself. Preserve
            // the Navigator and independent source-bound playback on selection.
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
                      routeLeaseKey: state.pageKey,
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
              path: '/private',
              builder: (context, state) =>
                  const RegionAggregationGate(region: AccessRegion.private),
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
                child: AggregationPage(
                  key: ValueKey(state.uri.toString()),
                  legacyLibraryId: state.pathParameters['viewId']!,
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
                child: _shelfAggregation(auth, state),
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
            // As on phone, selection is not ownership of the active player.
            auth: auth,
            child: child,
          ),
          routes: [
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const TvShell(),
            ),
            GoRoute(
              path: '/private',
              builder: (context, state) =>
                  const RegionAggregationGate(region: AccessRegion.private),
            ),
            GoRoute(
              path: '/library/:viewId',
              builder: (context, state) => AggregationPage(
                key: ValueKey(state.uri.toString()),
                legacyLibraryId: state.pathParameters['viewId']!,
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              builder: (context, state) => _shelfAggregation(auth, state),
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
                    routeLeaseKey: state.pageKey,
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
              path: '/private',
              pageBuilder: (context, state) => _desktopPage(
                state,
                const RegionAggregationGate(region: AccessRegion.private),
              ),
            ),
            GoRoute(
              path: '/library/:viewId',
              pageBuilder: (context, state) => _desktopPage(
                state,
                AggregationPage(
                  key: ValueKey(state.uri.toString()),
                  legacyLibraryId: state.pathParameters['viewId'] ?? '',
                ),
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              pageBuilder: (context, state) =>
                  _desktopPage(state, _shelfAggregation(auth, state)),
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
              path: AppRoutes.aggregation,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const AggregationPage()),
            ),
            GoRoute(
              path: AppRoutes.search,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const AggregationPage(search: true)),
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
  return router;
}

Widget _shelfAggregation(AuthController auth, GoRouterState state) {
  final command = state.extra is PlayerHostOpenItemCommand
      ? state.extra as PlayerHostOpenItemCommand
      : null;
  if (command != null &&
      (command.source == null || command.libraryId == null)) {
    return const SizedBox.shrink();
  }
  final source = state.pathParameters['source'];
  final query = state.uri.queryParameters;
  final child = AggregationPage(
    key: ValueKey((
      state.uri.toString(),
      command?.source,
      command?.regionGeneration,
    )),
    region: command?.source?.account.region ?? AccessRegion.ordinary,
    sourceCommand: command,
    legacySelected: command == null,
    legacyLibraryId: command == null ? query['parentId'] : null,
    initialGenre: query['genre'] ?? '',
    initialType: source == 'latest-movies'
        ? 'Movie'
        : source == 'latest-series'
        ? 'Series'
        : source == 'nextup'
        ? 'Episode'
        : const {'Movie', 'Series'}.contains(query['includeItemTypes'])
        ? query['includeItemTypes']
        : null,
    initialMode: source == 'nextup'
        ? QueryMode.nextUp
        : source == 'resume'
        ? QueryMode.continueWatching
        : source == 'latest-movies' || source == 'latest-series'
        ? QueryMode.recent
        : QueryMode.browse,
  );
  if (command == null) return child;
  return SourceDetailGate(
    key: ValueKey((
      state.uri.toString(),
      command.source,
      command.regionGeneration,
    )),
    auth: auth,
    itemId: command.itemId,
    command: command,
    showComparison: false,
    child: child,
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
